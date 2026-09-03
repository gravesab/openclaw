"""PropertyManager metadata for manuals stored by the Dashboard library.

The Dashboard owns the PDF bytes on the IntelMini external drive. This API
stores only asset-linked metadata, extraction chunks, and lifecycle events.
It deliberately has no PDF upload, filesystem, or content-download route.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
from functools import wraps
from pathlib import PurePosixPath
from uuid import uuid4

from flask import Flask, g, jsonify, request

import db as pm_db
from auth import auth_required, server_submitter_identity
from errors import error_response, validation_error

MAX_MANUAL_BYTES = 50 * 1024 * 1024
DOCUMENT_TYPES = {"operator_manual", "service_manual", "parts_manual", "safety_manual", "other"}
LIBRARY_LOCATOR_PREFIX = "dashboard-library://"
MANUAL_LIBRARY_SERVICE_TOKEN = os.environ.get(
    "PROPERTYMANAGER_MANUAL_LIBRARY_SERVICE_TOKEN", ""
).strip()
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _dashboard_library_required(fn):
    """Require the dedicated Dashboard-to-PropertyManager service token.

    Browser and Mac application API credentials are intentionally not accepted
    here: registration and source resolution are a Dashboard-only boundary.
    """

    @wraps(fn)
    def wrapper(*args, **kwargs):
        supplied = request.headers.get("X-PropertyManager-Manual-Library-Token", "")
        if not MANUAL_LIBRARY_SERVICE_TOKEN:
            return error_response(
                "MANUAL_LIBRARY_SERVICE_NOT_CONFIGURED",
                "Dashboard manual-library service authentication is not configured.",
                status=503,
            )
        if not supplied or not hmac.compare_digest(supplied, MANUAL_LIBRARY_SERVICE_TOKEN):
            return error_response(
                "UNAUTHORIZED_MANUAL_LIBRARY",
                "Dashboard service authentication required.",
                status=401,
            )
        g.operator_identity = "dashboard-manual-library"
        return fn(*args, **kwargs)

    return wrapper


def _safe_display_name(value: str) -> str:
    name = value.replace("\\", "/").rsplit("/", 1)[-1].strip()
    name = "".join(character for character in name if character.isprintable())
    return name[:255]


def _safe_title(value: str, fallback: str) -> str:
    title = " ".join(value.split())[:300]
    if title:
        return title
    stem = PurePosixPath(fallback).stem.strip()
    return stem[:300] or "Untitled manual"


def _validate_library_locator(value: object) -> str:
    locator = str(value or "").strip()
    if not locator.startswith(LIBRARY_LOCATOR_PREFIX):
        raise ValueError("source_locator must be a Dashboard library locator")
    relative = locator.removeprefix(LIBRARY_LOCATOR_PREFIX)
    path = PurePosixPath(relative)
    if (
        not relative
        or path.is_absolute()
        or ".." in path.parts
        or not path.parts
        or path.parts[0] != "Assets"
        or path.suffix.lower() != ".pdf"
    ):
        raise ValueError("source_locator is invalid")
    return f"{LIBRARY_LOCATOR_PREFIX}{path.as_posix()}"


def _public_manual(row: dict) -> dict:
    """Return only the Mac/UI-safe metadata contract."""
    return {
        "manual_id": row.get("manual_id"),
        "asset_id": row.get("asset_id"),
        "title": row.get("title"),
        "document_type": row.get("document_type"),
        "manufacturer": row.get("manufacturer"),
        "model_number": row.get("model_number"),
        "version_id": row.get("version_id"),
        "version_number": row.get("version_number"),
        "source_display_name": row.get("source_display_name"),
        "mime_type": row.get("mime_type"),
        "ingestion_status": row.get("ingestion_status"),
        "review_status": row.get("review_status"),
        "lifecycle_status": row.get("lifecycle_status"),
        "created_at": row.get("created_at"),
        "extracted_at": row.get("extracted_at"),
        "task_count": int(row.get("task_count") or 0),
    }


def _active_asset(asset_id: str) -> dict | None:
    return pm_db.execute_one_json(
        "SELECT id, name FROM propertymanager.assets WHERE id = %s AND is_active = true",
        (asset_id,),
    )


def _normalize_extraction_chunks(raw: object) -> list[dict]:
    if not isinstance(raw, list) or not raw or len(raw) > 200:
        raise ValueError("chunks must contain between 1 and 200 entries")
    normalized: list[dict] = []
    total_characters = 0
    for ordinal, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ValueError("Each extraction chunk must be an object")
        content = str(item.get("content") or "").strip()
        if not content or len(content) > 32_000:
            raise ValueError("Each extraction chunk must contain 1 to 32000 characters")
        page_number = item.get("page_number")
        if page_number is not None:
            try:
                page_number = int(page_number)
            except (TypeError, ValueError) as exc:
                raise ValueError("page_number must be an integer") from exc
            if page_number < 1:
                raise ValueError("page_number must be positive")
        heading = " ".join(str(item.get("section_heading") or "").split())[:500] or None
        total_characters += len(content)
        if total_characters > 1_500_000:
            raise ValueError("Extracted text is too large")
        normalized.append(
            {
                "id": str(uuid4()),
                "ordinal": ordinal,
                "page_number": page_number,
                "section_heading": heading,
                "content": content,
                "content_sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            }
        )
    return normalized


_MANUAL_SELECT = """
    SELECT m.id AS manual_id, m.asset_id, m.title, m.document_type, m.manufacturer, m.model_number,
           v.id AS version_id, v.version_number, v.source_display_name, v.mime_type,
           v.ingestion_status, v.review_status, v.lifecycle_status, v.created_at,
           (
               SELECT max(e.occurred_at)
               FROM propertymanager.asset_manual_state_event e
               WHERE e.manual_version_id = v.id AND e.event_type = 'ingestion_extracted'
           ) AS extracted_at,
           (
               SELECT count(*)
               FROM propertymanager.maintenance_tasks t
               WHERE t.asset_id = m.asset_id AND t.is_active = true
                 AND t.source_manual_name = v.source_display_name
           ) AS task_count
    FROM propertymanager.asset_manual m
    JOIN propertymanager.asset_manual_version v ON v.manual_id = m.id
"""


def register_handbook_routes(app: Flask) -> None:
    @app.get("/v1/assets/<asset_id>/manuals")
    @auth_required()
    def list_asset_manuals(asset_id: str):
        if _active_asset(asset_id) is None:
            return error_response("NOT_FOUND", "Asset not found", status=404)
        rows = pm_db.execute_json(
            _MANUAL_SELECT
            + " WHERE m.asset_id = %s AND v.lifecycle_status <> 'removed' ORDER BY m.title, v.version_number DESC",
            (asset_id,),
        )
        return jsonify([_public_manual(row) for row in rows])

    @app.post("/v1/internal/manual-library/assets/<asset_id>/manuals")
    @_dashboard_library_required
    def register_dashboard_manual(asset_id: str):
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return validation_error("JSON object body required")
        if _active_asset(asset_id) is None:
            return error_response("NOT_FOUND", "Asset not found", status=404)
        try:
            locator = _validate_library_locator(payload.get("source_locator"))
        except ValueError as exc:
            return validation_error(str(exc), field="source_locator")
        display_name = _safe_display_name(str(payload.get("source_display_name") or ""))
        if not display_name.lower().endswith(".pdf"):
            return validation_error("source_display_name must name a PDF", field="source_display_name")
        source_sha256 = str(payload.get("source_sha256") or "").strip().lower()
        if not _SHA256_RE.fullmatch(source_sha256):
            return validation_error("source_sha256 must be a lowercase SHA-256", field="source_sha256")
        try:
            byte_size = int(payload.get("byte_size"))
        except (TypeError, ValueError):
            return validation_error("byte_size must be an integer", field="byte_size")
        if byte_size <= 0 or byte_size > MAX_MANUAL_BYTES:
            return validation_error("byte_size is outside the allowed range", field="byte_size")
        document_type = str(payload.get("document_type") or "operator_manual").strip()
        if document_type not in DOCUMENT_TYPES:
            return validation_error("Unsupported manual document type", field="document_type")
        title = _safe_title(str(payload.get("title") or ""), display_name)
        manufacturer = " ".join(str(payload.get("manufacturer") or "").split())[:200] or None
        model_number = " ".join(str(payload.get("model_number") or "").split())[:200] or None

        duplicate = pm_db.execute_one_json(
            _MANUAL_SELECT
            + " WHERE m.asset_id = %s AND v.source_kind = 'pdf' AND v.source_sha256 = %s "
            + "AND v.lifecycle_status <> 'removed' ORDER BY v.version_number DESC LIMIT 1",
            (asset_id, source_sha256),
        )
        if duplicate is not None:
            result = _public_manual(duplicate)
            result["idempotent_replay"] = True
            return jsonify(result)

        manual_id, version_id, event_id = str(uuid4()), str(uuid4()), str(uuid4())
        created = pm_db.execute_top_level_one_json(
            """
            WITH created_manual AS (
                INSERT INTO propertymanager.asset_manual
                    (id, asset_id, document_key, title, document_type, manufacturer, model_number, created_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s, 'dashboard-manual-library')
                RETURNING id, asset_id, title, document_type, manufacturer, model_number
            ), created_version AS (
                INSERT INTO propertymanager.asset_manual_version
                    (id, manual_id, version_number, source_kind, source_locator, source_display_name,
                     source_sha256, mime_type, ingestion_status, review_status, lifecycle_status,
                     provenance, created_by)
                SELECT %s, id, 1, 'pdf', %s, %s, %s, 'application/pdf',
                       'pending', 'pending', 'draft', %s::jsonb, 'dashboard-manual-library'
                FROM created_manual
                RETURNING id, manual_id, version_number, source_display_name, mime_type,
                          ingestion_status, review_status, lifecycle_status, created_at
            ), created_event AS (
                INSERT INTO propertymanager.asset_manual_state_event
                    (id, manual_version_id, event_type, from_state, to_state, actor_id, reason)
                SELECT %s, id, 'ingestion_started', '{}'::jsonb,
                       '{"ingestion_status":"pending","review_status":"pending","lifecycle_status":"draft"}'::jsonb,
                       'dashboard-manual-library', 'Dashboard library registration'
                FROM created_version
            )
            SELECT row_to_json(result)
            FROM (
                SELECT m.id AS manual_id, m.asset_id, m.title, m.document_type, m.manufacturer, m.model_number,
                       v.id AS version_id, v.version_number, v.source_display_name, v.mime_type,
                       v.ingestion_status, v.review_status, v.lifecycle_status, v.created_at,
                       NULL::timestamptz AS extracted_at, 0 AS task_count
                FROM created_manual m JOIN created_version v ON v.manual_id = m.id
            ) result
            """,
            (
                manual_id, asset_id, f"dashboard-pdf-{source_sha256[:48]}", title, document_type,
                manufacturer, model_number, version_id, locator, display_name, source_sha256,
                json.dumps({"storage_owner": "dashboard-intelmini", "byte_size": byte_size}), event_id,
            ),
        )
        if created is None:
            raise RuntimeError("Manual registration did not return a library record")
        return jsonify(_public_manual(created)), 201

    @app.get("/v1/internal/manual-library/assets/<asset_id>/manuals/<manual_id>/versions/<version_id>/source")
    @_dashboard_library_required
    def resolve_dashboard_manual_source(asset_id: str, manual_id: str, version_id: str):
        row = pm_db.execute_one_json(
            """
            SELECT v.source_locator, v.source_display_name, v.mime_type
            FROM propertymanager.asset_manual m
            JOIN propertymanager.asset_manual_version v ON v.manual_id = m.id
            WHERE m.id = %s AND m.asset_id = %s AND v.id = %s AND v.lifecycle_status <> 'removed'
            """,
            (manual_id, asset_id, version_id),
        )
        if row is None:
            return error_response("NOT_FOUND", "Manual version not found", status=404)
        try:
            locator = _validate_library_locator(row.get("source_locator"))
        except ValueError:
            return error_response("MANUAL_SOURCE_UNAVAILABLE", "Manual source is unavailable", status=409)
        return jsonify({
            "source_locator": locator,
            "source_display_name": _safe_display_name(str(row.get("source_display_name") or "manual.pdf")),
            "mime_type": "application/pdf",
        })

    @app.post("/v1/assets/<asset_id>/manuals/<manual_id>/versions/<version_id>/extraction")
    @auth_required()
    def record_asset_manual_extraction(asset_id: str, manual_id: str, version_id: str):
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return validation_error("JSON object body required")
        try:
            chunks = _normalize_extraction_chunks(payload.get("chunks"))
        except ValueError as exc:
            return validation_error(str(exc), field="chunks")
        extractor_name = " ".join(str(payload.get("extractor_name") or "").split())[:100]
        extractor_version = " ".join(str(payload.get("extractor_version") or "").split())[:64]
        if not extractor_name or not extractor_version:
            return validation_error("Local extractor name and version are required", field="extractor_name")

        existing = pm_db.execute_one_json(
            _MANUAL_SELECT
            + " WHERE m.id = %s AND m.asset_id = %s AND v.id = %s AND v.lifecycle_status <> 'removed'",
            (manual_id, asset_id, version_id),
        )
        if existing is None:
            return error_response("NOT_FOUND", "Manual version not found", status=404)
        if existing.get("ingestion_status") == "extracted":
            result = _public_manual(existing)
            result["idempotent_replay"] = True
            return jsonify(result)
        if existing.get("ingestion_status") != "pending" or existing.get("lifecycle_status") != "draft":
            return error_response("MANUAL_NOT_EXTRACTABLE", "Manual is not awaiting extraction", status=409)

        values_sql = ", ".join("(%s::uuid, %s, %s, %s, %s, %s, %s)" for _ in chunks)
        values_params: list[object] = []
        for chunk in chunks:
            values_params.extend([
                chunk["id"], chunk["ordinal"], chunk["page_number"], chunk["section_heading"], chunk["content"],
                chunk["content_sha256"], json.dumps({"extractor": "local_mac"}),
            ])
        event_id = str(uuid4())
        actor_id = server_submitter_identity()
        created = pm_db.execute_top_level_one_json(
            f"""
            WITH supplied_chunks (id, chunk_ordinal, page_number, section_heading, content, content_sha256, extraction_metadata) AS (
                VALUES {values_sql}
            ), extractable_version AS (
                SELECT v.id, v.manual_id
                FROM propertymanager.asset_manual m
                JOIN propertymanager.asset_manual_version v ON v.manual_id = m.id
                WHERE m.id = %s AND m.asset_id = %s AND v.id = %s
                  AND v.ingestion_status = 'pending' AND v.review_status = 'pending'
                  AND v.lifecycle_status = 'draft'
                FOR UPDATE
            ), inserted_chunks AS (
                INSERT INTO propertymanager.asset_manual_chunk
                    (id, manual_version_id, chunk_ordinal, page_number, section_heading, content,
                     content_sha256, extraction_metadata)
                SELECT c.id, v.id, c.chunk_ordinal, c.page_number, c.section_heading, c.content,
                       c.content_sha256, c.extraction_metadata::jsonb
                FROM supplied_chunks c CROSS JOIN extractable_version v
            ), extracted_version AS (
                UPDATE propertymanager.asset_manual_version v
                SET ingestion_status = 'extracted', extractor_name = %s, extractor_version = %s
                WHERE v.id IN (SELECT id FROM extractable_version)
                RETURNING v.id, v.manual_id, v.version_number, v.source_display_name, v.mime_type,
                          v.ingestion_status, v.review_status, v.lifecycle_status, v.created_at
            ), extraction_event AS (
                INSERT INTO propertymanager.asset_manual_state_event
                    (id, manual_version_id, event_type, from_state, to_state, actor_id, reason)
                SELECT %s, id, 'ingestion_extracted', %s::jsonb, %s::jsonb, %s,
                       'local Mac extraction completed'
                FROM extracted_version
                RETURNING occurred_at
            )
            SELECT row_to_json(result)
            FROM (
                SELECT m.id AS manual_id, m.asset_id, m.title, m.document_type, m.manufacturer, m.model_number,
                       v.id AS version_id, v.version_number, v.source_display_name, v.mime_type,
                       v.ingestion_status, v.review_status, v.lifecycle_status, v.created_at,
                       (SELECT max(occurred_at) FROM extraction_event) AS extracted_at, 0 AS task_count
                FROM propertymanager.asset_manual m JOIN extracted_version v ON v.manual_id = m.id
            ) result
            """,
            tuple(values_params) + (
                manual_id, asset_id, version_id, extractor_name, extractor_version, event_id,
                json.dumps({"ingestion_status": "pending"}), json.dumps({"ingestion_status": "extracted"}), actor_id,
            ),
        )
        if created is None:
            return error_response(
                "MANUAL_NOT_EXTRACTABLE",
                "Manual extraction was already recorded or is unavailable",
                status=409,
            )
        return jsonify(_public_manual(created))
