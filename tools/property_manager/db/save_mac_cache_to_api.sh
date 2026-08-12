#!/usr/bin/env bash
# Save Mac PropertyManager Application Support JSON to Postgres via API.
set -euo pipefail

API_BASE="${PROPERTYMANAGER_API_BASE:-http://intelmini:5062}"
TOKEN="${PROPERTYMANAGER_API_TOKEN:-}"
APP_SUPPORT="${HOME}/Library/Application Support/PropertyManagerApp"
TASKS_JSON="${APP_SUPPORT}/maintenance_tasks.json"
CATS_JSON="${APP_SUPPORT}/maintenance_categories.json"
ATTACH_DIR="${APP_SUPPORT}/attachments"

pm_curl() {
  if [[ -n "${TOKEN}" ]]; then
    curl -fsS -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -fsS "$@"
  fi
}

if [[ ! -f "${TASKS_JSON}" ]]; then
  echo "missing ${TASKS_JSON}" >&2
  exit 1
fi

echo "Saving to ${API_BASE} ..."
pm_curl "${API_BASE}/health" >/dev/null

python3 - "${API_BASE}" "${TOKEN}" "${TASKS_JSON}" "${CATS_JSON}" "${ATTACH_DIR}" <<'PY'
import json, os, sys, urllib.request
from pathlib import Path

api_base, token, tasks_path, cats_path, attach_dir = sys.argv[1:6]
tasks = json.loads(Path(tasks_path).read_text())
cats = json.loads(Path(cats_path).read_text()) if Path(cats_path).exists() else []

def req(method, path, data=None, headers=None):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    if headers:
        h.update(headers)
    body = None if data is None else json.dumps(data).encode()
    request = urllib.request.Request(api_base + path, data=body, headers=h, method=method)
    with urllib.request.urlopen(request) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}

for c in cats:
    req("POST", "/categories", {
        "id": c.get("id"),
        "name": c["name"],
        "icon": c.get("icon") or "folder.fill",
        "color_name": c.get("colorName") or "gray",
        "is_built_in": bool(c.get("isBuiltIn", False)),
    })

saved = 0
for t in tasks:
    payload = {
        "id": t["id"],
        "area": t.get("area") or t.get("category") or "House",
        "item": t.get("item") or "",
        "category_name": t.get("category") or t.get("area") or "House",
        "kind": t.get("kind") or "Scheduled",
        "priority": t.get("priority") or "Medium",
        "frequency": t.get("frequency") or "Monthly",
        "task_description": t.get("taskDescription") or "",
        "response_instructions": t.get("responseInstructions") or "",
        "supplies_needed": t.get("suppliesNeeded") or "",
        "notes": t.get("notes") or "",
        "result_notes": t.get("resultNotes") or "",
        "completion_history": t.get("completionHistory") or [],
        "estimated_minutes": int(t.get("estimatedMinutes") or 30),
        "warning_days": int(t.get("warningDays") or 30),
        "critical_days": int(t.get("criticalDays") or 45),
        "last_done": t.get("lastDone"),
        "next_due": t.get("nextDue"),
        "send_telegram_update": bool(t.get("sendTelegramUpdate", True)),
        "include_in_daily_briefing": bool(t.get("includeInDailyBriefing", True)),
        "alert_if_overdue": bool(t.get("alertIfOverdue", True)),
        "is_active": bool(t.get("isActive", True)),
        "manufacturer": t.get("manufacturer") or "",
        "source_manual_name": t.get("sourceManualName") or "",
        "tools_required": t.get("toolsRequired") or [],
        "parts": [
            {
                "id": p.get("id"),
                "name": p.get("name") or "",
                "oem_part_number": p.get("oemPartNumber") or "",
                "part_number": p.get("partNumber") or "",
                "buy_url": p.get("buyURL") or "",
                "cost": float(p.get("cost") or 0),
            }
            for p in (t.get("parts") or [])
        ],
    }
    # Upsert via POST (ON CONFLICT id)
    req("POST", "/tasks", payload)
    saved += 1

    # Upload local photos that are not yet on server (best-effort by filename)
    remote = req("GET", f"/tasks/{t['id']}")
    remote_names = {p.get("file_name") for p in (remote.get("photos") or [])}
    for name in (t.get("photoFileNames") or []):
        if name in remote_names:
            continue
        local = Path(attach_dir) / name
        if not local.exists():
            # also try task-scoped folder
            alt = Path(attach_dir) / t["id"] / name
            local = alt if alt.exists() else local
        if not local.exists():
            continue
        boundary = "----PMBoundary"
        file_bytes = local.read_bytes()
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f"Content-Type: application/octet-stream\r\n\r\n"
        ).encode() + file_bytes + f"\r\n--{boundary}--\r\n".encode()
        headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(
            api_base + f"/tasks/{t['id']}/photos",
            data=body,
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(request) as resp:
            resp.read()

print(f"Saved {saved} tasks to Postgres via {api_base}")
PY

echo "Save complete."
