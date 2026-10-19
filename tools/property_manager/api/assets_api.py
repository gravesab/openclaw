"""Asset and meter REST endpoints for PropertyManager API (Phase 1 /v1/)."""

from __future__ import annotations

import base64
import json
import re
from datetime import date, datetime, timezone
from difflib import SequenceMatcher
from typing import Any
from uuid import UUID, uuid4

from flask import g, jsonify, request

import db as pm_db
from auth import auth_required
from decimal_utils import format_decimal, parse_decimal
from errors import error_response, validation_error
import meter_schedule as ms

ASSET_COLUMNS = """
    a.id, a.external_id, a.ranchbrain_guid, a.name, a.manufacturer, a.model,
    a.category, a.location, a.aliases, a.qr_token, a.is_active,
    a.placed_in_service_date, a.host_asset_id, a.is_pseudo,
    a.meter_proposed_type, a.meter_proposed_unit, a.meter_activated_at,
    a.created_at, a.updated_at
"""

PSEUDO_ASSET_WORK_ERROR = "Pseudo asset groups cannot have meters or maintenance tasks"

METER_COLUMNS = """
    m.asset_id, m.meter_type, m.current_value, m.unit, m.latest_reading_at,
    m.meter_epoch, m.row_version, m.updated_at
"""

READING_COLUMNS = """
    id, asset_id, value, reading_at, entry_method, note, correction_reason,
    usage_since_previous, created_at, previous_reading_id, meter_type_at_entry,
    unit_at_entry, status, operator_identity, integration_identity,
    idempotency_key, meter_epoch, corrects_reading_id
"""


def register_asset_routes(app) -> None:
    prefix = "/v1"
    app.add_url_rule(f"{prefix}/assets", "v1_list_assets", list_assets, methods=["GET"])
    app.add_url_rule(f"{prefix}/assets/<asset_id>", "v1_asset_detail", asset_detail, methods=["GET"])
    app.add_url_rule(
        f"{prefix}/assets/by-external-id/<external_id>",
        "v1_asset_by_external_id",
        asset_by_external_id,
        methods=["GET"],
    )
    app.add_url_rule(
        f"{prefix}/assets/by-qr/<qr_token>",
        "v1_asset_by_qr",
        asset_by_qr,
        methods=["GET"],
    )
    app.add_url_rule(f"{prefix}/assets", "v1_create_asset", create_asset, methods=["POST"])
    app.add_url_rule(f"{prefix}/assets/<asset_id>", "v1_patch_asset", patch_asset, methods=["PATCH"])
    app.add_url_rule(
        f"{prefix}/assets/<asset_id>/activate-meter",
        "v1_activate_meter",
        activate_meter,
        methods=["POST"],
    )
    app.add_url_rule(
        f"{prefix}/assets/<asset_id>/meter-readings",
        "v1_list_meter_readings",
        list_meter_readings,
        methods=["GET"],
    )
    app.add_url_rule(
        f"{prefix}/assets/<asset_id>/meter-readings",
        "v1_create_meter_reading",
        create_meter_reading,
        methods=["POST"],
    )
    app.add_url_rule(
        f"{prefix}/assets/<asset_id>/meter-readings/confirm",
        "v1_confirm_meter_reading",
        confirm_meter_reading,
        methods=["POST"],
    )
    app.add_url_rule(
        f"{prefix}/meter-readings/parse",
        "v1_parse_meter_reading",
        parse_meter_reading,
        methods=["POST"],
    )


def _encode_cursor(reading_at: str, created_at: str, reading_id: str) -> str:
    payload = json.dumps({"reading_at": reading_at, "created_at": created_at, "id": reading_id})
    return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")


def _decode_cursor(cursor: str) -> dict | None:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        return json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
    except (json.JSONDecodeError, ValueError):
        return None


def _serialize_reading(row: dict) -> dict:
    item = dict(row)
    val = ms._as_decimal(item.get("value"))
    usage = ms._as_decimal(item.get("usage_since_previous"))
    item["value"] = format_decimal(val) if val is not None else None
    item["usage_since_previous"] = format_decimal(usage) if usage is not None else None
    return item


def parse_placed_in_service_date(value: Any) -> date | None:
    """Accept an ISO civil date or null; never infer a date from a timestamp."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("placed_in_service_date must be an ISO date (YYYY-MM-DD) or null")
    normalized = value.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", normalized) is None:
        raise ValueError("placed_in_service_date must be an ISO date (YYYY-MM-DD) or null")
    try:
        return date.fromisoformat(normalized)
    except ValueError as exc:
        raise ValueError("placed_in_service_date must be an ISO date (YYYY-MM-DD) or null") from exc


def fetch_asset_or_404(asset_id: str) -> dict | None:
    row = pm_db.execute_one_json(
        f"""
        SELECT {ASSET_COLUMNS}, {METER_COLUMNS}
        FROM propertymanager.assets a
        LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
        WHERE a.id = %s AND a.is_active = true
        """,
        (asset_id,),
    )
    if row is None:
        return None
    return enrich_asset(row)


def asset_name_conflicts(name: str, *, excluding_asset_id: str | None = None) -> bool:
    """Return whether an active asset already uses this human-visible name."""
    normalized_name = name.strip()
    params: list[str] = [normalized_name]
    exclusion = ""
    if excluding_asset_id is not None:
        exclusion = " AND id <> %s"
        params.append(excluding_asset_id)
    row = pm_db.execute_one_json(
        f"""
        SELECT id
        FROM propertymanager.assets
        WHERE is_active = true
          AND lower(btrim(name)) = lower(btrim(%s))
          {exclusion}
        LIMIT 1
        """,
        params,
    )
    return row is not None


def duplicate_asset_name_response():
    return error_response(
        "ASSET_NAME_CONFLICT",
        "An active asset with this name already exists",
        field="name",
        status=409,
    )


def _normalize_asset_id(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def parse_is_pseudo(value: Any) -> bool:
    if value is None or value is False:
        return False
    if value is True:
        return True
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ("true", "1", "yes"):
            return True
        if lowered in ("false", "0", "no", ""):
            return False
    raise ValueError("is_pseudo must be a boolean")


def asset_is_pseudo(asset_id: str) -> bool:
    row = pm_db.execute_one_json(
        "SELECT is_pseudo FROM propertymanager.assets WHERE id = %s",
        (asset_id,),
    )
    if row is None:
        return False
    return bool(row.get("is_pseudo"))


def reject_if_pseudo_asset(asset_id: str, *, field: str = "asset_id"):
    """Return a validation response when asset_id is a pseudo group; else None."""
    if asset_is_pseudo(asset_id):
        return validation_error(PSEUDO_ASSET_WORK_ERROR, field=field)
    return None


def parse_host_asset_id(value: Any) -> str | None:
    """Accept a UUID string or null to clear the host link."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("host_asset_id must be a UUID string or null")
    normalized = value.strip()
    if not normalized:
        raise ValueError("host_asset_id must be a UUID string or null")
    try:
        return str(UUID(normalized))
    except (TypeError, ValueError) as exc:
        raise ValueError("host_asset_id must be a UUID string or null") from exc


def host_assignment_would_cycle(asset_id: str, host_asset_id: str) -> bool:
    """True when walking hosts from host_asset_id upward reaches asset_id."""
    current = host_asset_id
    seen: set[str] = set()
    while current:
        if current == asset_id:
            return True
        if current in seen:
            return True
        seen.add(current)
        row = pm_db.execute_one_json(
            "SELECT host_asset_id FROM propertymanager.assets WHERE id = %s",
            (current,),
        )
        if row is None:
            return False
        current = _normalize_asset_id(row.get("host_asset_id"))
    return False


def fetch_host_ref(host_asset_id: str | None) -> dict | None:
    host_id = _normalize_asset_id(host_asset_id)
    if host_id is None:
        return None
    row = pm_db.execute_one_json(
        """
        SELECT id, name, is_pseudo
        FROM propertymanager.assets
        WHERE id = %s
        """,
        (host_id,),
    )
    if row is None:
        return None
    return {
        "id": str(row["id"]),
        "name": row["name"],
        "is_pseudo": bool(row.get("is_pseudo")),
    }


def fetch_attachments(asset_id: str) -> list[dict]:
    rows = pm_db.execute_json(
        """
        SELECT id, name
        FROM propertymanager.assets
        WHERE is_active = true AND host_asset_id = %s
        ORDER BY lower(name), name
        """,
        (asset_id,),
    )
    return [{"id": str(row["id"]), "name": row["name"]} for row in rows]


ACTIVE_TASK_FILTER = """
    is_active = true
    AND kind <> 'Work Request'
    AND intake_state IS NULL
"""


def fetch_active_task_counts(asset_ids: list[str] | None = None) -> dict[str, int]:
    """Live COUNT of scheduled active tasks per asset (no cache).

    docker-exec mogrify JSON-encodes Python lists, so ``ANY(%s::uuid[])`` cannot
    take a list parameter. Prefer ``IN (%s, %s, …)`` or an unfiltered GROUP BY.
    """
    if asset_ids is not None and len(asset_ids) == 0:
        return {}
    if asset_ids is None:
        rows = pm_db.execute_json(
            f"""
            SELECT asset_id::text AS asset_id, COUNT(*)::int AS active_task_count
            FROM propertymanager.maintenance_tasks
            WHERE asset_id IS NOT NULL
              AND {ACTIVE_TASK_FILTER}
            GROUP BY asset_id
            """
        )
    else:
        placeholders = ", ".join(["%s"] * len(asset_ids))
        rows = pm_db.execute_json(
            f"""
            SELECT asset_id::text AS asset_id, COUNT(*)::int AS active_task_count
            FROM propertymanager.maintenance_tasks
            WHERE asset_id IN ({placeholders})
              AND {ACTIVE_TASK_FILTER}
            GROUP BY asset_id
            """,
            tuple(asset_ids),
        )
    return {
        str(row["asset_id"]): int(row["active_task_count"])
        for row in rows
        if row.get("asset_id") is not None
    }


def enrich_asset(
    row: dict,
    *,
    host_by_id: dict[str, dict] | None = None,
    attachments_by_host: dict[str, list[dict]] | None = None,
    active_task_count: int | None = None,
) -> dict:
    item = dict(row)
    placed_in_service_date = item.get("placed_in_service_date")
    if isinstance(placed_in_service_date, (date, datetime)):
        item["placed_in_service_date"] = (
            placed_in_service_date.date().isoformat()
            if isinstance(placed_in_service_date, datetime)
            else placed_in_service_date.isoformat()
        )
    asset_id = str(item["id"])
    item["is_pseudo"] = bool(item.get("is_pseudo"))
    host_asset_id = _normalize_asset_id(item.get("host_asset_id"))
    item["host_asset_id"] = host_asset_id
    if host_by_id is not None:
        item["host"] = host_by_id.get(host_asset_id) if host_asset_id else None
    else:
        item["host"] = fetch_host_ref(host_asset_id)
    if attachments_by_host is not None:
        item["attachments"] = list(attachments_by_host.get(asset_id, []))
    else:
        item["attachments"] = fetch_attachments(asset_id)
    current = ms._as_decimal(item.get("current_value"))
    if item["is_pseudo"]:
        tasks = []
    else:
        tasks = pm_db.execute_json(
            f"""
            SELECT id, item, schedule_kind, meter_interval_value, meter_interval_unit,
                   last_done_meter_value, next_due_meter_value, next_due, warning_days
            FROM propertymanager.maintenance_tasks
            WHERE asset_id = %s
              AND {ACTIVE_TASK_FILTER}
            ORDER BY item
            """,
            (asset_id,),
        )
    enriched_tasks = [ms.enrich_task_meter_fields(t, current) for t in tasks]
    overdue_count = sum(1 for t in enriched_tasks if t.get("overdue_meter"))
    due_soon = [
        t
        for t in enriched_tasks
        if t.get("remaining_meter") is not None
        and ms._as_decimal(t["remaining_meter"]) is not None
        and ms._as_decimal(t["remaining_meter"]) > 0
        and ms._as_decimal(t["remaining_meter"])
        <= (ms._as_decimal(t.get("meter_interval_value")) or parse_decimal("999999")) * parse_decimal("0.1")
    ]
    item["meter"] = {
        "meter_type": item.pop("meter_type", "none"),
        "current_value": format_decimal(current),
        "unit": item.pop("unit", ""),
        "latest_reading_at": item.pop("latest_reading_at"),
        "meter_epoch": item.pop("meter_epoch", 1),
        "row_version": item.pop("row_version", 1),
        "updated_at": item.pop("updated_at", None),
        "activated": item.get("meter_activated_at") is not None,
    }
    item.pop("asset_id", None)
    item["proposed_meter"] = {
        "meter_type": item.get("meter_proposed_type"),
        "unit": item.get("meter_proposed_unit"),
        "activated_at": item.get("meter_activated_at"),
    }
    item["tasks"] = enriched_tasks
    if item["is_pseudo"]:
        summary_count = 0
    elif active_task_count is not None:
        summary_count = int(active_task_count)
    else:
        summary_count = len(enriched_tasks)
    item["pm_summary"] = {
        "active_task_count": summary_count,
        "overdue_meter_count": overdue_count,
        "due_soon_count": len(due_soon),
    }
    return item


def _host_maps_for_rows(rows: list[dict]) -> tuple[dict[str, dict], dict[str, list[dict]]]:
    """Build host refs and attachment lists from the active asset list payload."""
    ref_by_id = {
        str(row["id"]): {
            "id": str(row["id"]),
            "name": row["name"],
            "is_pseudo": bool(row.get("is_pseudo")),
        }
        for row in rows
    }
    host_ids = {
        host_id
        for row in rows
        if (host_id := _normalize_asset_id(row.get("host_asset_id"))) is not None
    }
    missing_host_ids = sorted(host_ids - set(ref_by_id))
    if missing_host_ids:
        extras = pm_db.execute_json(
            """
            SELECT id, name, is_pseudo
            FROM propertymanager.assets
            WHERE id = ANY(%s::uuid[])
            """,
            (missing_host_ids,),
        )
        for row in extras:
            ref_by_id[str(row["id"])] = {
                "id": str(row["id"]),
                "name": row["name"],
                "is_pseudo": bool(row.get("is_pseudo")),
            }
    host_by_id = {
        host_id: ref_by_id[host_id]
        for host_id in host_ids
        if host_id in ref_by_id
    }
    attachments_by_host: dict[str, list[dict]] = {}
    for row in rows:
        host_id = _normalize_asset_id(row.get("host_asset_id"))
        if host_id is None:
            continue
        attachments_by_host.setdefault(host_id, []).append(
            {"id": str(row["id"]), "name": row["name"]}
        )
    for host_id, attachments in attachments_by_host.items():
        attachments.sort(key=lambda item: (item["name"].lower(), item["name"]))
    return host_by_id, attachments_by_host


def list_assets():
    rows = pm_db.execute_json(
        f"""
        SELECT {ASSET_COLUMNS}, {METER_COLUMNS}
        FROM propertymanager.assets a
        LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
        WHERE a.is_active = true
        ORDER BY a.category, a.name
        """
    )
    host_by_id, attachments_by_host = _host_maps_for_rows(rows)
    asset_ids = [str(row["id"]) for row in rows]
    active_counts = fetch_active_task_counts(asset_ids)
    return jsonify(
        [
            enrich_asset(
                row,
                host_by_id=host_by_id,
                attachments_by_host=attachments_by_host,
                active_task_count=(
                    0
                    if row.get("is_pseudo")
                    else active_counts.get(str(row["id"]), 0)
                ),
            )
            for row in rows
        ]
    )


def asset_detail(asset_id: str):
    row = fetch_asset_or_404(asset_id)
    if row is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    return jsonify(row)


def asset_by_external_id(external_id: str):
    row = pm_db.execute_one_json(
        f"""
        SELECT {ASSET_COLUMNS}, {METER_COLUMNS}
        FROM propertymanager.assets a
        LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
        WHERE a.external_id = %s AND a.is_active = true
        """,
        (external_id,),
    )
    if row is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    return jsonify(enrich_asset(row))


def asset_by_qr(qr_token: str):
    row = pm_db.execute_one_json(
        f"""
        SELECT {ASSET_COLUMNS}, {METER_COLUMNS}
        FROM propertymanager.assets a
        LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
        WHERE a.qr_token = %s AND a.is_active = true
        """,
        (qr_token,),
    )
    if row is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    return jsonify(enrich_asset(row))


@auth_required()
def create_asset():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return validation_error("JSON object body required")

    external_id = str(payload.get("external_id") or "").strip()
    name = str(payload.get("name") or "").strip()
    if not external_id or not name:
        return validation_error("external_id and name are required")
    if asset_name_conflicts(name):
        return duplicate_asset_name_response()

    try:
        is_pseudo = parse_is_pseudo(payload.get("is_pseudo"))
    except ValueError as exc:
        return validation_error(str(exc), field="is_pseudo")

    asset_id = str(payload.get("id") or uuid4())
    qr_token = str(payload.get("qr_token") or uuid4().hex)
    category = str(payload.get("category") or "")
    aliases = payload.get("aliases") or []
    if not isinstance(aliases, list):
        aliases = []

    if is_pseudo:
        # Groups are display-only roots: ignore equipment / meter intake fields.
        manufacturer = ""
        model = ""
        location = ""
        proposed_type = "none"
        proposed_unit = ""
        placed_in_service_date = None
    else:
        proposed_type = str(
            payload.get("meter_proposed_type") or ms.default_meter_type_for_category(category)
        )
        proposed_unit = str(payload.get("meter_proposed_unit") or ms.meter_unit_for_type(proposed_type))
        if proposed_type not in ms.METER_TYPES:
            return validation_error(
                f"meter_proposed_type must be one of {sorted(ms.METER_TYPES)}",
                field="meter_proposed_type",
            )
        manufacturer = str(payload.get("manufacturer") or "")
        model = str(payload.get("model") or "")
        location = str(payload.get("location") or "")
        try:
            placed_in_service_date = parse_placed_in_service_date(payload.get("placed_in_service_date"))
        except ValueError as exc:
            return validation_error(str(exc), field="placed_in_service_date")

    pm_db.execute(
        """
        INSERT INTO propertymanager.assets
            (id, external_id, ranchbrain_guid, name, manufacturer, model, category,
             location, aliases, qr_token, is_active, is_pseudo, meter_proposed_type, meter_proposed_unit,
             placed_in_service_date, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s, true, %s, %s, %s, %s, now(), now())
        """,
        (
            asset_id,
            external_id,
            payload.get("ranchbrain_guid"),
            name,
            manufacturer,
            model,
            category,
            location,
            json.dumps(aliases),
            qr_token,
            is_pseudo,
            proposed_type,
            proposed_unit,
            placed_in_service_date,
        ),
    )
    if not is_pseudo:
        pm_db.execute(
            """
            INSERT INTO propertymanager.asset_meter
                (asset_id, meter_type, current_value, unit, meter_epoch, row_version, updated_at)
            VALUES (%s, 'none', 0, '', 1, 1, now())
            ON CONFLICT (asset_id) DO NOTHING
            """,
            (asset_id,),
        )
    row = fetch_asset_or_404(asset_id)
    return jsonify(row), 201


@auth_required()
def patch_asset(asset_id: str):
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict) or not payload:
        return validation_error("JSON object body required")

    allowed = {
        "name",
        "manufacturer",
        "model",
        "category",
        "location",
        "aliases",
        "is_active",
        "placed_in_service_date",
        "host_asset_id",
    }
    unknown = sorted(set(payload) - allowed)
    if unknown:
        return validation_error(f"Unsupported fields: {', '.join(unknown)}")

    exists = pm_db.execute_one_json(
        "SELECT id, is_pseudo FROM propertymanager.assets WHERE id = %s",
        (asset_id,),
    )
    if exists is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    target_is_pseudo = bool(exists.get("is_pseudo"))

    if "name" in payload:
        name = str(payload.get("name") or "").strip()
        if not name:
            return validation_error("name is required", field="name")
        if asset_name_conflicts(name, excluding_asset_id=asset_id):
            return duplicate_asset_name_response()
        payload["name"] = name

    if "placed_in_service_date" in payload:
        try:
            payload["placed_in_service_date"] = parse_placed_in_service_date(payload["placed_in_service_date"])
        except ValueError as exc:
            return validation_error(str(exc), field="placed_in_service_date")

    if "host_asset_id" in payload:
        if target_is_pseudo:
            return validation_error(
                "Pseudo asset groups cannot be attached to a host",
                field="host_asset_id",
            )
        try:
            host_asset_id = parse_host_asset_id(payload["host_asset_id"])
        except ValueError as exc:
            return validation_error(str(exc), field="host_asset_id")
        if host_asset_id is not None:
            if host_asset_id == asset_id:
                return validation_error("An asset cannot be attached to itself", field="host_asset_id")
            host = pm_db.execute_one_json(
                """
                SELECT id, is_active
                FROM propertymanager.assets
                WHERE id = %s
                """,
                (host_asset_id,),
            )
            if host is None:
                return validation_error("Host asset was not found", field="host_asset_id")
            if not host.get("is_active"):
                return validation_error("Host asset must be active", field="host_asset_id")
            if host_assignment_would_cycle(asset_id, host_asset_id):
                return validation_error(
                    "Attaching would create a cycle in the host chain",
                    field="host_asset_id",
                )
        payload["host_asset_id"] = host_asset_id

    updates = []
    values = []
    for field in allowed:
        if field not in payload:
            continue
        val = payload[field]
        if field == "aliases":
            val = json.dumps(val if isinstance(val, list) else [])
            updates.append(f"{field} = %s::jsonb")
        else:
            updates.append(f"{field} = %s")
        values.append(val)
    if updates:
        values.append(asset_id)
        pm_db.execute(
            f"""
            UPDATE propertymanager.assets
            SET {", ".join(updates)}, updated_at = now()
            WHERE id = %s
            """,
            values,
        )

    row = fetch_asset_or_404(asset_id)
    return jsonify(row)


@auth_required()
def activate_meter(asset_id: str):
    payload = request.get_json(silent=True) or {}
    if fetch_asset_or_404(asset_id) is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    if (pseudo_err := reject_if_pseudo_asset(asset_id)) is not None:
        return pseudo_err

    row_version = payload.get("row_version")
    if row_version is None:
        if_match = request.headers.get("If-Match")
        if if_match:
            try:
                row_version = int(if_match.strip('"'))
            except ValueError:
                return validation_error("If-Match must be row_version integer", field="If-Match")

    try:
        updated = ms.activate_meter(
            asset_id,
            meter_type=payload.get("meter_type"),
            unit=payload.get("unit"),
            row_version=int(row_version) if row_version is not None else None,
        )
    except ValueError as exc:
        msg = str(exc)
        if msg.startswith("CONFLICT"):
            return error_response("CONFLICT", msg, status=409)
        return validation_error(msg)

    asset = fetch_asset_or_404(asset_id)
    return jsonify({"meter": updated, "asset": asset})


def list_meter_readings(asset_id: str):
    if fetch_asset_or_404(asset_id) is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)

    limit = min(max(int(request.args.get("limit", 50)), 1), 200)
    cursor = request.args.get("cursor")
    params: list = [asset_id]
    cursor_clause = ""
    if cursor:
        decoded = _decode_cursor(cursor)
        if decoded is None:
            return validation_error("invalid cursor", field="cursor")
        cursor_clause = """
            AND (reading_at, created_at, id) < (%s::timestamptz, %s::timestamptz, %s::uuid)
        """
        params.extend([decoded["reading_at"], decoded["created_at"], decoded["id"]])

    params.append(limit + 1)
    rows = pm_db.execute_json(
        f"""
        SELECT {READING_COLUMNS}
        FROM propertymanager.asset_meter_reading
        WHERE asset_id = %s
          AND status = 'accepted'
          {cursor_clause}
        ORDER BY reading_at DESC, created_at DESC, id DESC
        LIMIT %s
        """,
        params,
    )

    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = _encode_cursor(str(last["reading_at"]), str(last["created_at"]), str(last["id"]))
        rows = rows[:limit]

    return jsonify(
        {
            "items": [_serialize_reading(r) for r in rows],
            "next_cursor": next_cursor,
        }
    )


@auth_required(allow_pin=True)
def create_meter_reading(asset_id: str):
    asset = fetch_asset_or_404(asset_id)
    if asset is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    if (pseudo_err := reject_if_pseudo_asset(asset_id)) is not None:
        return pseudo_err

    payload = request.get_json(silent=True) or {}
    try:
        value, delta_applied = ms.resolve_meter_reading_absolute(
            asset_id,
            value=payload.get("value"),
            delta=payload.get("delta"),
            add_value=payload.get("add_value"),
        )
    except ValueError as exc:
        msg = str(exc)
        field = "delta" if "delta" in msg.lower() or "add_value" in msg.lower() else "value"
        if "either value" in msg or "value or delta" in msg:
            field = "value"
        return validation_error(msg, field=field)

    idempotency_key = request.headers.get("Idempotency-Key") or payload.get("idempotency_key")
    idempotency_key = str(idempotency_key).strip() if idempotency_key else None

    entry_method = str(payload.get("entry_method") or "manual").strip().lower()
    if entry_method not in ms.ENTRY_METHODS:
        entry_method = "manual"

    reading_at_raw = payload.get("reading_at")
    if reading_at_raw:
        reading_at = datetime.fromisoformat(str(reading_at_raw).replace("Z", "+00:00"))
        if reading_at.tzinfo is None:
            reading_at = reading_at.replace(tzinfo=timezone.utc)
    else:
        reading_at = datetime.now(timezone.utc)

    note = str(payload.get("note") or "").strip() or None
    row_version = payload.get("row_version")
    if row_version is None:
        if_match = request.headers.get("If-Match")
        if if_match:
            try:
                row_version = int(if_match.strip('"'))
            except ValueError:
                return validation_error("If-Match must be row_version integer", field="If-Match")

    if payload.get("correction_reason"):
        return error_response(
            "LOWER_READING_CONFIRMATION_REQUIRED",
            "correction_reason alone is insufficient; use preview then POST .../meter-readings/confirm",
            status=409,
            extra={"options": sorted(ms.CORRECTION_REASONS)},
        )

    try:
        result = ms.apply_meter_reading(
            asset_id,
            value,
            reading_at=reading_at,
            entry_method=entry_method,
            note=note,
            operator_identity=getattr(g, "operator_identity", None),
            integration_identity=getattr(g, "integration_identity", None),
            idempotency_key=idempotency_key,
            row_version=int(row_version) if row_version is not None else None,
        )
    except ValueError as exc:
        msg = str(exc)
        if msg.startswith("CONFLICT"):
            return error_response("CONFLICT", msg, status=409)
        return validation_error(msg)

    if result.get("lower_reading_preview"):
        return error_response(
            "LOWER_READING_CONFIRMATION_REQUIRED",
            "Reading is lower than previous accepted value in this meter epoch",
            status=409,
            extra={
                "previous_value": result.get("previous_value"),
                "proposed_value": result.get("proposed_value"),
                "options": result.get("options"),
                "preview_token": result.get("preview_token"),
                "delta": format_decimal(delta_applied) if delta_applied is not None else None,
            },
        )

    absolute_written = format_decimal(value)
    delta_out = format_decimal(delta_applied) if delta_applied is not None else None

    if result.get("idempotent_replay"):
        body = {
            "asset": fetch_asset_or_404(asset_id),
            "reading": _serialize_reading(result["reading"]),
            "idempotent_replay": True,
            "value": absolute_written,
            "current_value": result.get("current_value"),
            "delta": delta_out,
        }
        return jsonify(body)

    updated = fetch_asset_or_404(asset_id)
    return jsonify(
        {
            "asset": updated,
            "reading_id": result.get("reading_id"),
            "value": absolute_written,
            "current_value": result.get("current_value"),
            "delta": delta_out,
        }
    )


@auth_required(allow_pin=True)
def confirm_meter_reading(asset_id: str):
    if fetch_asset_or_404(asset_id) is None:
        return error_response("NOT_FOUND", "Asset not found", status=404)
    if (pseudo_err := reject_if_pseudo_asset(asset_id)) is not None:
        return pseudo_err

    payload = request.get_json(silent=True) or {}
    preview_token = str(payload.get("preview_token") or "").strip()
    correction_reason = str(payload.get("correction_reason") or "").strip().lower()
    operator_identity = str(payload.get("operator_identity") or getattr(g, "operator_identity", "") or "").strip()
    note = str(payload.get("note") or "").strip() or None

    if not preview_token:
        return validation_error("preview_token is required", field="preview_token")
    if not operator_identity:
        return validation_error("operator_identity is required", field="operator_identity")

    row_version = payload.get("row_version")
    if row_version is None:
        if_match = request.headers.get("If-Match")
        if if_match:
            try:
                row_version = int(if_match.strip('"'))
            except ValueError:
                return validation_error("If-Match must be row_version integer", field="If-Match")

    try:
        result = ms.confirm_lower_reading(
            asset_id,
            preview_token=preview_token,
            correction_reason=correction_reason,
            operator_identity=operator_identity,
            note=note,
            row_version=int(row_version) if row_version is not None else None,
        )
    except ValueError as exc:
        msg = str(exc)
        if msg.startswith("CONFLICT"):
            return error_response("CONFLICT", msg, status=409)
        return validation_error(msg)

    updated = fetch_asset_or_404(asset_id)
    return jsonify({"asset": updated, "reading_id": result.get("reading_id"), "current_value": result.get("current_value")})


_VALUE_PATTERN = re.compile(
    r"(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>hours?|hrs?|miles?|mi|cycles?)?",
    re.IGNORECASE,
)
# "add 2.5 hours", "add 10 miles" → delta mode
_DELTA_PATTERN = re.compile(
    r"\b(?:add|plus|\+)\s*(?P<delta>\d+(?:\.\d+)?)\s*(?P<unit>hours?|hrs?|miles?|mi|cycles?)?",
    re.IGNORECASE,
)


def _similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def _select_meter_asset(text: str, assets: list[dict[str, Any]]) -> tuple[dict[str, Any] | None, float]:
    """Prefer the most specific substring match before fuzzy similarity."""
    text_lower = text.lower()
    best = None
    best_score = 0.0
    best_rank = (0, 0, 0.0)

    for row in assets:
        names = [str(row.get("name") or "")]
        aliases = row.get("aliases") or []
        if isinstance(aliases, list):
            names.extend(str(alias) for alias in aliases)
        names.append(str(row.get("external_id") or ""))

        for name in names:
            if not name:
                continue
            is_substring = name.lower() in text_lower
            score = 1.0 if is_substring else _similarity(name, text)
            rank = (1 if is_substring else 0, len(name) if is_substring else 0, score)
            if rank > best_rank:
                best_rank = rank
                best_score = score
                best = row

    return best, best_score


def parse_meter_reading():
    payload = request.get_json(silent=True) or {}
    text = str(payload.get("text") or "").strip()
    if not text:
        return validation_error("text is required", field="text")

    delta_match = _DELTA_PATTERN.search(text)
    if delta_match:
        amount = format_decimal(parse_decimal(delta_match.group("delta"), field="delta"))
        entry_mode = "delta"
        absolute_value = None
        delta_value = amount
    else:
        match = _VALUE_PATTERN.search(text)
        if not match:
            return validation_error("Could not find a meter value in text", field="text")
        absolute_value = format_decimal(parse_decimal(match.group("value")))
        delta_value = None
        entry_mode = "absolute"

    assets = pm_db.execute_json(
        f"""
        SELECT {ASSET_COLUMNS}, {METER_COLUMNS}
        FROM propertymanager.assets a
        LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
        WHERE a.is_active = true
          AND a.is_pseudo = false
        """
    )

    best, best_score = _select_meter_asset(text, assets)

    if best is None or best_score < 0.35:
        return error_response(
            "PARSE_NO_MATCH",
            "Could not match asset from text",
            status=422,
            extra={"confidence": round(best_score, 3)},
        )

    meter_type = best.get("meter_type") or "none"
    unit = best.get("unit") or ms.meter_unit_for_type(meter_type)
    return jsonify(
        {
            "asset_id": str(best["id"]),
            "asset_name": best.get("name"),
            "value": absolute_value,
            "delta": delta_value,
            "entry_mode": entry_mode,
            "unit": unit,
            "meter_type": meter_type,
            "confidence": round(best_score, 3),
        }
    )
