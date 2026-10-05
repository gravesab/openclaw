"""Meter schedule recalculation and reading engine for PropertyManager Phase 1."""

from __future__ import annotations

import hashlib
import secrets
import time
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any
from uuid import uuid4

import db as pm_db
from decimal_utils import decimal_to_db, format_decimal, parse_decimal

METER_TYPES = {"runtime_hours", "mileage", "cycles", "none"}
METER_UNITS = {
    "runtime_hours": "hrs",
    "mileage": "mi",
    "cycles": "cycles",
    "none": "",
}
SCHEDULE_KINDS = {"calendar", "meter", "both"}
CORRECTION_REASONS = {"replacement", "rollover", "correction"}
ENTRY_METHODS = {"manual", "voice", "qr", "api", "telegram", "completion"}
READING_STATUSES = {"accepted", "rejected", "corrected"}

# In-memory preview tokens (dev VM); TTL 15 minutes
_PREVIEW_TOKENS: dict[str, dict[str, Any]] = {}
_PREVIEW_TTL_SECONDS = 900


def default_meter_type_for_category(category: str) -> str:
    normalized = (category or "").strip().lower()
    if normalized == "equipment":
        return "runtime_hours"
    if normalized in {"vehicles", "vehicle"}:
        return "mileage"
    return "none"


def meter_unit_for_type(meter_type: str) -> str:
    return METER_UNITS.get(meter_type, "")


def remaining_meter(current: Decimal | None, next_due: Decimal | None) -> Decimal | None:
    if current is None or next_due is None:
        return None
    return decimal_to_db(next_due - current)


def is_meter_due(current: Decimal | None, next_due: Decimal | None) -> bool:
    """True when current equals trigger (due now). Not overdue."""
    if current is None or next_due is None:
        return False
    return current == next_due


def is_meter_overdue(current: Decimal | None, next_due: Decimal | None) -> bool:
    """True only when current is strictly greater than trigger."""
    if current is None or next_due is None:
        return False
    return current > next_due


def enrich_task_meter_fields(task: dict[str, Any], current_meter: Decimal | None) -> dict[str, Any]:
    item = dict(task)
    next_due_meter = _as_decimal(item.get("next_due_meter_value"))
    rem = remaining_meter(current_meter, next_due_meter)
    item["remaining_meter"] = format_decimal(rem) if rem is not None else None
    item["due_meter"] = is_meter_due(current_meter, next_due_meter)
    item["overdue_meter"] = is_meter_overdue(current_meter, next_due_meter)
    return item


def _as_decimal(value: Any) -> Decimal | None:
    if value is None:
        return None
    try:
        return parse_decimal(value)
    except ValueError:
        return None


def parse_optional_meter_decimal(value: Any, *, field: str) -> Decimal | None:
    """Parse optional meter decimal. Blank string is rejected (blank ≠ 0). None clears."""
    if value is None:
        return None
    if isinstance(value, str) and value.strip() == "":
        raise ValueError(f"{field} must be a decimal number (blank is not zero)")
    parsed = parse_decimal(value, field=field)
    if not parsed.is_finite():
        raise ValueError(f"{field} must be a finite number")
    if parsed < 0:
        raise ValueError(f"{field} must be nonnegative")
    return decimal_to_db(parsed)


def parse_positive_delta(value: Any, *, field: str = "delta") -> Decimal:
    """Parse hours/miles to add. Must be finite and strictly > 0 (blank ≠ 0)."""
    if value is None or (isinstance(value, str) and value.strip() == ""):
        raise ValueError(f"{field} is required")
    parsed = parse_decimal(value, field=field)
    if not parsed.is_finite():
        raise ValueError(f"{field} must be a finite number")
    if parsed <= 0:
        raise ValueError(f"{field} must be greater than zero")
    return decimal_to_db(parsed)


def resolve_meter_reading_absolute(
    asset_id: str,
    *,
    value: Any = None,
    delta: Any = None,
    add_value: Any = None,
) -> tuple[Decimal, Decimal | None]:
    """Resolve POST body to absolute reading value.

    Accepts either ``value`` (absolute face) or ``delta`` (hours/miles since last).
    ``add_value`` is rejected — use ``delta``. Returns (absolute, delta_applied).
    """
    if add_value is not None and add_value != "":
        raise ValueError("add_value is not supported; use delta")

    has_value = value is not None and not (isinstance(value, str) and value.strip() == "")
    has_delta = delta is not None and not (isinstance(delta, str) and delta.strip() == "")

    if has_value and has_delta:
        raise ValueError("provide either value (absolute) or delta, not both")
    if not has_value and not has_delta:
        raise ValueError("value or delta is required")

    if has_delta:
        delta_dec = parse_positive_delta(delta, field="delta")
        meter = fetch_meter_row(asset_id)
        if meter is None:
            raise ValueError("asset_meter not found")
        current = _as_decimal(meter.get("current_value")) or Decimal("0")
        absolute = decimal_to_db(current + delta_dec)
        return absolute, delta_dec

    absolute = parse_decimal(value, field="value")
    if not absolute.is_finite():
        raise ValueError("value must be a finite number")
    return decimal_to_db(absolute), None


_TRIGGER_UNITS_BY_METER_TYPE: dict[str, set[str]] = {
    "runtime_hours": {"hrs", "hours", "hr", "h"},
    "mileage": {"mi", "mile", "miles"},
}
_CANONICAL_UNIT_BY_METER_TYPE: dict[str, str] = {
    "runtime_hours": "hrs",
    "mileage": "mi",
}


def validate_meter_trigger(
    *,
    asset_id: Any,
    schedule_kind: str,
    next_due_meter: Decimal,
    meter_interval_unit: str | None = None,
    expected_meter_type: str | None = None,
) -> list[str]:
    """Validate absolute meter trigger for activated runtime_hours or mileage meters.

    Returns warnings (non-fatal). Raises ValueError on reject.
    Controlling rule: linked asset meter_type (not task category).
    """
    if asset_id is None or str(asset_id).strip() == "":
        raise ValueError("asset_id is required when next_due_meter_value is set")
    kind = (schedule_kind or "").strip().lower()
    if kind not in {"meter", "both"}:
        raise ValueError(
            "schedule_kind must be 'meter' or 'both' when next_due_meter_value is set "
            "(silent calendar→meter promotion is forbidden)"
        )

    aid = str(asset_id).strip()
    if not meter_is_active(aid):
        raise ValueError("linked asset meter must be activated before setting a meter trigger")
    meter = fetch_meter_row(aid)
    if meter is None:
        raise ValueError("linked asset has no meter row")
    meter_type = str(meter.get("meter_type") or "")
    if expected_meter_type is not None and meter_type != expected_meter_type:
        raise ValueError(f"linked asset meter_type must be {expected_meter_type}")
    if meter_type not in _TRIGGER_UNITS_BY_METER_TYPE:
        raise ValueError(
            "linked asset meter_type must be runtime_hours or mileage when setting a meter trigger"
        )

    allowed_units = _TRIGGER_UNITS_BY_METER_TYPE[meter_type]
    canonical = _CANONICAL_UNIT_BY_METER_TYPE[meter_type]
    unit = (meter_interval_unit or canonical).strip().lower()
    if unit not in allowed_units:
        raise ValueError(
            f"meter_interval_unit must be {canonical} for {meter_type} triggers (got {unit!r})"
        )

    warnings: list[str] = []
    current = _as_decimal(meter.get("current_value"))
    if current is not None and next_due_meter < current:
        warnings.append(
            f"next_due_meter_value ({format_decimal(next_due_meter)}) is behind "
            f"current meter ({format_decimal(current)})"
        )
    return warnings


def validate_run_hours_trigger(
    *,
    asset_id: Any,
    schedule_kind: str,
    next_due_meter: Decimal,
    meter_interval_unit: str | None = None,
) -> list[str]:
    """Validate absolute run-hours trigger. Returns warnings (non-fatal). Raises ValueError on reject."""
    return validate_meter_trigger(
        asset_id=asset_id,
        schedule_kind=schedule_kind,
        next_due_meter=next_due_meter,
        meter_interval_unit=meter_interval_unit,
        expected_meter_type="runtime_hours",
    )


def fetch_meter_row(asset_id: str, *, for_update: bool = False) -> dict[str, Any] | None:
    suffix = " FOR UPDATE" if for_update else ""
    return pm_db.execute_one_json(
        f"""
        SELECT asset_id, meter_type, current_value, unit, latest_reading_at,
               meter_epoch, row_version, updated_at
        FROM propertymanager.asset_meter
        WHERE asset_id = %s
        {suffix}
        """,
        (asset_id,),
    )


def fetch_meter_rows(asset_ids: list[str]) -> dict[str, dict[str, Any]]:
    """Meter rows for many assets in one query, keyed by asset id string."""
    unique_ids = sorted({str(asset_id) for asset_id in asset_ids if asset_id})
    if not unique_ids:
        return {}
    placeholders = ", ".join(["%s"] * len(unique_ids))
    rows = pm_db.execute_json(
        f"""
        SELECT asset_id, meter_type, current_value, unit, latest_reading_at,
               meter_epoch, row_version, updated_at
        FROM propertymanager.asset_meter
        WHERE asset_id IN ({placeholders})
        """,
        unique_ids,
    )
    return {str(row["asset_id"]): row for row in rows}


def fetch_asset_proposed_meter(asset_id: str) -> dict[str, Any] | None:
    return pm_db.execute_one_json(
        """
        SELECT id, meter_proposed_type, meter_proposed_unit, meter_activated_at
        FROM propertymanager.assets
        WHERE id = %s
        """,
        (asset_id,),
    )


def meter_is_active(asset_id: str) -> bool:
    row = fetch_asset_proposed_meter(asset_id)
    if row is None:
        return False
    return row.get("meter_activated_at") is not None


def activate_meter(
    asset_id: str,
    *,
    meter_type: str | None = None,
    unit: str | None = None,
    row_version: int | None = None,
) -> dict[str, Any]:
    asset = fetch_asset_proposed_meter(asset_id)
    if asset is None:
        raise ValueError("asset not found")
    if asset.get("meter_activated_at") is not None:
        raise ValueError("meter already activated")

    proposed_type = meter_type or asset.get("meter_proposed_type") or "none"
    proposed_unit = unit or asset.get("meter_proposed_unit") or meter_unit_for_type(proposed_type)
    if proposed_type not in METER_TYPES:
        raise ValueError(f"meter_type must be one of {sorted(METER_TYPES)}")
    if proposed_type == "none":
        raise ValueError("cannot activate meter with type none")

    meter = fetch_meter_row(asset_id)
    if meter is None:
        raise ValueError("asset_meter not found")

    if row_version is not None and int(meter.get("row_version") or 0) != int(row_version):
        raise ValueError("CONFLICT: row_version mismatch")

    pm_db.execute(
        """
        UPDATE propertymanager.assets
        SET meter_activated_at = now(), updated_at = now()
        WHERE id = %s
        """,
        (asset_id,),
    )
    pm_db.execute(
        """
        UPDATE propertymanager.asset_meter
        SET meter_type = %s,
            unit = %s,
            row_version = row_version + 1,
            updated_at = now()
        WHERE asset_id = %s
        """,
        (proposed_type, proposed_unit, asset_id),
    )
    updated = fetch_meter_row(asset_id)
    return updated or {}


def recalc_tasks_for_asset(asset_id: str, current_meter: Decimal | None) -> list[dict[str, Any]]:
    """No-op for absolute meter triggers.

    Corrected contract: `next_due_meter_value` is an operator-authored absolute
    trigger. Due/overdue/remaining are enrichment against `current_meter`.
    Advancement happens only on completion (`meter_at_completion + interval` or
    clear when one-time). Never rewrite triggers from current+interval here —
    that destroyed guide first-due values (e.g. belts at 60k with 15k interval).
    """
    _ = (asset_id, current_meter)
    return []


def _latest_accepted_in_epoch(asset_id: str, epoch: int) -> dict[str, Any] | None:
    return pm_db.execute_one_json(
        """
        SELECT id, value, reading_at, created_at
        FROM propertymanager.asset_meter_reading
        WHERE asset_id = %s
          AND meter_epoch = %s
          AND status = 'accepted'
        ORDER BY reading_at DESC, created_at DESC
        LIMIT 1
        """,
        (asset_id, epoch),
    )


def _accepted_readings_in_epoch(asset_id: str, epoch: int) -> list[dict[str, Any]]:
    return pm_db.execute_json(
        """
        SELECT id, value, reading_at, created_at, previous_reading_id
        FROM propertymanager.asset_meter_reading
        WHERE asset_id = %s
          AND meter_epoch = %s
          AND status = 'accepted'
        ORDER BY reading_at ASC, created_at ASC
        """,
        (asset_id, epoch),
    )


def recalc_usage_for_epoch(asset_id: str, epoch: int) -> None:
    pm_db.execute_top_level_one_json(
        """WITH locked_meter AS (
               SELECT asset_id
               FROM propertymanager.asset_meter
               WHERE asset_id = %s AND meter_epoch = %s
               FOR UPDATE
           ), ordered AS (
               SELECT reading.id,
                      lag(reading.id) OVER chronology AS previous_id,
                      reading.value - lag(reading.value) OVER chronology AS usage
               FROM propertymanager.asset_meter_reading reading
               JOIN locked_meter meter ON meter.asset_id = reading.asset_id
               WHERE reading.meter_epoch = %s AND reading.status = 'accepted'
               WINDOW chronology AS (
                   ORDER BY reading.reading_at, reading.created_at, reading.id
               )
           ), updated AS (
               UPDATE propertymanager.asset_meter_reading reading
               SET previous_reading_id = ordered.previous_id,
                   usage_since_previous = ordered.usage
               FROM ordered
               WHERE reading.id = ordered.id
               RETURNING reading.id
           ), result AS (
               SELECT count(*)::integer AS updated_count FROM updated
           )
           SELECT row_to_json(result) FROM result""",
        (asset_id, epoch, epoch),
    )


def update_current_meter_from_latest(asset_id: str, epoch: int) -> None:
    latest = _latest_accepted_in_epoch(asset_id, epoch)
    if latest is None:
        pm_db.execute(
            """
            UPDATE propertymanager.asset_meter
            SET current_value = 0,
                latest_reading_at = NULL,
                row_version = row_version + 1,
                updated_at = now()
            WHERE asset_id = %s
            """,
            (asset_id,),
        )
        return
    pm_db.execute(
        """
        UPDATE propertymanager.asset_meter
        SET current_value = %s,
            latest_reading_at = %s,
            row_version = row_version + 1,
            updated_at = now()
        WHERE asset_id = %s
        """,
        (latest["value"], latest["reading_at"], asset_id),
    )


def _cleanup_preview_tokens() -> None:
    now = time.time()
    expired = [k for k, v in _PREVIEW_TOKENS.items() if v.get("expires_at", 0) < now]
    for key in expired:
        _PREVIEW_TOKENS.pop(key, None)


def create_lower_reading_preview(
    asset_id: str,
    *,
    value: Decimal,
    reading_at: datetime,
    entry_method: str,
    note: str | None,
    idempotency_key: str | None,
    previous_value: Decimal,
) -> str:
    _cleanup_preview_tokens()
    token = secrets.token_urlsafe(24)
    _PREVIEW_TOKENS[token] = {
        "asset_id": asset_id,
        "value": str(value),
        "reading_at": reading_at.isoformat(),
        "entry_method": entry_method,
        "note": note,
        "idempotency_key": idempotency_key,
        "previous_value": str(previous_value),
        "expires_at": time.time() + _PREVIEW_TTL_SECONDS,
    }
    return token


def consume_preview_token(token: str) -> dict[str, Any] | None:
    _cleanup_preview_tokens()
    payload = _PREVIEW_TOKENS.pop(token, None)
    if payload is None:
        return None
    if payload.get("expires_at", 0) < time.time():
        return None
    return payload


def find_idempotent_reading(asset_id: str, idempotency_key: str) -> dict[str, Any] | None:
    if not idempotency_key:
        return None
    return pm_db.execute_one_json(
        """
        SELECT id, asset_id, value, reading_at, entry_method, note, correction_reason,
               usage_since_previous, created_at, status, meter_epoch, idempotency_key
        FROM propertymanager.asset_meter_reading
        WHERE asset_id = %s
          AND idempotency_key = %s
          AND status = 'accepted'
        LIMIT 1
        """,
        (asset_id, idempotency_key),
    )


def insert_accepted_reading(
    asset_id: str,
    *,
    value: Decimal,
    reading_at: datetime,
    entry_method: str,
    note: str | None,
    correction_reason: str | None,
    meter_type: str,
    unit: str,
    meter_epoch: int,
    operator_identity: str | None,
    integration_identity: str | None,
    idempotency_key: str | None,
    corrects_reading_id: str | None = None,
    status: str = "accepted",
) -> dict[str, Any]:
    if status != "accepted":
        raise ValueError("insert_accepted_reading requires accepted status")
    rid = str(uuid4())
    normalized_value = decimal_to_db(value)
    allow_lower = correction_reason is not None
    inserted = pm_db.execute_top_level_one_json(
        """WITH locked_meter AS (
               SELECT asset_id, meter_type, unit, meter_epoch, current_value,
                      latest_reading_at
               FROM propertymanager.asset_meter
               WHERE asset_id = %s AND meter_epoch = %s
               FOR UPDATE
           ), latest_reading AS (
               SELECT r.id, r.value
               FROM propertymanager.asset_meter_reading r
               JOIN locked_meter m ON m.asset_id = r.asset_id
               WHERE r.meter_epoch = m.meter_epoch AND r.status = 'accepted'
               ORDER BY r.reading_at DESC, r.created_at DESC
               LIMIT 1
           ), inserted_reading AS (
               INSERT INTO propertymanager.asset_meter_reading
                   (id, asset_id, value, reading_at, entry_method, note,
                    correction_reason, usage_since_previous, previous_reading_id,
                    meter_type_at_entry, unit_at_entry, status, operator_identity,
                    integration_identity, idempotency_key, meter_epoch, corrects_reading_id)
               SELECT %s, m.asset_id, %s, %s, %s, %s, %s,
                      CASE
                          WHEN latest.id IS NULL OR %s IN ('replacement', 'rollover') THEN NULL
                          ELSE %s - latest.value
                      END,
                      latest.id, m.meter_type, m.unit, 'accepted', %s, %s, %s,
                      m.meter_epoch, %s
               FROM locked_meter m
               LEFT JOIN latest_reading latest ON true
               WHERE %s OR %s >= COALESCE(latest.value, m.current_value, 0)
               RETURNING id, asset_id, value, reading_at
           ), updated_meter AS (
               UPDATE propertymanager.asset_meter m
               SET current_value = CASE
                       WHEN m.latest_reading_at IS NULL OR reading.reading_at >= m.latest_reading_at
                           THEN reading.value
                       ELSE m.current_value
                   END,
                   latest_reading_at = CASE
                       WHEN m.latest_reading_at IS NULL OR reading.reading_at >= m.latest_reading_at
                           THEN reading.reading_at
                       ELSE m.latest_reading_at
                   END,
                   row_version = row_version + 1,
                   updated_at = now()
               FROM inserted_reading reading
               WHERE m.asset_id = reading.asset_id
               RETURNING m.asset_id, m.current_value
           ), result AS (
               SELECT reading.id, meter.current_value
               FROM inserted_reading reading
               JOIN updated_meter meter ON meter.asset_id = reading.asset_id
           )
           SELECT row_to_json(result) FROM result""",
        (
            asset_id,
            meter_epoch,
            rid,
            normalized_value,
            reading_at,
            entry_method,
            note,
            correction_reason,
            correction_reason,
            normalized_value,
            operator_identity,
            integration_identity,
            idempotency_key,
            corrects_reading_id,
            allow_lower,
            normalized_value,
        ),
    )
    if inserted is None:
        raise ValueError("CONFLICT: meter changed; reload before recording the reading")

    _ = (meter_type, unit)
    recalc_usage_for_epoch(asset_id, meter_epoch)
    meter = fetch_meter_row(asset_id)
    current = _as_decimal((meter or {}).get("current_value"))
    recalc_tasks_for_asset(asset_id, current)
    return {"reading_id": str(inserted["id"]), "current_value": format_decimal(current)}


def apply_meter_reading(
    asset_id: str,
    value: Decimal,
    *,
    reading_at: datetime,
    entry_method: str,
    note: str | None,
    operator_identity: str | None = None,
    integration_identity: str | None = None,
    idempotency_key: str | None = None,
    row_version: int | None = None,
) -> dict[str, Any]:
    """Normal reading path. Returns preview info if lower than previous in epoch."""
    if not meter_is_active(asset_id):
        raise ValueError("meter not activated; operator must activate proposed meter first")

    existing = find_idempotent_reading(asset_id, idempotency_key or "")
    if existing:
        meter = fetch_meter_row(asset_id)
        return {
            "reading_id": str(existing["id"]),
            "current_value": format_decimal(_as_decimal((meter or {}).get("current_value"))),
            "idempotent_replay": True,
            "reading": existing,
        }

    meter = fetch_meter_row(asset_id)
    if meter is None:
        raise ValueError("asset_meter not found")
    if meter.get("meter_type") == "none":
        raise ValueError("asset has no operating meter")

    if row_version is not None and int(meter.get("row_version") or 0) != int(row_version):
        raise ValueError("CONFLICT: row_version mismatch")

    epoch = int(meter.get("meter_epoch") or 1)
    prev = _latest_accepted_in_epoch(asset_id, epoch)
    prev_value = _as_decimal(prev.get("value")) if prev else _as_decimal(meter.get("current_value")) or Decimal("0")

    if value < prev_value:
        token = create_lower_reading_preview(
            asset_id,
            value=value,
            reading_at=reading_at,
            entry_method=entry_method,
            note=note,
            idempotency_key=idempotency_key,
            previous_value=prev_value,
        )
        return {
            "lower_reading_preview": True,
            "preview_token": token,
            "previous_value": format_decimal(prev_value),
            "proposed_value": format_decimal(value),
            "options": sorted(CORRECTION_REASONS),
        }

    return insert_accepted_reading(
        asset_id,
        value=value,
        reading_at=reading_at,
        entry_method=entry_method,
        note=note,
        correction_reason=None,
        meter_type=str(meter.get("meter_type") or "none"),
        unit=str(meter.get("unit") or ""),
        meter_epoch=epoch,
        operator_identity=operator_identity,
        integration_identity=integration_identity,
        idempotency_key=idempotency_key,
    )


def confirm_lower_reading(
    asset_id: str,
    *,
    preview_token: str,
    correction_reason: str,
    operator_identity: str,
    note: str | None = None,
    row_version: int | None = None,
) -> dict[str, Any]:
    if correction_reason not in CORRECTION_REASONS:
        raise ValueError(f"correction_reason must be one of {sorted(CORRECTION_REASONS)}")
    if not operator_identity:
        raise ValueError("operator_identity is required for lower-reading confirmation")

    preview = consume_preview_token(preview_token)
    if preview is None or preview.get("asset_id") != asset_id:
        raise ValueError("invalid or expired preview_token")

    idempotency_key = preview.get("idempotency_key")
    existing = find_idempotent_reading(asset_id, idempotency_key or "")
    if existing:
        meter = fetch_meter_row(asset_id)
        return {
            "reading_id": str(existing["id"]),
            "current_value": format_decimal(_as_decimal((meter or {}).get("current_value"))),
            "idempotent_replay": True,
        }

    meter = fetch_meter_row(asset_id)
    if meter is None:
        raise ValueError("asset_meter not found")
    if row_version is not None and int(meter.get("row_version") or 0) != int(row_version):
        raise ValueError("CONFLICT: row_version mismatch")

    epoch = int(meter.get("meter_epoch") or 1)
    value = parse_decimal(preview.get("value"))
    reading_at = datetime.fromisoformat(str(preview.get("reading_at")).replace("Z", "+00:00"))
    entry_method = str(preview.get("entry_method") or "manual")
    merged_note = note or preview.get("note")

    new_epoch = epoch
    if correction_reason in {"replacement", "rollover"}:
        new_epoch = epoch + 1
        pm_db.execute(
            """
            UPDATE propertymanager.asset_meter
            SET meter_epoch = %s,
                row_version = row_version + 1,
                updated_at = now()
            WHERE asset_id = %s
            """,
            (new_epoch, asset_id),
        )
        meter = fetch_meter_row(asset_id)

    corrects_id = None
    if correction_reason == "correction":
        prev = _latest_accepted_in_epoch(asset_id, epoch if correction_reason != "replacement" else epoch)
        if prev:
            corrects_id = str(prev["id"])

    return insert_accepted_reading(
        asset_id,
        value=value,
        reading_at=reading_at,
        entry_method=entry_method,
        note=merged_note,
        correction_reason=correction_reason,
        meter_type=str((meter or {}).get("meter_type") or "none"),
        unit=str((meter or {}).get("unit") or ""),
        meter_epoch=new_epoch,
        operator_identity=operator_identity,
        integration_identity=None,
        idempotency_key=idempotency_key,
        corrects_reading_id=corrects_id,
    )


def complete_task_meter(
    task_id: str,
    *,
    completed_at: datetime,
    note: str | None,
    meter_value_at_completion: Decimal | None,
    confirm_current_meter: bool = False,
    operator_identity: str | None = None,
    integration_identity: str | None = None,
) -> dict[str, Any] | None:
    task = pm_db.execute_one_json(
        """
        SELECT id, asset_id, warning_days, schedule_kind, meter_interval_value,
               last_done_meter_value, next_due_meter_value
        FROM propertymanager.maintenance_tasks
        WHERE id = %s AND is_active = true
        """,
        (task_id,),
    )
    if task is None:
        return None

    asset_id = task.get("asset_id")
    schedule_kind = task.get("schedule_kind") or "calendar"
    reading_id = None
    meter_val: Decimal | None = None
    next_due_meter: Decimal | None = None
    cleared_one_time = False

    meter_row = fetch_meter_row(str(asset_id)) if asset_id else None
    proposed_meter = fetch_asset_proposed_meter(str(asset_id)) if asset_id else None
    active_meter = bool(
        asset_id
        and meter_row
        and meter_row.get("meter_type") != "none"
        and (proposed_meter or {}).get("meter_activated_at") is not None
    )
    proposed_type = str((proposed_meter or {}).get("meter_proposed_type") or "none")
    meter_scheduled = schedule_kind in {"meter", "both"}
    meter_supplied = meter_value_at_completion is not None or confirm_current_meter

    if asset_id and not active_meter and proposed_type != "none":
        raise ValueError("activate the proposed asset meter before completing this task")
    if meter_scheduled and not active_meter:
        raise ValueError("meter-scheduled tasks require an activated asset meter")
    if active_meter and not meter_supplied:
        raise ValueError(
            "meter_value_at_completion or confirm_current_meter=true required for tasks linked to an active meter"
        )
    if meter_supplied and not active_meter:
        raise ValueError("meter completion values require an activated asset meter")

    if active_meter:
        if meter_val is None and confirm_current_meter:
            meter_val = _as_decimal(meter_row.get("current_value"))
        elif meter_value_at_completion is not None:
            meter_val = meter_value_at_completion

        if meter_val is not None:
            current_value = _as_decimal(meter_row.get("current_value")) or Decimal("0")
            if meter_val < current_value:
                raise ValueError("lower reading at completion requires preview/confirm flow first")
            reading_id = str(uuid4())
            next_due_meter = _as_decimal(task.get("next_due_meter_value"))
            if meter_scheduled:
                interval = _as_decimal(task.get("meter_interval_value"))
                if interval is not None and interval > 0:
                    next_due_meter = decimal_to_db(meter_val + interval)
                else:
                    # One-time trigger: clear absolute due threshold.
                    next_due_meter = None
                    cleared_one_time = True

    return {
        "asset_id": str(asset_id) if asset_id else None,
        "meter_reading_id": reading_id,
        "meter_value": format_decimal(meter_val) if meter_val is not None else None,
        "meter_value_decimal": meter_val,
        "next_due_meter_value": next_due_meter,
        "cleared_one_time": cleared_one_time,
        "schedule_kind": schedule_kind,
        "applied_meter": bool(active_meter and meter_val is not None),
    }


def apply_task_completion_transaction(
    *,
    task_id: str,
    completion_id: str,
    completed_at: datetime,
    next_due: datetime,
    note: str | None,
    meter_result: dict[str, Any],
    operator_identity: str | None,
    integration_identity: str | None,
) -> bool:
    """Atomically append the meter reading, completion, and rescheduled task state."""
    asset_id = str(meter_result["asset_id"])
    reading_id = str(meter_result["meter_reading_id"])
    meter_value = decimal_to_db(meter_result["meter_value_decimal"])
    next_due_meter = meter_result.get("next_due_meter_value")

    updated = pm_db.execute_top_level_one_json(
        """WITH locked_task AS (
               SELECT id, asset_id
               FROM propertymanager.maintenance_tasks
               WHERE id = %s AND asset_id = %s AND is_active = true
                 AND kind <> 'Work Request' AND intake_state IS NULL
               FOR UPDATE
           ), locked_meter AS (
               SELECT m.asset_id, m.meter_type, m.unit, m.meter_epoch,
                      m.current_value, m.latest_reading_at
               FROM propertymanager.asset_meter m
               JOIN propertymanager.assets a ON a.id = m.asset_id
               JOIN locked_task t ON t.asset_id = m.asset_id
               WHERE m.meter_type <> 'none' AND a.meter_activated_at IS NOT NULL
               FOR UPDATE OF m
           ), latest_reading AS (
               SELECT r.id, r.value
               FROM propertymanager.asset_meter_reading r
               JOIN locked_meter m ON m.asset_id = r.asset_id
               WHERE r.meter_epoch = m.meter_epoch AND r.status = 'accepted'
               ORDER BY r.reading_at DESC, r.created_at DESC
               LIMIT 1
           ), inserted_reading AS (
               INSERT INTO propertymanager.asset_meter_reading
                   (id, asset_id, value, reading_at, entry_method, note,
                    correction_reason, usage_since_previous, previous_reading_id,
                    meter_type_at_entry, unit_at_entry, status, operator_identity,
                    integration_identity, idempotency_key, meter_epoch, corrects_reading_id)
               SELECT %s, m.asset_id, %s, %s, 'completion', %s,
                      NULL,
                      CASE WHEN latest.id IS NULL THEN NULL ELSE %s - latest.value END,
                      latest.id, m.meter_type, m.unit, 'accepted', %s, %s, NULL,
                      m.meter_epoch, NULL
               FROM locked_meter m
               LEFT JOIN latest_reading latest ON true
               WHERE %s >= COALESCE(latest.value, m.current_value, 0)
               RETURNING id, asset_id, value, reading_at
           ), updated_meter AS (
               UPDATE propertymanager.asset_meter m
               SET current_value = CASE
                       WHEN m.latest_reading_at IS NULL OR reading.reading_at >= m.latest_reading_at
                           THEN reading.value
                       ELSE m.current_value
                   END,
                   latest_reading_at = CASE
                       WHEN m.latest_reading_at IS NULL OR reading.reading_at >= m.latest_reading_at
                           THEN reading.reading_at
                       ELSE m.latest_reading_at
                   END,
                   row_version = row_version + 1,
                   updated_at = now()
               FROM inserted_reading reading
               WHERE m.asset_id = reading.asset_id
               RETURNING m.asset_id, m.meter_epoch
           ), inserted_completion AS (
               INSERT INTO propertymanager.maintenance_completions
                   (id, task_id, completed_at, note, meter_value_at_completion, meter_reading_id)
               SELECT %s, task.id, %s, %s, reading.value, reading.id
               FROM locked_task task
               JOIN inserted_reading reading ON reading.asset_id = task.asset_id
               RETURNING task_id
           ), updated_task AS (
               UPDATE propertymanager.maintenance_tasks task
               SET last_done = %s,
                   next_due = %s,
                   last_done_meter_value = %s,
                   next_due_meter_value = %s,
                   deferred_until = NULL,
                   result_notes = COALESCE(%s, result_notes),
                   updated_at = now()
               FROM inserted_completion completion
               WHERE task.id = completion.task_id
               RETURNING task.id
           ), result AS (
               SELECT task.id, meter.meter_epoch
               FROM updated_task task
               JOIN updated_meter meter ON true
           )
           SELECT row_to_json(result) FROM result""",
        (
            task_id,
            asset_id,
            reading_id,
            meter_value,
            completed_at,
            note,
            meter_value,
            operator_identity,
            integration_identity,
            meter_value,
            completion_id,
            completed_at,
            note,
            completed_at,
            next_due,
            meter_value,
            next_due_meter,
            note,
        ),
    )
    if updated is not None:
        recalc_usage_for_epoch(asset_id, int(updated["meter_epoch"]))
    return updated is not None
