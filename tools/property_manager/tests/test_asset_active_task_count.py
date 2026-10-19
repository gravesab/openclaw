#!/usr/bin/env python3
"""Live pm_summary.active_task_count on asset enrich and list."""

from __future__ import annotations

import importlib
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
if str(API_DIR) not in sys.path:
    sys.path.insert(0, str(API_DIR))

assets_api = importlib.import_module("assets_api")


class ActiveTaskCountTests(unittest.TestCase):
    def test_enrich_counts_loaded_tasks_for_real_assets(self) -> None:
        row = {
            "id": "mower",
            "host_asset_id": None,
            "is_pseudo": False,
            "placed_in_service_date": None,
            "current_value": None,
            "meter_type": "none",
            "unit": "",
            "latest_reading_at": None,
            "meter_epoch": 1,
            "row_version": 1,
            "updated_at": None,
            "meter_activated_at": None,
            "meter_proposed_type": None,
            "meter_proposed_unit": None,
        }
        tasks = [
            {
                "id": "t1",
                "item": "Oil",
                "schedule_kind": "calendar",
                "meter_interval_value": None,
                "meter_interval_unit": None,
                "last_done_meter_value": None,
                "next_due_meter_value": None,
                "next_due": None,
                "warning_days": None,
            },
            {
                "id": "t2",
                "item": "Blades",
                "schedule_kind": "calendar",
                "meter_interval_value": None,
                "meter_interval_unit": None,
                "last_done_meter_value": None,
                "next_due_meter_value": None,
                "next_due": None,
                "warning_days": None,
            },
        ]
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=tasks), mock.patch.object(
            assets_api,
            "fetch_host_ref",
            return_value=None,
        ), mock.patch.object(
            assets_api,
            "fetch_attachments",
            return_value=[],
        ):
            enriched = assets_api.enrich_asset(row)
        self.assertEqual(enriched["pm_summary"]["active_task_count"], 2)
        self.assertEqual(len(enriched["tasks"]), 2)

    def test_enrich_prefers_prefetched_count(self) -> None:
        row = {
            "id": "barn",
            "host_asset_id": None,
            "is_pseudo": False,
            "placed_in_service_date": None,
            "current_value": None,
            "meter_type": "none",
            "unit": "",
            "latest_reading_at": None,
            "meter_epoch": 1,
            "row_version": 1,
            "updated_at": None,
            "meter_activated_at": None,
            "meter_proposed_type": None,
            "meter_proposed_unit": None,
        }
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=[]), mock.patch.object(
            assets_api,
            "fetch_host_ref",
            return_value=None,
        ), mock.patch.object(
            assets_api,
            "fetch_attachments",
            return_value=[],
        ):
            enriched = assets_api.enrich_asset(row, active_task_count=5)
        self.assertEqual(enriched["pm_summary"]["active_task_count"], 5)

    def test_pseudo_enrich_ignores_prefetched_count(self) -> None:
        row = {
            "id": "group",
            "host_asset_id": None,
            "is_pseudo": True,
            "placed_in_service_date": None,
            "current_value": None,
            "meter_type": "none",
            "unit": "",
            "latest_reading_at": None,
            "meter_epoch": 1,
            "row_version": 1,
            "updated_at": None,
            "meter_activated_at": None,
            "meter_proposed_type": None,
            "meter_proposed_unit": None,
        }
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=[]), mock.patch.object(
            assets_api,
            "fetch_host_ref",
            return_value=None,
        ), mock.patch.object(
            assets_api,
            "fetch_attachments",
            return_value=[],
        ):
            enriched = assets_api.enrich_asset(row, active_task_count=9)
        self.assertEqual(enriched["pm_summary"]["active_task_count"], 0)

    def test_fetch_active_task_counts_groups_by_asset(self) -> None:
        with mock.patch.object(
            assets_api.pm_db,
            "execute_json",
            return_value=[
                {"asset_id": "a1", "active_task_count": 3},
                {"asset_id": "a2", "active_task_count": 1},
            ],
        ) as execute:
            counts = assets_api.fetch_active_task_counts(["a1", "a2"])
        self.assertEqual(counts, {"a1": 3, "a2": 1})
        execute.assert_called_once()
        query, params = execute.call_args.args[0], execute.call_args.args[1]
        self.assertIn("GROUP BY asset_id", query)
        self.assertIn("IN (%s, %s)", query)
        self.assertEqual(params, ("a1", "a2"))

    def test_fetch_active_task_counts_empty_ids_skips_query(self) -> None:
        with mock.patch.object(assets_api.pm_db, "execute_json") as execute:
            self.assertEqual(assets_api.fetch_active_task_counts([]), {})
        execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
