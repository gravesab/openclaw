#!/usr/bin/env python3
"""Task bypass contracts: skip keeps the cadence, reschedule moves to a picked target."""

from __future__ import annotations

import os
import sys
import unittest
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
API_KEY = "task-bypass-test-key"
AUTH = {"Authorization": f"Bearer {API_KEY}"}
NOW = datetime(2026, 10, 4, 16, 0, tzinfo=timezone.utc)


def _load_app():
    with mock.patch.dict(
        os.environ,
        {
            "PROPERTYMANAGER_AUTH_DISABLED": "0",
            "PROPERTYMANAGER_API_KEY": API_KEY,
            "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
        },
        clear=False,
    ):
        if str(API_DIR) not in sys.path:
            sys.path.insert(0, str(API_DIR))
        for name in (
            "auth",
            "db",
            "errors",
            "decimal_utils",
            "meter_schedule",
            "task_schedule",
            "assets_api",
            "mapping_proposals",
            "maintenance_proposals",
            "work_requests",
            "propertymanager_api",
        ):
            sys.modules.pop(name, None)
        import auth
        import propertymanager_api as api

        auth.AUTH_DISABLED = False
        auth.API_KEY = API_KEY
        return api


class _FixedDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW if tz is None else NOW.astimezone(tz)


def _task(**overrides):
    task = {
        "id": "task",
        "frequency": "Monthly",
        "warning_days": 7,
        "asset_id": None,
        "schedule_kind": "calendar",
        "kind": "Maintenance",
        "intake_state": None,
        "next_due": "2026-10-01T17:00:00+00:00",
        "meter_interval_value": None,
        "next_due_meter_value": None,
        "deferred_until": None,
    }
    task.update(overrides)
    return task


class ScheduleMathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.ts = cls.api.ts

    def monthly(self, anchor):
        return self.api.next_calendar_due(anchor, frequency="Monthly", warning_days=7)

    def test_overdue_skip_keeps_the_due_day(self):
        due = datetime(2026, 10, 1, 17, 0, tzinfo=timezone.utc)
        self.assertEqual(
            self.ts.skip_calendar_due(due, now=NOW, advance=self.monthly),
            datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc),
        )

    def test_several_cycles_overdue_advances_until_ahead(self):
        due = datetime(2026, 7, 1, 17, 0, tzinfo=timezone.utc)
        self.assertEqual(
            self.ts.skip_calendar_due(due, now=NOW, advance=self.monthly),
            datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc),
        )

    def test_early_skip_moves_to_the_following_occurrence(self):
        due = datetime(2026, 10, 10, 17, 0, tzinfo=timezone.utc)
        self.assertEqual(
            self.ts.skip_calendar_due(due, now=NOW, advance=self.monthly),
            datetime(2026, 11, 10, 17, 0, tzinfo=timezone.utc),
        )

    def test_meter_skip_advances_whole_intervals_above_current_reading(self):
        skip = self.ts.skip_meter_due
        self.assertEqual(skip(Decimal("250"), interval=Decimal("250"), current_meter=Decimal("260")), Decimal("500"))
        self.assertEqual(skip(Decimal("250"), interval=Decimal("250"), current_meter=Decimal("750")), Decimal("1000"))
        self.assertEqual(skip(Decimal("250"), interval=Decimal("250"), current_meter=Decimal("100")), Decimal("500"))
        self.assertEqual(skip(Decimal("250"), interval=Decimal("250"), current_meter=None), Decimal("500"))

    def test_one_time_meter_trigger_cannot_be_skipped(self):
        with self.assertRaisesRegex(ValueError, "reschedule instead"):
            self.ts.skip_meter_due(Decimal("250"), interval=None, current_meter=Decimal("10"))

    def test_reschedule_date_rejects_past_and_accepts_today(self):
        today = date(2026, 10, 4)
        self.assertEqual(self.ts.parse_reschedule_date("2026-10-04", today=today), today)
        with self.assertRaisesRegex(ValueError, "past"):
            self.ts.parse_reschedule_date("2026-10-03", today=today)
        with self.assertRaisesRegex(ValueError, "YYYY-MM-DD"):
            self.ts.parse_reschedule_date("next week", today=today)

    def test_picked_date_is_stored_at_ranch_midday(self):
        self.assertEqual(
            self.ts.due_at_for_date(date(2026, 10, 20)),
            datetime(2026, 10, 20, 17, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(
            self.ts.due_at_for_date(date(2026, 12, 20)),
            datetime(2026, 12, 20, 18, 0, tzinfo=timezone.utc),
        )

    def test_schedule_change_never_writes_a_completion(self):
        with mock.patch.object(self.ts.pm_db, "execute_top_level_one_json", return_value={"id": "event"}) as run:
            applied = self.ts.apply_schedule_change(
                task=_task(),
                action="skip",
                new_next_due=datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc),
                new_next_due_meter=None,
                new_deferred_until=None,
                note="Parts on order",
                operator_identity="andrew",
                integration_identity=None,
            )
        self.assertTrue(applied)
        sql = run.call_args.args[0]
        self.assertNotIn("maintenance_completions", sql)
        self.assertNotIn("last_done", sql)
        self.assertIn("maintenance_task_schedule_events", sql)
        self.assertIn("next_due IS NOT DISTINCT FROM", sql)


class BypassRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    def setUp(self):
        patches = [
            mock.patch.object(self.api, "datetime", _FixedDatetime),
            mock.patch.object(self.api, "fetch_task_or_404", side_effect=lambda task_id: {"id": task_id}),
            mock.patch.object(self.api, "enrich_tasks", side_effect=lambda rows: [dict(rows[0])]),
            mock.patch.object(self.api.ts, "fetch_schedule_events", return_value=[{"action": "skip"}]),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def post(self, path, task, body=None, *, meter=None, applied=True):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=task), \
             mock.patch.object(self.api.ms, "fetch_meter_row", return_value=meter), \
             mock.patch.object(self.api.ts, "apply_schedule_change", return_value=applied) as apply:
            response = self.client.post(path, json=body or {}, headers=AUTH)
        return response, apply

    def test_skip_requires_credentials(self):
        self.assertEqual(self.client.post("/tasks/task/skip", json={}).status_code, 401)

    def test_calendar_skip_moves_to_next_occurrence_with_note(self):
        response, apply = self.post("/tasks/task/skip", _task(), {"note": "  Parts on order  "})
        self.assertEqual(response.status_code, 200, response.get_json())
        change = apply.call_args.kwargs
        self.assertEqual(change["action"], "skip")
        self.assertEqual(change["new_next_due"], datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc))
        self.assertIsNone(change["new_deferred_until"])
        self.assertEqual(change["note"], "Parts on order")
        self.assertEqual(response.get_json()["schedule_events"], [{"action": "skip"}])

    def test_meter_skip_advances_trigger_and_calendar(self):
        task = _task(asset_id="asset", schedule_kind="meter", meter_interval_value=250, next_due_meter_value=250)
        meter = {"meter_type": "runtime_hours", "current_value": "260"}
        response, apply = self.post("/tasks/task/skip", task, meter=meter)
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertEqual(apply.call_args.kwargs["new_next_due_meter"], Decimal("500"))

    def test_one_time_meter_skip_is_rejected(self):
        task = _task(asset_id="asset", schedule_kind="meter", next_due_meter_value=250)
        response, apply = self.post("/tasks/task/skip", task, meter={"meter_type": "runtime_hours", "current_value": "10"})
        self.assertEqual(response.status_code, 400)
        apply.assert_not_called()

    def test_work_requests_and_missing_tasks_are_rejected(self):
        response, apply = self.post("/tasks/task/skip", _task(kind="Work Request", intake_state="submitted"))
        self.assertEqual(response.status_code, 409)
        response, _ = self.post("/tasks/task/reschedule", None, {"next_due": "2026-10-20"})
        self.assertEqual(response.status_code, 404)
        apply.assert_not_called()

    def test_concurrent_change_is_a_conflict(self):
        response, _ = self.post("/tasks/task/skip", _task(), applied=False)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "SCHEDULE_CONFLICT")

    def test_calendar_reschedule_sets_the_picked_date(self):
        response, apply = self.post("/tasks/task/reschedule", _task(), {"next_due": "2026-10-20"})
        self.assertEqual(response.status_code, 200, response.get_json())
        change = apply.call_args.kwargs
        self.assertEqual(change["action"], "reschedule")
        self.assertEqual(change["new_next_due"], datetime(2026, 10, 20, 17, 0, tzinfo=timezone.utc))
        self.assertIsNone(change["new_deferred_until"])

    def test_meter_reschedule_by_date_holds_the_task(self):
        task = _task(asset_id="asset", schedule_kind="meter", meter_interval_value=250, next_due_meter_value=250)
        response, apply = self.post("/tasks/task/reschedule", task, {"next_due": "2026-10-20"})
        self.assertEqual(response.status_code, 200, response.get_json())
        change = apply.call_args.kwargs
        self.assertEqual(change["new_deferred_until"], date(2026, 10, 20))
        self.assertEqual(change["new_next_due_meter"], Decimal("250"))

    def test_meter_reschedule_by_value_must_be_above_reading(self):
        task = _task(asset_id="asset", schedule_kind="both", meter_interval_value=250, next_due_meter_value=250)
        meter = {"meter_type": "runtime_hours", "current_value": "300"}
        response, apply = self.post("/tasks/task/reschedule", task, {"next_due_meter_value": 300}, meter=meter)
        self.assertEqual(response.status_code, 400)
        apply.assert_not_called()
        response, apply = self.post("/tasks/task/reschedule", task, {"next_due_meter_value": "320.5"}, meter=meter)
        self.assertEqual(response.status_code, 200, response.get_json())
        change = apply.call_args.kwargs
        self.assertEqual(change["new_next_due_meter"], Decimal("320.5"))
        self.assertEqual(change["new_next_due"], datetime(2026, 10, 1, 17, 0, tzinfo=timezone.utc))
        self.assertIsNone(change["new_deferred_until"])

    def test_reschedule_rejects_past_dates_ambiguous_targets_and_calendar_meter_values(self):
        for body in (
            {"next_due": "2026-10-03"},
            {"next_due": "2026-10-20", "next_due_meter_value": 500},
            {},
            {"next_due_meter_value": 500},
            {"next_due": "2026-10-20", "note": "x" * 2001},
        ):
            response, apply = self.post("/tasks/task/reschedule", _task(), body)
            self.assertEqual(response.status_code, 400, body)
            apply.assert_not_called()


class DeferredEnrichmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()

    def enrich(self, deferred_until):
        row = _task(asset_id="asset", schedule_kind="meter", next_due_meter_value=250, deferred_until=deferred_until)
        meter = {"asset": {"current_value": "300"}}
        with mock.patch.object(self.api, "datetime", _FixedDatetime), \
             mock.patch.object(self.api.pm_db, "execute_json", return_value=[]), \
             mock.patch.object(self.api.ms, "fetch_meter_rows", return_value=meter):
            return self.api.enrich_tasks([row])[0]

    def test_held_meter_task_is_not_flagged_until_the_picked_date(self):
        held = self.enrich("2026-10-20")
        self.assertTrue(held["deferred"])
        self.assertFalse(held["overdue_meter"])
        released = self.enrich("2026-10-04")
        self.assertFalse(released["deferred"])
        self.assertTrue(released["overdue_meter"])


if __name__ == "__main__":
    unittest.main()
