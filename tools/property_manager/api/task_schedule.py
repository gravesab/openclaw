"""Task bypass: skip to the next scheduled occurrence or reschedule without a completion."""

from __future__ import annotations

from collections.abc import Callable
from datetime import date, datetime, time, timezone
from decimal import Decimal
from typing import Any
from uuid import uuid4
from zoneinfo import ZoneInfo

import db as pm_db
from decimal_utils import decimal_to_db, parse_decimal

RANCH_TIMEZONE = ZoneInfo("America/Chicago")
MAX_NOTE_LENGTH = 2000
MAX_SKIP_CYCLES = 1000
SCHEDULE_EVENT_LIMIT = 20

SCHEDULE_EVENT_COLUMNS = """
    id, task_id, action, previous_next_due, new_next_due,
    previous_next_due_meter_value, new_next_due_meter_value,
    previous_deferred_until, new_deferred_until, note, created_at
"""


def ranch_today(now: datetime) -> date:
    return now.astimezone(RANCH_TIMEZONE).date()


def parse_db_timestamp(value: Any) -> datetime | None:
    if value is None:
        return None
    parsed = datetime.fromisoformat(str(value))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def parse_db_date(value: Any) -> date | None:
    if value is None:
        return None
    return date.fromisoformat(str(value)[:10])


def is_deferred(deferred_until: Any, today: date) -> bool:
    held = parse_db_date(deferred_until)
    return held is not None and today < held


def due_at_for_date(day: date) -> datetime:
    """Store a picked civil date at ranch midday so every US client renders the same day."""
    return datetime.combine(day, time(12), RANCH_TIMEZONE).astimezone(timezone.utc)


def normalize_note(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("note must be a string")
    text = value.strip()
    if len(text) > MAX_NOTE_LENGTH:
        raise ValueError(f"note must be at most {MAX_NOTE_LENGTH} characters")
    return text or None


def skip_calendar_due(
    current_due: datetime | None,
    *,
    now: datetime,
    advance: Callable[[datetime], datetime],
) -> datetime:
    """Advance from the current due date by whole cycles until it is in the future.

    A skip always moves at least one cycle, so skipping a task that is not yet
    due moves it to the occurrence after this one.
    """
    next_due = advance(current_due or now)
    for _ in range(MAX_SKIP_CYCLES):
        if next_due > now:
            return next_due
        next_due = advance(next_due)
    raise ValueError("task is too many cycles overdue to skip; reschedule it instead")


def skip_meter_due(
    next_due_meter: Decimal | None,
    *,
    interval: Decimal | None,
    current_meter: Decimal | None,
) -> Decimal:
    """Advance the meter trigger by whole intervals until it is above the current reading."""
    if interval is None or interval <= 0:
        raise ValueError("one-time meter triggers cannot be skipped; reschedule instead")
    base = next_due_meter if next_due_meter is not None else current_meter
    if base is None:
        raise ValueError("meter-scheduled task has no trigger or reading to skip from")
    cycles = 1
    if current_meter is not None and base + interval <= current_meter:
        cycles = int((current_meter - base) // interval) + 1
    return decimal_to_db(base + interval * cycles)


def parse_reschedule_date(value: Any, *, today: date) -> date:
    if not isinstance(value, str):
        raise ValueError("next_due must be a YYYY-MM-DD date")
    try:
        day = date.fromisoformat(value.strip())
    except ValueError as exc:
        raise ValueError("next_due must be a YYYY-MM-DD date") from exc
    if day < today:
        raise ValueError("next_due cannot be in the past")
    return day


def parse_reschedule_meter(value: Any, *, current_meter: Decimal | None) -> Decimal:
    try:
        target = parse_decimal(value, field="next_due_meter_value")
    except ValueError as exc:
        raise ValueError("next_due_meter_value must be a number") from exc
    if not target.is_finite() or target < 0:
        raise ValueError("next_due_meter_value must be a finite nonnegative number")
    if current_meter is not None and target <= current_meter:
        raise ValueError("next_due_meter_value must be above the current meter reading")
    return decimal_to_db(target)


def apply_schedule_change(
    *,
    task: dict[str, Any],
    action: str,
    new_next_due: datetime | None,
    new_next_due_meter: Decimal | None,
    new_deferred_until: date | None,
    note: str | None,
    operator_identity: str | None,
    integration_identity: str | None,
) -> bool:
    """Update the task schedule and append its event atomically.

    Returns False when the task changed after it was read, so the caller can
    ask the user to reload instead of overwriting a concurrent change.
    """
    previous_meter = task.get("next_due_meter_value")
    updated = pm_db.execute_top_level_one_json(
        """WITH updated_task AS (
               UPDATE propertymanager.maintenance_tasks
               SET next_due = %s::timestamptz,
                   next_due_meter_value = %s::numeric,
                   deferred_until = %s::date,
                   updated_at = now()
               WHERE id = %s AND is_active = true
                 AND kind <> 'Work Request' AND intake_state IS NULL
                 AND next_due IS NOT DISTINCT FROM %s::timestamptz
                 AND next_due_meter_value IS NOT DISTINCT FROM %s::numeric
                 AND deferred_until IS NOT DISTINCT FROM %s::date
               RETURNING id
           ), inserted_event AS (
               INSERT INTO propertymanager.maintenance_task_schedule_events
                   (id, task_id, action, previous_next_due, new_next_due,
                    previous_next_due_meter_value, new_next_due_meter_value,
                    previous_deferred_until, new_deferred_until, note,
                    operator_identity, integration_identity)
               SELECT %s, task.id, %s, %s::timestamptz, %s::timestamptz,
                      %s::numeric, %s::numeric, %s::date, %s::date, %s, %s, %s
               FROM updated_task task
               RETURNING id
           )
           SELECT row_to_json(inserted_event) FROM inserted_event""",
        (
            new_next_due,
            new_next_due_meter,
            new_deferred_until,
            task["id"],
            task.get("next_due"),
            None if previous_meter is None else str(previous_meter),
            task.get("deferred_until"),
            str(uuid4()),
            action,
            task.get("next_due"),
            new_next_due,
            None if previous_meter is None else str(previous_meter),
            new_next_due_meter,
            task.get("deferred_until"),
            new_deferred_until,
            note,
            operator_identity,
            integration_identity,
        ),
    )
    return updated is not None


def fetch_schedule_events(task_id: str, *, limit: int = SCHEDULE_EVENT_LIMIT) -> list[dict[str, Any]]:
    return pm_db.execute_json(
        f"""
        SELECT {SCHEDULE_EVENT_COLUMNS}
        FROM propertymanager.maintenance_task_schedule_events
        WHERE task_id = %s
        ORDER BY created_at DESC
        LIMIT %s
        """,
        (task_id, limit),
    )
