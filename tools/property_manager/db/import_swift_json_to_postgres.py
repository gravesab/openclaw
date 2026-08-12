#!/usr/bin/env python3
"""One-time import of PropertyManagerApp Mac JSON into Postgres via docker exec psql.

Usage:
  python3 tools/property_manager/db/import_swift_json_to_postgres.py \\
    --tasks /path/to/maintenance_tasks.json \\
    --categories /path/to/maintenance_categories.json \\
    --attachments /path/to/attachments \\
    --dry-run | --apply
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ATTACHMENTS_ROOT = Path(
    os.environ.get(
        "PROPERTYMANAGER_ATTACHMENTS_ROOT",
        "/mnt/ai-storage/openclaw-documents/Property/attachments",
    )
)
PSQL = [
    "docker",
    "exec",
    "-i",
    "postgres",
    "psql",
    "-U",
    "openclaw",
    "-d",
    "openclaw",
    "-v",
    "ON_ERROR_STOP=1",
]


def q(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value).replace("'", "''")
    return f"'{text}'"


def q_json(value: Any) -> str:
    return q(json.dumps(value)) + "::jsonb"


def parse_ts(value: Any) -> str:
    if isinstance(value, datetime):
        dt = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    else:
        text = str(value).replace("Z", "+00:00")
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def migrate_parts(task: dict[str, Any]) -> list[dict[str, Any]]:
    parts = task.get("parts") or []
    if parts:
        return parts
    numbers = task.get("partNumbers") or []
    urls = task.get("referenceURLs") or []
    count = max(len(numbers), len(urls))
    out = []
    for i in range(count):
        out.append(
            {
                "id": str(uuid.uuid4()),
                "name": f"Part {i + 1}",
                "oemPartNumber": "",
                "partNumber": numbers[i] if i < len(numbers) else "",
                "buyURL": urls[i] if i < len(urls) else "",
                "cost": 0,
            }
        )
    return out


def report(tasks: list[dict], categories: list[dict], attachments: Path | None) -> dict[str, int]:
    photo_files = 0
    if attachments and attachments.exists():
        photo_files = sum(1 for p in attachments.rglob("*") if p.is_file())
    return {
        "categories": len(categories),
        "tasks": len(tasks),
        "parts": sum(len(migrate_parts(t)) for t in tasks),
        "photo_file_names_in_json": sum(len(t.get("photoFileNames") or []) for t in tasks),
        "attachment_files_on_disk": photo_files,
        "work_requests": sum(1 for t in tasks if (t.get("kind") or "") == "Work Request"),
    }


def category_sql(cat: dict[str, Any]) -> str:
    return f"""
INSERT INTO propertymanager.maintenance_categories
(id, name, icon, color_name, is_built_in, sort_order, updated_at)
VALUES (
  {q(cat.get("id") or str(uuid.uuid4()))},
  {q(cat["name"])},
  {q(cat.get("icon") or "folder.fill")},
  {q(cat.get("colorName") or cat.get("color_name") or "gray")},
  {q(bool(cat.get("isBuiltIn", cat.get("is_built_in", False))))},
  {int(cat.get("sort_order") or 100)},
  now()
)
ON CONFLICT (name) DO UPDATE SET
  icon = EXCLUDED.icon,
  color_name = EXCLUDED.color_name,
  is_built_in = EXCLUDED.is_built_in,
  updated_at = now();
"""


def task_sql(task: dict[str, Any]) -> tuple[str, str, list[str]]:
    task_id = str(task.get("id") or uuid.uuid4())
    area = (task.get("area") or task.get("category") or "House").strip()
    item = (task.get("item") or "").strip()
    category = (task.get("category") or area).strip()
    kind = task.get("kind") or "Scheduled"
    if kind not in ("Scheduled", "Work Request"):
        kind = "Scheduled"
    tools = task.get("toolsRequired") or task.get("tools_required") or []
    history = task.get("completionHistory") or task.get("completion_history") or []

    sql = f"""
DELETE FROM propertymanager.maintenance_tasks
WHERE area = {q(area)} AND item = {q(item)} AND id <> {q(task_id)};

INSERT INTO propertymanager.maintenance_tasks (
  id, area, item, category_name, kind, priority, frequency,
  task_description, response_instructions, supplies_needed,
  notes, result_notes, estimated_minutes, warning_days, critical_days,
  last_done, next_due, send_telegram_update, include_in_daily_briefing,
  alert_if_overdue, is_active, manufacturer, source_manual_name,
  completion_history, tools_required, updated_at
) VALUES (
  {q(task_id)}, {q(area)}, {q(item)}, {q(category)}, {q(kind)},
  {q(task.get("priority") or "Medium")}, {q(task.get("frequency") or "Monthly")},
  {q(task.get("taskDescription") or "")}, {q(task.get("responseInstructions") or "")},
  {q(task.get("suppliesNeeded") or "")}, {q(task.get("notes") or "")},
  {q(task.get("resultNotes") or "")}, {int(task.get("estimatedMinutes") or 30)},
  {int(task.get("warningDays") or 30)}, {int(task.get("criticalDays") or 45)},
  {q(parse_ts(task.get("lastDone")))}::timestamptz,
  {q(parse_ts(task.get("nextDue")))}::timestamptz,
  {q(bool(task.get("sendTelegramUpdate", True)))},
  {q(bool(task.get("includeInDailyBriefing", True)))},
  {q(bool(task.get("alertIfOverdue", True)))},
  {q(bool(task.get("isActive", True)))},
  {q(task.get("manufacturer") or "")}, {q(task.get("sourceManualName") or "")},
  {q_json(history)}, {q_json(tools)}, now()
)
ON CONFLICT (id) DO UPDATE SET
  area = EXCLUDED.area,
  item = EXCLUDED.item,
  category_name = EXCLUDED.category_name,
  kind = EXCLUDED.kind,
  priority = EXCLUDED.priority,
  frequency = EXCLUDED.frequency,
  task_description = EXCLUDED.task_description,
  response_instructions = EXCLUDED.response_instructions,
  supplies_needed = EXCLUDED.supplies_needed,
  notes = EXCLUDED.notes,
  result_notes = EXCLUDED.result_notes,
  estimated_minutes = EXCLUDED.estimated_minutes,
  warning_days = EXCLUDED.warning_days,
  critical_days = EXCLUDED.critical_days,
  last_done = EXCLUDED.last_done,
  next_due = EXCLUDED.next_due,
  send_telegram_update = EXCLUDED.send_telegram_update,
  include_in_daily_briefing = EXCLUDED.include_in_daily_briefing,
  alert_if_overdue = EXCLUDED.alert_if_overdue,
  is_active = EXCLUDED.is_active,
  manufacturer = EXCLUDED.manufacturer,
  source_manual_name = EXCLUDED.source_manual_name,
  completion_history = EXCLUDED.completion_history,
  tools_required = EXCLUDED.tools_required,
  updated_at = now();

DELETE FROM propertymanager.maintenance_task_parts WHERE task_id = {q(task_id)};
"""
    part_sqls = []
    for index, part in enumerate(migrate_parts(task)):
        part_sqls.append(
            f"""
INSERT INTO propertymanager.maintenance_task_parts
(id, task_id, name, oem_part_number, part_number, buy_url, cost, sort_order, updated_at)
VALUES (
  {q(part.get("id") or str(uuid.uuid4()))}, {q(task_id)},
  {q(part.get("name") or "")},
  {q(part.get("oemPartNumber") or part.get("oem_part_number") or "")},
  {q(part.get("partNumber") or part.get("part_number") or "")},
  {q(part.get("buyURL") or part.get("buy_url") or "")},
  {float(part.get("cost") or 0)}, {index}, now()
);
"""
        )
    return task_id, sql + "".join(part_sqls), list(task.get("photoFileNames") or [])


def copy_photos(task_id: str, names: list[str], attachments: Path | None) -> list[str]:
    if not names or not attachments:
        return []
    dest_dir = ATTACHMENTS_ROOT / task_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    sqls = []
    for name in names:
        src = attachments / task_id / name
        if not src.exists():
            matches = list(attachments.rglob(name))
            if not matches:
                continue
            src = matches[0]
        dest = dest_dir / name
        shutil.copy2(src, dest)
        sqls.append(
            f"""
INSERT INTO propertymanager.maintenance_task_photos
(id, task_id, file_name, storage_path)
VALUES ({q(str(uuid.uuid4()))}, {q(task_id)}, {q(name)}, {q(str(dest))});
"""
        )
    return sqls


def run_psql(sql: str) -> None:
    subprocess.run(PSQL, input=sql, text=True, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--categories", type=Path, default=None)
    parser.add_argument("--attachments", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not args.dry_run and not args.apply:
        raise SystemExit("Specify --dry-run or --apply")

    tasks = load_json(args.tasks)
    categories = []
    if args.categories and args.categories.exists():
        categories = load_json(args.categories)

    summary = report(tasks, categories, args.attachments)
    print("IMPORT REPORT")
    for key, value in summary.items():
        print(f"  {key}: {value}")
    if args.dry_run:
        print("Dry-run only; no database writes.")
        return

    ATTACHMENTS_ROOT.mkdir(parents=True, exist_ok=True)
    chunks = ["BEGIN;"]
    for cat in categories:
        chunks.append(category_sql(cat))
    photo_count = 0
    for task in tasks:
        task_id, sql, photo_names = task_sql(task)
        chunks.append(sql)
        photo_sqls = copy_photos(task_id, photo_names, args.attachments)
        chunks.extend(photo_sqls)
        photo_count += len(photo_sqls)
    chunks.append("COMMIT;")
    run_psql("\n".join(chunks))
    print(f"Applied. photos_copied={photo_count}")
    print(f"Attachments root: {ATTACHMENTS_ROOT}")


if __name__ == "__main__":
    main()
