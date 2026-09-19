#!/usr/bin/env python3
"""Unit tests for the asset placed-in-service civil-date contract."""

from __future__ import annotations

import importlib
import sys
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
if str(API_DIR) not in sys.path:
    sys.path.insert(0, str(API_DIR))

assets_api = importlib.import_module("assets_api")


class PlacedInServiceDateTests(unittest.TestCase):
    def test_accepts_iso_civil_date_and_null(self) -> None:
        self.assertEqual(assets_api.parse_placed_in_service_date("2026-09-19"), date(2026, 9, 19))
        self.assertIsNone(assets_api.parse_placed_in_service_date(None))

    def test_rejects_timestamps_and_invalid_dates(self) -> None:
        for value in ("20260919", "2026-09-19T00:00:00Z", "2026-02-30", 20260919):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    assets_api.parse_placed_in_service_date(value)

    def test_enrichment_serializes_a_civil_date_as_iso(self) -> None:
        row = {
            "id": "asset-1",
            "placed_in_service_date": date(2024, 1, 15),
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
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=[]):
            enriched = assets_api.enrich_asset(row)
        self.assertEqual(enriched["placed_in_service_date"], "2024-01-15")


if __name__ == "__main__":
    unittest.main()
