#!/usr/bin/env python3
"""Focused completion authentication and meter-capture contracts."""

from __future__ import annotations

import os
import sys
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
API_KEY = "task-completion-test-key"


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


class TaskCompletionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    def test_auth_check_rejects_missing_credential_and_exposes_no_identity(self):
        denied = self.client.get("/auth/check")
        self.assertEqual(denied.status_code, 401)

        accepted = self.client.get(
            "/auth/check", headers={"Authorization": f"Bearer {API_KEY}"}
        )
        self.assertEqual(accepted.status_code, 200)
        self.assertEqual(accepted.get_json(), {"authenticated": True})

    def test_calendar_completion_captures_zero_on_activated_meter(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "schedule_kind": "calendar",
            "meter_interval_value": None,
            "next_due_meter_value": None,
        }
        meter = {"meter_type": "runtime_hours", "current_value": "0", "unit": "hrs"}
        asset = {
            "meter_proposed_type": "runtime_hours",
            "meter_activated_at": "2026-08-29T12:00:00+00:00",
        }
        with mock.patch.object(self.api.ms.pm_db, "execute_one_json", return_value=task), \
             mock.patch.object(self.api.ms, "fetch_meter_row", return_value=meter), \
             mock.patch.object(self.api.ms, "fetch_asset_proposed_meter", return_value=asset):
            result = self.api.ms.complete_task_meter(
                "task",
                completed_at=datetime.now(timezone.utc),
                note=None,
                meter_value_at_completion=Decimal("0"),
            )

        self.assertTrue(result["applied_meter"])
        self.assertEqual(result["meter_value_decimal"], Decimal("0"))
        self.assertIsNone(result["next_due_meter_value"])
        self.assertIsNotNone(result["meter_reading_id"])

    def test_active_meter_requires_explicit_confirmation(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "schedule_kind": "calendar",
            "meter_interval_value": None,
            "next_due_meter_value": None,
        }
        meter = {"meter_type": "runtime_hours", "current_value": "0", "unit": "hrs"}
        asset = {
            "meter_proposed_type": "runtime_hours",
            "meter_activated_at": "2026-08-29T12:00:00+00:00",
        }

        with mock.patch.object(self.api.ms.pm_db, "execute_one_json", return_value=task), \
             mock.patch.object(self.api.ms, "fetch_meter_row", return_value=meter), \
             mock.patch.object(self.api.ms, "fetch_asset_proposed_meter", return_value=asset):
            with self.assertRaisesRegex(ValueError, "required for tasks linked"):
                self.api.ms.complete_task_meter(
                    "task",
                    completed_at=datetime.now(timezone.utc),
                    note=None,
                    meter_value_at_completion=None,
                )
    def test_proposed_meter_requires_activation_before_completion(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "schedule_kind": "calendar",
            "meter_interval_value": None,
            "next_due_meter_value": None,
        }
        meter = {"meter_type": "none", "current_value": "0", "unit": ""}
        asset = {"meter_proposed_type": "runtime_hours", "meter_activated_at": None}

        with mock.patch.object(self.api.ms.pm_db, "execute_one_json", return_value=task), \
             mock.patch.object(self.api.ms, "fetch_meter_row", return_value=meter), \
             mock.patch.object(self.api.ms, "fetch_asset_proposed_meter", return_value=asset):
            with self.assertRaisesRegex(ValueError, "activate the proposed"):
                self.api.ms.complete_task_meter(
                    "task",
                    completed_at=datetime.now(timezone.utc),
                    note=None,
                    meter_value_at_completion=None,
                )
    def test_meter_reading_and_completion_use_one_atomic_database_statement(self):
        completed_at = datetime.now(timezone.utc)
        meter_result = {
            "asset_id": "asset",
            "meter_reading_id": "reading",
            "meter_value_decimal": Decimal("0"),
            "next_due_meter_value": None,
        }

        with mock.patch.object(
            self.api.ms.pm_db,
            "execute_top_level_one_json",
            return_value={"id": "task", "meter_epoch": 1},
        ) as execute, mock.patch.object(
            self.api.ms, "recalc_usage_for_epoch"
        ) as recalc:
            applied = self.api.ms.apply_task_completion_transaction(
                task_id="task",
                completion_id="completion",
                completed_at=completed_at,
                next_due=completed_at,
                note="done",
                meter_result=meter_result,
                operator_identity="operator",
                integration_identity=None,
            )

        self.assertTrue(applied)
        sql = execute.call_args.args[0]
        self.assertIn("WITH locked_task AS", sql)
        self.assertIn("inserted_reading AS", sql)
        self.assertIn("inserted_completion AS", sql)
        self.assertIn("updated_task AS", sql)
        self.assertEqual(execute.call_count, 1)
        recalc.assert_called_once_with("asset", 1)

    def test_atomic_json_helper_uses_tcp_connection_when_configured(self):
        cursor = mock.MagicMock()
        cursor.__enter__.return_value = cursor
        cursor.fetchone.return_value = ({"id": "task"},)
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.cursor.return_value = cursor

        with mock.patch.object(self.api.pm_db, "use_docker", return_value=False), \
             mock.patch.object(self.api.pm_db, "connect", return_value=connection), \
             mock.patch.object(self.api.pm_db, "_docker_psql") as docker_psql:
            result = self.api.pm_db.execute_top_level_one_json(
                "SELECT row_to_json(q) FROM (SELECT %s AS id) q",
                ("task",),
            )

        self.assertEqual(result, {"id": "task"})
        cursor.execute.assert_called_once_with(
            "SELECT row_to_json(q) FROM (SELECT %s AS id) q",
            ("task",),
        )
        connection.commit.assert_called_once()
        docker_psql.assert_not_called()

    def test_regular_reading_and_completion_share_the_meter_row_lock(self):
        with mock.patch.object(
            self.api.ms.pm_db,
            "execute_top_level_one_json",
            return_value={"id": "reading", "current_value": "1"},
        ) as execute, mock.patch.object(
            self.api.ms, "recalc_usage_for_epoch"
        ) as recalc, mock.patch.object(
            self.api.ms, "fetch_meter_row", return_value={"current_value": "1"}
        ), mock.patch.object(
            self.api.ms, "recalc_tasks_for_asset"
        ):
            result = self.api.ms.insert_accepted_reading(
                "asset",
                value=Decimal("1"),
                reading_at=datetime.now(timezone.utc),
                entry_method="manual",
                note=None,
                correction_reason=None,
                meter_type="runtime_hours",
                unit="hrs",
                meter_epoch=1,
                operator_identity="operator",
                integration_identity=None,
                idempotency_key="retry-key",
            )

        self.assertEqual(result["reading_id"], "reading")
        sql = execute.call_args.args[0]
        self.assertIn("WITH locked_meter AS", sql)
        self.assertIn("FOR UPDATE", sql)
        self.assertIn("inserted_reading AS", sql)
        self.assertIn("updated_meter AS", sql)
        self.assertIn("reading.reading_at >= m.latest_reading_at", sql)
        self.assertEqual(execute.call_count, 1)
        recalc.assert_called_once_with("asset", 1)

    def test_completion_route_does_not_split_meter_and_task_writes(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "frequency": "Monthly",
            "warning_days": 7,
            "schedule_kind": "calendar",
            "kind": "Scheduled",
            "intake_state": None,
        }
        updated = {"id": "task", "area": "Barn", "item": "Inspect"}
        meter_result = {
            "asset_id": "asset",
            "meter_reading_id": "reading",
            "meter_value_decimal": Decimal("0"),
            "next_due_meter_value": None,
            "applied_meter": True,
        }

        with mock.patch.object(
            self.api.pm_db, "execute_one_json", side_effect=[task, updated]
        ), mock.patch.object(
            self.api.ms, "complete_task_meter", return_value=meter_result
        ), mock.patch.object(
            self.api.ms, "apply_task_completion_transaction", return_value=True
        ) as atomic, mock.patch.object(
            self.api.pm_db, "execute_script"
        ) as split_write, mock.patch.object(
            self.api, "enrich_tasks", side_effect=lambda rows: rows
        ):
            response = self.client.post(
                "/tasks/task/complete",
                json={"meter_value_at_completion": 0},
                headers={"Authorization": f"Bearer {API_KEY}"},
            )

        self.assertEqual(response.status_code, 200)
        atomic.assert_called_once()
        self.assertEqual(
            atomic.call_args.kwargs["next_due"].month,
            (datetime.now(timezone.utc).month % 12) + 1,
        )
        split_write.assert_not_called()

    def test_calendar_next_due_uses_frequency_not_warning_window(self):
        completed_at = datetime(2026, 1, 31, 12, tzinfo=timezone.utc)

        self.assertEqual(
            self.api.next_calendar_due(completed_at, frequency="Monthly", warning_days=30),
            datetime(2026, 2, 28, 12, tzinfo=timezone.utc),
        )
        self.assertEqual(
            self.api.next_calendar_due(completed_at, frequency="Every 2 Weeks", warning_days=30),
            datetime(2026, 2, 14, 12, tzinfo=timezone.utc),
        )
        self.assertEqual(
            self.api.next_calendar_due(completed_at, frequency="Yearly", warning_days=30),
            datetime(2027, 1, 31, 12, tzinfo=timezone.utc),
        )
        self.assertEqual(
            self.api.next_calendar_due(completed_at, frequency="Every 2 Years", warning_days=30),
            datetime(2028, 1, 31, 12, tzinfo=timezone.utc),
        )
        self.assertEqual(
            self.api.next_calendar_due(completed_at, frequency="Every 3-4 Months", warning_days=30),
            datetime(2026, 4, 30, 12, tzinfo=timezone.utc),
        )

    def test_completion_route_rejects_non_boolean_meter_confirmation(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "warning_days": 7,
            "schedule_kind": "calendar",
            "kind": "Scheduled",
            "intake_state": None,
        }

        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=task), \
             mock.patch.object(self.api.ms, "complete_task_meter") as complete_meter:
            response = self.client.post(
                "/tasks/task/complete",
                json={"confirm_current_meter": "false"},
                headers={"Authorization": f"Bearer {API_KEY}"},
            )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["field"], "confirm_current_meter")
        complete_meter.assert_not_called()

    def test_completion_route_rejects_negative_and_nonfinite_meter_values(self):
        task = {
            "id": "task",
            "asset_id": "asset",
            "warning_days": 7,
            "schedule_kind": "calendar",
            "kind": "Scheduled",
            "intake_state": None,
        }

        for invalid in (-1, "NaN", "Infinity"):
            with self.subTest(invalid=invalid), mock.patch.object(
                self.api.pm_db, "execute_one_json", return_value=task
            ), mock.patch.object(self.api.ms, "complete_task_meter") as complete_meter:
                response = self.client.post(
                    "/tasks/task/complete",
                    json={"meter_value_at_completion": invalid},
                    headers={"Authorization": f"Bearer {API_KEY}"},
                )
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.get_json()["field"], "meter_value_at_completion")
                complete_meter.assert_not_called()

    def test_task_list_enrichment_reads_all_meters_in_one_query(self):
        tasks = [
            {"id": f"task-{index}", "asset_id": asset, "completion_history": [], "tools_required": []}
            for index, asset in enumerate(["asset-a", "asset-b", "asset-a", None])
        ]
        with mock.patch.object(
            self.api.pm_db,
            "execute_json",
            side_effect=[[], [], [{"asset_id": "asset-a", "current_value": "12"}]],
        ) as execute_json, mock.patch.object(self.api.ms, "fetch_meter_row") as per_asset:
            enriched = self.api.enrich_tasks(tasks)

        self.assertEqual(execute_json.call_count, 3)
        self.assertEqual(execute_json.call_args_list[2].args[1], ["asset-a", "asset-b"])
        per_asset.assert_not_called()
        self.assertEqual(len(enriched), 4)


if __name__ == "__main__":
    unittest.main()
