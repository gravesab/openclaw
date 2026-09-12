"""Usage and failover telemetry for the AI execution engine.

Phase 2F.5 records configured versus observed routing without blocking
successful execution responses when telemetry persistence fails.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from typing import Any, Mapping, Protocol, Sequence, runtime_checkable

from tools.ai_intelligence.execution_models import (
    AttemptStatus,
    ExecutionAttempt,
    ExecutionResult,
    ExecutionStatus,
)
from tools.ai_intelligence.routing_models import (
    AssignmentType,
    RoutingDecision,
)


@runtime_checkable
class ExecutionTelemetryRecorder(Protocol):
    """Persistence behavior required by the execution engine."""

    def record(
        self,
        decision: RoutingDecision,
        result: ExecutionResult,
    ) -> None:
        ...


@dataclass(frozen=True)
class ObservedUsageRecord:
    """One observed routing outcome ready for database persistence."""

    component_id: str
    model_id: str
    request_id: str
    task_type: str
    routing_mode: str
    selected_as: str
    success: bool
    duration_ms: int
    privacy_tier: str
    usage_metadata: Mapping[str, Any]


def build_observed_usage_record(
    decision: RoutingDecision,
    result: ExecutionResult,
) -> ObservedUsageRecord:
    """Build the observed-usage row for one execution result."""

    configured_primary = decision.chain.primary.model_id
    configured_candidates = tuple(
        assignment.model_id
        for assignment in decision.chain.ordered_candidates
    )
    assignment_by_model = {
        assignment.model_id: assignment
        for assignment in decision.chain.ordered_candidates
    }
    failover_occurred = (
        result.status is ExecutionStatus.SUCCESS
        and result.selected_model_id is not None
        and result.selected_model_id != configured_primary
    ) or (
        result.status is ExecutionStatus.FAILED
        and len(result.attempts) > 1
    )

    if result.selected_model_id is not None:
        observed_model_id = result.selected_model_id
    else:
        observed_model_id = result.attempts[-1].model_id

    selected_as = _selected_as(
        observed_model_id=observed_model_id,
        configured_primary=configured_primary,
        succeeded=result.status is ExecutionStatus.SUCCESS,
        assignment_type=(
            assignment_by_model[observed_model_id].assignment_type
            if observed_model_id in assignment_by_model
            else None
        ),
    )

    attempts = tuple(
        _serialize_attempt(
            attempt=attempt,
            attempt_number=index,
            assignment_type=(
                assignment_by_model[attempt.model_id].assignment_type
                if attempt.model_id in assignment_by_model
                else None
            ),
        )
        for index, attempt in enumerate(result.attempts, start=1)
    )

    duration_ms = sum(attempt.duration_ms for attempt in result.attempts)

    return ObservedUsageRecord(
        component_id=result.component_id,
        model_id=observed_model_id,
        request_id=result.request_id,
        task_type=decision.task_type,
        routing_mode=decision.routing_mode.value,
        selected_as=selected_as,
        success=result.status is ExecutionStatus.SUCCESS,
        duration_ms=duration_ms,
        privacy_tier=decision.privacy_tier.value,
        usage_metadata={
            "configured_primary_model_id": configured_primary,
            "configured_candidate_model_ids": list(
                configured_candidates
            ),
            "observed_selected_model_id": result.selected_model_id,
            "failover_occurred": failover_occurred,
            "attempt_count": len(attempts),
            "attempts": list(attempts),
            "final_status": result.status.value,
        },
    )


def summarize_failover_status(
    *,
    drift_rows: Sequence[Mapping[str, Any]],
    recent_rows: Sequence[Mapping[str, Any]],
    configured_assignment_rows: Sequence[Mapping[str, Any]] = (),
    recent_usage_limit: int | None = None,
) -> dict[str, Any]:
    """Build a briefing/dashboard summary from stored telemetry."""

    matched = 0
    drift = 0
    not_observed = 0
    for row in drift_rows:
        status = str(row.get("deployment_status", ""))
        if status == "matched":
            matched += 1
        elif status == "drift":
            drift += 1
        else:
            not_observed += 1

    recent_failovers = [
        row
        for row in recent_rows
        if bool((row.get("usage_metadata") or {}).get("failover_occurred"))
    ]
    recent_failures = [
        row for row in recent_rows if row.get("success") is False
    ]

    model_usage: dict[str, dict[str, Any]] = {}

    def usage_entry(model_id: str) -> dict[str, Any]:
        return model_usage.setdefault(
            model_id,
            {
                "model_id": model_id,
                "configured_assignments": {},
                "observed_attempt_count": 0,
                "successful_attempt_count": 0,
                "failed_attempt_count": 0,
                "latest_observed_at": None,
            },
        )

    for row in configured_assignment_rows:
        model_id = str(row.get("model_id") or "").strip()
        if not model_id:
            continue
        entry = usage_entry(model_id)
        component_id = str(row.get("component_id") or "").strip()
        assignment_type = str(row.get("assignment_type") or "").strip()
        if component_id and assignment_type:
            entry["configured_assignments"].setdefault(
                component_id, set()
            ).add(assignment_type)

    for row in recent_rows:
        observed_at = _stringify(row.get("observed_at"))
        metadata = row.get("usage_metadata") or {}
        attempts = metadata.get("attempts", []) if isinstance(metadata, Mapping) else []
        observed_attempts = [
            attempt for attempt in attempts if isinstance(attempt, Mapping)
        ]
        if not observed_attempts:
            observed_attempts = [
                {
                    "model_id": row.get("model_id"),
                    "succeeded": row.get("success"),
                }
            ]
        for attempt in observed_attempts:
            model_id = str(attempt.get("model_id") or "").strip()
            if not model_id:
                continue
            entry = usage_entry(model_id)
            entry["observed_attempt_count"] += 1
            if attempt.get("succeeded") is True:
                entry["successful_attempt_count"] += 1
            elif attempt.get("succeeded") is False:
                entry["failed_attempt_count"] += 1
            if observed_at and (
                entry["latest_observed_at"] is None
                or observed_at > entry["latest_observed_at"]
            ):
                entry["latest_observed_at"] = observed_at

    model_usage_rows = [
        {
            "model_id": entry["model_id"],
            "usage_status": (
                "used"
                if entry["observed_attempt_count"]
                else "not-observed"
            ),
            "observed_attempt_count": entry["observed_attempt_count"],
            "successful_attempt_count": entry["successful_attempt_count"],
            "failed_attempt_count": entry["failed_attempt_count"],
            "latest_observed_at": entry["latest_observed_at"],
            "configured_assignments": [
                {
                    "component_id": component_id,
                    "assignment_types": sorted(assignment_types),
                }
                for component_id, assignment_types in sorted(
                    entry["configured_assignments"].items()
                )
            ],
        }
        for entry in model_usage.values()
    ]
    model_usage_rows.sort(
        key=lambda entry: (entry["usage_status"] != "used", entry["model_id"])
    )

    if drift > 0 or recent_failures:
        overall = "attention"
    elif recent_failovers:
        overall = "failover-active"
    elif matched > 0:
        overall = "healthy"
    else:
        overall = "unknown"

    return {
        "status": overall,
        "configured_versus_observed": {
            "matched": matched,
            "drift": drift,
            "not_observed": not_observed,
            "rows": [
                {
                    "component_id": row.get("component_id"),
                    "configured_primary_model": row.get(
                        "configured_primary_model"
                    ),
                    "latest_observed_model": row.get(
                        "latest_observed_model"
                    ),
                    "deployment_status": row.get("deployment_status"),
                    "observed_at": _stringify(row.get("observed_at")),
                }
                for row in drift_rows
            ],
        },
        "recent_failover_count": len(recent_failovers),
        "recent_failure_count": len(recent_failures),
        "model_usage": {
            "observation_limit": recent_usage_limit or len(recent_rows),
            "used": sum(
                row["usage_status"] == "used" for row in model_usage_rows
            ),
            "not_observed": sum(
                row["usage_status"] == "not-observed"
                for row in model_usage_rows
            ),
            "rows": model_usage_rows,
        },
        "recent_observations": [
            {
                "component_id": row.get("component_id"),
                "model_id": row.get("model_id"),
                "selected_as": row.get("selected_as"),
                "success": row.get("success"),
                "failover_occurred": bool(
                    (row.get("usage_metadata") or {}).get(
                        "failover_occurred"
                    )
                ),
                "observed_at": _stringify(row.get("observed_at")),
                "request_id": row.get("request_id"),
            }
            for row in recent_rows[:10]
        ],
    }


def format_failover_status_text(summary: Mapping[str, Any]) -> str:
    """Render a compact operator-facing telemetry summary."""

    configured = summary.get("configured_versus_observed", {})
    lines = [
        "AI Routing Telemetry",
        f"Status: {summary.get('status', 'unknown')}",
        (
            "Configured vs observed: "
            f"matched={configured.get('matched', 0)} "
            f"drift={configured.get('drift', 0)} "
            f"not_observed={configured.get('not_observed', 0)}"
        ),
        (
            "Recent failovers: "
            f"{summary.get('recent_failover_count', 0)}"
        ),
        (
            "Recent failures: "
            f"{summary.get('recent_failure_count', 0)}"
        ),
    ]

    model_usage = summary.get("model_usage", {})
    lines.append(
        "Model usage in this telemetry window: "
        f"used={model_usage.get('used', 0)} "
        f"not_observed={model_usage.get('not_observed', 0)}"
    )

    drift_rows = [
        row
        for row in configured.get("rows", [])
        if row.get("deployment_status") == "drift"
    ]
    if drift_rows:
        lines.append("Drift:")
        for row in drift_rows[:5]:
            lines.append(
                "- "
                f"{row.get('component_id')}: "
                f"configured={row.get('configured_primary_model')} "
                f"observed={row.get('latest_observed_model')}"
            )

    failovers = [
        row
        for row in summary.get("recent_observations", [])
        if row.get("failover_occurred")
    ]
    if failovers:
        lines.append("Recent failover events:")
        for row in failovers[:5]:
            lines.append(
                "- "
                f"{row.get('component_id')} -> {row.get('model_id')} "
                f"at {row.get('observed_at')}"
            )

    return "\n".join(lines) + "\n"


def _selected_as(
    *,
    observed_model_id: str,
    configured_primary: str,
    succeeded: bool,
    assignment_type: AssignmentType | None,
) -> str:
    if not succeeded:
        return "unknown"

    if assignment_type is AssignmentType.PRIMARY:
        return "primary"

    if assignment_type is AssignmentType.FALLBACK:
        return "fallback"

    if observed_model_id == configured_primary:
        return "primary"

    return "fallback"


def _serialize_attempt(
    *,
    attempt: ExecutionAttempt,
    attempt_number: int,
    assignment_type: AssignmentType | None,
) -> dict[str, Any]:
    return {
        "attempt_number": attempt_number,
        "model_id": attempt.model_id,
        "provider_name": attempt.provider_name,
        "assignment_type": (
            assignment_type.value if assignment_type is not None else None
        ),
        "status": attempt.status.value,
        "duration_ms": attempt.duration_ms,
        "error_type": attempt.error_type,
        "error_message": attempt.error_message,
        "succeeded": attempt.status is AttemptStatus.SUCCESS,
    }


def _stringify(value: Any) -> str | None:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def warn_telemetry_failure(error: Exception) -> None:
    """Emit a non-fatal telemetry warning for operators."""

    print(
        f"AI Intelligence telemetry recording failed: {error}",
        file=sys.stderr,
    )


def dumps_metadata(metadata: Mapping[str, Any]) -> str:
    """Serialize usage metadata for PostgreSQL jsonb storage."""

    return json.dumps(metadata, separators=(",", ":"), sort_keys=True)
