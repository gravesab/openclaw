#!/usr/bin/env python3
"""Delta / hours-since-last meter entry tests.

Run:
  PROPERTYMANAGER_AUTH_DISABLED=1 python3 tools/property_manager/tests/test_meter_delta.py
"""

from __future__ import annotations

import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(__file__))
from test_phase1_meters import (  # noqa: E402
    AUTH_HEADERS,
    _req,
    wait_health,
)
from test_run_hours_trigger import (  # noqa: E402
    _create_runtime_hours_asset,
    _insert_task,
    _set_current_meter,
)


def test_delta_accumulates() -> str:
    asset_id = _create_runtime_hours_asset(name="Delta Accrue Mower")
    _set_current_meter(asset_id, "100")

    status, body = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"delta": "2.5", "entry_method": "api"},
    )
    assert status == 200, body
    assert body.get("current_value") in {"102.5", "102.500"}, body
    assert body.get("value") in {"102.5", "102.500"}, body
    assert body.get("delta") in {"2.5", "2.500"}, body
    meter = (body.get("asset") or {}).get("meter") or {}
    assert meter.get("current_value") in {102.5, "102.5", "102.500"}, meter
    return asset_id


def test_remaining_shifts_after_delta(asset_id: str) -> None:
    task_id = _insert_task(asset_id=asset_id, schedule_kind="meter", next_due="150", interval="50")
    # current is 102.5 from prior test
    status, task = _req("GET", f"/tasks/{task_id}")
    assert status == 200, task
    rem = float(task.get("remaining_meter"))
    assert abs(rem - 47.5) < 0.001, task


def test_reject_both_value_and_delta(asset_id: str) -> None:
    status, body = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"value": "200", "delta": "1"},
    )
    assert status == 400, body
    msg = (body.get("message") or "").lower()
    assert "both" in msg or "either" in msg, body


def test_reject_neither() -> None:
    asset_id = _create_runtime_hours_asset(name="Delta Neither")
    _set_current_meter(asset_id, "10")
    status, body = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"entry_method": "api"},
    )
    assert status == 400, body


def test_reject_nonpositive_delta(asset_id: str) -> None:
    for bad in ("0", "-1", "", "0.0"):
        status, body = _req(
            "POST",
            f"/v1/assets/{asset_id}/meter-readings",
            {"delta": bad},
        )
        assert status == 400, (bad, body)


def test_reject_add_value_alias(asset_id: str) -> None:
    status, body = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"add_value": "1"},
    )
    assert status == 400, body
    assert "delta" in (body.get("message") or "").lower(), body


def test_absolute_still_works(asset_id: str) -> None:
    status, body = _req(
        "POST",
        f"/v1/assets/{asset_id}/meter-readings",
        {"value": "200", "entry_method": "api"},
    )
    assert status == 200, body
    assert body.get("current_value") in {"200", "200.0", "200.000"}, body
    assert body.get("delta") is None, body


def test_parse_add_phrase() -> None:
    # Needs an activated asset whose name appears in the phrase.
    asset_id = _create_runtime_hours_asset(name=f"ParseDelta {uuid.uuid4().hex[:6]}")
    status, asset = _req("GET", f"/v1/assets/{asset_id}")
    assert status == 200, asset
    name = asset.get("name")
    status, body = _req(
        "POST",
        "/v1/meter-readings/parse",
        {"text": f"add 2.5 hours on {name}"},
    )
    assert status == 200, body
    assert body.get("entry_mode") == "delta", body
    assert body.get("delta") in {"2.5", "2.500"}, body
    assert body.get("value") is None, body
    assert body.get("asset_id") == asset_id, body


def main() -> int:
    print(f"AUTH key present={bool(AUTH_HEADERS.get('Authorization'))}")
    wait_health()
    asset_id = test_delta_accumulates()
    print("PASS delta accumulates")
    test_remaining_shifts_after_delta(asset_id)
    print("PASS remaining after delta")
    test_reject_both_value_and_delta(asset_id)
    print("PASS reject both")
    test_reject_neither()
    print("PASS reject neither")
    test_reject_nonpositive_delta(asset_id)
    print("PASS reject nonpositive delta")
    test_reject_add_value_alias(asset_id)
    print("PASS reject add_value")
    test_absolute_still_works(asset_id)
    print("PASS absolute still works")
    test_parse_add_phrase()
    print("PASS parse add phrase")
    print("ALL METER DELTA TESTS PASSED")
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
