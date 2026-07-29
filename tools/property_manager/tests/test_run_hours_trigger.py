#!/usr/bin/env python3
"""Run-hours trigger contract tests (v1.3 corrections).

Covers due_meter / overdue_meter (strict >), explicit schedule_kind,
validation, one-time clear, warnings when trigger behind current.

Run:
  PROPERTYMANAGER_AUTH_DISABLED=1 python3 tools/property_manager/tests/test_run_hours_trigger.py
"""

from __future__ import annotations

import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(__file__))
from test_phase1_meters import (  # noqa: E402
    API,
    AUTH_HEADERS,
    _psql,
    _req,
    wait_health,
)


def _create_runtime_hours_asset(*, category: str = "Equipment", name: str = "RH Test") -> str:
    ext = f"TEST-RH-{uuid.uuid4().hex[:8]}"
    status, asset = _req(
        "POST",
        "/v1/assets",
        {"external_id": ext, "name": name, "category": category},
    )
    assert status == 201, asset
    asset_id = asset["id"]
    # Force proposed type for non-Equipment categories that default to none.
    if category.lower() != "equipment":
        _psql(
            f"""
            UPDATE propertymanager.assets
            SET meter_proposed_type = 'runtime_hours', meter_proposed_unit = 'hrs'
            WHERE id = '{asset_id}';
            UPDATE propertymanager.asset_meter
            SET meter_type = 'runtime_hours', unit = 'hrs'
            WHERE asset_id = '{asset_id}';
            """
        )
    status, activated = _req(
        "POST",
        f"/v1/assets/{asset_id}/activate-meter",
        {"meter_type": "runtime_hours", "unit": "hrs"},
    )
    assert status == 200, activated
    return asset_id


def _set_current_meter(asset_id: str, value: str) -> None:
    status, reading = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"value": value, "entry_method": "api"},
    )
    assert status == 200, reading


def _insert_task(
    *,
    asset_id: str | None,
    schedule_kind: str,
    next_due: str | None,
    interval: str | None = None,
    category: str = "Equipment",
) -> str:
    task_id = str(uuid.uuid4())
    item = f"RH Trigger {uuid.uuid4().hex[:8]}"
    interval_sql = f"'{interval}'" if interval is not None else "NULL"
    due_sql = f"'{next_due}'" if next_due is not None else "NULL"
    asset_sql = f"'{asset_id}'" if asset_id else "NULL"
    _psql(
        f"""
        INSERT INTO propertymanager.maintenance_tasks
            (id, area, item, category_name, priority, frequency, warning_days, critical_days,
             estimated_minutes, last_done, next_due, is_active, schedule_kind, kind,
             completion_history, tools_required, origin, asset_id,
             meter_interval_value, meter_interval_unit, next_due_meter_value,
             send_telegram_update, include_in_daily_briefing, alert_if_overdue)
        VALUES ('{task_id}', '{category}', '{item}', '{category}', 'Medium', 'Monthly',
                7, 14, 30, now(), now() + interval '30 days', true, '{schedule_kind}', 'Scheduled',
                '[]'::jsonb, '[]'::jsonb, 'owner', {asset_sql},
                {interval_sql}, 'hrs', {due_sql},
                true, true, true);
        """
    )
    return task_id


def test_exact_threshold_due_not_overdue() -> str:
    asset_id = _create_runtime_hours_asset(name="Exact Due Mower")
    _set_current_meter(asset_id, "127.4")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="127.4", interval="50")

    status, task = _req("GET", f"/tasks/{task_id}")
    assert status == 200, task
    assert task.get("due_meter") is True, task
    assert task.get("overdue_meter") is False, task
    assert task.get("remaining_meter") in {"0", "0.0", "0.000"}, task
    return asset_id


def test_above_threshold_overdue(asset_id: str) -> None:
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="100", interval="50")
    # current is already 127.4 from prior test on same asset
    status, task = _req("GET", f"/tasks/{task_id}")
    assert status == 200, task
    assert task.get("overdue_meter") is True, task
    assert task.get("due_meter") is False, task
    rem = float(task.get("remaining_meter"))
    assert rem < 0, task


def test_below_threshold_remaining() -> None:
    asset_id = _create_runtime_hours_asset(name="Remaining Mower")
    _set_current_meter(asset_id, "80")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="150", interval="50")
    status, task = _req("GET", f"/tasks/{task_id}")
    assert status == 200, task
    assert task.get("due_meter") is False, task
    assert task.get("overdue_meter") is False, task
    assert float(task.get("remaining_meter")) == 70.0, task


def test_reject_calendar_plus_trigger_no_silent_promote() -> None:
    asset_id = _create_runtime_hours_asset(name="No Promote")
    _set_current_meter(asset_id, "10")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="calendar", next_due=None)

    status, body = _req(
        "PATCH",
        f"/tasks/{task_id}",
        {"next_due_meter_value": "150"},
    )
    assert status == 400, body
    msg = str(body.get("message") or body.get("error") or body).lower()
    assert "schedule_kind" in msg or "meter" in msg, body

    status, task = _req("GET", f"/tasks/{task_id}")
    assert status == 200, task
    assert (task.get("schedule_kind") or "calendar") == "calendar", task
    assert task.get("next_due_meter_value") in (None, ""), task


def test_explicit_both_accepted() -> None:
    asset_id = _create_runtime_hours_asset(name="Both Schedule")
    _set_current_meter(asset_id, "10")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="calendar", next_due=None)

    status, body = _req(
        "PATCH",
        f"/tasks/{task_id}",
        {
            "next_due_meter_value": "150",
            "schedule_kind": "both",
            "meter_interval_unit": "hrs",
        },
    )
    assert status == 200, body
    assert body.get("schedule_kind") == "both", body
    assert str(body.get("next_due_meter_value")) in {"150", "150.0", "150.000"}, body


def test_trigger_behind_current_warning() -> None:
    asset_id = _create_runtime_hours_asset(name="Behind Trigger")
    _set_current_meter(asset_id, "200")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due=None)

    status, body = _req(
        "PATCH",
        f"/tasks/{task_id}",
        {
            "next_due_meter_value": "150",
            "schedule_kind": "meter",
            "meter_interval_unit": "hrs",
        },
    )
    assert status == 200, body
    warnings = body.get("warnings") or []
    assert warnings, body
    assert any("behind" in str(w).lower() for w in warnings), warnings


def test_blank_invalid_negative_rejected() -> None:
    asset_id = _create_runtime_hours_asset(name="Invalid Trigger")
    _set_current_meter(asset_id, "10")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due=None)

    for bad in ("", "abc", "-5"):
        status, body = _req(
            "PATCH",
            f"/tasks/{task_id}",
            {"next_due_meter_value": bad, "schedule_kind": "meter"},
        )
        assert status == 400, (bad, body)


def test_unlinked_rejected() -> None:
    task_id = _insert_task(asset_id=None, schedule_kind="meter", next_due=None, category="House")
    status, body = _req(
        "PATCH",
        f"/tasks/{task_id}",
        {"next_due_meter_value": "100", "schedule_kind": "meter"},
    )
    assert status == 400, body
    msg = str(body.get("message") or body.get("error") or body).lower()
    assert "asset" in msg, body


def test_runtime_hours_non_equipment_category_allowed() -> None:
    asset_id = _create_runtime_hours_asset(category="Outbuildings", name="Generator Hours")
    _set_current_meter(asset_id, "5")
    task_id = _insert_task(
        asset_id=asset_id,
        schedule_kind="meter",
        next_due=None,
        category="Outbuildings",
    )
    status, body = _req(
        "PATCH",
        f"/tasks/{task_id}",
        {
            "next_due_meter_value": "40",
            "schedule_kind": "meter",
            "meter_interval_unit": "hrs",
        },
    )
    assert status == 200, body
    assert str(body.get("next_due_meter_value")) in {"40", "40.0", "40.000"}, body


def test_one_time_completion_clears_trigger() -> None:
    asset_id = _create_runtime_hours_asset(name="One Time Clear")
    _set_current_meter(asset_id, "99")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="100", interval=None)

    status, body = _req(
        "POST",
        f"/tasks/{task_id}/complete",
        {"confirm_current_meter": True},
    )
    # confirm uses current 99; may still complete. Prefer explicit meter value:
    if status != 200:
        status, body = _req(
            "POST",
            f"/tasks/{task_id}/complete",
            {"meter_value_at_completion": "100"},
        )
    assert status == 200, body
    assert body.get("next_due_meter_value") in (None, ""), body
    assert str(body.get("last_done_meter_value")) in {"100", "100.0", "100.000", "99", "99.0", "99.000"}, body


def test_interval_completion_advances() -> None:
    asset_id = _create_runtime_hours_asset(name="Interval Advance")
    _set_current_meter(asset_id, "50")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="50", interval="25")

    status, body = _req(
        "POST",
        f"/tasks/{task_id}/complete",
        {"meter_value_at_completion": "50"},
    )
    assert status == 200, body
    assert str(body.get("next_due_meter_value")) in {"75", "75.0", "75.000"}, body


def test_duplicate_completion_safe() -> None:
    asset_id = _create_runtime_hours_asset(name="Dup Complete")
    _set_current_meter(asset_id, "10")
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="10", interval="10")

    status1, body1 = _req(
        "POST",
        f"/tasks/{task_id}/complete",
        {"meter_value_at_completion": "10"},
    )
    assert status1 == 200, body1
    status2, body2 = _req(
        "POST",
        f"/tasks/{task_id}/complete",
        {"meter_value_at_completion": "20"},
    )
    # Second complete should succeed (new completion row); next due advances again.
    assert status2 == 200, body2
    assert str(body2.get("next_due_meter_value")) in {"30", "30.0", "30.000"}, body2


def main() -> int:
    print(f"API={API}")
    wait_health()
    asset_id = test_exact_threshold_due_not_overdue()
    print("PASS exact threshold due_meter")
    test_above_threshold_overdue(asset_id)
    print("PASS above threshold overdue_meter")
    test_below_threshold_remaining()
    print("PASS below threshold remaining")
    test_reject_calendar_plus_trigger_no_silent_promote()
    print("PASS no silent promote")
    test_explicit_both_accepted()
    print("PASS schedule_kind=both")
    test_trigger_behind_current_warning()
    print("PASS trigger behind warning")
    test_blank_invalid_negative_rejected()
    print("PASS blank/invalid/negative rejected")
    test_unlinked_rejected()
    print("PASS unlinked rejected")
    test_runtime_hours_non_equipment_category_allowed()
    print("PASS runtime_hours non-Equipment")
    test_one_time_completion_clears_trigger()
    print("PASS one-time clear")
    test_interval_completion_advances()
    print("PASS interval advance")
    test_duplicate_completion_safe()
    print("PASS duplicate completion")
    print("ALL RUN-HOURS TRIGGER TESTS PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
