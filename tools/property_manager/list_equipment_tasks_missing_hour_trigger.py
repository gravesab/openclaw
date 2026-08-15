#!/usr/bin/env python3
"""List Equipment-linked tasks missing a run-hours trigger (next_due_meter_value)."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

DEFAULT_BASE = os.environ.get("PROPERTYMANAGER_API_BASE", "http://127.0.0.1:5062")


def get_json(url: str, api_key: str | None = None):
    req = urllib.request.Request(url)
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
        req.add_header("X-API-Key", api_key)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--api-key", default=os.environ.get("PROPERTYMANAGER_API_KEY", ""))
    args = parser.parse_args()

    tasks = get_json(f"{args.base.rstrip('/')}/tasks", args.api_key or None)
    assets = get_json(f"{args.base.rstrip('/')}/v1/assets", args.api_key or None)
    equipment_ids = {
        str(a["id"])
        for a in assets
        if str(a.get("category") or "").strip().lower() == "equipment"
    }

    missing = []
    for t in tasks:
        asset_id = t.get("asset_id")
        if not asset_id or str(asset_id) not in equipment_ids:
            continue
        trigger = t.get("next_due_meter_value")
        if trigger is None or trigger == "":
            missing.append(t)

    print(f"equipment_tasks_missing_run_hours_trigger={len(missing)}")
    for t in missing:
        print(
            f"{t.get('id')}\t{t.get('item')}\tasset={t.get('asset_id')}\t"
            f"interval={t.get('meter_interval_value')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
