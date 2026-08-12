#!/usr/bin/env python3
"""One-time normalize of maintenance_tasks.item / area titles.

Canonical form: `Asset Name: Task Name` (group = linked asset name else area).
Does not mass-rewrite other fields.

Usage (on Mini, with db.env loaded / PROPERTYMANAGER_DB_VIA_DOCKER=1):

  python3 normalize_task_titles.py --dry-run
  python3 normalize_task_titles.py --apply
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

API_DIR = Path(__file__).resolve().parents[1] / "api"
sys.path.insert(0, str(API_DIR))

# Prefer operator env file without printing secrets.
_ENV = Path(os.path.expanduser("~/.config/openclaw/db.env"))
if _ENV.is_file():
    for line in _ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)

import db as pm_db  # noqa: E402
import task_title as tt  # noqa: E402


def classify_reason(*, area: str, item: str, group: str, new_item: str, new_area: str) -> list[str]:
    reasons: list[str] = []
    prefix = f"{group}:"
    lower_item = item.lower()
    if not lower_item.startswith(prefix.lower()):
        reasons.append("missing_prefix")
    rem = item
    if rem.lower().startswith(prefix.lower()):
        rem = rem[len(prefix) :].lstrip(" \t:-")
        if rem.lower().startswith(prefix.lower()):
            reasons.append("duplicated_prefix")
    if area != new_area:
        reasons.append("area_realign")
    if item != new_item and not reasons:
        reasons.append("title_canonicalize")
    return reasons or ["title_canonicalize"]


def collect_changes() -> tuple[list[dict], int]:
    rows = pm_db.execute_json(
        """
        SELECT
            t.id,
            t.area,
            t.item,
            t.asset_id,
            a.name AS asset_name
        FROM propertymanager.maintenance_tasks t
        LEFT JOIN propertymanager.assets a
            ON a.id = t.asset_id AND a.is_active = true
        WHERE t.is_active = true
        ORDER BY t.area, t.item
        """
    )
    asset_names = {
        str(r["asset_id"]): str(r["asset_name"]).strip()
        for r in rows
        if r.get("asset_id") and r.get("asset_name")
    }

    def fetch_name(aid: str) -> str | None:
        return asset_names.get(str(aid))

    changes: list[dict] = []
    for row in rows:
        area = str(row.get("area") or "")
        item = str(row.get("item") or "")
        asset_id = row.get("asset_id")
        new_area, new_item = tt.normalize_task_area_and_item(
            area=area,
            item=item,
            asset_id=asset_id,
            fetch_asset_name=fetch_name,
        )
        if new_area == area and new_item == item:
            continue
        group = new_area
        changes.append(
            {
                "id": str(row["id"]),
                "old_area": area,
                "old_item": item,
                "new_area": new_area,
                "new_item": new_item,
                "asset_id": str(asset_id) if asset_id else None,
                "reasons": classify_reason(
                    area=area,
                    item=item,
                    group=group,
                    new_item=new_item,
                    new_area=new_area,
                ),
            }
        )
    return changes, len(rows)


def apply_changes(changes: list[dict]) -> int:
    applied = 0
    for change in changes:
        pm_db.execute(
            """
            UPDATE propertymanager.maintenance_tasks
            SET area = %s,
                item = %s,
                updated_at = now()
            WHERE id = %s AND is_active = true
            """,
            (change["new_area"], change["new_item"], change["id"]),
        )
        applied += 1
    return applied


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="List proposed changes only")
    mode.add_argument("--apply", action="store_true", help="Write area/item normalizations")
    parser.add_argument("--sample", type=int, default=20, help="Sample rows to print")
    args = parser.parse_args()

    changes, total = collect_changes()
    missing = sum(1 for c in changes if "missing_prefix" in c["reasons"])
    dupes = sum(1 for c in changes if "duplicated_prefix" in c["reasons"])
    realign = sum(1 for c in changes if "area_realign" in c["reasons"])

    print(f"active_tasks={total}")
    print(f"needs_change={len(changes)}")
    print(f"missing_prefix={missing}")
    print(f"duplicated_prefix={dupes}")
    print(f"area_realign={realign}")
    print("--- samples ---")
    for change in changes[: max(0, args.sample)]:
        print(
            f"{change['id'][:8]}… | {change['reasons']} | "
            f"area {change['old_area']!r} -> {change['new_area']!r} | "
            f"item {change['old_item']!r} -> {change['new_item']!r}"
        )

    if args.dry_run:
        print("mode=dry-run (no writes)")
        return 0

    applied = apply_changes(changes)
    print(f"mode=apply applied={applied}")

    after, total_after = collect_changes()
    print(f"after_active_tasks={total_after}")
    print(f"after_needs_change={len(after)}")
    if after:
        print("--- remaining samples ---")
        for change in after[:10]:
            print(
                f"{change['id'][:8]}… | {change['reasons']} | "
                f"{change['old_item']!r} -> {change['new_item']!r}"
            )
    return 0 if not after else 1


if __name__ == "__main__":
    raise SystemExit(main())
