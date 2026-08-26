"""Isolated PropertyManager work-request intake routes.

Work requests are deliberately not exposed through the maintenance-task routes:
they cannot become due work, completions, meter readings, inventory movements,
Calendar events, purchases, or Finance entries until an explicit human review
creates a separate scheduled task.
"""

from __future__ import annotations

import hashlib
import os
from datetime import datetime, timedelta, timezone
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
        operation_id = str(uuid4())
        submitter = server_submitter_identity()
        pm_db.execute(
            """
            INSERT INTO propertymanager.maintenance_attachment_operations
                (id, created_by, content_type, max_bytes, expires_at)
            VALUES (%s, %s, %s, %s, now() + interval '20 minutes')
            """,
            (operation_id, submitter, JPEG_CONTENT_TYPE, max_bytes),
        )
        return jsonify({"attachment_id": operation_id, "content_type": JPEG_CONTENT_TYPE,
                        "max_bytes": max_bytes, "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60}), 201

    @app.put("/v1/work-requests/attachments/<attachment_id>/content")
    @auth_required()
    def upload_work_request_attachment(attachment_id: str):
        operation = pm_db.execute_one_json(
            """SELECT id, created_by, content_type, max_bytes, state, expires_at
               FROM propertymanager.maintenance_attachment_operations WHERE id = %s""",
            (attachment_id,),
        )
        if operation is None or operation.get("created_by") != server_submitter_identity():
            return error_response("NOT_FOUND", "Attachment operation not found", status=404)
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
        attachment_operations: dict[str, dict] = {}
        for attachment_id in attachment_ids:
            operation = pm_db.execute_one_json(
                """SELECT id, content_type, storage_path, byte_size, sha256 FROM propertymanager.maintenance_attachment_operations
                   WHERE id = %s AND created_by = %s AND state = 'uploaded' AND expires_at > now()""",
                (attachment_id, submitter),
            )
            if operation is None:
                return error_response("ATTACHMENT_UNAVAILABLE", "An attachment is unavailable", status=409)
            attachment_operations[attachment_id] = operation
        request_id = str(uuid4())
        now = datetime.now(timezone.utc)
        try:
            pm_db.execute(
                """INSERT INTO propertymanager.maintenance_tasks
                    (id, area, item, category_name, priority, frequency, task_description,
                     warning_days, critical_days, last_done, next_due, is_active, kind,
                     intake_state, submitted_by, submitted_at, intake_idempotency_key,
                     schedule_kind, completion_history, tools_required)
                   VALUES (%s, %s, %s, 'House', 'Medium', 'As Needed', %s,
                           0, 0, %s, %s, true, 'Work Request', 'submitted', %s, %s, %s,
                           'calendar', '[]'::jsonb, '[]'::jsonb)""",
                (request_id, area or 'Unassigned', 'Work request', description, now, now, submitter, now, idempotency_key),
            )
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
        if asset_id:
            pm_db.execute("UPDATE propertymanager.maintenance_tasks SET asset_id = %s WHERE id = %s", (asset_id, request_id))
        pm_db.execute(
            """INSERT INTO propertymanager.maintenance_task_intake_events
                (id, task_id, from_state, to_state, actor, reason)
               VALUES (%s, %s, NULL, 'submitted', %s, 'submitted from mobile intake')""",
            (str(uuid4()), request_id, submitter),
        )
        for material in materials:
            pm_db.execute(
                """INSERT INTO propertymanager.maintenance_task_parts
                    (id, task_id, name, quantity, unit, notes, sort_order, provenance, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, 'request_draft', now(), now())""",
                (material["id"], request_id, material["name"], material["quantity"], material["unit"], material["notes"], material["sort_order"]),
            )
        for attachment_id in attachment_ids:
            operation = attachment_operations[attachment_id]
            pm_db.execute(
                """INSERT INTO propertymanager.maintenance_task_photos
                    (id, task_id, file_name, storage_path, content_type, byte_size, sha256, sanitized_at)
                   VALUES (%s, %s, '', %s, %s, %s, %s, now())""",
                (attachment_id, request_id, operation["storage_path"], operation["content_type"], operation["byte_size"], operation["sha256"]),
            )
            pm_db.execute("UPDATE propertymanager.maintenance_attachment_operations SET state = 'attached' WHERE id = %s", (attachment_id,))
        created = _request_row(request_id)
        return jsonify(_public_request(created or {"id": request_id, "intake_state": "submitted"})), 201

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
        pm_db.execute(
            """UPDATE propertymanager.maintenance_tasks
               SET area = %s, asset_id = %s, category_name = %s, priority = %s,
                   intake_state = 'triaged', triaged_by = %s, triaged_at = now(), triage_reason = %s, updated_at = now()
               WHERE id = %s AND kind = 'Work Request' AND intake_state = 'submitted'""",
            (area, asset_id, category, priority, g.operator_identity, reason, request_id),
        )
        pm_db.execute(
            """INSERT INTO propertymanager.maintenance_task_intake_events
                (id, task_id, from_state, to_state, actor, reason)
               VALUES (%s, %s, 'submitted', 'triaged', %s, %s)""",
            (str(uuid4()), request_id, g.operator_identity, reason),
        )
        return jsonify(_public_request(_request_row(request_id) or row))

    @app.post("/v1/work-requests/<request_id>/convert")
    @review_required()
    def convert_work_request(request_id: str):
        row = _request_row(request_id)
        if row is None:
            return error_response("NOT_FOUND", "Work request not found", status=404)
        if row.get("intake_state") != "triaged":
            return error_response("INVALID_INTAKE_STATE", "Only triaged requests can be converted", status=409)
        maintenance_id = str(uuid4())
        pm_db.execute_script([
            ("""INSERT INTO propertymanager.maintenance_tasks
                (id, area, item, category_name, priority, frequency, task_description,
                 warning_days, critical_days, last_done, next_due, is_active, kind,
                 asset_id, schedule_kind, origin, completion_history, tools_required)
               VALUES (%s, %s, %s, %s, %s, 'As Needed', %s,
                       30, 45, now(), now() + interval '30 days', true, 'Scheduled',
                       %s, 'calendar', 'owner', '[]'::jsonb, '[]'::jsonb)""",
             (maintenance_id, row.get("area"), "Work request: " + str(row.get("task_description") or "")[:120],
              row.get("category_name"), row.get("priority"), row.get("task_description"), row.get("asset_id"))),
            ("""UPDATE propertymanager.maintenance_tasks
                SET intake_state = 'converted', converted_task_id = %s, updated_at = now()
                WHERE id = %s AND intake_state = 'triaged'""", (maintenance_id, request_id)),
            ("""INSERT INTO propertymanager.maintenance_task_intake_events
                (id, task_id, from_state, to_state, actor, reason)
                VALUES (%s, %s, 'triaged', 'converted', %s, 'explicit maintenance conversion')""",
             (str(uuid4()), request_id, g.operator_identity)),
        ])
        return jsonify({"request": _public_request(_request_row(request_id) or row), "maintenance_task_id": maintenance_id})
