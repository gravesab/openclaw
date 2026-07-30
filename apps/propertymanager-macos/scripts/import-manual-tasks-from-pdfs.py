#!/usr/bin/env python3
"""Batch-import manufacturer maintenance tasks from mirrored RanchBrain manuals."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

APP = Path.home() / "Development/PropertyManagerApp"
MANUALS = APP / "manuals"
JSON_PATH = Path.home() / "Library/Application Support/PropertyManagerApp/maintenance_tasks.json"
OLLAMA_URL = os.environ.get("PROPERTYMANAGER_OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("PROPERTYMANAGER_OLLAMA_MODEL", "llama3.1:latest")
MAX_CHARS = 10_000

PRIORITY = [
    "Home/Ecowater/EcoWater Owners Manual.pdf",
    "Home/Pool/Pool Tmer User Manual.pdf",
    "Home/Jacuzzi/Strong-Spas-Manual2020sm.pdf",
    "Equipment/Toro/Toro-22in-Kohler-Mower/UseandCareManual-Toro-22inKohlerHighWheelVariableSpeedGasSelfPropelledMower.pdf",
    "DR-Power/DR-Field-Mower/DR Field Mower Manual.pdf",
    "DR-Power/DR-SP22/DR SP22 Mower Safety Manual.pdf",
    "Landscape/Chainsaws/Husqvarna/Husqvarna 450 Rancher Operator's Manual.pdf",
    "Landscape/Chainsaws/Husqvarna/Husqvarna 435 440 Operator's Manual.pdf",
    "Home/Locks/Yale Assure Manual.pdf",
    "Home/Generator/Generator - Generrac Air-Cooled Generator Manual.pdf",
]

EXTRACT_SWIFT = r'''
import Foundation
import PDFKit

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: extract <pdf> <out.txt>\n", stderr)
    exit(2)
}
let pdfURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let document = PDFDocument(url: pdfURL) else {
    fputs("unable to open pdf\n", stderr)
    exit(1)
}
var parts: [String] = []
for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { continue }
    let pageText = page.string ?? ""
    if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
    parts.append("----- page \(index + 1) -----\n\(pageText)")
}
try parts.joined(separator: "\n\n").write(to: outURL, atomically: true, encoding: .utf8)
print(parts.count)
'''

MAINT_HINTS = re.compile(
    r"maintain|maintenance|service|schedule|every\s+\d|replace|filter|lubricat|"
    r"inspect|torque|oil|grease|clean|flush|backwash|winteriz|seasonal|"
    r"part\s*number|socket|wrench|mm\b|interval",
    re.I,
)


def task_key(area: str, item: str) -> str:
    return f"{area.strip().lower()}|{item.strip().lower()}"


def extract_text(pdf: Path) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "extract.swift"
        out = Path(tmp) / "out.txt"
        script.write_text(EXTRACT_SWIFT)
        subprocess.check_call(
            ["swift", str(script), str(pdf), str(out)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return out.read_text(encoding="utf-8", errors="ignore")


def prioritize_manual_text(raw: str, max_chars: int = MAX_CHARS) -> str:
    pages = re.split(r"\n----- page \d+ -----\n", raw)
    pages = [p.strip() for p in pages if p.strip()]
    if not pages:
        return raw[:max_chars]

    scored = []
    for idx, page in enumerate(pages, start=1):
        score = len(MAINT_HINTS.findall(page))
        scored.append((score, idx, page))
    scored.sort(key=lambda row: (-row[0], row[1]))

    chosen: list[str] = []
    total = 0
    # Keep a bit of front-matter for product identity.
    for page in pages[:2]:
        chunk = f"----- early page -----\n{page}"
        chosen.append(chunk)
        total += len(chunk)
        if total >= max_chars // 4:
            break

    for score, idx, page in scored:
        if score <= 0 and total > max_chars // 3:
            continue
        chunk = f"----- page {idx} -----\n{page}"
        if total + len(chunk) > max_chars:
            remain = max_chars - total
            if remain > 500:
                chosen.append(chunk[:remain])
            break
        chosen.append(chunk)
        total += len(chunk)
        if total >= max_chars:
            break

    return "\n\n".join(chosen)


def ask_ollama(manual_name: str, text: str) -> dict:
    import urllib.request

    system = (
        "Return ONLY JSON. No markdown. Schema: "
        '{"manufacturer":"...","equipment":"...","tasks":[{"area":"House","item":"Check salt level",'
        '"category":"House","frequency":"Monthly","warningDays":30,"criticalDays":45,'
        '"estimatedMinutes":15,"taskDescription":"...","responseInstructions":"1. ...",'
        '"suppliesNeeded":"salt","partNumbers":[],"referenceURLs":[],'
        '"toolsRequired":[{"name":"scoop","size":"","notes":""}],"notes":"p.12"}]} '
        "Extract concrete manufacturer maintenance/inspection/service tasks only. Set JSON equipment to the machine/asset name. Task area may be a subsystem; the importer stores equipment as Area. "
        "Never use placeholder words like string. Do not invent part numbers or URLs."
    )
    body = {
        "model": MODEL,
        "stream": False,
        "messages": [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": (
                    f"Manual file: {manual_name}\n"
                    "Respond with a single JSON object only. First character must be { .\nExtract 4-8 concrete manufacturer maintenance tasks.\n\n"
                    f"{text}"
                ),
            },
        ],
        "options": {"temperature": 0.1},
    }
    req = urllib.request.Request(
        f"{OLLAMA_URL.rstrip('/')}/api/chat",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        payload = json.loads(resp.read().decode())
    content = payload["message"]["content"].strip()
    if content.startswith("```"):
        content = content.strip("`")
        if content.startswith("json"):
            content = content[4:].strip()
    start_brace = content.find("{")
    end_brace = content.rfind("}")
    if start_brace < 0 or end_brace <= start_brace:
        print(f"raw_response_prefix={content[:400]!r}", flush=True)
        return {"manufacturer": "", "equipment": "", "tasks": []}
    try:
        data = json.loads(content[start_brace : end_brace + 1])
    except json.JSONDecodeError as exc:
        print(f"json_error={exc} raw_response_prefix={content[:400]!r}", flush=True)
        return {"manufacturer": "", "equipment": "", "tasks": []}
    if not isinstance(data, dict):
        return {"manufacturer": "", "equipment": "", "tasks": []}
    data.setdefault("tasks", [])
    return data


def frequency_to_warning(freq: str | None, warning: int | None) -> int:
    if isinstance(warning, int) and warning > 0:
        return warning
    text = (freq or "").lower()
    if "daily" in text:
        return 1
    if "2 week" in text or "biweek" in text or "every 2" in text:
        return 14
    if "week" in text:
        return 7
    if "quarter" in text:
        return 90
    if "year" in text or "annual" in text:
        return 365
    if "month" in text:
        return 30
    return 30


def normalize_category(raw: str | None, area: str) -> str:
    text = (raw or area or "").lower()
    if "pool" in text:
        return "Pool"
    if "hot" in text or "tub" in text or "spa" in text:
        return "Home"
    if "ground" in text or "yard" in text or "mower" in text or "lawn" in text:
        return "Grounds"
    if "safety" in text:
        return "Safety"
    if "house" in text or "home" in text or "lock" in text or "water" in text or "system" in text:
        return "House"
    return "Equipment"


def normalize_frequency(raw: str | None, warning_days: int) -> str:
    text = (raw or "").lower()
    if "daily" in text:
        return "Daily"
    if "2 week" in text or "biweek" in text or "every 2" in text:
        return "Every 2 Weeks"
    if "week" in text:
        return "Weekly"
    if "quarter" in text:
        return "Quarterly"
    if "year" in text or "annual" in text:
        return "Yearly"
    if "month" in text:
        return "Monthly"
    if warning_days <= 1:
        return "Daily"
    if warning_days <= 7:
        return "Weekly"
    if warning_days <= 14:
        return "Every 2 Weeks"
    if warning_days <= 45:
        return "Monthly"
    if warning_days <= 120:
        return "Quarterly"
    return "Yearly"


def is_placeholder(value: str) -> bool:
    cleaned = value.strip().lower()
    return cleaned in {"", "string", "number", "item", "task", "n/a", "none", "null"}


def to_task(raw: dict, manufacturer: str, equipment: str, manual_name: str) -> dict | None:
    # Area is the equipment identity (Tractor, DR Field Mower, ...).
    equipment_name = (equipment or "").strip() or "Equipment"
    subsystem = str(raw.get("area") or "").strip()
    area = equipment_name
    item = str(raw.get("item") or "").strip()
    if is_placeholder(item):
        return None
    if (
        subsystem
        and subsystem.lower() != area.lower()
        and subsystem.lower() not in item.lower()
        and not is_placeholder(subsystem)
    ):
        item = f"{subsystem}: {item}"
    warning = frequency_to_warning(raw.get("frequency"), raw.get("warningDays"))
    critical = raw.get("criticalDays")
    if not isinstance(critical, int) or critical < warning:
        critical = max(warning * 2, warning + 7)
    last_done = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    next_due = last_done + timedelta(days=warning)
    tools = []
    for tool in raw.get("toolsRequired") or []:
        name = str(tool.get("name") or "").strip()
        if is_placeholder(name):
            continue
        tools.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "name": name,
                "size": str(tool.get("size") or "").strip(),
                "notes": str(tool.get("notes") or "").strip(),
            }
        )
    desc = str(raw.get("taskDescription") or f"{area}: {item}").strip()
    instructions = str(raw.get("responseInstructions") or "").strip()
    if not instructions or is_placeholder(instructions):
        # Never manufacture a generic How-To for a manufacturer task.
        # Tasks without extracted procedure text remain out of the import.
        return None
    if is_placeholder(desc) or desc.lower() == "string":
        desc = f"{area}: {item}"
    notes_bits = []
    if raw.get("notes") and not is_placeholder(str(raw.get("notes"))):
        notes_bits.append(str(raw["notes"]).strip())
    notes_bits.append(f"Source manual: {manual_name}")
    if manufacturer:
        notes_bits.append(f"Manufacturer: {manufacturer}")
    return {
        "id": str(uuid.uuid4()).upper(),
        "area": area,
        "item": item,
        "category": normalize_category(raw.get("category"), area),
        "priority": "Medium",
        "frequency": normalize_frequency(raw.get("frequency"), warning),
        "taskDescription": desc,
        "responseInstructions": instructions,
        "suppliesNeeded": str(raw.get("suppliesNeeded") or "").strip(),
        "notes": "\n".join(notes_bits),
        "resultNotes": "",
        "completionHistory": [],
        "estimatedMinutes": max(int(raw.get("estimatedMinutes") or 30), 5),
        "warningDays": warning,
        "criticalDays": critical,
        "lastDone": last_done.isoformat().replace("+00:00", "Z"),
        "nextDue": next_due.isoformat().replace("+00:00", "Z"),
        "sendTelegramUpdate": True,
        "includeInDailyBriefing": True,
        "alertIfOverdue": True,
        "isActive": True,
        "manufacturer": manufacturer,
        "sourceManualName": manual_name,
        "partNumbers": [
            str(p).strip()
            for p in (raw.get("partNumbers") or [])
            if str(p).strip() and not is_placeholder(str(p))
        ],
        "referenceURLs": [
            str(u).strip()
            for u in (raw.get("referenceURLs") or [])
            if str(u).strip() and str(u).strip().lower().startswith("http")
        ],
        "toolsRequired": tools,
    }


def load_tasks() -> list[dict]:
    if not JSON_PATH.exists():
        return []
    return json.loads(JSON_PATH.read_text())


def save_tasks(tasks: list[dict]) -> None:
    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    if JSON_PATH.exists():
        backup = JSON_PATH.with_name(
            f"maintenance_tasks.json.backup-before-manual-import.{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        )
        backup.write_text(JSON_PATH.read_text())
    JSON_PATH.write_text(json.dumps(tasks, indent=2) + "\n")


def merge_tasks(existing: list[dict], incoming: list[dict]) -> tuple[list[dict], int]:
    existing_keys = {task_key(t.get("area", ""), t.get("item", "")) for t in existing}
    existing_by_key = {
        task_key(t.get("area", ""), t.get("item", "")): t for t in existing
    }
    added_tasks: list[dict] = []
    added = 0
    for task in incoming:
        key = task_key(task["area"], task["item"])
        if key in existing_by_key:
            cur = existing_by_key[key]
            for field in ("manufacturer", "sourceManualName"):
                if not cur.get(field):
                    cur[field] = task.get(field, "")
            for field in ("partNumbers", "toolsRequired", "referenceURLs"):
                if not cur.get(field):
                    cur[field] = task.get(field, [])
            continue
        existing_by_key[key] = task
        existing_keys.add(key)
        added_tasks.append(task)
        added += 1
    return added_tasks + existing, added


def process_pdf(rel: str) -> tuple[int, str]:
    pdf = MANUALS / rel
    if not pdf.exists():
        return 0, f"missing {rel}"
    print(f"\n=== {rel} ===", flush=True)
    raw = extract_text(pdf)
    if not raw.strip():
        return 0, "no text"
    focused = prioritize_manual_text(raw, max_chars=MAX_CHARS)
    # Keep prompt short so the model returns JSON instead of prose.
    text = (raw[:4000] + "\n\n" + focused)[:MAX_CHARS]
    print(f"extracted_chars={len(raw)} focused_chars={len(text)} model={MODEL}", flush=True)
    payload = ask_ollama(pdf.name, text)
    manufacturer = str(payload.get("manufacturer") or "").strip()
    equipment = str(payload.get("equipment") or "").strip()
    incoming = []
    for raw_task in payload.get("tasks") or []:
        task = to_task(raw_task, manufacturer, equipment, pdf.name)
        if task:
            incoming.append(task)
    if not incoming:
        preview = json.dumps(payload)[:300]
        print(f"empty/placeholder tasks payload={preview}", flush=True)
        return 0, "no tasks"
    existing = load_tasks()
    merged, added = merge_tasks(existing, incoming)
    save_tasks(merged)
    print(
        f"manufacturer={manufacturer!r} proposed={len(incoming)} added={added} total={len(merged)}",
        flush=True,
    )
    for task in incoming[:5]:
        print(f"  - {task['area']} / {task['item']}", flush=True)
    return added, "ok"


def main() -> int:
    selected = sys.argv[1:] or PRIORITY
    total_added = 0
    results = []
    for rel in selected:
        try:
            added, status = process_pdf(rel)
            total_added += added
            results.append((rel, added, status))
        except Exception as exc:  # noqa: BLE001
            print(f"FAILED {rel}: {exc}", flush=True)
            results.append((rel, 0, f"error: {exc}"))
    print("\n=== SUMMARY ===", flush=True)
    for rel, added, status in results:
        print(f"{added:3d}  {status:10s}  {rel}", flush=True)
    print(f"total_added={total_added}", flush=True)
    print(f"json={JSON_PATH}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
