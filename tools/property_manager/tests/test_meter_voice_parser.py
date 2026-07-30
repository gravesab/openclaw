"""Focused tests for PropertyManager voice meter-value extraction."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

from assets_api import _extract_spoken_meter_value  # noqa: E402


class MeterVoiceParserTests(unittest.TestCase):
    def test_prefers_value_with_unit_over_digits_in_asset_name(self):
        value, meter_type = _extract_spoken_meter_value(
            "Development Reliability Mower 8c3d73cba8 now has 127.4 hours",
            ["Development Reliability Mower 8c3d73cba8"],
        )
        self.assertEqual(value, "127.4")
        self.assertEqual(meter_type, "runtime_hours")

    def test_removes_numeric_model_name_when_unit_is_omitted(self):
        value, meter_type = _extract_spoken_meter_value(
            "John Deere 1025R is now at 65.2",
            ["John Deere 1025R", "1025R"],
        )
        self.assertEqual(value, "65.2")
        self.assertIsNone(meter_type)

    def test_accepts_comma_separated_mileage(self):
        value, meter_type = _extract_spoken_meter_value(
            "Toyota 4Runner now has 10,000 miles",
            ["Toyota 4Runner", "4Runner"],
        )
        self.assertEqual(value, "10000")
        self.assertEqual(meter_type, "mileage")

    def test_uses_last_number_when_no_unit_or_asset_number_remains(self):
        value, meter_type = _extract_spoken_meter_value(
            "The mower reading changed from yesterday and is now 42.75",
            ["The mower"],
        )
        self.assertEqual(value, "42.75")
        self.assertIsNone(meter_type)


if __name__ == "__main__":
    unittest.main()
