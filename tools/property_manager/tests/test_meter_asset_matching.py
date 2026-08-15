#!/usr/bin/env python3
"""Unit tests for deterministic Property Manager meter-text asset matching."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

from assets_api import _select_meter_asset  # noqa: E402


class MeterAssetMatchingTests(unittest.TestCase):
    def test_longest_substring_beats_generic_alias_regardless_of_row_order(self):
        generic = {
            "id": "generic",
            "name": "Toro 22in Kohler High Wheel Mower",
            "aliases": ["mower"],
        }
        specific = {
            "id": "specific",
            "name": "Phase2 Proposed Mower",
            "aliases": [],
        }

        for assets in ([generic, specific], [specific, generic]):
            selected, confidence = _select_meter_asset("Phase2 Proposed Mower 42.5 hours", assets)
            self.assertIs(selected, specific)
            self.assertEqual(confidence, 1.0)


if __name__ == "__main__":
    unittest.main()
