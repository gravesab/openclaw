"""Regression tests for absolute PropertyManager meter triggers."""

from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock


API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

import meter_schedule as schedule  # noqa: E402


class MeterScheduleRecalculationTests(unittest.TestCase):
    def test_preserves_operator_entered_absolute_trigger(self):
        tasks = [
            {
                "id": "task-1",
                "meter_interval_value": "25",
                "last_done_meter_value": None,
                "next_due_meter_value": "125",
            }
        ]
        with (
            mock.patch.object(schedule.pm_db, "execute_json", return_value=tasks),
            mock.patch.object(schedule.pm_db, "execute") as execute,
        ):
            updated = schedule.recalc_tasks_for_asset("asset-1", Decimal("127.4"))

        self.assertEqual(updated, [])
        execute.assert_not_called()

    def test_initializes_trigger_when_no_absolute_value_exists(self):
        tasks = [
            {
                "id": "task-2",
                "meter_interval_value": "25",
                "last_done_meter_value": None,
                "next_due_meter_value": None,
            }
        ]
        with (
            mock.patch.object(schedule.pm_db, "execute_json", return_value=tasks),
            mock.patch.object(schedule.pm_db, "execute") as execute,
        ):
            updated = schedule.recalc_tasks_for_asset("asset-1", Decimal("100"))

        self.assertEqual(updated[0]["next_due_meter_value"], "125")
        self.assertEqual(execute.call_args.args[1][0], Decimal("125"))

    def test_completed_task_repeats_from_completion_meter(self):
        tasks = [
            {
                "id": "task-3",
                "meter_interval_value": "25",
                "last_done_meter_value": "127.4",
                "next_due_meter_value": "125",
            }
        ]
        with (
            mock.patch.object(schedule.pm_db, "execute_json", return_value=tasks),
            mock.patch.object(schedule.pm_db, "execute") as execute,
        ):
            updated = schedule.recalc_tasks_for_asset("asset-1", Decimal("130"))

        self.assertEqual(updated[0]["next_due_meter_value"], "152.4")
        self.assertEqual(execute.call_args.args[1][0], Decimal("152.4"))


if __name__ == "__main__":
    unittest.main()
