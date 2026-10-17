#!/usr/bin/env python3
"""Unit tests for pseudo asset groups (is_pseudo)."""

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


class ParseIsPseudoTests(unittest.TestCase):
    def test_accepts_boolish_values(self) -> None:
        self.assertFalse(assets_api.parse_is_pseudo(None))
        self.assertFalse(assets_api.parse_is_pseudo(False))
        self.assertTrue(assets_api.parse_is_pseudo(True))
        self.assertTrue(assets_api.parse_is_pseudo("true"))
        self.assertFalse(assets_api.parse_is_pseudo("false"))

    def test_rejects_invalid_values(self) -> None:
        for value in ("maybe", [], {}):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    assets_api.parse_is_pseudo(value)


class RejectPseudoAssetTests(unittest.TestCase):
    def test_rejects_when_row_is_pseudo(self) -> None:
        with mock.patch.object(
            assets_api.pm_db,
            "execute_one_json",
            return_value={"is_pseudo": True},
        ):
            response = assets_api.reject_if_pseudo_asset("asset-1")
        self.assertIsNotNone(response)

    def test_allows_real_assets(self) -> None:
        with mock.patch.object(
            assets_api.pm_db,
            "execute_one_json",
            return_value={"is_pseudo": False},
        ):
            self.assertIsNone(assets_api.reject_if_pseudo_asset("asset-1"))


class EnrichPseudoTests(unittest.TestCase):
    def test_enrichment_exposes_is_pseudo(self) -> None:
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
            return_value=[{"id": "mower", "name": "Toro"}],
        ):
            enriched = assets_api.enrich_asset(row)
        self.assertTrue(enriched["is_pseudo"])
        self.assertEqual(enriched["attachments"][0]["name"], "Toro")


if __name__ == "__main__":
    unittest.main()
