#!/usr/bin/env python3
"""Copy one PropertyManager manual and its accepted manufacturer tasks to another database.

``export`` reads the source (DEV). ``apply`` plans against the target
(Production), prints the plan, runs every write inside one locked transaction
and rolls it back unless ``--commit`` is given.

- Tasks belong to a manual only through ``provenance.accepted_task_ids``.
- New tasks arrive with no history, due one interval from now; meter tasks
  count from the target asset's current reading.
- Existing tasks keep their history, due dates and owner-editable fields; only
  manual-derived wording and schedule definitions are updated.
- A task is deactivated only when it is inactive in the source, still active in
  the target, and its id was approved with ``--deactivate``. Nothing is deleted.
- Completions, photos, work requests, owner-added tasks and meter readings are
  never written.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import secrets
import subprocess
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any
from uuid import UUID

API_DIR = Path(__file__).resolve().parent / "api"
if API_DIR.is_dir() and str(API_DIR) not in sys.path:
    sys.path.insert(0, str(API_DIR))

from propertymanager_api import next_calendar_due  # noqa: E402

FORMAT = "propertymanager-manual-package"
FORMAT_VERSION = 1
SCHEMA = "propertymanager"
LIBRARY_PREFIX = "dashboard-library://"
ASSETS_PREFIX = "Assets/"
VERSION_CHILD_TABLES = ("asset_manual_chunk", "asset_manual_state_event", "asset_manual_part")
# Manual-derived definition fields. Owner-editable fields stay as the target has them.
SYNCED_TASK_FIELDS = (
    "item",
    "category_name",
    "priority",
    "frequency",
    "task_description",
    "response_instructions",
    "supplies_needed",
    "estimated_minutes",
    "warning_days",
    "critical_days",
    "manufacturer",
    "source_manual_name",
    "tools_required",
    "schedule_kind",
    "meter_interval_value",
    "meter_interval_unit",
)
OWNER_TASK_FIELDS = (
    "area",
    "notes",
    "send_telegram_update",
    "include_in_daily_briefing",
    "alert_if_overdue",
    "part_url",
    "vendor",
    "part_number",
    "part_cost",
    "annual_cost",
)
LONG_TEXT_FIELDS = {"task_description", "response_instructions", "supplies_needed"}
PART_FIXED_FIELDS = {"id", "task_id", "created_at", "updated_at"}
LOCKED_TABLES = (
    "assets",
    "asset_meter",
    "asset_manual",
    "asset_manual_version",
    *VERSION_CHILD_TABLES,
    "maintenance_tasks",
    "maintenance_task_parts",
)
IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*$")
DO_TAG = "$pmdo$"

COLUMNS_SQL = f"""
SELECT coalesce(jsonb_object_agg(relname, cols), '{{}}'::jsonb) FROM (
    SELECT c.relname, jsonb_agg(a.attname ORDER BY a.attnum) AS cols
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    WHERE n.nspname = '{SCHEMA}' AND c.relkind = 'r' AND a.attnum > 0
      AND NOT a.attisdropped AND a.attgenerated = ''
    GROUP BY c.relname
) t
"""


class PackageError(RuntimeError):
    """The package cannot be exported or applied; nothing was written."""


@dataclass(frozen=True)
class Psql:
    """Runs SQL through ``docker exec psql`` with the SQL on stdin, never in argv."""

    container: str
    user: str
    database: str

    def run(self, sql: str) -> str:
        command = [
            "docker", "exec", "-i", self.container,
            "psql", "-X", "-q", "-U", self.user, "-d", self.database,
            "-v", "ON_ERROR_STOP=1", "-At", "-f", "-",
        ]
        result = subprocess.run(command, input=sql, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise PackageError((result.stderr or result.stdout).strip()[-4000:] or "psql failed")
        return result.stdout

    def read_json(self, select_sql: str) -> Any:
        output = self.run(f"BEGIN TRANSACTION READ ONLY;\n{select_sql};\nROLLBACK;\n")
        lines = [line for line in output.splitlines() if line.strip()]
        if len(lines) != 1:
            raise PackageError(f"expected one JSON row, got {len(lines)}")
        return json.loads(lines[0])


def _ident(name: str) -> str:
    if not IDENTIFIER.fullmatch(name):
        raise PackageError(f"unexpected identifier {name!r}")
    return f'"{name}"'


def _table(name: str) -> str:
    return f"{SCHEMA}.{_ident(name)}"


def _quote(text: str) -> str:
    if DO_TAG in text:
        raise PackageError("package text contains the reserved quoting tag")
    while True:
        tag = f"$pm{secrets.token_hex(6)}$"
        if tag not in text:
            return f"{tag}{text}{tag}"


def _jsonb(value: Any) -> str:
    return _quote(json.dumps(value, sort_keys=True, default=str)) + "::jsonb"


def _uuid(value: Any) -> str:
    try:
        return str(UUID(str(value)))
    except ValueError as exc:
        raise PackageError(f"not a UUID: {value!r}") from exc


def _uuid_array(ids: Iterable[str]) -> str:
    return "ARRAY[" + ", ".join(f"'{_uuid(i)}'" for i in ids) + "]::uuid[]"


def _rows_sql(table: str, columns: Iterable[str], where: str, order: str = "id") -> str:
    select_list = ", ".join(f"t.{_ident(c)}" for c in columns)
    return (
        f"(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.{_ident(order)}), '[]'::jsonb) "
        f"FROM (SELECT {select_list} FROM {_table(table)} t WHERE {where}) r)"
    )


def _accepted(version: dict[str, Any]) -> list[str]:
    ids = (version.get("provenance") or {}).get("accepted_task_ids") or []
    return [_uuid(i) for i in ids]


def read_columns(db: Psql) -> dict[str, list[str]]:
    return db.read_json(COLUMNS_SQL)


# --------------------------------------------------------------------- export


def list_manuals(db: Psql) -> list[dict[str, Any]]:
    return db.read_json(
        f"""
        SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.asset_name, r.title), '[]'::jsonb) FROM (
            SELECT m.id, m.title, m.document_key, a.name AS asset_name, a.is_active AS asset_active,
                   (SELECT count(*) FROM {SCHEMA}.asset_manual_version v
                     WHERE v.manual_id = m.id AND v.lifecycle_status <> 'removed') AS versions,
                   (SELECT count(DISTINCT x) FROM {SCHEMA}.asset_manual_version v,
                           jsonb_array_elements_text(coalesce(v.provenance -> 'accepted_task_ids', '[]'::jsonb)) x
                     WHERE v.manual_id = m.id AND v.lifecycle_status <> 'removed') AS linked_tasks
            FROM {SCHEMA}.asset_manual m JOIN {SCHEMA}.assets a ON a.id = m.asset_id
        ) r
        """
    )


def export_package(db: Psql, manual_id: str, *, now: datetime | None = None) -> dict[str, Any]:
    manual_id = _uuid(manual_id)
    columns = read_columns(db)
    manual = f"'{manual_id}'::uuid"
    asset = f"(SELECT asset_id FROM {_table('asset_manual')} WHERE id = {manual})"
    live_versions = f"(SELECT id FROM {_table('asset_manual_version')} WHERE manual_id = {manual} AND lifecycle_status <> 'removed')"
    linked_tasks = (
        f"(SELECT DISTINCT x::uuid FROM {_table('asset_manual_version')} v, "
        f"jsonb_array_elements_text(coalesce(v.provenance -> 'accepted_task_ids', '[]'::jsonb)) x "
        f"WHERE v.manual_id = {manual} AND v.lifecycle_status <> 'removed')"
    )
    asset_tasks = f"(SELECT id FROM {_table('maintenance_tasks')} WHERE asset_id = {asset})"
    children = [table for table in VERSION_CHILD_TABLES if table in columns]
    children_sql = ", ".join(
        f"'{table}', {_rows_sql(table, columns[table], f't.manual_version_id IN {live_versions}')}"
        for table in children
    )
    data = db.read_json(
        f"""
        SELECT jsonb_build_object(
            'asset', (SELECT to_jsonb(r) FROM (SELECT t.id, t.name, t.is_active FROM {_table('assets')} t
                      WHERE t.id = {asset}) r),
            'manual', (SELECT to_jsonb(r) FROM (SELECT {', '.join(f't.{_ident(c)}' for c in columns['asset_manual'])}
                       FROM {_table('asset_manual')} t WHERE t.id = {manual}) r),
            'versions', {_rows_sql('asset_manual_version', columns['asset_manual_version'],
                                   f"t.manual_id = {manual} AND t.lifecycle_status <> 'removed'", order='version_number')},
            'tasks', {_rows_sql('maintenance_tasks', columns['maintenance_tasks'],
                                f't.id IN {linked_tasks} AND t.asset_id = {asset}')},
            'task_parts', {_rows_sql('maintenance_task_parts', columns['maintenance_task_parts'],
                                     f't.task_id IN {linked_tasks} AND t.task_id IN {asset_tasks}')},
            'children', jsonb_build_object({children_sql})
        )
        """
    )
    if data["manual"] is None:
        raise PackageError(f"manual {manual_id} was not found in {db.database}")
    found = {task["id"] for task in data["tasks"]}
    unresolved = sorted({i for version in data["versions"] for i in _accepted(version)} - found)
    tables = ["asset_manual", "asset_manual_version", "maintenance_tasks", "maintenance_task_parts", *children]
    return {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "exported_at": (now or datetime.now(timezone.utc)).isoformat(),
        "source_database": db.database,
        "columns": {table: columns[table] for table in tables},
        "unresolved_task_links": unresolved,
        **data,
    }


# ---------------------------------------------------------------------- plan


SECTION_ORDER = (
    "Blockers",
    "Manual",
    "Versions",
    "Tasks to add",
    "Tasks to update",
    "Parts",
    "Deactivation (needs your approval)",
    "Left unchanged",
)


@dataclass
class Plan:
    sections: dict[str, list[str]] = field(default_factory=lambda: {name: [] for name in SECTION_ORDER})
    insert_manual: dict[str, Any] | None = None
    insert_versions: list[dict[str, Any]] = field(default_factory=list)
    version_links: dict[str, list[str]] = field(default_factory=dict)
    version_extractions: list[dict[str, Any]] = field(default_factory=list)
    insert_children: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    insert_tasks: list[dict[str, Any]] = field(default_factory=list)
    task_updates: list[dict[str, Any]] = field(default_factory=list)
    insert_parts: list[dict[str, Any]] = field(default_factory=list)
    part_updates: list[dict[str, Any]] = field(default_factory=list)
    deactivate: list[str] = field(default_factory=list)
    removal_candidates: list[str] = field(default_factory=list)

    @property
    def blockers(self) -> list[str]:
        return self.sections["Blockers"]

    @property
    def has_changes(self) -> bool:
        return bool(
            self.insert_manual or self.insert_versions or self.version_links or self.version_extractions
            or self.insert_children or self.insert_tasks or self.task_updates or self.insert_parts
            or self.part_updates or self.deactivate
        )

    def add(self, section: str, line: str) -> None:
        self.sections[section].append(line)


def _label(task: dict[str, Any]) -> str:
    return f"{task.get('area') or '?'} / {task.get('item') or '?'}"


def _describe_change(name: str, old: Any, new: Any) -> str:
    if name in LONG_TEXT_FIELDS:
        return f"{name} reworded ({len(str(old or ''))} -> {len(str(new or ''))} characters)"
    return f"{name} {json.dumps(old, default=str)} -> {json.dumps(new, default=str)}"


def _fresh_task(task: dict[str, Any], now: datetime, meter: dict[str, Any] | None) -> dict[str, Any]:
    interval = task.get("meter_interval_value")
    meter_scheduled = task.get("schedule_kind") in ("meter", "both") and interval is not None and Decimal(str(interval)) != 0
    next_meter = None
    if meter_scheduled:
        if meter is None or meter.get("current_value") is None:
            raise PackageError(f"{_label(task)}: meter task, but the target asset has no meter reading to count from.")
        next_meter = Decimal(str(meter["current_value"])) + Decimal(str(interval))
    row = dict(task)
    row.update(
        last_done=None,
        next_due=next_calendar_due(now, frequency=task.get("frequency"), warning_days=int(task.get("warning_days") or 0)).isoformat(),
        result_notes="",
        completion_history=[],
        last_done_meter_value=None,
        next_due_meter_value=str(next_meter) if next_meter is not None else None,
        converted_task_id=None,
        is_active=True,
        created_at=now.isoformat(),
        updated_at=now.isoformat(),
    )
    return row


def _plan_tasks(plan: Plan, package: dict[str, Any], target: dict[str, Any], now: datetime, approved: set[str]) -> set[str]:
    """Plan task and part writes; return ids of package tasks that will exist in the target."""
    target_tasks = {task["id"]: task for task in target["tasks"]}
    by_name = {(task["area"], task["item"]): task for task in target["tasks"]}
    target_parts = {part["id"]: part for part in target["task_parts"]}
    package_parts: dict[str, list[dict[str, Any]]] = {}
    for part in package["task_parts"]:
        if part.get("provenance") != "request_draft":
            package_parts.setdefault(part["task_id"], []).append(part)
    categories = set(target.get("categories") or [])
    present: set[str] = set()

    for task in sorted(package["tasks"], key=lambda t: (t.get("area") or "", t.get("item") or "", t["id"])):
        task_id, label = task["id"], _label(task)
        current = target_tasks.get(task_id)
        if task.get("origin") != "manufacturer" or task.get("kind") == "Work Request" or task.get("intake_state"):
            plan.add("Left unchanged", f"{label}: owner-added task or work request; never copied")
            continue
        if current is None:
            if not task.get("is_active"):
                plan.add("Left unchanged", f"{label}: inactive in the source; not copied")
                continue
            clash = by_name.get((task.get("area"), task.get("item")))
            if clash:
                plan.add("Blockers", f"{label}: a different task ({clash['id']}) already uses this area and item in the target.")
                continue
            try:
                row = _fresh_task(task, now, target.get("meter"))
            except PackageError as exc:
                plan.add("Blockers", str(exc))
                continue
            for part in package_parts.get(task_id, []):
                if part["id"] in target_parts:
                    plan.add("Blockers", f"{label}: part {part['id']} already exists in the target on another task.")
                plan.insert_parts.append(part)
            plan.insert_tasks.append(row)
            present.add(task_id)
            due = row["next_due"][:10]
            meter_note = f"; next at {row['next_due_meter_value']} {task.get('meter_interval_unit') or ''}".rstrip() if row["next_due_meter_value"] else ""
            parts_note = f"; {len(package_parts.get(task_id, []))} part(s)" if package_parts.get(task_id) else ""
            plan.add("Tasks to add", f"{label} ({task.get('frequency') or 'no frequency'}; due {due}{meter_note}{parts_note})")
            if task.get("category_name") and task["category_name"] not in categories:
                plan.add("Left unchanged", f"{label}: category {task['category_name']!r} does not exist in the target")
            continue
        if current.get("asset_id") != task.get("asset_id") or current.get("origin") != "manufacturer":
            plan.add("Blockers", f"{label}: task {task_id} exists in the target on a different asset or as an owner task.")
            continue
        present.add(task_id)
        if current["is_active"] and task.get("is_active"):
            changes = {name: task[name] for name in SYNCED_TASK_FIELDS if name in task and task[name] != current.get(name)}
            clash = by_name.get((current.get("area"), changes["item"])) if "item" in changes else None
            if clash and clash["id"] != task_id:
                plan.add("Blockers", f"{label}: renaming to {changes['item']!r} would collide with task {clash['id']}.")
                continue
            if changes:
                plan.task_updates.append({"id": task_id, **changes})
                described = "; ".join(_describe_change(name, current.get(name), value) for name, value in changes.items())
                plan.add("Tasks to update", f"{label}: {described} (history and due date kept)")
            kept = [name for name in OWNER_TASK_FIELDS if name in task and task[name] != current.get(name)]
            if kept:
                plan.add("Left unchanged", f"{label}: kept the target's {', '.join(kept)}")
            _plan_existing_parts(plan, label, task_id, package_parts.get(task_id, []), target_parts)
        elif current["is_active"]:
            plan.removal_candidates.append(task_id)
            if task_id in approved:
                plan.deactivate.append(task_id)
                plan.add("Deactivation (needs your approval)", f"{label} ({task_id}): approved; will be deactivated, history kept")
            else:
                plan.add("Deactivation (needs your approval)", f"{label} ({task_id}): inactive in the source; approve with --deactivate {task_id}")
        elif task.get("is_active"):
            plan.add("Left unchanged", f"{label}: inactive in the target; left inactive")

    for task_id in sorted(approved - set(plan.removal_candidates)):
        plan.add("Blockers", f"--deactivate {task_id} is not a task this package can deactivate.")
    return present


def _plan_existing_parts(
    plan: Plan, label: str, task_id: str, parts: list[dict[str, Any]], target_parts: dict[str, dict[str, Any]]
) -> None:
    package_ids = {part["id"] for part in parts}
    for part in parts:
        existing = target_parts.get(part["id"])
        if existing is None:
            plan.insert_parts.append(part)
            plan.add("Parts", f"{label}: add {part.get('name') or part['id']}")
        elif existing["task_id"] != task_id:
            plan.add("Blockers", f"{label}: part {part['id']} belongs to a different task in the target.")
        else:
            changes = {k: v for k, v in part.items() if k not in PART_FIXED_FIELDS and v != existing.get(k)}
            if changes:
                plan.part_updates.append({"id": part["id"], "task_id": task_id, **changes})
                plan.add("Parts", f"{label}: update {part.get('name') or part['id']} ({', '.join(sorted(changes))})")
    for part in target_parts.values():
        if part["task_id"] == task_id and part["id"] not in package_ids:
            plan.add("Left unchanged", f"{label}: kept target-only part {part.get('name') or part['id']}")


def _plan_versions(
    plan: Plan, package: dict[str, Any], target: dict[str, Any], present: set[str], pdf_sha256: Callable[[str], str | None]
) -> None:
    target_versions = {version["id"]: version for version in target["versions"]}
    numbers = {(v["manual_id"], v["version_number"]): v["id"] for v in target["versions"]}
    known = set(target_versions)
    for version in package["versions"]:
        version_id = version["id"]
        name = f"v{version['version_number']} {version.get('source_display_name') or ''}".rstrip()
        accepted = _accepted(version)
        linked = sorted(i for i in accepted if i in present)
        if set(accepted) - present:
            plan.add("Left unchanged", f"{name}: {len(set(accepted) - present)} linked task(s) are not copied, so they stay unlinked")
        current = target_versions.get(version_id)
        if current is not None:
            if current["manual_id"] != version["manual_id"] or current["source_sha256"] != version["source_sha256"]:
                plan.add("Blockers", f"{name}: version {version_id} exists in the target with a different manual or PDF checksum.")
                continue
            merged = sorted(set(_accepted(current)) | set(linked))
            notes = []
            if merged != sorted(_accepted(current)):
                plan.version_links[version_id] = merged
                notes.append(f"links {len(merged) - len(_accepted(current))} more task(s)")
            if current["ingestion_status"] != "extracted" and version["ingestion_status"] == "extracted":
                plan.version_extractions.append(
                    {key: version.get(key) for key in ("id", "ingestion_status", "extractor_name", "extractor_version")}
                )
                notes.append("marks extraction complete")
            plan.add("Versions", f"{name}: already present" + (f"; {', '.join(notes)}" if notes else ""))
            if current.get("source_locator") != version.get("source_locator"):
                plan.add("Left unchanged", f"{name}: the target keeps its own PDF location")
            continue
        if version["lifecycle_status"] == "active":
            plan.add("Blockers", f"{name}: active manual versions are not supported by this tool.")
            continue
        locator = version.get("source_locator") or ""
        if not locator.startswith(LIBRARY_PREFIX + ASSETS_PREFIX):
            plan.add("Blockers", f"{name}: PDF location {locator!r} is not in the shared Dashboard library (Assets/).")
        else:
            relative = locator[len(LIBRARY_PREFIX):]
            digest = pdf_sha256(relative)
            if digest is None:
                plan.add("Blockers", f"{name}: {relative} was not found in the target's PDF library.")
            elif digest != version["source_sha256"]:
                plan.add("Blockers", f"{name}: {relative} in the target's PDF library has a different checksum.")
        superseded = version.get("supersedes_version_id")
        if superseded and superseded not in known:
            plan.add("Blockers", f"{name}: it replaces version {superseded}, which is not in the target or this package.")
        other = numbers.get((version["manual_id"], version["version_number"]))
        if other and other != version_id:
            plan.add("Blockers", f"{name}: the target already has a different version {version['version_number']} of this manual.")
        row = dict(version)
        if "accepted_task_ids" in (version.get("provenance") or {}) or linked:
            row["provenance"] = {**(version.get("provenance") or {}), "accepted_task_ids": linked}
        plan.insert_versions.append(row)
        known.add(version_id)
        numbers[(version["manual_id"], version["version_number"])] = version_id
        plan.add("Versions", f"{name}: new; PDF checksum verified in the library; links {len(linked)} task(s)")


def build_plan(
    package: dict[str, Any],
    target: dict[str, Any],
    *,
    target_columns: dict[str, list[str]],
    now: datetime,
    approved_deactivations: Iterable[str] = (),
    pdf_sha256: Callable[[str], str | None],
) -> Plan:
    if package.get("format") != FORMAT or package.get("format_version") != FORMAT_VERSION:
        raise PackageError("not a PropertyManager manual package (format/version mismatch)")
    plan = Plan()
    asset, manual = package["asset"], package["manual"]
    target_asset = target.get("asset")
    if target_asset is None:
        plan.add("Blockers", f"Asset {asset['name']} ({asset['id']}) does not exist in the target.")
    elif not target_asset["is_active"]:
        plan.add("Blockers", f"Asset {asset['name']} is deactivated in the target; deactivated assets never receive tasks.")

    for table, columns in package["columns"].items():
        rows = package["children"].get(table) if table in VERSION_CHILD_TABLES else True
        if table not in target_columns:
            if rows:
                plan.add("Blockers", f"The target has no {table} table; apply its migration first.")
            continue
        missing = sorted(set(columns) - set(target_columns[table]))
        if missing:
            plan.add("Blockers", f"{table}: the target is missing columns {missing}; apply the matching migration first.")

    same_id = next((m for m in target["manuals"] if m["id"] == manual["id"]), None)
    same_key = next(
        (m for m in target["manuals"] if m["id"] != manual["id"]
         and m["asset_id"] == manual["asset_id"] and m["document_key"] == manual["document_key"]),
        None,
    )
    if same_key:
        plan.add("Blockers", f"The target already has a different manual ({same_key['id']}) with this document key on the asset.")
    if same_id is None:
        plan.insert_manual = manual
        plan.add("Manual", f"{manual['title']}: new")
    elif same_id["asset_id"] != manual["asset_id"] or same_id["document_key"] != manual["document_key"]:
        plan.add("Blockers", f"Manual {manual['id']} exists in the target on a different asset or document key.")
    else:
        plan.add("Manual", f"{manual['title']}: already present")

    approved = {_uuid(task_id) for task_id in approved_deactivations}
    present = _plan_tasks(plan, package, target, now, approved)
    _plan_versions(plan, package, target, present, pdf_sha256)

    for table, rows in package["children"].items():
        existing = {row["id"] for row in target["children"].get(table, [])}
        new_rows = [row for row in rows if row["id"] not in existing]
        if new_rows and table in target_columns:
            plan.insert_children[table] = new_rows
            plan.add("Versions", f"{table}: add {len(new_rows)} row(s)")
    return plan


# ---------------------------------------------------------------- target read


def _snapshot_cte(package: dict[str, Any], columns: dict[str, list[str]]) -> str:
    keys = {
        "asset_id": _uuid(package["asset"]["id"]),
        "manual_id": _uuid(package["manual"]["id"]),
        "document_key": package["manual"]["document_key"],
        "version_ids": sorted(_uuid(v["id"]) for v in package["versions"]),
        "task_ids": sorted(_uuid(t["id"]) for t in package["tasks"]),
        "area_items": sorted([t["area"], t["item"]] for t in package["tasks"]),
        "part_ids": sorted(_uuid(p["id"]) for p in package["task_parts"]),
        "children": {table: sorted(_uuid(r["id"]) for r in rows) for table, rows in package["children"].items()},
    }

    def ids(path: str) -> str:
        return f"(SELECT jsonb_array_elements_text(j #> '{{{path}}}')::uuid FROM k)"

    one = "(SELECT (j ->> '{key}')::uuid FROM k)"
    asset_id, manual_id = one.format(key="asset_id"), one.format(key="manual_id")
    children = ", ".join(
        f"'{table}', {_rows_sql(table, ['id', 'manual_version_id'], f't.id IN {ids(f'children,{table}')} OR t.manual_version_id IN {ids('version_ids')}')}"
        for table in VERSION_CHILD_TABLES
        if table in columns
    )
    return f"""
WITH k AS (SELECT {_jsonb(keys)} AS j),
s AS (SELECT jsonb_build_object(
    'asset', (SELECT to_jsonb(r) FROM (SELECT t.id, t.name, t.is_active FROM {_table('assets')} t WHERE t.id = {asset_id}) r),
    'meter', (SELECT to_jsonb(r) FROM (SELECT t.asset_id, t.meter_type, t.current_value, t.unit
              FROM {_table('asset_meter')} t WHERE t.asset_id = {asset_id}) r),
    'manuals', {_rows_sql('asset_manual', ['id', 'asset_id', 'document_key', 'title'],
                          f"t.id = {manual_id} OR (t.asset_id = {asset_id} AND t.document_key = (SELECT j ->> 'document_key' FROM k))")},
    'versions', {_rows_sql('asset_manual_version',
                           ['id', 'manual_id', 'version_number', 'source_sha256', 'source_locator', 'lifecycle_status',
                            'ingestion_status', 'extractor_name', 'extractor_version', 'provenance'],
                           f"t.id IN {ids('version_ids')} OR t.manual_id = {manual_id}")},
    'tasks', {_rows_sql('maintenance_tasks', columns['maintenance_tasks'],
                        f"t.id IN {ids('task_ids')} OR (t.area, t.item) IN "
                        "(SELECT e ->> 0, e ->> 1 FROM k, jsonb_array_elements(j -> 'area_items') e)")},
    'task_parts', {_rows_sql('maintenance_task_parts', columns['maintenance_task_parts'],
                             f"t.task_id IN {ids('task_ids')} OR t.id IN {ids('part_ids')}")},
    'children', jsonb_build_object({children}),
    'categories', (SELECT coalesce(jsonb_agg(name ORDER BY name), '[]'::jsonb) FROM {_table('maintenance_categories')})
) AS snapshot)
"""


def read_target(db: Psql, package: dict[str, Any], columns: dict[str, list[str]]) -> tuple[dict[str, Any], str]:
    result = db.read_json(
        _snapshot_cte(package, columns) + " SELECT jsonb_build_object('snapshot', snapshot, 'fingerprint', md5(snapshot::text)) FROM s"
    )
    return result["snapshot"], result["fingerprint"]


def library_hasher(root: Path | None) -> Callable[[str], str | None]:
    def sha256(relative: str) -> str | None:
        if root is None:
            return None
        base = root.resolve()
        path = (base / relative).resolve()
        if base not in path.parents or not path.is_file():
            return None
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                digest.update(block)
        return digest.hexdigest()

    return sha256


# ------------------------------------------------------------------- writes


def _do(body: str) -> str:
    return f"DO {DO_TAG} DECLARE n bigint; BEGIN {body} END {DO_TAG};"


def _expect(count: int, what: str) -> str:
    return f"IF n <> {count} THEN RAISE EXCEPTION '{what}: expected {count}, got %', n; END IF;"


def _insert(table: str, rows: list[dict[str, Any]], columns: list[str]) -> str:
    cols = ", ".join(_ident(c) for c in columns)
    return _do(
        f"WITH w AS (INSERT INTO {_table(table)} ({cols}) SELECT {cols} "
        f"FROM jsonb_populate_recordset(NULL::{_table(table)}, {_jsonb(rows)}) RETURNING 1) "
        f"SELECT count(*) INTO n FROM w; {_expect(len(rows), f'{table} inserts')}"
    )


def _update(table: str, row: dict[str, Any], fields: list[str], *, guard: str = "", touch: bool = False) -> str:
    sets = ", ".join(f"{_ident(f)} = s.{_ident(f)}" for f in fields) + (", updated_at = now()" if touch else "")
    return _do(
        f"WITH w AS (UPDATE {_table(table)} t SET {sets} "
        f"FROM jsonb_populate_record(NULL::{_table(table)}, {_jsonb(row)}) s "
        f"WHERE t.id = s.id {guard} RETURNING 1) SELECT count(*) INTO n FROM w; {_expect(1, f'{table} update')}"
    )


def render_script(
    plan: Plan,
    package: dict[str, Any],
    *,
    target_columns: dict[str, list[str]],
    guard_sql: str,
    fingerprint: str,
    commit: bool,
) -> str:
    if not re.fullmatch(r"[0-9a-f]{32}", fingerprint):
        raise PackageError("invalid target fingerprint")
    columns = package["columns"]
    locked = ", ".join(_table(t) for t in LOCKED_TABLES if t in target_columns)
    out = [
        "BEGIN;",
        "SET LOCAL lock_timeout = '15s';",
        f"LOCK TABLE {locked} IN SHARE ROW EXCLUSIVE MODE;",
        _do(
            f"IF ({guard_sql}) IS DISTINCT FROM '{fingerprint}' THEN RAISE EXCEPTION "
            "'The target changed after the plan was made; nothing was written. Run apply again.'; END IF;"
        ),
    ]
    if plan.insert_manual:
        out.append(_insert("asset_manual", [plan.insert_manual], columns["asset_manual"]))
    for version in plan.insert_versions:
        out.append(_insert("asset_manual_version", [version], columns["asset_manual_version"]))
    for row in plan.version_extractions:
        out.append(_update("asset_manual_version", row, ["ingestion_status", "extractor_name", "extractor_version"],
                           guard="AND t.ingestion_status <> 'extracted'"))
    for version_id, linked in sorted(plan.version_links.items()):
        out.append(_do(
            f"WITH w AS (UPDATE {_table('asset_manual_version')} t SET provenance = "
            f"jsonb_set(t.provenance, '{{accepted_task_ids}}', {_jsonb(linked)}, true) "
            f"WHERE t.id = '{_uuid(version_id)}' RETURNING 1) SELECT count(*) INTO n FROM w; {_expect(1, 'version link update')}"
        ))
    for table, rows in plan.insert_children.items():
        out.append(_insert(table, rows, columns[table]))
    if plan.insert_tasks:
        out.append(_insert("maintenance_tasks", plan.insert_tasks, columns["maintenance_tasks"]))
    for row in plan.task_updates:
        out.append(_update("maintenance_tasks", row, [k for k in row if k != "id"],
                           guard="AND t.is_active AND t.origin = 'manufacturer'", touch=True))
    if plan.insert_parts:
        out.append(_insert("maintenance_task_parts", plan.insert_parts, columns["maintenance_task_parts"]))
    for row in plan.part_updates:
        out.append(_update("maintenance_task_parts", row, [k for k in row if k not in ("id", "task_id")],
                           guard="AND t.task_id = s.task_id", touch=True))
    if plan.deactivate:
        out.append(_do(
            f"WITH w AS (UPDATE {_table('maintenance_tasks')} t SET is_active = false, updated_at = now() "
            f"WHERE t.id = ANY({_uuid_array(plan.deactivate)}) AND t.is_active AND t.origin = 'manufacturer' "
            f"RETURNING 1) SELECT count(*) INTO n FROM w; {_expect(len(plan.deactivate), 'deactivations')}"
        ))
    inserted = [row["id"] for row in plan.insert_tasks] or [package["asset"]["id"]]
    deactivated = plan.deactivate or [package["asset"]["id"]]
    versions = [v["id"] for v in package["versions"]] or [package["asset"]["id"]]
    out.append(
        "SELECT jsonb_build_object("
        f"'tasks_added_with_no_history', (SELECT count(*) FROM {_table('maintenance_tasks')} WHERE id = ANY({_uuid_array(inserted)}) "
        "AND completion_history = '[]'::jsonb AND last_done IS NULL AND is_active), "
        f"'tasks_deactivated', (SELECT count(*) FROM {_table('maintenance_tasks')} WHERE id = ANY({_uuid_array(deactivated)}) AND NOT is_active), "
        f"'versions_present', (SELECT count(*) FROM {_table('asset_manual_version')} WHERE id = ANY({_uuid_array(versions)})));"
    )
    out.append("COMMIT;" if commit else "ROLLBACK;")
    return "\n".join(out) + "\n"


@dataclass
class Prepared:
    plan: Plan
    script: str | None


def prepare_apply(
    db: Psql,
    package: dict[str, Any],
    *,
    library_root: Path | None,
    approved_deactivations: Iterable[str] = (),
    commit: bool = False,
    now: datetime | None = None,
) -> Prepared:
    columns = read_columns(db)
    target, fingerprint = read_target(db, package, columns)
    plan = build_plan(
        package,
        target,
        target_columns=columns,
        now=now or datetime.now(timezone.utc),
        approved_deactivations=approved_deactivations,
        pdf_sha256=library_hasher(library_root),
    )
    if plan.blockers or not plan.has_changes:
        return Prepared(plan, None)
    guard_sql = _snapshot_cte(package, columns) + " SELECT md5(snapshot::text) FROM s"
    script = render_script(plan, package, target_columns=columns, guard_sql=guard_sql, fingerprint=fingerprint, commit=commit)
    return Prepared(plan, script)


def execute(db: Psql, prepared: Prepared) -> dict[str, Any]:
    if prepared.script is None:
        raise PackageError("nothing to execute")
    lines = [line for line in db.run(prepared.script).splitlines() if line.strip()]
    return json.loads(lines[-1])


def format_report(package: dict[str, Any], plan: Plan) -> str:
    asset = package["asset"]
    lines = [
        f"Manual package: {package['manual']['title']} for {asset['name']} "
        f"(exported {package['exported_at'][:19]} from {package['source_database']})",
    ]
    for name in SECTION_ORDER:
        entries = plan.sections[name]
        if entries:
            lines.append(f"\n{name} ({len(entries)}):")
            lines.extend(f"  - {entry}" for entry in entries)
    if package.get("unresolved_task_links"):
        lines.append(f"\nNote: {len(package['unresolved_task_links'])} linked task id(s) were not found on this asset in the source.")
    return "\n".join(lines)


# ---------------------------------------------------------------------- CLI


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Copy one PropertyManager manual package between databases.")
    parser.add_argument("--container", required=True, help="PostgreSQL docker container")
    parser.add_argument("--db-user", required=True)
    parser.add_argument("--database", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="list manuals in this database")
    export = commands.add_parser("export", help="write one manual's package (read-only)")
    export.add_argument("--manual-id", required=True)
    export.add_argument("--out", required=True, type=Path)
    apply = commands.add_parser("apply", help="dry-run or commit a package against this database")
    apply.add_argument("package", type=Path)
    apply.add_argument("--library-root", type=Path, help="local path of the shared PDF library")
    apply.add_argument("--deactivate", action="append", default=[], metavar="TASK_ID")
    apply.add_argument("--commit", action="store_true")
    args = parser.parse_args(argv)
    db = Psql(args.container, args.db_user, args.database)

    try:
        if args.command == "list":
            for row in list_manuals(db):
                state = "" if row["asset_active"] else "  [asset deactivated]"
                print(f"{row['id']}  {row['asset_name']} | {row['title']} | versions {row['versions']}, "
                      f"linked tasks {row['linked_tasks']}{state}")
            return 0
        if args.command == "export":
            package = export_package(db, args.manual_id)
            args.out.write_text(json.dumps(package, indent=1, sort_keys=True, default=str) + "\n", encoding="utf-8")
            print(f"Wrote {args.out}: {len(package['versions'])} version(s), {len(package['tasks'])} linked task(s), "
                  f"{len(package['task_parts'])} part(s).")
            return 0
        package = json.loads(args.package.read_text(encoding="utf-8"))
        prepared = prepare_apply(
            db, package, library_root=args.library_root, approved_deactivations=args.deactivate, commit=args.commit
        )
        print(format_report(package, prepared.plan))
        if prepared.plan.blockers:
            print("\nNot applied: resolve the blockers above. Nothing changed.")
            return 2
        if prepared.script is None:
            print("\nNothing to change: the target already matches this package.")
            return 0
        summary = execute(db, prepared)
        verdict = "COMMITTED." if args.commit else "DRY RUN: every write ran inside one transaction and was rolled back. Nothing changed."
        print(f"\n{verdict}\nCheck inside the transaction: {json.dumps(summary, sort_keys=True)}")
        return 0
    except PackageError as exc:
        print(f"Failed; nothing changed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
