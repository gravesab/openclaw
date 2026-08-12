#!/usr/bin/env python3
"""Unit tests for case- and whitespace-insensitive asset-name uniqueness."""

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


class AssetNameUniquenessTests(unittest.TestCase):
    def test_conflict_lookup_is_case_and_whitespace_insensitive(self) -> None:
        with mock.patch.object(assets_api.pm_db, "execute_one_json", return_value={"id": "existing"}) as lookup:
            self.assertTrue(assets_api.asset_name_conflicts("  Barn Pump  "))

        sql, params = lookup.call_args.args
        self.assertIn("lower(btrim(name)) = lower(btrim(%s))", sql)
        self.assertEqual(params, ["Barn Pump"])

    def test_rename_excludes_the_asset_being_renamed(self) -> None:
        with mock.patch.object(assets_api.pm_db, "execute_one_json", return_value=None) as lookup:
            self.assertFalse(
                assets_api.asset_name_conflicts("Barn Pump", excluding_asset_id="asset-123")
            )

        sql, params = lookup.call_args.args
        self.assertIn("id <> %s", sql)
        self.assertEqual(params, ["Barn Pump", "asset-123"])


if __name__ == "__main__":
    unittest.main()
