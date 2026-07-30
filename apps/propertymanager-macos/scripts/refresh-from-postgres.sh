#!/usr/bin/env bash
# Refresh Mac PropertyManager cache from Postgres via PropertyManager API.
set -euo pipefail

API_BASE="${PROPERTYMANAGER_API_BASE:-http://192.168.50.104:5062}"
TOKEN="${PROPERTYMANAGER_API_TOKEN:-}"
APP_SUPPORT="${HOME}/Library/Application Support/PropertyManagerApp"
TASKS_JSON="${APP_SUPPORT}/maintenance_tasks.json"
CATS_JSON="${APP_SUPPORT}/maintenance_categories.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "${APP_SUPPORT}"

pm_curl() {
  if [[ -n "${TOKEN}" ]]; then
    curl -fsS -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -fsS "$@"
  fi
}

echo "Refreshing from ${API_BASE} ..."
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pm_curl "${API_BASE}/health" >"${TMP}/health.json"
pm_curl "${API_BASE}/tasks?include_inactive=1" >"${TMP}/tasks.api.json"
pm_curl "${API_BASE}/categories" >"${TMP}/categories.api.json"

if [[ -f "${TASKS_JSON}" ]]; then
  cp -a "${TASKS_JSON}" "${APP_SUPPORT}/maintenance_tasks.json.backup-before-postgres-refresh-${STAMP}"
fi
if [[ -f "${CATS_JSON}" ]]; then
  cp -a "${CATS_JSON}" "${APP_SUPPORT}/maintenance_categories.json.backup-before-postgres-refresh-${STAMP}"
fi

python3 - "${TMP}/tasks.api.json" "${TMP}/categories.api.json" "${TASKS_JSON}" "${CATS_JSON}" <<'PY'
import json, sys
from pathlib import Path

tasks_api = json.loads(Path(sys.argv[1]).read_text())
cats_api = json.loads(Path(sys.argv[2]).read_text())
tasks_out = Path(sys.argv[3])
cats_out = Path(sys.argv[4])

def map_part(p):
    return {
        "id": p.get("id"),
        "name": p.get("name") or "",
        "oemPartNumber": p.get("oem_part_number") or "",
        "partNumber": p.get("part_number") or "",
        "buyURL": p.get("buy_url") or "",
        "cost": float(p.get("cost") or 0),
    }

def map_tool(t):
    if not isinstance(t, dict):
        return {"id": None, "name": str(t), "size": "", "notes": ""}
    return {
        "id": t.get("id"),
        "name": t.get("name") or "",
        "size": t.get("size") or "",
        "notes": t.get("notes") or "",
    }

mapped_tasks = []
for t in tasks_api:
    photos = t.get("photos") or []
    mapped_tasks.append({
        "id": t["id"],
        "area": t.get("area") or "",
        "item": t.get("item") or "",
        "category": t.get("category_name") or t.get("area") or "House",
        "kind": t.get("kind") or "Scheduled",
        "priority": t.get("priority") or "Medium",
        "frequency": t.get("frequency") or "Monthly",
        "taskDescription": t.get("task_description") or "",
        "responseInstructions": t.get("response_instructions") or "",
        "suppliesNeeded": t.get("supplies_needed") or "",
        "notes": t.get("notes") or "",
        "resultNotes": t.get("result_notes") or "",
        "completionHistory": t.get("completion_history") or [],
        "estimatedMinutes": int(t.get("estimated_minutes") or 30),
        "warningDays": int(t.get("warning_days") or 30),
        "criticalDays": int(t.get("critical_days") or 45),
        "lastDone": t.get("last_done"),
        "nextDue": t.get("next_due"),
        "sendTelegramUpdate": bool(t.get("send_telegram_update", True)),
        "includeInDailyBriefing": bool(t.get("include_in_daily_briefing", True)),
        "alertIfOverdue": bool(t.get("alert_if_overdue", True)),
        "isActive": bool(t.get("is_active", True)),
        "manufacturer": t.get("manufacturer") or "",
        "sourceManualName": t.get("source_manual_name") or "",
        "origin": t.get("origin") or ("manufacturer" if (t.get("source_manual_name") or "").strip() else "owner"),
        "partNumbers": [],
        "referenceURLs": [],
        "toolsRequired": [map_tool(x) for x in (t.get("tools_required") or [])],
        "parts": [map_part(p) for p in (t.get("parts") or [])],
        "photoFileNames": [p.get("file_name") for p in photos if p.get("file_name")],
    })

mapped_cats = []
for c in cats_api:
    mapped_cats.append({
        "id": c["id"],
        "name": c["name"],
        "icon": c.get("icon") or "folder.fill",
        "colorName": c.get("color_name") or "gray",
        "isBuiltIn": bool(c.get("is_built_in", False)),
    })

tasks_out.write_text(json.dumps(mapped_tasks, indent=2) + "\n")
cats_out.write_text(json.dumps(mapped_cats, indent=2) + "\n")
print(f"Wrote {len(mapped_tasks)} tasks -> {tasks_out}")
print(f"Wrote {len(mapped_cats)} categories -> {cats_out}")
PY

echo "Refresh complete."
