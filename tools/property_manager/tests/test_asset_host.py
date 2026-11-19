#!/usr/bin/env python3
"""Unit tests for asset host attachment (implements → host)."""

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


class ParseHostAssetIdTests(unittest.TestCase):
    def test_accepts_uuid_and_null(self) -> None:
        self.assertEqual(
            assets_api.parse_host_asset_id("11111111-1111-4111-8111-111111111111"),
            "11111111-1111-4111-8111-111111111111",
        )
        self.assertIsNone(assets_api.parse_host_asset_id(None))

    def test_rejects_invalid_values(self) -> None:
        for value in ("", "not-a-uuid", 123, []):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    assets_api.parse_host_asset_id(value)


class HostCycleTests(unittest.TestCase):
    def test_detects_direct_and_indirect_cycles(self) -> None:
        mapping = {
            "host": {"host_asset_id": "child"},
            "child": {"host_asset_id": None},
            "mid": {"host_asset_id": "root"},
            "root": {"host_asset_id": None},
        }

        def execute_one_json(query, params):
            return mapping.get(params[0])

        with mock.patch.object(assets_api.pm_db, "execute_one_json", side_effect=execute_one_json):
            self.assertTrue(assets_api.host_assignment_would_cycle("child", "host"))
            self.assertFalse(assets_api.host_assignment_would_cycle("child", "root"))
            self.assertTrue(assets_api.host_assignment_would_cycle("root", "mid"))


class EnrichHostTests(unittest.TestCase):
    def test_enrichment_adds_host_and_attachments(self) -> None:
        row = {
            "id": "implement",
            "host_asset_id": "tractor",
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
            return_value={"id": "tractor", "name": "John Deere 1025R"},
        ), mock.patch.object(
            assets_api,
            "fetch_attachments",
            return_value=[],
        ):
            enriched = assets_api.enrich_asset(row)
        self.assertEqual(enriched["host_asset_id"], "tractor")
        self.assertEqual(enriched["host"], {"id": "tractor", "name": "John Deere 1025R"})
        self.assertEqual(enriched["attachments"], [])

    def test_list_maps_build_reverse_attachments(self) -> None:
        rows = [
            {"id": "tractor", "name": "John Deere 1025R", "host_asset_id": None, "is_pseudo": False},
            {"id": "mowers", "name": "Mowers", "host_asset_id": None, "is_pseudo": True},
            {"id": "tiller", "name": "JD rototiller", "host_asset_id": "tractor", "is_pseudo": False},
            {"id": "blade", "name": "Box blade", "host_asset_id": "tractor", "is_pseudo": False},
            {"id": "toro", "name": "Toro", "host_asset_id": "mowers", "is_pseudo": False},
        ]
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=[]):
            host_by_id, attachments_by_host = assets_api._host_maps_for_rows(rows)
        self.assertEqual(host_by_id["tractor"]["name"], "John Deere 1025R")
        self.assertFalse(host_by_id["tractor"]["is_pseudo"])
        self.assertTrue(host_by_id["mowers"]["is_pseudo"])
        self.assertEqual(
            [item["name"] for item in attachments_by_host["tractor"]],
            ["Box blade", "JD rototiller"],
        )
        self.assertEqual(
            [item["name"] for item in attachments_by_host["mowers"]],
            ["Toro"],
        )


if __name__ == "__main__":
    unittest.main()
