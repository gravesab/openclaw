#!/usr/bin/env python3

from pathlib import Path
import csv
import json
import uuid
from datetime import datetime, timedelta, timezone

csv_path = Path.home() / "Development/PropertyManagerApp/imports/maintenance_log_from_intelmini.csv"
json_dir = Path.home() / "Library/Application Support/PropertyManagerApp"
json_path = json_dir / "maintenance_tasks.json"

if not csv_path.exists():
    raise SystemExit(f"ERROR: CSV file not found: {csv_path}")

rows = []

with csv_path.open(newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

if not rows:
    raise SystemExit("ERROR: CSV has no task rows.")

def category_from_area(area):
    lower = area.lower()

    if "pool" in lower:
        return "Pool"

    if "hot" in lower or "tub" in lower or "spa" in lower:
        return "Hot Tub"

    if "tractor" in lower or "mower" in lower or "pump" in lower or "equipment" in lower:
        return "Equipment"

    if "trail" in lower or "ground" in lower or "yard" in lower or "land" in lower:
        return "Grounds"

    if "safety" in lower or "fire" in lower or "smoke" in lower:
        return "Safety"

    return "House"

def frequency_from_warning_days(days):
    if days <= 1:
        return "Daily"

    if days <= 7:
        return "Weekly"

    if days <= 14:
        return "Every 2 Weeks"

    if days <= 45:
        return "Monthly"

    if days <= 120:
        return "Quarterly"

    return "Yearly"

def priority_from_dates(last_done, warning_days, critical_days):
    today = datetime.now(timezone.utc).date()
    warning_date = (last_done + timedelta(days=warning_days)).date()
    critical_date = (last_done + timedelta(days=critical_days)).date()

    if today >= critical_date:
        return "High"

    if today >= warning_date:
        return "Medium"

    return "Low"

def estimated_minutes(area, item):
    combined = f"{area} {item}".lower()

    if "water test" in combined:
        return 15

    if "filter" in combined:
        return 30

    if "drain" in combined:
        return 60

    if "oil" in combined:
        return 30

    if "grease" in combined:
        return 20

    if "inspection" in combined:
        return 30

    return 30

def default_response(area, item):
    combined = f"{area} {item}".lower()

    if "water test" in combined:
        return """1. Collect a water sample.

2. Test pH, sanitizer/chlorine, alkalinity, and other required levels.

3. Adjust chemicals only as needed.

4. Circulate water after adding chemicals.

5. Record readings and mark the task complete."""

    if "filter" in combined:
        return """1. Turn off equipment if needed.

2. Remove, rinse, clean, or backwash the filter.

3. Reinstall or reset equipment.

4. Check for normal water flow.

5. Record completion notes."""

    if "tractor" in combined:
        return """1. Park tractor safely on level ground.

2. Inspect the required item.

3. Add fluid, grease, adjust, or repair as needed.

4. Record any issue that needs follow-up.

5. Mark the task complete."""

    return """1. Inspect the area or equipment.

2. Complete the maintenance task.

3. Record any readings, supplies used, or issues found.

4. Add follow-up notes if needed.

5. Mark the task complete."""

def task_key(area, item):
    return f"{area.strip().lower()}|{item.strip().lower()}"

existing_tasks = []

if json_path.exists():
    try:
        existing_tasks = json.loads(json_path.read_text())
    except json.JSONDecodeError:
        backup_path = json_path.with_name(
            f"maintenance_tasks.unreadable.{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
        )
        backup_path.write_text(json_path.read_text())

existing_by_key = {
    task_key(task.get("area", ""), task.get("item", "")): task
    for task in existing_tasks
    if task.get("area") and task.get("item")
}

tasks = []
imported_keys = set()

for row in rows:
    area = row["area"].strip()
    item = row["item"].strip()
    warning_days = int(row["warning_days"])
    critical_days = int(row["critical_days"])

    y, m, d = map(int, row["last_done"].strip().split("-"))

    last_done = datetime(y, m, d, 12, 0, 0, tzinfo=timezone.utc)
    next_due = last_done + timedelta(days=warning_days)
    key = task_key(area, item)

    if key in existing_by_key:
        task = dict(existing_by_key[key])
        # Shared OpenClaw columns only — keep Mac-only rich fields.
        task.update({
            "area": area,
            "item": item,
            "warningDays": warning_days,
            "criticalDays": critical_days,
            "lastDone": last_done.isoformat().replace("+00:00", "Z"),
            "nextDue": next_due.isoformat().replace("+00:00", "Z"),
        })
    else:
        task = {
            "id": str(uuid.uuid4()).upper(),
            "area": area,
            "item": item,
            "category": category_from_area(area),
            "priority": priority_from_dates(last_done, warning_days, critical_days),
            "frequency": frequency_from_warning_days(warning_days),
            "taskDescription": f"{area}: {item}",
            "responseInstructions": default_response(area, item),
            "suppliesNeeded": "",
            "notes": f"Imported from OpenClaw. Warning days: {warning_days}. Critical days: {critical_days}.",
            "resultNotes": "",
            "completionHistory": [],
            "estimatedMinutes": estimated_minutes(area, item),
            "warningDays": warning_days,
            "criticalDays": critical_days,
            "lastDone": last_done.isoformat().replace("+00:00", "Z"),
            "nextDue": next_due.isoformat().replace("+00:00", "Z"),
            "sendTelegramUpdate": True,
            "includeInDailyBriefing": True,
            "alertIfOverdue": True,
            "isActive": True,
        }

    tasks.append(task)
    imported_keys.add(key)

# Keep Mac-only tasks that are not present on Intel CSV.
for key, task in existing_by_key.items():
    if key not in imported_keys:
        tasks.append(task)

json_dir.mkdir(parents=True, exist_ok=True)

if json_path.exists():
    backup_path = json_path.with_name(
        f"maintenance_tasks.json.backup-before-pull-sync.{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    )
    backup_path.write_text(json_path.read_text())

json_path.write_text(json.dumps(tasks, indent=2))

print(f"Loaded {len(tasks)} tasks into Swift app JSON.")
print(json_path)
