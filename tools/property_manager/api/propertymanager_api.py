#!/usr/bin/env python3
from __future__ import annotations

import logging
import os
import base64
import hashlib
import json
import re
from calendar import monthrange
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from flask import Flask, Response, jsonify, request
from werkzeug.exceptions import HTTPException

import db as pm_db
import meter_schedule as ms
import task_title as tt
from assets_api import register_asset_routes
from auth import auth_required, auth_status
from decimal_utils import parse_decimal, decimal_to_db
from errors import error_response, validation_error
from mapping_proposals import register_mapping_routes
from maintenance_proposals import register_maintenance_proposal_routes
from work_requests import _sanitize_jpeg, register_work_request_routes
from handbook_api import register_handbook_routes

app = Flask(__name__)
register_maintenance_proposal_routes(app)
register_work_request_routes(app)
register_handbook_routes(app)

# The dashboard documents a 50 MiB PDF ceiling.  Keep the API boundary aligned
# so a valid manual or photo is not rejected by Flask before route validation.
MAX_UPLOAD_BYTES = int(os.environ.get("PROPERTYMANAGER_MAX_CONTENT_LENGTH", str(50 * 1024 * 1024)))
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_BYTES

ATTACHMENTS_ROOT = os.environ.get(
    "PROPERTYMANAGER_ATTACHMENTS_ROOT",
    "/mnt/ai-storage/openclaw-documents/Property/attachments",
)

logger = logging.getLogger("propertymanager_api")
EXPECTED_SCHEMA_VERSION = "014"
MAX_TASK_PHOTO_BYTES = 25 * 1024 * 1024
MAX_COMPLETION_HISTORY_ENTRIES = 100
MAX_COMPLETION_HISTORY_ENTRY_BYTES = 4 * 1024
_TASK_PHOTO_NAME_RE = re.compile(r"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\.jpg$")


def _requested_task_photo_name(file_name: object) -> str | None:
    value = str(file_name or "").strip()
    if not value or len(value) > 255 or "/" in value or "\\" in value or "\x00" in value:
        return None
    return value


def _completion_history_error(history: object) -> str | None:
    """Keep task upserts bounded even if a client retries a malformed state."""
    if not isinstance(history, list):
        return "completion_history must be an array"
    if len(history) > MAX_COMPLETION_HISTORY_ENTRIES:
        return "completion_history has too many entries"
    if any(
        not isinstance(entry, str)
        or len(entry.encode("utf-8")) > MAX_COMPLETION_HISTORY_ENTRY_BYTES
        for entry in history
    ):
        return "completion_history contains an invalid or oversized entry"
    return None


def _safe_legacy_photo_bytes(storage_path: object) -> bytes | None:
    """Read an importer-era photo only when it remains under the configured root."""
    if not storage_path:
        return None
    try:
        root = Path(ATTACHMENTS_ROOT).resolve(strict=True)
        candidate = Path(str(storage_path)).resolve(strict=True)
        if not candidate.is_file() or not candidate.is_relative_to(root):
            return None
        if candidate.stat().st_size > MAX_TASK_PHOTO_BYTES:
            return None
        return candidate.read_bytes()
    except (OSError, ValueError):
        return None


def _legacy_photo_content_type(file_name: str) -> str:
    suffix = Path(file_name).suffix.lower()
    return {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
        ".heic": "image/heic", ".heif": "image/heic", ".gif": "image/gif",
        ".webp": "image/webp", ".tif": "image/tiff", ".tiff": "image/tiff",
    }.get(suffix, "application/octet-stream")


def _add_calendar_months(value: datetime, months: int) -> datetime:
    """Advance a timestamp by whole calendar months without changing its timezone."""
    month_index = value.month - 1 + months
    year = value.year + month_index // 12
    month = month_index % 12 + 1
    return value.replace(day=min(value.day, monthrange(year, month)[1]), year=year, month=month)


def next_calendar_due(
    completed_at: datetime,
    *,
    frequency: str | None,
    warning_days: int,
) -> datetime:
    """Return the next calendar occurrence; warning days are alert thresholds, not cadence."""
    normalized = " ".join((frequency or "").casefold().split())
    day_intervals = {
        "daily": 1,
        "weekly": 7,
        "biweekly": 14,
        "every 2 weeks": 14,
    }
    if normalized in day_intervals:
        return completed_at + timedelta(days=day_intervals[normalized])
    if normalized == "monthly":
        return _add_calendar_months(completed_at, 1)
    if normalized == "quarterly":
        return _add_calendar_months(completed_at, 3)
    if normalized in {"semiannual", "semi-annually", "every 6 months"}:
        return _add_calendar_months(completed_at, 6)
    if normalized in {"annual", "annually", "yearly"}:
        return _add_calendar_months(completed_at, 12)

    every_match = re.fullmatch(
        r"every\s+(\d+)(?:\s*-\s*\d+)?\s+(day|days|week|weeks|month|months|year|years)",
        normalized,
    )
    if every_match:
        interval = int(every_match.group(1))
        unit = every_match.group(2)
        if unit.startswith("day"):
            return completed_at + timedelta(days=interval)
        if unit.startswith("week"):
            return completed_at + timedelta(days=interval * 7)
        if unit.startswith("month"):
            return _add_calendar_months(completed_at, interval)
        return _add_calendar_months(completed_at, interval * 12)

    # Legacy free-text frequencies remain deployable. Preserve their existing
    # fallback until each is normalized to an explicit cadence.
    return completed_at + timedelta(days=max(warning_days, 1))

TASK_COLUMNS = """
    id, area, item, category_name, priority, frequency,
    task_description, response_instructions, supplies_needed,
    notes, result_notes, estimated_minutes,
    warning_days, critical_days,
    last_done, next_due,
    send_telegram_update, include_in_daily_briefing,
    alert_if_overdue, is_active,
    part_url, vendor, part_number, part_cost, annual_cost,
    kind, manufacturer, source_manual_name, origin,
    asset_id, schedule_kind, meter_interval_value, meter_interval_unit,
    last_done_meter_value, next_due_meter_value,
    completion_history, tools_required,
    created_at, updated_at
"""

PATCHABLE_FIELDS = {
    "area",
    "item",
    "estimated_minutes",
    "vendor",
    "part_number",
    "part_url",
    "part_cost",
    "annual_cost",
    "notes",
    "supplies_needed",
    "task_description",
    "response_instructions",
    "manufacturer",
    "source_manual_name",
    "origin",
    "asset_id",
    "schedule_kind",
    "meter_interval_value",
    "meter_interval_unit",
    "last_done_meter_value",
    "next_due_meter_value",
}

NUMERIC_PATCH_FIELDS = {
    "part_cost",
    "annual_cost",
    "meter_interval_value",
    "last_done_meter_value",
    "next_due_meter_value",
    "estimated_minutes",
}

PART_COLUMNS = """
    id, task_id, name, oem_part_number, part_number, buy_url, cost, quantity,
    vendor, notes, sort_order, created_at, updated_at
"""

PART_UPSERT_FIELDS = {
    "name",
    "oem_part_number",
    "part_number",
    "buy_url",
    "cost",
    "quantity",
    "vendor",
    "notes",
    "sort_order",
}


def normalize_patch_value(field: str, value):
    if field in NUMERIC_PATCH_FIELDS:
        if value is None:
            return None
        # Blank string is invalid for meter fields (blank ≠ 0); other numerics may clear via "".
        if value == "":
            if field in {
                "meter_interval_value",
                "last_done_meter_value",
                "next_due_meter_value",
            }:
                raise ValueError(f"{field} must be a decimal number (blank is not zero)")
            return None
        try:
            if field in {
                "meter_interval_value",
                "last_done_meter_value",
                "next_due_meter_value",
            }:
                return ms.parse_optional_meter_decimal(value, field=field)
            if field == "estimated_minutes":
                return int(value)
            return float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{field} must be a number") from exc

    if field == "schedule_kind":
        text = str(value or "").strip().lower()
        if text not in ms.SCHEDULE_KINDS:
            raise ValueError(f"schedule_kind must be one of {sorted(ms.SCHEDULE_KINDS)}")
        return text

    if field == "origin":
        text = str(value or "").strip().lower()
        if text in {"manufacturer", "owner"}:
            return text
        raise ValueError("origin must be 'manufacturer' or 'owner'")

    if value is None:
        return None
    text = str(value).strip()
    return text or None


def normalize_origin(value) -> str:
    text = str(value or "").strip().lower()
    if text in {"manufacturer", "owner"}:
        return text
    return "owner"


def fetch_asset_name(asset_id: str) -> str | None:
    row = pm_db.execute_one_json(
        """
        SELECT name
        FROM propertymanager.assets
        WHERE id = %s AND is_active = true
        """,
        (asset_id,),
    )
    if row is None:
        return None
    name = row.get("name")
    return str(name).strip() if name else None


def normalize_written_task_title(*, area: str, item: str, asset_id) -> tuple[str, str]:
    return tt.normalize_task_area_and_item(
        area=area,
        item=item,
        asset_id=asset_id,
        fetch_asset_name=fetch_asset_name,
    )


def normalize_part_payload(raw: dict, *, sort_order: int) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("Each part must be an object")

    unknown = sorted(set(raw) - PART_UPSERT_FIELDS - {"id"})
    if unknown:
        raise ValueError(f"Unsupported part fields: {', '.join(unknown)}")

    def text_field(key: str, default: str = "") -> str:
        value = raw.get(key, default)
        if value is None:
            return default
        return str(value).strip()

    cost_raw = raw.get("cost", 0)
    if cost_raw is None or cost_raw == "":
        cost = 0.0
    else:
        try:
            cost = float(cost_raw)
        except (TypeError, ValueError) as exc:
            raise ValueError("cost must be a number") from exc

    quantity_raw = raw.get("quantity", 1)
    if quantity_raw is None or quantity_raw == "":
        quantity = 1.0
    else:
        try:
            quantity = float(quantity_raw)
        except (TypeError, ValueError) as exc:
            raise ValueError("quantity must be a number") from exc
    if quantity <= 0:
        raise ValueError("quantity must be greater than zero")

    sort_raw = raw.get("sort_order", sort_order)
    try:
        sort_value = int(sort_raw if sort_raw is not None else sort_order)
    except (TypeError, ValueError) as exc:
        raise ValueError("sort_order must be an integer") from exc

    part_id = raw.get("id")
    if part_id is not None and str(part_id).strip():
        part_id = str(part_id).strip()
    else:
        part_id = str(uuid4())

    return {
        "id": part_id,
        "name": text_field("name"),
        "oem_part_number": text_field("oem_part_number"),
        "part_number": text_field("part_number"),
        "buy_url": text_field("buy_url"),
        "cost": cost,
        "quantity": quantity,
        "vendor": text_field("vendor"),
        "notes": text_field("notes"),
        "sort_order": sort_value,
    }


def fetch_task_or_404(task_id: str) -> dict | None:
    row = pm_db.execute_one_json(
        f"""
        SELECT
            {TASK_COLUMNS}
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND is_active = true
          AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        (task_id,),
    )
    if row and (row.get("kind") == "Work Request" or row.get("intake_state") is not None):
        return None
    return row


def enrich_tasks(rows: list[dict]) -> list[dict]:
    if not rows:
        return []
    ids = [str(row["id"]) for row in rows]
    placeholders = ", ".join(["%s"] * len(ids))

    parts_rows = pm_db.execute_json(
        f"""
        SELECT
            {PART_COLUMNS}
        FROM propertymanager.maintenance_task_parts
        WHERE task_id IN ({placeholders})
        ORDER BY sort_order, name
        """,
        ids,
    )
    photos_rows = pm_db.execute_json(
        f"""
        SELECT id, task_id, file_name, created_at
        FROM propertymanager.maintenance_task_photos
        WHERE task_id IN ({placeholders})
        ORDER BY created_at
        """,
        ids,
    )

    parts_by_task: dict[str, list] = {}
    for part in parts_rows:
        parts_by_task.setdefault(str(part["task_id"]), []).append(part)

    photos_by_task: dict[str, list] = {}
    for photo in photos_rows:
        photos_by_task.setdefault(str(photo["task_id"]), []).append(photo)

    # One query for all meters: a per-task lookup made GET /tasks exceed client timeouts.
    meters_by_asset = ms.fetch_meter_rows([str(row["asset_id"]) for row in rows if row.get("asset_id")])

    enriched = []
    for row in rows:
        item = dict(row)
        task_id = str(item["id"])
        item["parts"] = parts_by_task.get(task_id, [])
        item["photos"] = photos_by_task.get(task_id, [])
        if item.get("completion_history") is None:
            item["completion_history"] = []
        if item.get("tools_required") is None:
            item["tools_required"] = []
        current_meter = None
        asset_id = item.get("asset_id")
        if asset_id:
            meter_row = meters_by_asset.get(str(asset_id))
            if meter_row:
                current_meter = ms._as_decimal(meter_row.get("current_value"))
            item = ms.enrich_task_meter_fields(item, current_meter)
        enriched.append(item)
    return enriched


def _probe_postgres_and_schema() -> tuple[bool, bool, bool]:
    """Return reachability, base-schema availability, and verified current-migration status."""
    try:
        row = pm_db.execute_one_json(
            """
            SELECT
                to_regclass('propertymanager.assets')::text AS assets_table,
                to_regclass('propertymanager.asset_meter')::text AS meter_table,
                to_regclass('propertymanager.maintenance_tasks')::text AS tasks_table,
                to_regclass('propertymanager.maintenance_proposals')::text AS proposals_table,
                (
                    SELECT count(*) = 8
                    FROM information_schema.tables
                    WHERE table_schema = 'propertymanager'
                      AND table_name IN (
                          'asset_manual', 'asset_manual_version', 'asset_manual_chunk',
                          'asset_manual_state_event', 'maintenance_attachment_operations',
                          'maintenance_task_intake_events', 'maintenance_task_photos',
                          'schema_migrations'
                      )
                ) AS required_tables,
                (
                    SELECT count(*) = 8
                    FROM information_schema.columns
                    WHERE table_schema = 'propertymanager'
                      AND table_name = 'maintenance_tasks'
                      AND column_name IN (
                          'intake_state', 'submitted_by', 'submitted_at', 'triaged_by',
                          'triaged_at', 'triage_reason', 'converted_task_id',
                          'intake_idempotency_key'
                      )
                ) AS intake_columns,
                (
                    SELECT count(*) = 11
                    FROM information_schema.columns
                    WHERE table_schema = 'propertymanager'
                      AND table_name = 'maintenance_task_photos'
                      AND column_name IN (
                          'id', 'task_id', 'file_name', 'storage_path', 'created_at',
                          'original_file_name', 'content_type', 'byte_size', 'sha256',
                          'content', 'sanitized_at'
                      )
                ) AS photo_columns,
                (
                    SELECT count(*) = 5
                    FROM pg_indexes
                    WHERE schemaname = 'propertymanager'
                      AND indexname IN (
                          'asset_manual_version_one_active_idx',
                          'asset_manual_chunk_search_idx',
                          'maintenance_tasks_work_request_idempotency_idx',
                          'maintenance_attachment_operations_allocation_idempotency_idx',
                          'maintenance_task_photos_task_file_name_uidx'
                      )
                ) AS required_indexes
            """
        )
        if row is None:
            return True, False, False
        schema_ok = bool(
            row.get("assets_table")
            and row.get("meter_table")
            and row.get("tasks_table")
            and row.get("proposals_table")
        )
        required_objects = bool(
            row.get("required_tables")
            and row.get("intake_columns")
            and row.get("photo_columns")
            and row.get("required_indexes")
        )
        if not (schema_ok and required_objects):
            return True, schema_ok, False
        marker = pm_db.execute_one_json(
            """
            SELECT EXISTS (
                SELECT 1
                FROM propertymanager.schema_migrations
                WHERE version = %s
            ) AS migration_applied
            """,
            (EXPECTED_SCHEMA_VERSION,),
        )
        return True, schema_ok, bool(marker and marker.get("migration_applied"))
    except Exception:
        logger.exception("health check: postgres/schema probe failed")
        return False, False, False


@app.get("/health")
def health():
    postgres_reachable, schema_available, schema_current = _probe_postgres_and_schema()
    healthy = postgres_reachable and schema_available and schema_current
    if schema_current:
        schema_contract_status = f"migration_{EXPECTED_SCHEMA_VERSION}_applied"
    elif postgres_reachable:
        schema_contract_status = f"migration_{EXPECTED_SCHEMA_VERSION}_not_verified"
    else:
        schema_contract_status = "unavailable"
    body = {
        "status": "ok" if healthy else "degraded",
        "service": "propertymanager-api",
        "api_version": "v1",
        "api_process": "healthy",
        "postgres_reachable": postgres_reachable,
        "schema_available": schema_available,
        "db_mode": "docker_exec" if pm_db.use_docker() else "tcp",
        "schema_version": EXPECTED_SCHEMA_VERSION if schema_current else None,
        "schema_contract_status": schema_contract_status,
        "max_content_length": MAX_UPLOAD_BYTES,
        **auth_status(),
    }
    return jsonify(body), (200 if healthy else 503)


@app.get("/v1/test/slow-db")
def test_slow_db():
    """Test-only drain probe: sleep inside docker-exec when env gate is set.

    Enabled only when ``PROPERTYMANAGER_TEST_SLOW_DB_MS`` is a positive integer.
    Used by ``tests/test_restart_drain.py`` to prove in-flight DB work survives
    ``systemctl --user restart propertymanager-api``.
    """
    raw = os.environ.get("PROPERTYMANAGER_TEST_SLOW_DB_MS", "").strip()
    if not raw:
        return error_response(
            "NOT_FOUND",
            "slow-db probe disabled (set PROPERTYMANAGER_TEST_SLOW_DB_MS)",
            status=404,
        )
    try:
        ms = int(raw)
    except ValueError:
        return error_response(
            "VALIDATION_ERROR",
            "PROPERTYMANAGER_TEST_SLOW_DB_MS must be an integer millisecond value",
            status=400,
        )
    if ms <= 0:
        return error_response(
            "NOT_FOUND",
            "slow-db probe disabled (PROPERTYMANAGER_TEST_SLOW_DB_MS <= 0)",
            status=404,
        )
    ms = min(ms, 30_000)
    pm_db.test_slow_sleep(ms / 1000.0)
    return jsonify({"ok": True, "slept_ms": ms, "db_mode": "docker_exec" if pm_db.use_docker() else "tcp"})


@app.errorhandler(413)
def handle_payload_too_large(_exc):
    return error_response(
        "PAYLOAD_TOO_LARGE",
        "Request body exceeds configured size limit.",
        status=413,
        extra={"max_content_length": MAX_UPLOAD_BYTES},
    )


@app.errorhandler(Exception)
def handle_unexpected(exc):
    """Sanitize client errors; keep diagnostics in logs only."""
    if isinstance(exc, HTTPException):
        status = exc.code or 500
        if status < 500:
            return error_response(
                "HTTP_ERROR",
                exc.description or exc.name or "Request error",
                status=status,
            )
        logger.exception("HTTP %s from werkzeug", status)
        return error_response("INTERNAL_ERROR", "An internal error occurred.", status=status)
    logger.exception("Unhandled API exception")
    return error_response("INTERNAL_ERROR", "An internal error occurred.", status=500)


@app.get("/categories")
def categories():
    rows = pm_db.execute_json(
        """
        SELECT id, name, icon, color_name, is_built_in, sort_order, created_at, updated_at
        FROM propertymanager.maintenance_categories
        ORDER BY sort_order, name
        """
    )
    return jsonify(rows)


@app.post("/categories")
@auth_required()
def create_category():
    """Create a category (used by Mac/iPhone when adding a category)."""
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object body required"}), 400

    name = str(payload.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    existing = pm_db.execute_one_json(
        """
        SELECT id, name, icon, color_name, is_built_in, sort_order, created_at, updated_at
        FROM propertymanager.maintenance_categories
        WHERE lower(name) = lower(%s)
        LIMIT 1
        """,
        (name,),
    )
    if existing is not None:
        return jsonify(existing), 200

    category_id = str(payload.get("id") or uuid4())
    icon = str(payload.get("icon") or "folder.fill").strip() or "folder.fill"
    color_name = str(payload.get("color_name") or "gray").strip() or "gray"
    is_built_in = bool(payload.get("is_built_in", False))

    max_sort_row = pm_db.execute_one_json(
        """
        SELECT COALESCE(MAX(sort_order), 0)::int AS max_sort
        FROM propertymanager.maintenance_categories
        """
    )
    sort_order = int(payload.get("sort_order") or ((max_sort_row or {}).get("max_sort") or 0) + 10)

    pm_db.execute(
        """
        INSERT INTO propertymanager.maintenance_categories
            (id, name, icon, color_name, is_built_in, sort_order, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, now(), now())
        """,
        (category_id, name, icon, color_name, is_built_in, sort_order),
    )

    created = pm_db.execute_one_json(
        """
        SELECT id, name, icon, color_name, is_built_in, sort_order, created_at, updated_at
        FROM propertymanager.maintenance_categories
        WHERE id = %s
        """,
        (category_id,),
    )
    if created is None:
        return jsonify({"error": "Category create failed"}), 500
    return jsonify(created), 201


FALLBACK_CATEGORY_NAME = "House"


@app.delete("/categories/<category_id>")
@auth_required()
def delete_category(category_id: str):
    """Delete a category. If active tasks remain, require explicit reassign_to."""
    category = pm_db.execute_one_json(
        """
        SELECT id, name, is_built_in
        FROM propertymanager.maintenance_categories
        WHERE id = %s
        """,
        (category_id,),
    )
    if category is None:
        return jsonify({"error": "Category not found"}), 404

    name = str(category.get("name") or "").strip()
    if not name:
        return jsonify({"error": "Category has no name"}), 400
    if name.lower() == FALLBACK_CATEGORY_NAME.lower():
        return jsonify({"error": f"Cannot delete the fallback category '{FALLBACK_CATEGORY_NAME}'"}), 400

    payload = request.get_json(silent=True) or {}
    reassign_to = str(payload.get("reassign_to") or request.args.get("reassign_to") or "").strip()

    task_count_row = pm_db.execute_one_json(
        """
        SELECT COUNT(*)::int AS task_count
        FROM propertymanager.maintenance_tasks
        WHERE is_active = true AND kind <> 'Work Request' AND intake_state IS NULL
          AND lower(category_name) = lower(%s)
        """,
        (name,),
    )
    task_count = int((task_count_row or {}).get("task_count") or 0)

    if task_count > 0 and not reassign_to:
        return (
            jsonify(
                {
                    "error": (
                        f"Category '{name}' has {task_count} active task"
                        f"{'' if task_count == 1 else 's'}. "
                        "Choose a destination category (reassign_to) before deleting."
                    ),
                    "task_count": task_count,
                    "requires_reassign": True,
                    "category_id": category_id,
                    "category_name": name,
                }
            ),
            409,
        )

    reassigned = 0
    destination_name = None
    if task_count > 0:
        if reassign_to.lower() == name.lower():
            return jsonify({"error": "reassign_to must be a different category"}), 400

        destination = pm_db.execute_one_json(
            """
            SELECT id, name
            FROM propertymanager.maintenance_categories
            WHERE lower(name) = lower(%s)
            LIMIT 1
            """,
            (reassign_to,),
        )
        if destination is None:
            return jsonify({"error": f"Destination category '{reassign_to}' not found"}), 400

        destination_name = str(destination["name"])
        reassigned = pm_db.execute(
            """
            UPDATE propertymanager.maintenance_tasks
            SET category_name = %s,
                area = %s,
                updated_at = now()
            WHERE is_active = true
              AND kind <> 'Work Request' AND intake_state IS NULL
              AND lower(category_name) = lower(%s)
            """,
            (destination_name, destination_name, name),
        )

    deleted = pm_db.execute(
        """
        DELETE FROM propertymanager.maintenance_categories
        WHERE id = %s
        """,
        (category_id,),
    )
    if deleted == 0:
        return jsonify({"error": "Category not found"}), 404

    return jsonify(
        {
            "deleted": True,
            "category_id": category_id,
            "category_name": name,
            "reassigned_to": destination_name,
            "tasks_reassigned": int(reassigned or 0),
        }
    )


@app.get("/tasks")
def tasks():
    rows = pm_db.execute_json(
        f"""
        SELECT
            {TASK_COLUMNS}
        FROM propertymanager.maintenance_tasks
        WHERE is_active = true AND kind <> 'Work Request'
        ORDER BY area, item
        """
    )
    return jsonify(enrich_tasks(rows))


@app.get("/tasks/<task_id>")
def task_detail(task_id: str):
    row = pm_db.execute_one_json(
        f"""
        SELECT
            {TASK_COLUMNS}
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND is_active = true
          AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        (task_id,),
    )
    if row is None:
        return jsonify({"error": "Task not found"}), 404
    return jsonify(enrich_tasks([row])[0])


@app.post("/tasks")
@auth_required()
def upsert_task():
    """Create or replace a task (used by Mac Publish)."""
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object body required"}), 400

    requested_kind = str(payload.get("kind") or "Scheduled").strip() or "Scheduled"
    if requested_kind.casefold() == "work request":
        return error_response(
            "INTAKE_ROUTE_REQUIRED",
            "Work requests may be created only through the work-request intake API",
            status=409,
        )

    task_id = str(payload.get("id") or uuid4())
    origin = normalize_origin(payload.get("origin"))
    source_manual = str(payload.get("source_manual_name") or "").strip()
    if not payload.get("origin") and source_manual:
        origin = "manufacturer"

    tools = payload.get("tools_required") or []
    history = payload.get("completion_history") or []
    if not isinstance(tools, list):
        tools = []
    history_error = _completion_history_error(history)
    if history_error:
        return validation_error(history_error, field="completion_history")

    schedule_kind = str(payload.get("schedule_kind") or "calendar").strip().lower()
    if schedule_kind not in ms.SCHEDULE_KINDS:
        schedule_kind = "calendar"

    try:
        meter_interval_value = None
        if "meter_interval_value" in payload:
            meter_interval_value = ms.parse_optional_meter_decimal(
                payload.get("meter_interval_value"), field="meter_interval_value"
            )
        last_done_meter = None
        if "last_done_meter_value" in payload:
            last_done_meter = ms.parse_optional_meter_decimal(
                payload.get("last_done_meter_value"), field="last_done_meter_value"
            )
        next_due_meter = None
        if "next_due_meter_value" in payload:
            raw_trigger = payload.get("next_due_meter_value")
            if raw_trigger is None:
                next_due_meter = None
            else:
                next_due_meter = ms.parse_optional_meter_decimal(
                    raw_trigger, field="next_due_meter_value"
                )
    except ValueError as exc:
        return validation_error(str(exc))

    asset_id = payload.get("asset_id")
    if asset_id is not None and str(asset_id).strip() == "":
        asset_id = None

    area, item = normalize_written_task_title(
        area=str(payload.get("area") or "House"),
        item=str(payload.get("item") or ""),
        asset_id=asset_id,
    )

    existing_dates = None
    if payload.get("id"):
        existing_dates = pm_db.execute_one_json(
            """
            SELECT last_done, next_due
            FROM propertymanager.maintenance_tasks
            WHERE id = %s
            """,
            (task_id,),
        )
    default_last_done = datetime.now(timezone.utc)
    last_done = (
        payload.get("last_done")
        or (existing_dates or {}).get("last_done")
        or default_last_done
    )
    next_due = (
        payload.get("next_due")
        or (existing_dates or {}).get("next_due")
        or (default_last_done + timedelta(days=30))
    )

    meter_interval_unit = str(payload.get("meter_interval_unit") or "").strip() or None
    warnings: list[str] = []
    if next_due_meter is not None:
        if meter_interval_unit is None and asset_id:
            meter_row = ms.fetch_meter_row(str(asset_id))
            meter_type = str((meter_row or {}).get("meter_type") or "")
            meter_interval_unit = ms._CANONICAL_UNIT_BY_METER_TYPE.get(meter_type) or "hrs"
        elif meter_interval_unit is None:
            meter_interval_unit = "hrs"
        try:
            warnings = ms.validate_meter_trigger(
                asset_id=asset_id,
                schedule_kind=schedule_kind,
                next_due_meter=next_due_meter,
                meter_interval_unit=meter_interval_unit,
            )
        except ValueError as exc:
            return validation_error(str(exc))

    pm_db.execute(
        """
        INSERT INTO propertymanager.maintenance_tasks AS current_task (
            id, area, item, category_name, priority, frequency,
            task_description, response_instructions, supplies_needed,
            notes, result_notes, estimated_minutes,
            warning_days, critical_days,
            last_done, next_due,
            send_telegram_update, include_in_daily_briefing,
            alert_if_overdue, is_active,
            kind, manufacturer, source_manual_name, origin,
            asset_id, schedule_kind, meter_interval_value, meter_interval_unit,
            last_done_meter_value, next_due_meter_value,
            completion_history, tools_required,
            created_at, updated_at
        ) VALUES (
            %s, %s, %s, %s, %s, %s,
            %s, %s, %s,
            %s, %s, %s,
            %s, %s,
            %s, %s,
            %s, %s,
            %s, %s,
            %s, %s, %s, %s,
            %s, %s, %s, %s,
            %s, %s,
            %s::jsonb, %s::jsonb,
            now(), now()
        )
        ON CONFLICT (id) DO UPDATE SET
            area = EXCLUDED.area,
            item = EXCLUDED.item,
            category_name = EXCLUDED.category_name,
            priority = EXCLUDED.priority,
            frequency = EXCLUDED.frequency,
            task_description = EXCLUDED.task_description,
            response_instructions = EXCLUDED.response_instructions,
            supplies_needed = EXCLUDED.supplies_needed,
            notes = EXCLUDED.notes,
            result_notes = EXCLUDED.result_notes,
            estimated_minutes = EXCLUDED.estimated_minutes,
            warning_days = EXCLUDED.warning_days,
            critical_days = EXCLUDED.critical_days,
            last_done = EXCLUDED.last_done,
            next_due = EXCLUDED.next_due,
            send_telegram_update = EXCLUDED.send_telegram_update,
            include_in_daily_briefing = EXCLUDED.include_in_daily_briefing,
            alert_if_overdue = EXCLUDED.alert_if_overdue,
            is_active = EXCLUDED.is_active,
            kind = EXCLUDED.kind,
            manufacturer = EXCLUDED.manufacturer,
            source_manual_name = EXCLUDED.source_manual_name,
            origin = EXCLUDED.origin,
            asset_id = EXCLUDED.asset_id,
            schedule_kind = EXCLUDED.schedule_kind,
            meter_interval_value = EXCLUDED.meter_interval_value,
            meter_interval_unit = EXCLUDED.meter_interval_unit,
            last_done_meter_value = EXCLUDED.last_done_meter_value,
            next_due_meter_value = EXCLUDED.next_due_meter_value,
            completion_history = EXCLUDED.completion_history,
            tools_required = EXCLUDED.tools_required,
            updated_at = now()
        WHERE current_task.kind <> 'Work Request' AND current_task.intake_state IS NULL
        """,
        (
            task_id,
            area,
            item,
            str(payload.get("category_name") or area or "House"),
            str(payload.get("priority") or "Medium"),
            str(payload.get("frequency") or "Monthly"),
            str(payload.get("task_description") or ""),
            str(payload.get("response_instructions") or ""),
            str(payload.get("supplies_needed") or ""),
            str(payload.get("notes") or ""),
            str(payload.get("result_notes") or ""),
            int(payload.get("estimated_minutes") or 30),
            int(payload.get("warning_days") or 30),
            int(payload.get("critical_days") or 45),
            last_done,
            next_due,
            bool(payload.get("send_telegram_update", True)),
            bool(payload.get("include_in_daily_briefing", True)),
            bool(payload.get("alert_if_overdue", True)),
            bool(payload.get("is_active", True)),
            requested_kind,
            str(payload.get("manufacturer") or ""),
            source_manual,
            origin,
            asset_id,
            schedule_kind,
            meter_interval_value,
            meter_interval_unit,
            last_done_meter,
            next_due_meter,
            json.dumps(history),
            json.dumps(tools),
        ),
    )

    # The ON CONFLICT predicate is the atomic authority boundary. Re-fetch
    # before any meter or parts side effect so an intake-record collision fails
    # closed even when another request created that row after our earlier reads.
    updated = fetch_task_or_404(task_id)
    if updated is None:
        return error_response(
            "INTAKE_ROUTE_REQUIRED",
            "Work requests may be changed only through the work-request API",
            status=409,
        )

    if asset_id and schedule_kind in {"meter", "both"}:
        meter_row = ms.fetch_meter_row(str(asset_id))
        current = ms._as_decimal((meter_row or {}).get("current_value"))
        ms.recalc_tasks_for_asset(str(asset_id), current)

    parts = payload.get("parts")
    if isinstance(parts, list):
        pm_db.execute(
            "DELETE FROM propertymanager.maintenance_task_parts WHERE task_id = %s",
            (task_id,),
        )
        for index, raw in enumerate(parts):
            if not isinstance(raw, dict):
                continue
            try:
                part = normalize_part_payload(raw, sort_order=index)
            except ValueError:
                continue
            pm_db.execute(
                """
                INSERT INTO propertymanager.maintenance_task_parts
                    (id, task_id, name, oem_part_number, part_number, buy_url, cost,
                     quantity, vendor, notes, sort_order, created_at, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now(), now())
                """,
                (
                    part["id"],
                    task_id,
                    part["name"],
                    part["oem_part_number"],
                    part["part_number"],
                    part["buy_url"],
                    part["cost"],
                    part["quantity"],
                    part["vendor"],
                    part["notes"],
                    part["sort_order"],
                ),
            )

    updated = fetch_task_or_404(task_id)
    if updated is None:
        return jsonify({"error": "Task upsert failed"}), 500
    body = enrich_tasks([updated])[0]
    if warnings:
        body["warnings"] = warnings
    return jsonify(body)


@app.patch("/tasks/<task_id>")
@auth_required()
def patch_task(task_id: str):
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object body required"}), 400
    if not payload:
        return jsonify({"error": "No fields to update"}), 400

    unknown = sorted(set(payload) - PATCHABLE_FIELDS)
    if unknown:
        return jsonify({"error": f"Unsupported fields: {', '.join(unknown)}"}), 400

    updates = {}
    try:
        for field, value in payload.items():
            updates[field] = normalize_patch_value(field, value)
    except ValueError as exc:
        return validation_error(str(exc))

    existing = fetch_task_or_404(task_id)
    if existing is None:
        return jsonify({"error": "Task not found"}), 404

    # Re-canonicalize title when area/item/asset_id participate in the patch.
    if {"area", "item", "asset_id"} & set(updates):
        effective_area = updates["area"] if "area" in updates else existing.get("area")
        effective_item = updates["item"] if "item" in updates else existing.get("item")
        effective_asset = updates["asset_id"] if "asset_id" in updates else existing.get("asset_id")
        area, item = normalize_written_task_title(
            area=str(effective_area or "House"),
            item=str(effective_item or ""),
            asset_id=effective_asset,
        )
        updates["area"] = area
        updates["item"] = item

    warnings: list[str] = []
    setting_trigger = "next_due_meter_value" in updates and updates.get("next_due_meter_value") is not None
    if setting_trigger:
        effective_asset = updates["asset_id"] if "asset_id" in updates else existing.get("asset_id")
        effective_kind = updates["schedule_kind"] if "schedule_kind" in updates else (
            existing.get("schedule_kind") or "calendar"
        )
        effective_unit = updates["meter_interval_unit"] if "meter_interval_unit" in updates else (
            existing.get("meter_interval_unit")
        )
        if not effective_unit:
            meter_row = ms.fetch_meter_row(str(effective_asset)) if effective_asset else None
            meter_type = str((meter_row or {}).get("meter_type") or "")
            effective_unit = ms._CANONICAL_UNIT_BY_METER_TYPE.get(meter_type) or "hrs"
            if "meter_interval_unit" not in updates:
                updates["meter_interval_unit"] = effective_unit
        try:
            warnings = ms.validate_meter_trigger(
                asset_id=effective_asset,
                schedule_kind=str(effective_kind),
                next_due_meter=updates["next_due_meter_value"],
                meter_interval_unit=str(effective_unit),
            )
        except ValueError as exc:
            return validation_error(str(exc))

    set_clause = ", ".join(f"{column} = %s" for column in updates)
    values = list(updates.values()) + [task_id]

    affected = pm_db.execute(
        f"""
        UPDATE propertymanager.maintenance_tasks
        SET {set_clause},
            updated_at = now()
        WHERE id = %s AND is_active = true
          AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        values,
    )

    updated = fetch_task_or_404(task_id)
    if updated is None or affected == 0:
        return jsonify({"error": "Task not found"}), 404
    body = enrich_tasks([updated])[0]
    if warnings:
        body["warnings"] = warnings
    return jsonify(body)


@app.delete("/tasks/<task_id>")
@auth_required()
def delete_task(task_id: str):
    """Soft-delete a task by setting is_active=false (keeps history/parts)."""
    affected = pm_db.execute(
        """
        UPDATE propertymanager.maintenance_tasks
        SET is_active = false,
            updated_at = now()
        WHERE id = %s AND is_active = true
          AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        (task_id,),
    )
    if affected == 0:
        return jsonify({"error": "Task not found"}), 404
    return jsonify({"deleted": True, "task_id": task_id})


@app.post("/tasks/<task_id>/photos")
@auth_required()
def upload_task_photo(task_id: str):
    """Store one validated task photo in PostgreSQL under an opaque identifier."""
    if fetch_task_or_404(task_id) is None:
        return jsonify({"error": "Task not found"}), 404

    uploaded = request.files.get("file")
    if uploaded is None:
        return validation_error("Photo file is required", field="file")
    content = uploaded.read(MAX_TASK_PHOTO_BYTES + 1)
    if not content:
        return validation_error("Photo file is empty", field="file")
    if len(content) > MAX_TASK_PHOTO_BYTES:
        return validation_error("Photo exceeds the 25 MiB limit", field="file")
    try:
        content = _sanitize_jpeg(content)
    except ValueError:
        return validation_error("Only JPEG photos are accepted", field="file")

    content_type, extension = "image/jpeg", "jpg"
    digest = hashlib.sha256(content).hexdigest()
    existing = pm_db.execute_one_json(
        """SELECT file_name FROM propertymanager.maintenance_task_photos
           WHERE task_id = %s AND sha256 = %s
           ORDER BY created_at LIMIT 1""",
        (task_id, digest),
    )
    if existing and existing.get("file_name"):
        return jsonify({"file_name": existing["file_name"], "idempotent_replay": True})
    photo_id = str(uuid4())
    file_name = f"{photo_id}.{extension}"
    pm_db.execute(
        """
        INSERT INTO propertymanager.maintenance_task_photos
            (id, task_id, file_name, storage_path, original_file_name, content_type,
             byte_size, sha256, content, sanitized_at)
        VALUES (%s, %s, %s, %s, NULL, %s, %s, %s, %s, now())
        """,
        (
            photo_id,
            task_id,
            file_name,
            f"database://maintenance-task-photo/{photo_id}",
            content_type,
            len(content),
            digest,
            content,
        ),
    )
    return jsonify({"file_name": file_name}), 201


@app.get("/tasks/<task_id>/photos/content")
@auth_required()
def download_task_photo(task_id: str):
    """Return photo bytes only for the owning active maintenance task."""
    if fetch_task_or_404(task_id) is None:
        return jsonify({"error": "Task not found"}), 404
    file_name = _requested_task_photo_name(request.args.get("file_name"))
    if file_name is None:
        return validation_error("file_name must be an opaque photo ID", field="file_name")
    row = pm_db.execute_one_json(
        """
        SELECT encode(content, 'base64') AS content_base64, content_type, storage_path
        FROM propertymanager.maintenance_task_photos
        WHERE task_id = %s AND file_name = %s
        """,
        (task_id, file_name),
    )
    if row is None:
        return jsonify({"error": "Photo content not found"}), 404
    content_type = str(row.get("content_type") or _legacy_photo_content_type(file_name))
    if row.get("content_base64"):
        try:
            # PostgreSQL's encode(..., 'base64') wraps long values at 76
            # characters. Strip only that transport whitespace, then retain
            # strict validation for the actual Base64 payload.
            encoded = "".join(str(row["content_base64"]).split())
            content = base64.b64decode(encoded, validate=True)
        except ValueError:
            logger.error("task photo %s has malformed stored content", file_name)
            return jsonify({"error": "Photo content not found"}), 404
    else:
        content = _safe_legacy_photo_bytes(row.get("storage_path"))
        if content is None:
            return jsonify({"error": "Photo content not found"}), 404
    response = Response(content, mimetype=content_type)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, no-store"
    return response


@app.delete("/tasks/<task_id>/photos")
@auth_required()
def delete_task_photo(task_id: str):
    """Delete one opaque task photo without resolving any filesystem path."""
    if fetch_task_or_404(task_id) is None:
        return jsonify({"error": "Task not found"}), 404
    payload = request.get_json(silent=True)
    file_name = _requested_task_photo_name(payload.get("file_name") if isinstance(payload, dict) else None)
    if file_name is None:
        return validation_error("file_name is required", field="file_name")
    affected = pm_db.execute(
        """DELETE FROM propertymanager.maintenance_task_photos
           WHERE task_id = %s AND file_name = %s""",
        (task_id, file_name),
    )
    if affected == 0:
        return jsonify({"error": "Photo not found"}), 404
    return jsonify({"deleted": True, "file_name": file_name})


@app.put("/tasks/<task_id>/parts")
@auth_required()
def replace_task_parts(task_id: str):
    """Replace the full parts list for a task (used by iPhone edit form)."""
    if fetch_task_or_404(task_id) is None:
        return jsonify({"error": "Task not found"}), 404

    payload = request.get_json(silent=True)
    if not isinstance(payload, list):
        return jsonify({"error": "JSON array body required"}), 400

    try:
        parts = [
            normalize_part_payload(item, sort_order=index)
            for index, item in enumerate(payload)
        ]
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    pm_db.execute(
        """
        DELETE FROM propertymanager.maintenance_task_parts
        WHERE task_id = %s
        """,
        (task_id,),
    )

    for part in parts:
        pm_db.execute(
            """
            INSERT INTO propertymanager.maintenance_task_parts
                (id, task_id, name, oem_part_number, part_number, buy_url, cost,
                 quantity, vendor, notes, sort_order, created_at, updated_at)
            VALUES
                (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now(), now())
            """,
            (
                part["id"],
                task_id,
                part["name"],
                part["oem_part_number"],
                part["part_number"],
                part["buy_url"],
                part["cost"],
                part["quantity"],
                part["vendor"],
                part["notes"],
                part["sort_order"],
            ),
        )

    pm_db.execute(
        """
        UPDATE propertymanager.maintenance_tasks
        SET updated_at = now()
        WHERE id = %s AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        (task_id,),
    )

    updated = fetch_task_or_404(task_id)
    if updated is None:
        return jsonify({"error": "Task not found"}), 404
    return jsonify(enrich_tasks([updated])[0])


@app.post("/tasks/<task_id>/parts")
@auth_required()
def create_task_part(task_id: str):
    if fetch_task_or_404(task_id) is None:
        return jsonify({"error": "Task not found"}), 404

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object body required"}), 400

    existing = pm_db.execute_json(
        """
        SELECT COALESCE(MAX(sort_order), -1) AS max_sort
        FROM propertymanager.maintenance_task_parts
        WHERE task_id = %s
        """,
        (task_id,),
    )
    next_sort = int((existing[0] or {}).get("max_sort") or -1) + 1

    try:
        part = normalize_part_payload(payload, sort_order=next_sort)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    pm_db.execute(
        """
        INSERT INTO propertymanager.maintenance_task_parts
            (id, task_id, name, oem_part_number, part_number, buy_url, cost,
             quantity, vendor, notes, sort_order, created_at, updated_at)
        VALUES
            (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now(), now())
        """,
        (
            part["id"],
            task_id,
            part["name"],
            part["oem_part_number"],
            part["part_number"],
            part["buy_url"],
            part["cost"],
            part["quantity"],
            part["vendor"],
            part["notes"],
            part["sort_order"],
        ),
    )
    pm_db.execute(
        """
        UPDATE propertymanager.maintenance_tasks
        SET updated_at = now()
        WHERE id = %s AND kind <> 'Work Request' AND intake_state IS NULL
        """,
        (task_id,),
    )
    updated = fetch_task_or_404(task_id)
    return jsonify(enrich_tasks([updated])[0])


@app.post("/tasks/<task_id>/complete")
@auth_required()
def complete_task(task_id: str):
    from flask import g

    payload = request.get_json(silent=True) or {}
    note = str(payload.get("note") or "").strip() or None
    completed_at = datetime.now(timezone.utc)

    task = pm_db.execute_one_json(
        """
        SELECT id, frequency, warning_days, asset_id, schedule_kind, kind, intake_state
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND is_active = true
        """,
        (task_id,),
    )
    if task is None:
        return error_response("NOT_FOUND", "Task not found", status=404)
    if task.get("kind") == "Work Request" or task.get("intake_state"):
        return error_response("INTAKE_NOT_MAINTENANCE", "Work requests cannot be completed", status=409)

    # Frequency defines recurrence; warning and critical days define alert windows.
    warning_days = int(task.get("warning_days") or 0)
    next_due = next_calendar_due(
        completed_at,
        frequency=task.get("frequency"),
        warning_days=warning_days,
    )

    meter_value = None
    meter_value_raw = payload.get("meter_value_at_completion")
    if meter_value_raw is not None and meter_value_raw != "":
        try:
            meter_value = parse_decimal(meter_value_raw, field="meter_value_at_completion")
        except ValueError as exc:
            return validation_error(str(exc), field="meter_value_at_completion")
        if not meter_value.is_finite() or meter_value < 0:
            return validation_error(
                "meter_value_at_completion must be a finite nonnegative number",
                field="meter_value_at_completion",
            )

    confirm_current_raw = payload.get("confirm_current_meter", False)
    if not isinstance(confirm_current_raw, bool):
        return validation_error(
            "confirm_current_meter must be a boolean",
            field="confirm_current_meter",
        )
    confirm_current = confirm_current_raw

    try:
        meter_result = ms.complete_task_meter(
            task_id,
            completed_at=completed_at,
            note=note,
            meter_value_at_completion=meter_value,
            confirm_current_meter=confirm_current,
            operator_identity=getattr(g, "operator_identity", None),
            integration_identity=getattr(g, "integration_identity", None),
        )
    except ValueError as exc:
        return validation_error(str(exc))

    completion_id = str(uuid4())
    meter_val_db = None
    if meter_result and meter_result.get("meter_value_decimal") is not None:
        meter_val_db = decimal_to_db(meter_result["meter_value_decimal"])
    elif meter_value is not None:
        meter_val_db = decimal_to_db(meter_value)

    if meter_result and meter_result.get("applied_meter"):
        try:
            applied = ms.apply_task_completion_transaction(
                task_id=task_id,
                completion_id=completion_id,
                completed_at=completed_at,
                next_due=next_due,
                note=note,
                meter_result=meter_result,
                operator_identity=getattr(g, "operator_identity", None),
                integration_identity=getattr(g, "integration_identity", None),
            )
        except RuntimeError as exc:
            return error_response("DB_ERROR", str(exc), status=500)
        if not applied:
            return error_response(
                "COMPLETION_CONFLICT",
                "Task or meter changed before completion; reload and confirm the current reading.",
                status=409,
            )
    else:
        statements: list[tuple] = [
            (
                """
                INSERT INTO propertymanager.maintenance_completions
                    (id, task_id, completed_at, note, meter_value_at_completion, meter_reading_id)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    completion_id,
                    task_id,
                    completed_at,
                    note,
                    meter_val_db,
                    (meter_result or {}).get("meter_reading_id"),
                ),
            ),
        ]
        statements.append(
            (
                """
                UPDATE propertymanager.maintenance_tasks
                SET last_done = %s,
                    next_due = %s,
                    result_notes = COALESCE(%s, result_notes),
                    updated_at = now()
                WHERE id = %s
                """,
                (completed_at, next_due, note, task_id),
            )
        )

        try:
            pm_db.execute_script(statements)
        except RuntimeError as exc:
            return error_response("DB_ERROR", str(exc), status=500)

    updated = pm_db.execute_one_json(
        f"""
        SELECT
            {TASK_COLUMNS}
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND is_active = true
        """,
        (task_id,),
    )
    if updated is None:
        return jsonify({"error": "Task not found"}), 404
    return jsonify(enrich_tasks([updated])[0])


register_asset_routes(app)
register_mapping_routes(app)


@app.get("/auth/check")
@auth_required()
def auth_check():
    """Verify the configured runtime credential without exposing identity details."""
    return jsonify({"authenticated": True})


if __name__ == "__main__":
    # Normal operation: tools/property_manager/api/run_api.sh (Gunicorn).
    # Direct Flask is an emergency rollback only — never debug/reloader.
    import sys

    print(
        "Do not run propertymanager_api.py directly for normal service operation.\n"
        "Use: tools/property_manager/api/run_api.sh  (Gunicorn WSGI)\n"
        "Emergency Flask rollback only:\n"
        "  PROPERTYMANAGER_ALLOW_FLASK_DEV=1 python3 propertymanager_api.py",
        file=sys.stderr,
    )
    if os.environ.get("PROPERTYMANAGER_ALLOW_FLASK_DEV", "").strip().lower() not in {
        "1",
        "true",
        "yes",
    }:
        sys.exit(2)
    port = int(os.environ.get("PROPERTYMANAGER_API_PORT", "5062"))
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False)
