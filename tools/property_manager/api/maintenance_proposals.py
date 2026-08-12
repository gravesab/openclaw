"""Review queue for model-generated maintenance proposals.

This module deliberately cannot create, update, complete, or delete a
maintenance task. Models may submit pending proposals; an authenticated human
may confirm or reject the exact stored version for later deterministic
execution by a separately governed workflow.
"""

from __future__ import annotations

import json
from uuid import uuid4

from flask import g, jsonify, request

import db as pm_db
from auth import auth_required, review_required
from errors import error_response, validation_error


DISPOSITIONS = {
    "completed_work",
    "inspection_observation",
    "planned_work",
    "needs_review",
    "reject",
}
REQUIRED_PROPOSAL_FIELDS = {
    "disposition",
    "title",
    "performed_on",
    "scheduled_for",
    "location",
    "action",
    "confidence",
    "reason",
}


def register_maintenance_proposal_routes(app) -> None:
    app.add_url_rule(
        "/v1/maintenance-proposals",
        "create_maintenance_proposal",
        create_maintenance_proposal,
        methods=["POST"],
    )
    app.add_url_rule(
        "/v1/maintenance-proposals",
        "list_maintenance_proposals",
        list_maintenance_proposals,
        methods=["GET"],
    )
    app.add_url_rule(
        "/v1/maintenance-proposals/<proposal_id>",
        "get_maintenance_proposal",
        get_maintenance_proposal,
        methods=["GET"],
    )
    app.add_url_rule(
        "/v1/maintenance-proposals/<proposal_id>/confirm",
        "confirm_maintenance_proposal",
        confirm_maintenance_proposal,
        methods=["POST"],
    )
    app.add_url_rule(
        "/v1/maintenance-proposals/<proposal_id>/reject",
        "reject_maintenance_proposal",
        reject_maintenance_proposal,
        methods=["POST"],
    )


def _validate_proposal(value) -> str | None:
    if not isinstance(value, dict) or set(value) != REQUIRED_PROPOSAL_FIELDS:
        return "proposal must contain exactly the required schema fields"
    if value.get("disposition") not in DISPOSITIONS:
        return "proposal disposition is invalid"
    for field in ("title", "action", "reason"):
        if not isinstance(value.get(field), str) or not value[field].strip():
            return f"proposal.{field} must be a non-empty string"
    for field in ("performed_on", "scheduled_for", "location"):
        if value.get(field) is not None and not isinstance(value[field], str):
            return f"proposal.{field} must be a string or null"
    confidence = value.get("confidence")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        return "proposal.confidence must be a number"
    if not 0 <= confidence <= 1:
        return "proposal.confidence must be between 0 and 1"
    if value["disposition"] == "planned_work" and value.get("performed_on"):
        return "planned work cannot include performed_on"
    return None


def _row(proposal_id: str) -> dict | None:
    return pm_db.execute_one_json(
        """
        SELECT id, proposal_version, operation_id, schema_version,
               source_evidence_ref, provider, model, model_output,
               guardrail_actions, validation_status, status, created_by,
               integration_identity, idempotency_key, reviewed_by,
               reviewed_at, rejection_reason, created_at, updated_at
        FROM propertymanager.maintenance_proposals
        WHERE id = %s
        """,
        (proposal_id,),
    )


@auth_required()
def create_maintenance_proposal():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return validation_error("JSON object body required")

    required = {
        "operation_id",
        "schema_version",
        "source_evidence_ref",
        "provider",
        "model",
        "proposal",
        "guardrail_actions",
        "validation_status",
    }
    missing = sorted(field for field in required if field not in payload)
    if missing:
        return validation_error("missing required fields", details=[{"field": f} for f in missing])

    idempotency_key = request.headers.get("Idempotency-Key", "").strip()
    if not idempotency_key:
        return validation_error("Idempotency-Key header is required", field="Idempotency-Key")

    for field in ("operation_id", "schema_version", "source_evidence_ref", "provider", "model"):
        if not isinstance(payload.get(field), str) or not payload[field].strip():
            return validation_error(f"{field} must be a non-empty string", field=field)
    if payload.get("validation_status") != "valid":
        return validation_error("validation_status must be valid", field="validation_status")
    if not isinstance(payload.get("guardrail_actions"), list) or not all(
        isinstance(item, str) for item in payload["guardrail_actions"]
    ):
        return validation_error("guardrail_actions must be an array of strings", field="guardrail_actions")
    proposal_error = _validate_proposal(payload.get("proposal"))
    if proposal_error:
        return validation_error(proposal_error, field="proposal")

    integration = g.integration_identity
    if not integration:
        return validation_error(
            "X-Integration-Identity header is required", field="X-Integration-Identity"
        )
    replay = pm_db.execute_one_json(
        """
        SELECT id
        FROM propertymanager.maintenance_proposals
        WHERE integration_identity = %s AND idempotency_key = %s
        """,
        (integration, idempotency_key),
    )
    if replay:
        existing = _row(str(replay["id"]))
        if existing is not None:
            existing["idempotent_replay"] = True
        return jsonify(existing), 200

    proposal_id = str(uuid4())
    affected = pm_db.execute(
        """
        INSERT INTO propertymanager.maintenance_proposals (
            id, proposal_version, operation_id, schema_version,
            source_evidence_ref, provider, model, model_output,
            guardrail_actions, validation_status, status, created_by,
            integration_identity, idempotency_key
        ) VALUES (
            %s, 1, %s, %s, %s, %s, %s, %s::jsonb,
            %s::jsonb, 'valid', 'pending', %s, %s, %s
        )
        ON CONFLICT (integration_identity, idempotency_key) DO NOTHING
        """,
        (
            proposal_id,
            payload["operation_id"].strip(),
            payload["schema_version"].strip(),
            payload["source_evidence_ref"].strip(),
            payload["provider"].strip(),
            payload["model"].strip(),
            json.dumps(payload["proposal"]),
            json.dumps(payload["guardrail_actions"]),
            integration,
            integration,
            idempotency_key,
        ),
    )
    if affected == 0:
        replay = pm_db.execute_one_json(
            """
            SELECT id
            FROM propertymanager.maintenance_proposals
            WHERE integration_identity = %s AND idempotency_key = %s
            """,
            (integration, idempotency_key),
        )
        if replay:
            existing = _row(str(replay["id"]))
            if existing is not None:
                existing["idempotent_replay"] = True
            return jsonify(existing), 200
        return error_response("IDEMPOTENCY_CONFLICT", "Proposal submission conflicted", status=409)
    return jsonify(_row(proposal_id)), 201


@auth_required()
def list_maintenance_proposals():
    status = str(request.args.get("status") or "pending").strip().lower()
    if status not in {"pending", "confirmed", "rejected", "all"}:
        return validation_error("status must be pending, confirmed, rejected, or all", field="status")
    where = "" if status == "all" else "WHERE status = %s"
    params = () if status == "all" else (status,)
    rows = pm_db.execute_json(
        f"""
        SELECT id, proposal_version, operation_id, schema_version,
               source_evidence_ref, provider, model, model_output,
               guardrail_actions, validation_status, status, created_by,
               integration_identity, reviewed_by, reviewed_at,
               rejection_reason, created_at, updated_at
        FROM propertymanager.maintenance_proposals
        {where}
        ORDER BY created_at DESC
        """,
        params,
    )
    return jsonify(rows)


@auth_required()
def get_maintenance_proposal(proposal_id: str):
    row = _row(proposal_id)
    if row is None:
        return error_response("NOT_FOUND", "Maintenance proposal not found", status=404)
    return jsonify(row)


def _review_payload(proposal_id: str):
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return None, validation_error("JSON object body required")
    version = payload.get("proposal_version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        return None, validation_error("proposal_version must be a positive integer", field="proposal_version")
    row = _row(proposal_id)
    if row is None:
        return None, error_response("NOT_FOUND", "Maintenance proposal not found", status=404)
    if row.get("status") != "pending":
        return None, error_response("PROPOSAL_NOT_PENDING", "Proposal has already been reviewed", status=409)
    if int(row.get("proposal_version") or 0) != version:
        return None, error_response("STALE_PROPOSAL_VERSION", "Proposal changed; review the current version", status=409)
    return (payload, row), None


@review_required()
def confirm_maintenance_proposal(proposal_id: str):
    reviewed, error = _review_payload(proposal_id)
    if error:
        return error
    _payload, row = reviewed
    proposal = row.get("model_output") or {}
    if proposal.get("disposition") in {"needs_review", "reject"}:
        return error_response(
            "PROPOSAL_NOT_CONFIRMABLE",
            "Proposal must be corrected or rejected before confirmation",
            status=409,
        )
    affected = pm_db.execute(
        """
        UPDATE propertymanager.maintenance_proposals
        SET status = 'confirmed', reviewed_by = %s, reviewed_at = now(), updated_at = now()
        WHERE id = %s AND status = 'pending' AND proposal_version = %s
        """,
        (g.operator_identity or "unknown", proposal_id, row["proposal_version"]),
    )
    if affected == 0:
        return error_response(
            "PROPOSAL_REVIEW_CONFLICT", "Proposal was reviewed concurrently", status=409
        )
    return jsonify(_row(proposal_id))


@review_required()
def reject_maintenance_proposal(proposal_id: str):
    reviewed, error = _review_payload(proposal_id)
    if error:
        return error
    payload, row = reviewed
    reason = payload.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        return validation_error("reason must be a non-empty string", field="reason")
    affected = pm_db.execute(
        """
        UPDATE propertymanager.maintenance_proposals
        SET status = 'rejected', reviewed_by = %s, reviewed_at = now(),
            rejection_reason = %s, updated_at = now()
        WHERE id = %s AND status = 'pending' AND proposal_version = %s
        """,
        (g.operator_identity or "unknown", reason.strip(), proposal_id, row["proposal_version"]),
    )
    if affected == 0:
        return error_response(
            "PROPOSAL_REVIEW_CONFLICT", "Proposal was reviewed concurrently", status=409
        )
    return jsonify(_row(proposal_id))
