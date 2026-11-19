#!/usr/bin/env python3
"""Manual package export/plan/apply: planning rules and a disposable-PostgreSQL round trip."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path

from tools.property_manager import manual_package as mp

NOW = datetime(2026, 10, 2, 18, 0, tzinfo=timezone.utc)
ASSET = "11111111-1111-4111-8111-111111111111"
MANUAL = "22222222-2222-4222-8222-222222222222"
V1 = "33333333-3333-4333-8333-333333333331"
V2 = "33333333-3333-4333-8333-333333333332"
T_EXISTING = "44444444-4444-4444-8444-444444444441"
T_RETIRED = "44444444-4444-4444-8444-444444444443"
T_METER = "44444444-4444-4444-8444-444444444444"
T_NEW = "44444444-4444-4444-8444-444444444445"
T_OWNER = "44444444-4444-4444-8444-444444444446"
P_EXISTING = "55555555-5555-4555-8555-555555555551"
P_NEW = "55555555-5555-4555-8555-555555555552"
CHUNK = "66666666-6666-4666-8666-666666666661"
EVENT = "77777777-7777-4777-8777-777777777771"
V1_SHA = "a" * 64


def task(task_id: str, item: str, **overrides) -> dict:
    row = {
        "id": task_id, "area": "Pump house", "item": item, "category_name": "Equipment", "priority": "Medium",
        "frequency": "Monthly", "task_description": "Check it", "response_instructions": "", "supplies_needed": "",
        "notes": "", "result_notes": "", "estimated_minutes": 10, "warning_days": 7, "critical_days": 0,
        "last_done": None, "next_due": "2026-11-02T00:00:00+00:00", "is_active": True, "kind": "Scheduled",
        "manufacturer": "Acme", "source_manual_name": "pump.pdf", "completion_history": [], "tools_required": [],
        "origin": "manufacturer", "asset_id": ASSET, "schedule_kind": "calendar", "meter_interval_value": None,
        "meter_interval_unit": None, "last_done_meter_value": None, "next_due_meter_value": None,
        "intake_state": None, "converted_task_id": None,
    }
    row.update(overrides)
    return row


def version(version_id: str, number: int, accepted: list[str], **overrides) -> dict:
    row = {
        "id": version_id, "manual_id": MANUAL, "version_number": number, "source_kind": "pdf",
        "source_locator": f"dashboard-library://Assets/pump-v{number}.pdf", "source_display_name": f"pump-v{number}.pdf",
        "source_sha256": V1_SHA, "mime_type": "application/pdf", "ingestion_status": "extracted",
        "review_status": "pending", "lifecycle_status": "draft", "supersedes_version_id": None,
        "extractor_name": "x", "extractor_version": "1", "provenance": {"accepted_task_ids": accepted},
        "created_by": "dev",
    }
    row.update(overrides)
    return row


def package(tasks: list[dict], versions: list[dict], parts: list[dict] | None = None, children: dict | None = None) -> dict:
    return {
        "format": mp.FORMAT, "format_version": mp.FORMAT_VERSION, "exported_at": NOW.isoformat(),
        "source_database": "dev", "unresolved_task_links": [],
        "columns": {"asset_manual": ["id"], "asset_manual_version": ["id"], "maintenance_tasks": ["id"],
                    "maintenance_task_parts": ["id"]},
        "asset": {"id": ASSET, "name": "Pump", "is_active": True},
        "manual": {"id": MANUAL, "asset_id": ASSET, "document_key": "pump", "title": "Pump manual"},
        "versions": versions, "tasks": tasks, "task_parts": parts or [], "children": children or {},
    }


def target(tasks: list[dict], versions: list[dict], parts: list[dict] | None = None, **overrides) -> dict:
    row = {
        "asset": {"id": ASSET, "name": "Pump", "is_active": True},
        "meter": {"asset_id": ASSET, "meter_type": "runtime_hours", "current_value": 120, "unit": "hours"},
        "manuals": [{"id": MANUAL, "asset_id": ASSET, "document_key": "pump", "title": "Pump manual"}],
        "versions": versions, "tasks": tasks, "task_parts": parts or [], "children": {}, "categories": ["Equipment"],
    }
    row.update(overrides)
    return row


COLUMNS = {name: ["id"] for name in ("asset_manual", "asset_manual_version", "maintenance_tasks", "maintenance_task_parts")}


def plan(pkg: dict, tgt: dict, approved=(), library=None) -> mp.Plan:
    return mp.build_plan(pkg, tgt, target_columns=COLUMNS, now=NOW, approved_deactivations=approved,
                         pdf_sha256=library or (lambda _relative: V1_SHA))


class ManualPackagePlanTests(unittest.TestCase):
    def test_identical_package_plans_no_changes(self) -> None:
        tasks = [task(T_EXISTING, "Filter")]
        versions = [version(V1, 1, [T_EXISTING])]
        result = plan(package(tasks, versions), target(tasks, versions))
        self.assertEqual(result.blockers, [])
        self.assertFalse(result.has_changes)

    def test_new_tasks_get_no_history_and_one_interval_from_now(self) -> None:
        meter_task = task(T_METER, "Oil", schedule_kind="meter", meter_interval_value=50, meter_interval_unit="hours",
                          frequency="Annual", completion_history=[{"x": 1}], last_done="2026-01-01T00:00:00+00:00")
        pkg = package([meter_task, task(T_NEW, "Belt", frequency="Quarterly")], [version(V1, 1, [T_METER, T_NEW])])
        result = plan(pkg, target([], [version(V1, 1, [])]))
        self.assertEqual(result.blockers, [])
        rows = {row["id"]: row for row in result.insert_tasks}
        self.assertEqual(rows[T_METER]["completion_history"], [])
        self.assertIsNone(rows[T_METER]["last_done"])
        self.assertEqual(rows[T_METER]["next_due_meter_value"], "170")
        self.assertTrue(rows[T_NEW]["next_due"].startswith("2027-01-02"))
        self.assertEqual(result.version_links, {V1: sorted([T_METER, T_NEW])})

    def test_meter_task_without_target_meter_is_blocked(self) -> None:
        meter_task = task(T_METER, "Oil", schedule_kind="meter", meter_interval_value=50)
        result = plan(package([meter_task], [version(V1, 1, [T_METER])]), target([], [version(V1, 1, [])], meter=None))
        self.assertTrue(any("no meter reading" in b for b in result.blockers))

    def test_changed_task_updates_definition_only(self) -> None:
        current = task(T_EXISTING, "Filter", notes="owner note", next_due="2026-10-20T00:00:00+00:00",
                       completion_history=[{"done": True}])
        changed = task(T_EXISTING, "Filter", frequency="Quarterly", notes="dev note", task_description="Check it well")
        result = plan(package([changed], [version(V1, 1, [T_EXISTING])]), target([current], [version(V1, 1, [T_EXISTING])]))
        self.assertEqual(result.task_updates, [{"id": T_EXISTING, "frequency": "Quarterly", "task_description": "Check it well"}])
        self.assertTrue(any("kept the target's notes" in line for line in result.sections["Left unchanged"]))

    def test_owner_tasks_and_work_requests_are_never_copied(self) -> None:
        tasks = [task(T_OWNER, "Mine", origin="owner"), task(T_NEW, "Request", kind="Work Request", intake_state="submitted")]
        result = plan(package(tasks, [version(V1, 1, [T_OWNER, T_NEW])]), target([], [version(V1, 1, [])]))
        self.assertEqual(result.insert_tasks, [])
        self.assertFalse(result.has_changes)

    def test_inactive_source_task_needs_approval_to_deactivate(self) -> None:
        current = task(T_RETIRED, "Old")
        retired = task(T_RETIRED, "Old", is_active=False)
        args = (package([retired], [version(V1, 1, [T_RETIRED])]), target([current], [version(V1, 1, [T_RETIRED])]))
        pending = plan(*args)
        self.assertEqual((pending.removal_candidates, pending.deactivate), ([T_RETIRED], []))
        approved = plan(*args, approved=[T_RETIRED])
        self.assertEqual(approved.deactivate, [T_RETIRED])

    def test_unknown_deactivation_approval_blocks(self) -> None:
        tasks = [task(T_EXISTING, "Filter")]
        result = plan(package(tasks, [version(V1, 1, [T_EXISTING])]), target(tasks, [version(V1, 1, [T_EXISTING])]),
                      approved=[T_NEW])
        self.assertTrue(any(T_NEW in b for b in result.blockers))

    def test_name_clash_and_inactive_asset_block(self) -> None:
        clash = task(T_EXISTING, "Belt", origin="owner")
        result = plan(package([task(T_NEW, "Belt")], [version(V1, 1, [T_NEW])]),
                      target([clash], [version(V1, 1, [])], asset={"id": ASSET, "name": "Pump", "is_active": False}))
        self.assertTrue(any("already uses this area and item" in b for b in result.blockers))
        self.assertTrue(any("deactivated" in b for b in result.blockers))

    def test_new_version_requires_matching_pdf_in_library(self) -> None:
        pkg = package([], [version(V1, 1, []), version(V2, 2, [], supersedes_version_id=V1)])
        missing = plan(pkg, target([], [version(V1, 1, [])]), library=lambda _relative: None)
        self.assertTrue(any("not found" in b for b in missing.blockers))
        wrong = plan(pkg, target([], [version(V1, 1, [])]), library=lambda _relative: "b" * 64)
        self.assertTrue(any("different checksum" in b for b in wrong.blockers))
        ok = plan(pkg, target([], [version(V1, 1, [])]))
        self.assertEqual([v["id"] for v in ok.insert_versions], [V2])

    def test_existing_version_with_other_checksum_blocks(self) -> None:
        result = plan(package([], [version(V1, 1, [])]), target([], [version(V1, 1, [], source_sha256="c" * 64)]))
        self.assertTrue(any("different manual or PDF checksum" in b for b in result.blockers))

    def test_target_only_parts_are_kept_and_changed_parts_updated(self) -> None:
        tasks = [task(T_EXISTING, "Filter")]
        source_parts = [{"id": P_EXISTING, "task_id": T_EXISTING, "name": "Filter", "quantity": 2, "provenance": "maintenance"}]
        target_parts = [
            {"id": P_EXISTING, "task_id": T_EXISTING, "name": "Filter", "quantity": 1, "provenance": "maintenance"},
            {"id": P_NEW, "task_id": T_EXISTING, "name": "Owner gasket", "quantity": 1, "provenance": "maintenance"},
        ]
        result = plan(package(tasks, [version(V1, 1, [T_EXISTING])], source_parts),
                      target(tasks, [version(V1, 1, [T_EXISTING])], target_parts))
        self.assertEqual(result.part_updates, [{"id": P_EXISTING, "task_id": T_EXISTING, "quantity": 2}])
        self.assertTrue(any("Owner gasket" in line for line in result.sections["Left unchanged"]))


IMAGE = "pgvector/pgvector:pg16"
MIGRATION_DIR = Path(__file__).resolve().parents[1] / "db"
PRODUCTION_MIGRATIONS = (
    "001_initial_schema.sql", "002_rich_task_model.sql", "003_part_quantity.sql", "004_task_origin.sql",
    "005_assets_and_meters.sql", "006_phase1_meter_audit.sql", "009_maintenance_proposals.sql",
    "010_handbook_ingestion_v1.sql", "011_work_request_intake.sql", "012_dev_schema_forward_repair.sql",
)
BASE_SEED = f"""
INSERT INTO propertymanager.maintenance_categories (id, name, icon, color_name)
VALUES (gen_random_uuid(), 'Equipment', 'wrench', 'blue') ON CONFLICT (name) DO NOTHING;
INSERT INTO propertymanager.assets (id, external_id, name, qr_token) VALUES ('{ASSET}', 'pump-1', 'Pump', 'qr-pump');
INSERT INTO propertymanager.asset_manual (id, asset_id, document_key, title, document_type, created_by)
VALUES ('{MANUAL}', '{ASSET}', 'pump', 'Pump manual', 'operator_manual', 'dev');
INSERT INTO propertymanager.asset_manual_version
    (id, manual_id, version_number, source_kind, source_locator, source_display_name, source_sha256, mime_type,
     ingestion_status, review_status, lifecycle_status, provenance, created_by)
VALUES ('{V1}', '{MANUAL}', 1, 'pdf', 'dashboard-library://Assets/pump-v1.pdf', 'pump-v1.pdf', '{V1_SHA}',
        'application/pdf', 'extracted', 'pending', 'draft', '{{"accepted_task_ids": ["{T_EXISTING}", "{T_RETIRED}"]}}', 'dev');
INSERT INTO propertymanager.maintenance_tasks
    (id, area, item, category_name, frequency, task_description, warning_days, critical_days, next_due, origin, asset_id)
VALUES ('{T_EXISTING}', 'Pump house', 'Filter', 'Equipment', 'Monthly', 'Check filter', 7, 0, '2026-10-20', 'manufacturer', '{ASSET}'),
       ('{T_RETIRED}', 'Pump house', 'Old check', 'Equipment', 'Monthly', 'Old', 7, 0, '2026-10-21', 'manufacturer', '{ASSET}'),
       ('{T_OWNER}', 'Pump house', 'Owner check', 'Equipment', 'Weekly', 'Mine', 3, 0, '2026-10-05', 'owner', '{ASSET}');
INSERT INTO propertymanager.maintenance_task_parts (id, task_id, name, quantity, provenance)
VALUES ('{P_EXISTING}', '{T_EXISTING}', 'Filter cartridge', 1, 'maintenance');
"""


class ManualPackageRoundTripTests(unittest.TestCase):
    """Export from a source database and apply to a target database, both at the Production schema."""

    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("docker") is None:
            raise unittest.SkipTest("Docker is required for the manual package round trip")
        if subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True).returncode != 0:
            raise unittest.SkipTest(f"{IMAGE} is not available locally")
        token = uuid.uuid4().hex[:12]
        cls.user = f"pm_pkg_{token}"
        cls.container = subprocess.run(
            ["docker", "run", "--detach", "--rm", "--pull=never", "--name", f"openclaw-pm-package-test-{token}",
             "--label", "ai.openclaw.test=propertymanager-manual-package", "--env", "POSTGRES_HOST_AUTH_METHOD=trust",
             "--env", f"POSTGRES_USER={cls.user}", "--env", "POSTGRES_DB=source", IMAGE],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        try:
            # The image runs a temporary server during initdb, then restarts; wait for the final one.
            deadline = time.monotonic() + 60
            while True:
                logs = subprocess.run(["docker", "logs", cls.container], capture_output=True, text=True)
                ready = subprocess.run(["docker", "exec", cls.container, "pg_isready", "-U", cls.user, "-d", "source"],
                                       capture_output=True)
                if "init process complete" in logs.stdout + logs.stderr and ready.returncode == 0:
                    break
                if time.monotonic() > deadline:
                    raise AssertionError("PostgreSQL did not become ready")
                time.sleep(0.5)
            subprocess.run(["docker", "exec", cls.container, "createdb", "-U", cls.user, "target"], check=True,
                           capture_output=True)
            cls.source = mp.Psql(cls.container, cls.user, "source")
            cls.target = mp.Psql(cls.container, cls.user, "target")
        except BaseException:
            subprocess.run(["docker", "rm", "--force", cls.container], capture_output=True)
            raise

    @classmethod
    def tearDownClass(cls) -> None:
        subprocess.run(["docker", "rm", "--force", cls.container], capture_output=True)

    def setUp(self) -> None:
        self.library = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.library)
        pdf = b"%PDF-1.7\nrevision two\n"
        (self.library / "Assets").mkdir()
        (self.library / "Assets" / "pump-v2.pdf").write_bytes(pdf)
        v2_sha = hashlib.sha256(pdf).hexdigest()
        reset = "DROP SCHEMA IF EXISTS propertymanager CASCADE;\n" + "\n".join(
            (MIGRATION_DIR / f).read_text() for f in PRODUCTION_MIGRATIONS
        )
        for db in (self.source, self.target):
            db.run(reset)
            db.run(BASE_SEED)
        self.target.run(f"""
            INSERT INTO propertymanager.asset_meter (asset_id, meter_type, current_value, unit)
            VALUES ('{ASSET}', 'runtime_hours', 120, 'hours');
            UPDATE propertymanager.maintenance_tasks
               SET last_done = '2026-09-20', completion_history = '[{{"completed_at": "2026-09-20"}}]', notes = 'owner note'
             WHERE id = '{T_EXISTING}';
            INSERT INTO propertymanager.maintenance_completions (id, task_id, completed_at)
            VALUES (gen_random_uuid(), '{T_EXISTING}', '2026-09-20');
        """)
        self.source.run(f"""
            INSERT INTO propertymanager.asset_meter (asset_id, meter_type, current_value, unit)
            VALUES ('{ASSET}', 'runtime_hours', 500, 'hours');
            UPDATE propertymanager.maintenance_tasks SET frequency = 'Quarterly', notes = 'dev note' WHERE id = '{T_EXISTING}';
            UPDATE propertymanager.maintenance_tasks SET is_active = false WHERE id = '{T_RETIRED}';
            UPDATE propertymanager.maintenance_task_parts SET quantity = 2 WHERE id = '{P_EXISTING}';
            INSERT INTO propertymanager.maintenance_task_parts (id, task_id, name, quantity, provenance)
            VALUES ('{P_NEW}', '{T_EXISTING}', 'O-ring', 1, 'maintenance');
            UPDATE propertymanager.asset_manual_version
               SET provenance = '{{"accepted_task_ids": ["{T_EXISTING}", "{T_RETIRED}", "{T_OWNER}"]}}' WHERE id = '{V1}';
            INSERT INTO propertymanager.maintenance_tasks
                (id, area, item, category_name, frequency, task_description, warning_days, critical_days, next_due,
                 origin, asset_id, schedule_kind, meter_interval_value, meter_interval_unit, completion_history, last_done)
            VALUES ('{T_METER}', 'Pump house', 'Oil change', 'Equipment', 'Annual', 'Change oil', 14, 0, '2026-05-01',
                    'manufacturer', '{ASSET}', 'meter', 50, 'hours', '[{{"completed_at": "2026-04-01"}}]', '2026-04-01'),
                   ('{T_NEW}', 'Pump house', 'Belt check', 'Equipment', 'Quarterly', 'Check belt', 7, 0, '2026-05-01',
                    'manufacturer', '{ASSET}', 'calendar', NULL, NULL, '[]', NULL);
            INSERT INTO propertymanager.asset_manual_version
                (id, manual_id, version_number, source_kind, source_locator, source_display_name, source_sha256, mime_type,
                 ingestion_status, review_status, lifecycle_status, supersedes_version_id, provenance, created_by)
            VALUES ('{V2}', '{MANUAL}', 2, 'pdf', 'dashboard-library://Assets/pump-v2.pdf', 'pump-v2.pdf', '{v2_sha}',
                    'application/pdf', 'extracted', 'pending', 'draft', '{V1}',
                    '{{"accepted_task_ids": ["{T_METER}", "{T_NEW}"]}}', 'dev');
            INSERT INTO propertymanager.asset_manual_chunk (id, manual_version_id, chunk_ordinal, content, content_sha256)
            VALUES ('{CHUNK}', '{V2}', 0, 'Change the oil every 50 hours.', '{"d" * 64}');
            INSERT INTO propertymanager.asset_manual_state_event (id, manual_version_id, event_type, to_state, actor_id)
            VALUES ('{EVENT}', '{V2}', 'ingestion_extracted', '{{"ingestion_status": "extracted"}}', 'dev');
        """)

    def query(self, sql: str) -> object:
        return self.target.read_json(sql)

    def target_state(self) -> object:
        return self.query(
            "SELECT jsonb_build_object("
            "'tasks', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM propertymanager.maintenance_tasks t), "
            "'parts', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM propertymanager.maintenance_task_parts p), "
            "'versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.id) FROM propertymanager.asset_manual_version v), "
            "'chunks', (SELECT count(*) FROM propertymanager.asset_manual_chunk), "
            "'completions', (SELECT count(*) FROM propertymanager.maintenance_completions))"
        )

    def apply(self, pkg: dict, *, commit: bool, approved=()) -> mp.Prepared:
        prepared = mp.prepare_apply(self.target, pkg, library_root=self.library, approved_deactivations=approved,
                                    commit=commit, now=NOW)
        self.assertEqual(prepared.plan.blockers, [])
        if prepared.script is not None:
            mp.execute(self.target, prepared)
        return prepared

    def test_round_trip(self) -> None:
        pkg = json.loads(json.dumps(mp.export_package(self.source, MANUAL, now=NOW), default=str))
        self.assertEqual(len(pkg["versions"]), 2)
        before = self.target_state()

        dry = self.apply(pkg, commit=False)
        self.assertTrue(dry.plan.has_changes)
        self.assertEqual(self.target_state(), before)

        committed = self.apply(pkg, commit=True)
        self.assertEqual(committed.plan.removal_candidates, [T_RETIRED])
        tasks = {t["id"]: t for t in self.query(
            "SELECT jsonb_agg(to_jsonb(t)) FROM propertymanager.maintenance_tasks t")}
        self.assertEqual(tasks[T_METER]["completion_history"], [])
        self.assertIsNone(tasks[T_METER]["last_done"])
        self.assertEqual(float(tasks[T_METER]["next_due_meter_value"]), 170.0)
        self.assertTrue(tasks[T_NEW]["next_due"].startswith("2027-01-02"))
        existing = tasks[T_EXISTING]
        self.assertEqual(existing["frequency"], "Quarterly")
        self.assertEqual(existing["notes"], "owner note")
        self.assertEqual(existing["completion_history"], [{"completed_at": "2026-09-20"}])
        self.assertTrue(existing["next_due"].startswith("2026-10-20"))
        self.assertTrue(tasks[T_RETIRED]["is_active"])
        self.assertEqual(self.query("SELECT count(*) FROM propertymanager.maintenance_completions"), 1)
        parts = {p["id"]: p for p in self.query("SELECT jsonb_agg(to_jsonb(p)) FROM propertymanager.maintenance_task_parts p")}
        self.assertEqual(float(parts[P_EXISTING]["quantity"]), 2.0)
        self.assertIn(P_NEW, parts)
        versions = {v["id"]: v for v in self.query("SELECT jsonb_agg(to_jsonb(v)) FROM propertymanager.asset_manual_version v")}
        self.assertEqual(sorted(versions[V1]["provenance"]["accepted_task_ids"]), sorted([T_EXISTING, T_RETIRED]))
        self.assertEqual(sorted(versions[V2]["provenance"]["accepted_task_ids"]), sorted([T_METER, T_NEW]))
        self.assertEqual(self.query("SELECT count(*) FROM propertymanager.asset_manual_chunk"), 1)
        self.assertEqual(self.query("SELECT count(*) FROM propertymanager.asset_manual_state_event"), 1)

        approved = self.apply(pkg, commit=True, approved=[T_RETIRED])
        self.assertEqual(approved.plan.deactivate, [T_RETIRED])
        self.assertFalse(approved.plan.insert_tasks or approved.plan.task_updates or approved.plan.insert_parts)
        self.assertFalse(self.query(
            f"SELECT to_jsonb(is_active) FROM propertymanager.maintenance_tasks WHERE id = '{T_RETIRED}'"))

        again = mp.prepare_apply(self.target, pkg, library_root=self.library, now=NOW)
        self.assertEqual(again.plan.blockers, [])
        self.assertIsNone(again.script)

    def test_target_change_after_planning_writes_nothing(self) -> None:
        pkg = json.loads(json.dumps(mp.export_package(self.source, MANUAL, now=NOW), default=str))
        prepared = mp.prepare_apply(self.target, pkg, library_root=self.library, commit=True, now=NOW)
        self.target.run(f"UPDATE propertymanager.maintenance_tasks SET notes = 'edited meanwhile' WHERE id = '{T_EXISTING}';")
        before = self.target_state()
        with self.assertRaisesRegex(mp.PackageError, "target changed"):
            mp.execute(self.target, prepared)
        self.assertEqual(self.target_state(), before)


if __name__ == "__main__":
    unittest.main()
