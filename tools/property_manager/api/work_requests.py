"""Isolated PropertyManager work-request intake routes.

Work requests are deliberately not exposed through the maintenance-task routes:
they cannot become due work, completions, meter readings, inventory movements,
Calendar events, purchases, or Finance entries until an explicit human review
creates a separate scheduled task.
"""

from __future__ import annotations

import fcntl
import hashlib
import math
import os
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID, uuid4

from flask import Flask, g, jsonify, request

import db as pm_db
from auth import auth_required, review_required, server_submitter_identity
from errors import error_response, validation_error

MAX_DESCRIPTION_CHARS = 12_000
MAX_PHOTO_BYTES = 10 * 1024 * 1024
MAX_PHOTOS_PER_REQUEST = 5
ATTACHMENT_TTL_MINUTES = 20
JPEG_CONTENT_TYPE = "image/jpeg"


def _attachment_root() -> Path:
    return Path(os.environ.get("PROPERTYMANAGER_ATTACHMENTS_ROOT", "/var/lib/propertymanager/attachments"))


@contextmanager
def _attachment_upload_lock(root: Path, attachment_id: str):
    """Serialize finalization for one opaque attachment across API workers."""
    lock_path = root / f".{attachment_id}.upload.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def _attachment_operation(attachment_id: str) -> dict | None:
    return pm_db.execute_one_json(
        """SELECT id, created_by, content_type, max_bytes, state, expires_at,
                  allocation_idempotency_key, storage_path, byte_size, sha256
           FROM propertymanager.maintenance_attachment_operations WHERE id = %s""",
        (attachment_id,),
    )


def _operation_matches_file(operation: dict | None, destination: Path, size: int, digest: str) -> bool:
    return bool(
        operation
        and operation.get("state") in {"uploaded", "attached"}
        and operation.get("storage_path") == str(destination)
        and int(operation.get("byte_size") or 0) == size
        and operation.get("sha256") == digest
    )


def _replay_attachment_allocation(existing: dict, max_bytes: int):
    if existing.get("content_type") != JPEG_CONTENT_TYPE or int(existing.get("max_bytes") or 0) != max_bytes:
        return error_response("IDEMPOTENCY_CONFLICT", "Attachment retry payload does not match", status=409)
    if existing.get("expired") and existing.get("state") != "attached":
        root = _attachment_root()
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _attachment_upload_lock(root, str(existing["id"])):
            (root / f"{existing['id']}.jpg").unlink(missing_ok=True)
            pm_db.execute(
                """UPDATE propertymanager.maintenance_attachment_operations
                   SET state = 'issued', expires_at = now() + interval '20 minutes',
                       storage_path = NULL, byte_size = NULL, sha256 = NULL, uploaded_at = NULL
                   WHERE id = %s AND expires_at <= now() AND state IN ('issued', 'uploaded', 'expired')""",
                (existing["id"],),
            )
    return jsonify({
        "attachment_id": existing["id"],
        "content_type": JPEG_CONTENT_TYPE,
        "max_bytes": max_bytes,
        "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60,
        "idempotent_replay": True,
    })


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
        if not math.isfinite(quantity) or quantity <= 0:
            raise ValueError("material quantity must be finite and greater than zero")
        normalized.append({
            "id": str(uuid4()), "name": name, "quantity": quantity,
            "unit": str(value.get("unit") or "").strip(),
            "notes": str(value.get("note") or "").strip(), "sort_order": position,
        })
    return normalized


def _normalize_uuid(value: str, *, field: str) -> str:
    try:
        return str(UUID(value))
    except (ValueError, AttributeError) as exc:
        raise ValueError(f"{field} must be a valid opaque ID") from exc


def _reap_expired_unattached_photos(submitter: str) -> None:
    """Remove expired intake uploads without touching photos attached to requests."""
    expired = pm_db.execute_json(
        """SELECT id FROM propertymanager.maintenance_attachment_operations
           WHERE created_by = %s AND state IN ('issued', 'uploaded', 'expired') AND expires_at <= now()""",
        (submitter,),
    )
    if not expired:
        return
    root = _attachment_root()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    for row in expired:
        attachment_id = str(row.get("id") or "")
        try:
            attachment_id = _normalize_uuid(attachment_id, field="attachment_id")
        except ValueError:
            continue
        with _attachment_upload_lock(root, attachment_id):
            operation = pm_db.execute_one_json(
                """SELECT id FROM propertymanager.maintenance_attachment_operations
                   WHERE id = %s AND created_by = %s
                     AND state IN ('issued', 'uploaded', 'expired') AND expires_at <= now()""",
                (attachment_id, submitter),
            )
            if operation is None:
                continue
            (root / f"{attachment_id}.jpg").unlink(missing_ok=True)
            pm_db.execute(
                """UPDATE propertymanager.maintenance_attachment_operations
                   SET state = 'expired', storage_path = NULL, byte_size = NULL, sha256 = NULL
                   WHERE id = %s AND created_by = %s
                     AND state IN ('issued', 'uploaded', 'expired') AND expires_at <= now()""",
                (attachment_id, submitter),
            )


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
            """SELECT id, content_type, max_bytes, state, expires_at <= now() AS expired
               FROM propertymanager.maintenance_attachment_operations
               WHERE created_by = %s AND allocation_idempotency_key = %s""",
            (submitter, idempotency_key),
        )
        if existing:
            return _replay_attachment_allocation(existing, max_bytes)
        _reap_expired_unattached_photos(submitter)
        operation_id = str(uuid4())
        try:
            created = pm_db.execute_top_level_one_json(
                """WITH allocation_lock AS (
                       SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))
                   ), issued AS (
                       INSERT INTO propertymanager.maintenance_attachment_operations
                           (id, created_by, content_type, max_bytes, expires_at, allocation_idempotency_key)
                       SELECT %s, %s, %s, %s, now() + interval '20 minutes', %s
                       FROM allocation_lock
                       WHERE (
                           SELECT count(*) FROM propertymanager.maintenance_attachment_operations
                           WHERE created_by = %s AND state IN ('issued', 'uploaded') AND expires_at > now()
                       ) < %s
                       RETURNING id
                   )
                   SELECT row_to_json(issued) FROM issued""",
                (submitter, operation_id, submitter, JPEG_CONTENT_TYPE, max_bytes, idempotency_key,
                 submitter, MAX_PHOTOS_PER_REQUEST),
            )
        except Exception:
            existing = pm_db.execute_one_json(
                """SELECT id, content_type, max_bytes, state, expires_at <= now() AS expired
                   FROM propertymanager.maintenance_attachment_operations
                   WHERE created_by = %s AND allocation_idempotency_key = %s""",
                (submitter, idempotency_key),
            )
            if existing:
                return _replay_attachment_allocation(existing, max_bytes)
            raise
        if created is None:
            return error_response(
                "ATTACHMENT_LIMIT_REACHED",
                f"At most {MAX_PHOTOS_PER_REQUEST} active photos may be allocated",
                status=409,
            )
        return jsonify({"attachment_id": operation_id, "content_type": JPEG_CONTENT_TYPE,
                        "max_bytes": max_bytes, "expires_in_seconds": ATTACHMENT_TTL_MINUTES * 60}), 201

    @app.put("/v1/work-requests/attachments/<attachment_id>/content")
    @auth_required()
    def upload_work_request_attachment(attachment_id: str):
        try:
            UUID(attachment_id)
        except ValueError:
            return error_response("NOT_FOUND", "Attachment operation not found", status=404)
        operation = _attachment_operation(attachment_id)
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
        if (request.content_type or "").split(";", 1)[0].lower() != JPEG_CONTENT_TYPE:
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
        digest = hashlib.sha256(sanitized).hexdigest()
        with _attachment_upload_lock(root, attachment_id):
            # Re-check under the cross-process lock. A concurrent request may
            # have finalized this operation after the first authorization read.
            operation = _attachment_operation(attachment_id)
            if operation is None or operation.get("created_by") != server_submitter_identity():
                return error_response("NOT_FOUND", "Attachment operation not found", status=404)
            if operation.get("allocation_idempotency_key") != idempotency_key:
                return error_response("ATTACHMENT_RETRY_UNAUTHORIZED", "Attachment retry key is invalid", status=409)
            if operation.get("state") in {"uploaded", "attached"}:
                return jsonify({"attachment_id": attachment_id, "status": "uploaded", "idempotent_replay": True})
            if operation.get("state") != "issued":
                return error_response("ATTACHMENT_NOT_UPLOADABLE", "Attachment cannot be uploaded", status=409)
            if operation.get("expires_at") and str(operation["expires_at"]) < datetime.now(timezone.utc).isoformat():
                return error_response("ATTACHMENT_EXPIRED", "Attachment operation expired", status=409)

            temporary = root / f".{attachment_id}.{uuid4()}.tmp"
            try:
                with temporary.open("xb") as handle:
                    handle.write(sanitized)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, destination)
                try:
                    affected = pm_db.execute(
                        """UPDATE propertymanager.maintenance_attachment_operations
                           SET state = 'uploaded', storage_path = %s, byte_size = %s, sha256 = %s, uploaded_at = now()
                           WHERE id = %s AND state = 'issued'""",
                        (str(destination), len(sanitized), digest, attachment_id),
                    )
                except Exception:
                    finalized = _attachment_operation(attachment_id)
                    if _operation_matches_file(finalized, destination, len(sanitized), digest):
                        return jsonify({"attachment_id": attachment_id, "status": "uploaded", "idempotent_replay": True})
                    destination.unlink(missing_ok=True)
                    raise
                if affected != 1:
                    finalized = _attachment_operation(attachment_id)
                    if _operation_matches_file(finalized, destination, len(sanitized), digest):
                        return jsonify({"attachment_id": attachment_id, "status": "uploaded", "idempotent_replay": True})
                    destination.unlink(missing_ok=True)
                    return error_response("ATTACHMENT_NOT_UPLOADABLE", "Attachment cannot be finalized", status=409)
            finally:
                temporary.unlink(missing_ok=True)
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
        if asset_id:
            try:
                asset_id = _normalize_uuid(asset_id, field="asset_id")
            except ValueError as exc:
                return validation_error(str(exc), field="asset_id")
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
        if len(attachment_ids) > MAX_PHOTOS_PER_REQUEST:
            return validation_error(
                f"At most {MAX_PHOTOS_PER_REQUEST} photos may be attached",
                field="attachment_ids",
            )
        try:
            attachment_ids = [_normalize_uuid(value, field="attachment_ids") for value in attachment_ids]
        except ValueError as exc:
            return validation_error(str(exc), field="attachment_ids")
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
            "SELECT %s, %s, %s, 'House', 'Medium', 'As Needed', %s, 0, 0, %s, %s, true, "
            "'Work Request', %s, 'submitted', %s, %s, %s, 'calendar', '[]'::jsonb, '[]'::jsonb "
            "FROM attachment_guard RETURNING id"
            ")",
            "intake_event AS ("
            "INSERT INTO propertymanager.maintenance_task_intake_events (id, task_id, from_state, to_state, actor, reason) "
            "SELECT %s, id, NULL, 'submitted', %s, 'submitted from mobile intake' FROM created_request"
            ")",
        ]
        params: list[object] = [
            *attachment_params, submitter, len(attachment_ids), request_id, area or "Unassigned",
            f"Work request {request_id}", description,
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
        try:
            asset_id = _normalize_uuid(asset_id, field="asset_id")
        except ValueError as exc:
            return validation_error(str(exc), field="asset_id")
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
                   SELECT %s, area, 'Work request: ' || left(coalesce(task_description, ''), 72)
                          || ' [' || id::text || ']',
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
