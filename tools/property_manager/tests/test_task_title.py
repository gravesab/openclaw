"""Unit tests for task title canonicalization (no DB)."""

from __future__ import annotations

import sys
from pathlib import Path

API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

import task_title as tt  # noqa: E402


def test_strip_leading_group_prefix_collapses_repeats():
    assert tt.strip_leading_group_prefix("Pool: Clean filter", "Pool") == "Clean filter"
    assert tt.strip_leading_group_prefix("Pool: Pool: Clean filter", "Pool") == "Clean filter"
    assert tt.strip_leading_group_prefix("pool: clean filter", "Pool") == "clean filter"
    assert tt.strip_leading_group_prefix("Clean filter", "Pool") == "Clean filter"


def test_canonical_task_item_no_double_prefix():
    assert tt.canonical_task_item(group="Pool", item="Clean filter") == "Pool: Clean filter"
    assert tt.canonical_task_item(group="Pool", item="Pool: Clean filter") == "Pool: Clean filter"
    assert tt.canonical_task_item(group="Pool", item="Pool: Pool: Clean filter") == "Pool: Clean filter"


def test_resolve_group_prefers_asset_name():
    def fetch(_aid: str) -> str | None:
        return "Spa Pump"

    assert (
        tt.resolve_task_group_name(area="Spa", asset_id="abc", fetch_asset_name=fetch) == "Spa Pump"
    )
    assert tt.resolve_task_group_name(area="Pool", asset_id=None, fetch_asset_name=fetch) == "Pool"


def test_normalize_aligns_area_to_group():
    def fetch(_aid: str) -> str | None:
        return "Zero Turn"

    area, item = tt.normalize_task_area_and_item(
        area="Equipment",
        item="Oil change",
        asset_id="x",
        fetch_asset_name=fetch,
    )
    assert area == "Zero Turn"
    assert item == "Zero Turn: Oil change"
