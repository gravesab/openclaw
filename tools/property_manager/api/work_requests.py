"""Isolated PropertyManager work-request intake routes.

Work requests are deliberately not exposed through the maintenance-task routes:
they cannot become due work, completions, meter readings, inventory movements,
Calendar events, purchases, or Finance entries until an explicit human review
creates a separate scheduled task.
"""

from __future__ import annotations

import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from flask import Flask, g, jsonify, request

import db as pm_db
from auth import auth_required, review_required, server_submitter_identity
from errors import error_response, validation_error

MAX_DESCRIPTION_CHARS = 12_000
MAX_PHOTO_BYTES = 10 * 1024 * 1024
ATTACHMENT_TTL_MINUTES = 20
JPEG_CONTENT_TYPE = "image/jpeg"


def _attachment_root() -> Path:
    return Path(os.environ.get("PROPERTYMANAGER_ATTACHMENTS_ROOT", "/var/lib/propertymanager/attachments"))


def _request_row(request_id: str) -> dict | None:
    return pm_db.execute_one_json(
        """
        SELECT id, area, item, task_description, asset_id, category_name, priority,
               intake_state, submitted_by, submitted_at, triaged_by, triaged_at,
               triage_reason, converted_task_id, intake_idempotency_key
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND kind = 'Work Request' AND is_active = true
        """,
        (request_id,),
    )


def _public_request(row: dict, *, replay: bool = False) -> dict:
    result = {
        "id": row["id"],
        "request_number": str(row["id"]),
        "area": row.get("area"),
        "asset_id": row.get("asset_id"),
        "description": row.get("task_description"),
        "intake_state": row.get("intake_state"),
        "submitted_at": row.get("submitted_at"),
        "submitted_by": row.get("submitted_by"),
        "triaged_at": row.get("triaged_at"),
        "converted_task_id": row.get("converted_task_id"),
    }
    if replay:
        result["idempotent_replay"] = True
    return result


def _sanitize_jpeg(payload: bytes) -> bytes:
    """Drop JPEG APP metadata segments, including EXIF GPS, before persistence."""
    if not payload.startswith(b"\xff\xd8"):
        raise ValueError("Photo bytes are not a JPEG image")
    output = bytearray(payload[:2])
    index = 2
    while index < len(payload):
        if payload[index] != 0xFF:
            raise ValueError("Malformed JPEG image")
        marker_start = index
        while index < len(payload) and payload[index] == 0xFF:
            index += 1
        if index >= len(payload):
            raise ValueError("Malformed JPEG image")
        marker = payload[index]
        index += 1
        if marker in {0xD9, 0xDA}:  # EOI or start of scan; the remainder is image data.
            output.extend(payload[marker_start:])
            return bytes(output)
        if marker in set(range(0xD0, 0xD8)) | {0x01}:
            output.extend(payload[marker_start:index])
            continue
        if index + 2 > len(payload):
            raise ValueError("Malformed JPEG image")
        length = int.from_bytes(payload[index:index + 2], "big")
        if length < 2 or index + length > len(payload):
            raise ValueError("Malformed JPEG image")
        # APP0-APP15 segments may contain EXIF/XMP/IPTC/location data. They are
        # nonessential for the intake display and are never retained.
        if not 0xE0 <= marker <= 0xEF:
            output.extend(payload[marker_start:index + length])
        index += length
    raise ValueError("Malformed JPEG image")


def _normalize_materials(raw: object) -> list[dict]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError("materials must be an array")
    normalized: list[dict] = []
    for position, value in enumerate(raw):
        if not isinstance(value, dict):
            raise ValueError("Each material must be an object")
        name = str(value.get("name") or "").strip()
        if not name:
            raise ValueError("Each material needs a name")
        try:
            quantity = float(value.get("quantity") if value.get("quantity") is not None else 1)
        except (TypeError, ValueError) as exc:
            raise ValueError("material quantity must be a number") from exc
        if quantity <= 0:
            raise ValueError("material quantity must be greater than zero")
        normalized.append({
            "id": str(uuid4()), "name": name, "quantity": quantity,
            "unit": str(value.get("unit") or "").strip(),
            "notes": str(value.get("note") or "").strip(), "sort_order": position,
        })
    return normalized


def _attachment_values_cte(attachment_ids: list[str]) -> tuple[str, list[str]]:
    """Build a UUID values relation for the single intake transaction."""
    if not attachment_ids:
        return "SELECT NULL::uuid AS id WHERE false", []
    return "VALUES " + ", ".join("(%s::uuid)" for _ in attachment_ids), attachment_ids


def register_work_request_routes(app: Flask) -> None:
    @app.post("/v1/work-requests/attachments")
    @auth_required()
    def issue_work_request_attachment():
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return validation_error("JSON object body required")
        if str(payload.get("content_type") or "").lower() != JPEG_CONTENT_TYPE:
            return validation_error("Only JPEG photos are accepted", field="content_type")
        try:
            max_bytes = int(payload.get("byte_size") or 0)
        except (TypeError, ValueError):
            return validation_error("byte_size must be an integer", field="byte_size")
        if max_bytes < 1 or max_bytes > MAX_PHOTO_BYTES:
            return validation_error("Photo size is outside the allowed range", field="byte_size")
        submitter = server_submitter_identity()
        idempotency_key = str(request.headers.get("Idempotency-Key") or "").strip()
        if not idempotency_key or len(idempotency_key) > 200:
            return validation_error("Idempotency-Key is required", field="Idempotency-Key")
        existing = pm_db.execute_one_json(
            """SELECT id, content_type, max_bytes
               FROM propertymanager.maintenance_attachment_operations
               WHERE created_by = %s AND allocation_idempotency_key = %s""",
            (submitter, idempotency_key),
        )
        if existing:
            if existing.get("content_type") != JPEG_CONTENT_TYPE or int(existing.get("max_bytes") or 0) != max_bytes:
                return error_response("IDEMPOTENCY_CONFLICT", "Attachment retry payload does not match", status=409)
            return jsonify({"attachment_id": existing["id"], "content_type": JPEG_CONTENT_TYPE,
                            "max_bytes": max_bytes, "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60,
                            "idempotent_replay": True})
        operation_id = str(uuid4())
        try:
            pm_db.execute(
                """
                INSERT INTO propertymanager.maintenance_attachment_operations
                    (id, created_by, content_type, max_bytes, expires_at, allocation_idempotency_key)
                VALUES (%s, %s, %s, %s, now() + interval '20 minutes', %s)
                """,
                (operation_id, submitter, JPEG_CONTENT_TYPE, max_bytes, idempotency_key),
            )
        except Exception:
            existing = pm_db.execute_one_json(
                """SELECT id, content_type, max_bytes
                   FROM propertymanager.maintenance_attachment_operations
                   WHERE created_by = %s AND allocation_idempotency_key = %s""",
                (submitter, idempotency_key),
            )
            if existing and existing.get("content_type") == JPEG_CONTENT_TYPE and int(existing.get("max_bytes") or 0) == max_bytes:
                return jsonify({"attachment_id": existing["id"], "content_type": JPEG_CONTENT_TYPE,
                                "max_bytes": max_bytes, "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60,
                                "idempotent_replay": True})
            raise
        return jsonify({"attachment_id": operation_id, "content_type": JPEG_CONTENT_TYPE,
                        "max_bytes": max_bytes, "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60}), 201

    @app.put("/v1/work-requests/attachments/<attachment_id>/content")
    @auth_required()
    def upload_work_request_attachment(attachment_id: str):
        operation = pm_db.execute_one_json(
            """SELECT id, created_by, content_type, max_bytes, state, expires_at, allocation_idempotency_key
               FROM propertymanager.maintenance_attachment_operations WHERE id = %s""",
            (attachment_id,),
        )
        if operation is None or operation.get("created_by") != server_submitter_identity():
            return error_response("NOT_FOUND", "Attachment operation not found", status=404)
        idempotency_key = str(request.headers.get("Idempotency-Key") or "").strip()
        if not idempotency_key or operation.get("allocation_idempotency_key") != idempotency_key:
            return error_response("ATTACHMENT_RETRY_UNAUTHORIZED", "Attachment retry key is invalid", status=409)
        if operation.get("state") in {"uploaded", "attached"}:
            return jsonify({"attachment_id": attachment_id, "status": "uploaded", "idempotent_replay": True})
        if operation.get("state") != "issued":
            return error_response("ATTACHMENT_NOT_UPLOADABLE", "Attachment cannot be uploaded", status=409)
        if operation.get("expires_at") and str(operation["expires_at"]) < datetime.now(timezone.utc).isoformat():
            return error_response("ATTACHMENT_EXPIRED", "Attachment operation expired", status=409)
        if request.content_type.split(";", 1)[0].lower() != JPEG_CONTENT_TYPE:
            return validation_error("Content-Type must be image/jpeg", field="Content-Type")
        raw = request.get_data(cache=False)
        if not raw or len(raw) > int(operation["max_bytes"]):
            return validation_error("Photo size is outside the issued limit", field="photo")
        try:
            sanitized = _sanitize_jpeg(raw)
        except ValueError as exc:
            return validation_error(str(exc), field="photo")
        root = _attachment_root()
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination = root / f"{attachment_id}.jpg"
        destination.write_bytes(sanitized)
        digest = hashlib.sha256(sanitized).hexdigest()
        pm_db.execute(
            """UPDATE propertymanager.maintenance_attachment_operations
               SET state = 'uploaded', storage_path = %s, byte_size = %s, sha256 = %s, uploaded_at = now()
               WHERE id = %s AND state = 'issued'""",
            (str(destination), len(sanitized), digest, attachment_id),
        )
        # Never reveal a host path, filename, digest, or download URL.
        return jsonify({"attachment_id": attachment_id, "status": "uploaded"})

    @app.post("/v1/work-requests")
    @auth_required()
    def submit_work_request():
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return validation_error("JSON object body required")
        idempotency_key = str(request.headers.get("Idempotency-Key") or "").strip()
        if not idempotency_key or len(idempotency_key) > 200:
            return validation_error("Idempotency-Key is required", field="Idempotency-Key")
        submitter = server_submitter_identity()
        existing = pm_db.execute_one_json(
            """SELECT id, area, item, task_description, asset_id, intake_state, submitted_by, submitted_at,
                      triaged_at, converted_task_id FROM propertymanager.maintenance_tasks
               WHERE kind = 'Work Request' AND submitted_by = %s AND intake_idempotency_key = %s""",
            (submitter, idempotency_key),
        )
        if existing:
            return jsonify(_public_request(existing, replay=True))
        description = str(payload.get("description") or "").strip()
        if not description or len(description) > MAX_DESCRIPTION_CHARS:
            return validation_error("description is required and must be at most 12000 characters", field="description")
        asset_id = str(payload.get("asset_id") or "").strip() or None
        area = str(payload.get("area") or "").strip()
        if not asset_id and not area:
            return validation_error("area is required when asset_id is not supplied", field="area")
        try:
            materials = _normalize_materials(payload.get("materials"))
        except ValueError as exc:
            return validation_error(str(exc), field="materials")
        attachment_ids = payload.get("attachment_ids") or []
        if not isinstance(attachment_ids, list) or any(not isinstance(value, str) for value in attachment_ids):
            return validation_error("attachment_ids must be an array of opaque IDs", field="attachment_ids")
        if len(set(attachment_ids)) != len(attachment_ids):
            return validation_error("attachment_ids must not contain duplicates", field="attachment_ids")
        for attachment_id in attachment_ids:
            operation = pm_db.execute_one_json(
                """SELECT id, content_type, storage_path, byte_size, sha256 FROM propertymanager.maintenance_attachment_operations
                   WHERE id = %s AND created_by = %s AND state = 'uploaded' AND expires_at > now()""",
                (attachment_id, submitter),
            )
            if operation is None:
                return error_response("ATTACHMENT_UNAVAILABLE", "An attachment is unavailable", status=409)
        request_id = str(uuid4())
        now = datetime.now(timezone.utc)
        attachment_values, attachment_params = _attachment_values_cte(attachment_ids)
        statements = [
            "requested_attachments(id) AS (" + attachment_values + ")",
            "locked_attachments AS ("
            "SELECT o.id, o.storage_path, o.content_type, o.byte_size, o.sha256 "
            "FROM propertymanager.maintenance_attachment_operations o "
            "JOIN requested_attachments r ON r.id = o.id "
            "WHERE o.created_by = %s AND o.state = 'uploaded' AND o.expires_at > now() FOR UPDATE"
            ")",
            "attachment_guard AS ("
            "SELECT 1 AS ok FROM locked_attachments HAVING count(*) = %s"
            ")",
            "created_request AS ("
            "INSERT INTO propertymanager.maintenance_tasks "
            "(id, area, item, category_name, priority, frequency, task_description, warning_days, critical_days, "
            "last_done, next_due, is_active, kind, asset_id, intake_state, submitted_by, submitted_at, "
            "intake_idempotency_key, schedule_kind, completion_history, tools_required) "
            "SELECT %s, %s, 'Work request', 'House', 'Medium', 'As Needed', %s, 0, 0, %s, %s, true, "
            "'Work Request', %s, 'submitted', %s, %s, %s, 'calendar', '[]'::jsonb, '[]'::jsonb "
            "FROM attachment_guard RETURNING id"
            ")",
            "intake_event AS ("
            "INSERT INTO propertymanager.maintenance_task_intake_events (id, task_id, from_state, to_state, actor, reason) "
            "SELECT %s, id, NULL, 'submitted', %s, 'submitted from mobile intake' FROM created_request"
            ")",
        ]
        params: list[object] = [
            *attachment_params, submitter, len(attachment_ids), request_id, area or "Unassigned", description,
            now, now, asset_id, submitter, now, idempotency_key, str(uuid4()), submitter,
        ]
        for position, material in enumerate(materials):
            statements.append(
                f"draft_material_{position} AS ("
                "INSERT INTO propertymanager.maintenance_task_parts "
                "(id, task_id, name, quantity, unit, notes, sort_order, provenance, created_at, updated_at) "
                "SELECT %s, id, %s, %s, %s, %s, %s, 'request_draft', now(), now() FROM created_request"
                ")"
            )
            params.extend([
                material["id"], material["name"], material["quantity"], material["unit"],
                material["notes"], material["sort_order"],
            ])
        statements.extend([
            "attached_operations AS ("
            "UPDATE propertymanager.maintenance_attachment_operations o SET state = 'attached' "
            "FROM locked_attachments a WHERE o.id = a.id AND o.state = 'uploaded' RETURNING o.id"
            ")",
            "attached_photos AS ("
            "INSERT INTO propertymanager.maintenance_task_photos "
            "(id, task_id, file_name, storage_path, content_type, byte_size, sha256, sanitized_at) "
            "SELECT a.id, r.id, '', a.storage_path, a.content_type, a.byte_size, a.sha256, now() "
            "FROM created_request r JOIN locked_attachments a ON true JOIN attached_operations u ON u.id = a.id"
            ")",
            "SELECT row_to_json(created_request) FROM created_request",
        ])
        try:
            created = pm_db.execute_top_level_one_json("WITH " + ",\n".join(statements), tuple(params))
        except Exception:
            existing = pm_db.execute_one_json(
                """SELECT id, area, item, task_description, asset_id, intake_state, submitted_by, submitted_at,
                          triaged_at, converted_task_id FROM propertymanager.maintenance_tasks
                   WHERE kind = 'Work Request' AND submitted_by = %s AND intake_idempotency_key = %s""",
                (submitter, idempotency_key),
            )
            if existing:
                return jsonify(_public_request(existing, replay=True))
            raise
        if created is None:
            return error_response("ATTACHMENT_UNAVAILABLE", "An attachment is unavailable", status=409)
        created_row = _request_row(request_id)
        return jsonify(_public_request(created_row or {"id": request_id, "intake_state": "submitted"})), 201

    @app.get("/v1/work-requests/<request_id>")
    @auth_required()
    def get_work_request(request_id: str):
        row = _request_row(request_id)
        if row is None:
            return error_response("NOT_FOUND", "Work request not found", status=404)
        return jsonify(_public_request(row))

    @app.post("/v1/work-requests/<request_id>/triage")
    @review_required()
    def triage_work_request(request_id: str):
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return validation_error("JSON object body required")
        row = _request_row(request_id)
        if row is None:
            return error_response("NOT_FOUND", "Work request not found", status=404)
        if row.get("intake_state") != "submitted":
            return error_response("INVALID_INTAKE_STATE", "Only submitted requests can be triaged", status=409)
        area = str(payload.get("area") or row.get("area") or "").strip()
        asset_id = str(payload.get("asset_id") or row.get("asset_id") or "").strip()
        category = str(payload.get("category_name") or "").strip()
        priority = str(payload.get("priority") or "").strip()
        reason = str(payload.get("reason") or "").strip()
        if not all((area, asset_id, category, priority, reason)):
            return validation_error("area, asset_id, category_name, priority, and reason are required")
        triaged = pm_db.execute_top_level_one_json(
            """WITH triaged_request AS (
                   UPDATE propertymanager.maintenance_tasks
                   SET area = %s, asset_id = %s, category_name = %s, priority = %s,
                       intake_state = 'triaged', triaged_by = %s, triaged_at = now(), triage_reason = %s, updated_at = now()
                   WHERE id = %s AND kind = 'Work Request' AND intake_state = 'submitted'
                   RETURNING id
               ), intake_event AS (
                   INSERT INTO propertymanager.maintenance_task_intake_events
                       (id, task_id, from_state, to_state, actor, reason)
                   SELECT %s, id, 'submitted', 'triaged', %s, %s FROM triaged_request
               )
               SELECT row_to_json(triaged_request) FROM triaged_request""",
            (area, asset_id, category, priority, g.operator_identity, reason, request_id,
             str(uuid4()), g.operator_identity, reason),
        )
        if triaged is None:
            return error_response("INVALID_INTAKE_STATE", "Only submitted requests can be triaged", status=409)
        return jsonify(_public_request(_request_row(request_id) or row))

    @app.post("/v1/work-requests/<request_id>/convert")
    @review_required()
    def convert_work_request(request_id: str):
        maintenance_id = str(uuid4())
        converted = pm_db.execute_top_level_one_json(
            """WITH claimed_request AS (
                   UPDATE propertymanager.maintenance_tasks
                   SET intake_state = 'converted', converted_task_id = %s, updated_at = now()
                   WHERE id = %s AND kind = 'Work Request' AND intake_state = 'triaged'
                   RETURNING area, task_description, category_name, priority, asset_id, id
               ), scheduled_task AS (
                   INSERT INTO propertymanager.maintenance_tasks
                       (id, area, item, category_name, priority, frequency, task_description,
                        warning_days, critical_days, last_done, next_due, is_active, kind,
                        asset_id, schedule_kind, origin, completion_history, tools_required)
                   SELECT %s, area, 'Work request: ' || left(coalesce(task_description, ''), 120),
                          category_name, priority, 'As Needed', task_description,
                          30, 45, now(), now() + interval '30 days', true, 'Scheduled',
                          asset_id, 'calendar', 'owner', '[]'::jsonb, '[]'::jsonb
                   FROM claimed_request RETURNING id
               ), intake_event AS (
                   INSERT INTO propertymanager.maintenance_task_intake_events (id, task_id, from_state, to_state, actor, reason)
                   SELECT %s, id, 'triaged', 'converted', %s, 'explicit maintenance conversion' FROM claimed_request
               )
               SELECT row_to_json(scheduled_task) FROM scheduled_task""",
            (maintenance_id, request_id, maintenance_id, str(uuid4()), g.operator_identity),
        )
        if converted is None:
            row = _request_row(request_id)
            if row is None:
                return error_response("NOT_FOUND", "Work request not found", status=404)
            return error_response("INVALID_INTAKE_STATE", "Only triaged requests can be converted", status=409)
        return jsonify({
            "request": _public_request(_request_row(request_id) or {"id": request_id, "intake_state": "converted"}),
            "maintenance_task_id": maintenance_id,
        })
