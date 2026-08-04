#!/usr/bin/env python3
"""Adversarial tests for the audit-only migration authority verifier."""

from __future__ import annotations

import ast
import copy
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.property_manager.db import migration_authority as authority

REPO_ROOT = Path(__file__).resolve().parents[3]
DB_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
MANIFEST_PATH = DB_DIR / "migration_authority.json"
API_DIR = REPO_ROOT / "tools" / "property_manager" / "api"
APPROVED_HASHES = {
    "001_initial_schema.sql": "11b4427e5115cb159b1b48e0a2886ef1e9e04575f7455c26e2e4ba068021d84f",
    "002_rich_task_model.sql": "a60c5e604bc42d5331c2b77819e3976588d76b99ae25880eb8c85114f59d8ec2",
    "003_part_quantity.sql": "49365ba4d30ff4543ad3a48a9aa3a0b430aebb300c3d67e568c6a679bb218147",
    "004_task_origin.sql": "1e9a03e9cc383928c992638685df922a3bc6a28a4a54a8a8f18b98be0da6c40c",
    "005_assets_and_meters.sql": "f90a39cdc6234d72a431d4caba23720d98aa7b4dff1a83f15845ecb936ff0147",
    "006_phase1_meter_audit.sql": "3d5c09888b0ae9a4898a7497bf01bf2a46ccddbaf3236e94c804b5cf6cb521a0",
}
APPROVED_CONTRACT_HASH = "f3fac5c764d65f2f01d155461b3447e79b7128c7b1f93cda56600d27bfdc11d4"
APPROVED_TABLES = (
    "asset_meter",
    "asset_meter_reading",
    "asset_task_mapping_proposals",
    "assets",
    "maintenance_categories",
    "maintenance_completions",
    "maintenance_task_parts",
    "maintenance_task_photos",
    "maintenance_tasks",
)


class FixtureMetadataSource:
    def __init__(self, metadata):
        self.metadata = metadata
        self.calls = 0

    def inspect_read_only(self):
        self.calls += 1
        return copy.deepcopy(self.metadata)


class AuthorityFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-authority-")
        self.root = Path(self.temporary.name)
        self.db = self.root / "db"
        self.db.mkdir()
        shutil.copy2(MANIFEST_PATH, self.db / MANIFEST_PATH.name)
        for filename in APPROVED_HASHES:
            shutil.copy2(DB_DIR / filename, self.db / filename)
        self.manifest_path = self.db / MANIFEST_PATH.name
        self.manifest = authority._load_manifest_at(self.manifest_path)
        self.identity = authority.ExpectedIdentity("isolated_fixture", "unit-test")

    def tearDown(self):
        self.temporary.cleanup()

    def file_audit(self):
        return authority._audit_migration_files_at(self.db, self.manifest_path)

    def metadata(self, *, ledger_state="absent"):
        entries = []
        if ledger_state == "present":
            entries = [
                {
                    "order": spec.order,
                    "version": spec.version,
                    "filename": spec.filename,
                    "sha256": spec.sha256,
                }
                for spec in self.manifest.canonical
            ]
        return {
            "declared_version": "006",
            "concurrent_migration_activity": False,
            "unexplained_schema_objects": False,
            "identity": {
                "database_name": self.identity.database_name,
                "environment": self.identity.environment,
            },
            "ledger": {"state": ledger_state, "entries": entries},
            "schema": copy.deepcopy(self.manifest.schema_contract),
        }

    def snapshot(self, metadata):
        return authority._audit_supplied_metadata(metadata, self.identity, self.manifest)


class ManifestFingerprintTests(AuthorityFixture):
    def test_manifest_has_independently_pinned_contract_and_migrations(self):
        raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        encoded = json.dumps(raw["schema_contract"], sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), APPROVED_CONTRACT_HASH)
        self.assertEqual(
            {item["filename"]: item["sha256"] for item in raw["canonical_migrations"]},
            APPROVED_HASHES,
        )
        contract = raw["schema_contract"]
        self.assertEqual(tuple(contract["tables"]), APPROVED_TABLES)
        self.assertEqual(sum(len(item["columns"]) for item in contract["tables"].values()), 124)
        self.assertEqual(sum(len(item["constraints"]) for item in contract["tables"].values()), 32)
        self.assertEqual(sum(len(item["indexes"]) for item in contract["tables"].values()), 25)
        migration_created_indexes = {
            "maintenance_task_parts_task_id_idx", "maintenance_task_photos_task_id_idx",
            "assets_external_id_idx", "assets_qr_token_idx", "assets_name_lower_idx",
            "asset_meter_reading_asset_id_reading_at_idx", "maintenance_tasks_asset_id_idx",
            "asset_meter_reading_idempotency_idx", "asset_meter_reading_asset_epoch_reading_at_idx",
            "asset_meter_reading_status_idx", "asset_task_mapping_proposals_status_idx",
            "asset_task_mapping_proposals_task_asset_pending_idx",
        }
        all_indexes = {
            index["name"]
            for table in contract["tables"].values()
            for index in table["indexes"]
        }
        self.assertTrue(migration_created_indexes <= all_indexes)
        self.assertEqual(len(contract["canonical_data"]["maintenance_categories"]["rows"]), 8)

    def test_every_fingerprinted_property_is_required(self):
        base = self.metadata()
        samples = (
            ("columns", "type", "bogus"),
            ("columns", "nullable", None),
            ("columns", "default", "bogus"),
            ("columns", "precision", 999),
            ("columns", "scale", 999),
            ("columns", "generated", "bogus"),
            ("constraints", "definition", "bogus"),
            ("constraints", "on_update", "CASCADE"),
            ("constraints", "on_delete", "RESTRICT"),
            ("indexes", "unique", None),
            ("indexes", "method", "hash"),
            ("indexes", "keys", []),
            ("indexes", "predicate", "bogus"),
        )
        table = "asset_meter_reading"
        for collection, property_name, value in samples:
            with self.subTest(collection=collection, property=property_name):
                metadata = copy.deepcopy(base)
                candidates = metadata["schema"]["tables"][table][collection]
                candidate = next(
                    item for item in candidates
                    if property_name in item and item[property_name] != value
                )
                candidate[property_name] = value
                self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)

    def test_missing_and_extra_schema_objects_fail_closed(self):
        cases = []
        missing_table = self.metadata()
        del missing_table["schema"]["tables"]["assets"]
        cases.append((missing_table, authority.AuditStatus.SNAPSHOT_PARTIAL))
        extra_table = self.metadata()
        extra_table["schema"]["tables"]["later_table"] = {"columns": [], "constraints": [], "indexes": []}
        cases.append((extra_table, authority.AuditStatus.SNAPSHOT_LATER))
        for collection in ("columns", "constraints", "indexes"):
            missing = self.metadata()
            missing["schema"]["tables"]["assets"][collection].pop()
            cases.append((missing, authority.AuditStatus.SNAPSHOT_PARTIAL))
            extra = self.metadata()
            prototype = copy.deepcopy(extra["schema"]["tables"]["assets"][collection][0])
            prototype["name"] = "later_object"
            extra["schema"]["tables"]["assets"][collection].append(prototype)
            cases.append((extra, authority.AuditStatus.SNAPSHOT_LATER))
        for metadata, status in cases:
            with self.subTest(status=status):
                self.assertEqual(self.snapshot(metadata).status, status)

    def test_seeded_canonical_data_is_exact(self):
        missing = self.metadata()
        missing["schema"]["canonical_data"]["maintenance_categories"]["rows"].pop()
        changed = self.metadata()
        changed["schema"]["canonical_data"]["maintenance_categories"]["rows"][0][1] = "Other"
        self.assertEqual(self.snapshot(missing).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)
        self.assertEqual(self.snapshot(changed).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)

    def test_incomplete_manifest_fingerprints_are_rejected(self):
        for collection, property_name in (("columns", "nullable"), ("constraints", "on_delete"), ("indexes", "predicate")):
            raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
            del raw["schema_contract"]["tables"]["asset_meter_reading"][collection][0][property_name]
            path = self.root / f"incomplete-{collection}.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            with self.subTest(collection=collection), self.assertRaises(authority.AuthorityConfigurationError):
                authority._load_manifest_at(path)


class FilesystemAuthorityTests(AuthorityFixture):
    def assert_invalid(self, result):
        self.assertFalse(result.ok)
        self.assertIn(result.status, {authority.AuditStatus.MIGRATION_FILES_INVALID, authority.AuditStatus.AUTHORITY_UNAVAILABLE})
        self.assertNotIn(str(self.root), result.human_report())
        self.assertNotIn(str(self.root), result.machine_report())

    def test_private_fixture_helper_and_canonical_production_audit(self):
        self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)
        self.assertEqual(authority.audit_canonical_migration_files().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)

    def test_cli_refuses_authority_path_overrides(self):
        for option in ("--manifest", "--migration-dir"):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                authority._parser().parse_args([option, str(self.root)])

    def test_each_checksum_is_enforced(self):
        for filename in APPROVED_HASHES:
            with self.subTest(filename=filename):
                path = self.db / filename
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                try:
                    self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_INVALID)
                finally:
                    path.write_bytes(original)

    def test_missing_renamed_duplicate_and_later_files_are_rejected(self):
        missing = self.db / "002_rich_task_model.sql"
        original = missing.read_bytes()
        missing.unlink()
        self.assert_invalid(self.file_audit())
        missing.write_bytes(original)
        renamed = self.db / "002_other.sql"
        shutil.copy2(missing, renamed)
        self.assert_invalid(self.file_audit())
        renamed.unlink()
        for name in ("007_future.sql", "008_future.sql", "009_future.sql"):
            path = self.db / name
            path.write_text("SELECT 1;", encoding="utf-8")
            self.assert_invalid(self.file_audit())
            path.unlink()

    def test_symlinked_manifest_directory_and_file_are_rejected(self):
        real_manifest = self.root / "real.json"
        shutil.copy2(self.manifest_path, real_manifest)
        self.manifest_path.unlink()
        self.manifest_path.symlink_to(real_manifest)
        self.assert_invalid(self.file_audit())
        self.manifest_path.unlink()
        shutil.copy2(real_manifest, self.manifest_path)
        real_file = self.db / "real.sql"
        target = self.db / "001_initial_schema.sql"
        target.rename(real_file)
        target.symlink_to(real_file)
        self.assert_invalid(self.file_audit())
        target.unlink()
        real_file.rename(target)
        linked_dir = self.root / "linked-db"
        linked_dir.symlink_to(self.db, target_is_directory=True)
        self.assert_invalid(authority._audit_migration_files_at(linked_dir, self.manifest_path))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO unavailable")
    def test_fifo_is_rejected_without_opening(self):
        fifo = self.db / "007_fifo.sql"
        os.mkfifo(fifo)
        self.assert_invalid(self.file_audit())

    def test_nested_case_varied_and_alternate_numeric_forms_are_rejected(self):
        names = ("001_UPPER.SQL", "1_initial.sql", "01_initial.sql", "0001_initial.sql")
        for name in names:
            with self.subTest(name=name):
                path = self.db / name
                path.write_text("SELECT 1;", encoding="utf-8")
                self.assert_invalid(self.file_audit())
                path.unlink()
        nested = self.db / "nested"
        nested.mkdir()
        (nested / "010_nested.sql").write_text("SELECT 1;", encoding="utf-8")
        self.assert_invalid(self.file_audit())

    def test_nonregular_directory_masquerading_as_migration_is_rejected(self):
        (self.db / "007_directory.sql").mkdir()
        self.assert_invalid(self.file_audit())

    def test_discovery_read_and_permission_failures_are_sanitized(self):
        with mock.patch.object(authority.os, "scandir", side_effect=PermissionError("/secret/path token=abc")):
            result = self.file_audit()
        self.assert_invalid(result)
        with mock.patch.object(authority, "_read_regular_file", side_effect=PermissionError("/secret/file")):
            result = self.file_audit()
        self.assert_invalid(result)
        target = self.db / "001_initial_schema.sql"
        mode = stat.S_IMODE(target.stat().st_mode)
        target.chmod(0)
        try:
            result = self.file_audit()
            if os.geteuid() != 0:
                self.assert_invalid(result)
        finally:
            target.chmod(mode)

    def test_replacement_during_read_fails_closed(self):
        target = self.db / "001_initial_schema.sql"
        def alter():
            target.write_bytes(target.read_bytes() + b"\n")
        with self.assertRaises(OSError):
            authority._read_regular_file(target, _post_read=alter)


class MetadataAndLedgerTests(AuthorityFixture):
    def test_only_consistent_snapshot_succeeds_and_identity_stays_unproven(self):
        result = self.snapshot(self.metadata())
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_CONSISTENT)
        self.assertTrue(result.ok)
        self.assertEqual(result.identity_assurance, "unproven")
        self.assertNotIn("database_verified", result.machine_report())

    def test_missing_or_malformed_declared_version_fails(self):
        for value in (None, 6, "unknown", ""):
            metadata = self.metadata()
            if value is None:
                metadata.pop("declared_version")
            else:
                metadata["declared_version"] = value
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        lower, higher = self.metadata(), self.metadata()
        lower["declared_version"], higher["declared_version"] = "005", "009"
        self.assertEqual(self.snapshot(lower).status, authority.AuditStatus.SNAPSHOT_PARTIAL)
        self.assertEqual(self.snapshot(higher).status, authority.AuditStatus.SNAPSHOT_LATER)

    def test_concurrency_and_unexplained_state_are_explicit_booleans(self):
        for field in ("concurrent_migration_activity", "unexplained_schema_objects"):
            for value in (None, "false", 0, True):
                metadata = self.metadata()
                if value is None:
                    metadata.pop(field)
                else:
                    metadata[field] = value
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)

    def test_identity_is_exact_nonempty_and_cannot_self_certify(self):
        mutations = (
            ("database_name", ""), ("database_name", "unknown"),
            ("environment", " "), ("environment", "unit-test\nforged: yes"),
        )
        for field, value in mutations:
            metadata = self.metadata()
            metadata["identity"][field] = value
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)
        for key in ("proven", "identity_proven", "verified"):
            metadata = self.metadata()
            metadata["identity"][key] = True
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)

    def test_incomplete_metadata_cannot_claim_verification(self):
        metadata = {"identity": {"database_name": "isolated_fixture", "environment": "unit-test"}}
        result = self.snapshot(metadata)
        self.assertFalse(result.ok)
        self.assertNotEqual(result.status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)

    def test_present_ledger_requires_exact_order_filename_and_checksum(self):
        valid = self.metadata(ledger_state="present")
        self.assertEqual(self.snapshot(valid).status, authority.AuditStatus.SNAPSHOT_CONSISTENT)
        mutations = []
        filename = copy.deepcopy(valid)
        filename["ledger"]["entries"][0]["filename"] = "001_other.sql"
        mutations.append(filename)
        order = copy.deepcopy(valid)
        order["ledger"]["entries"][0], order["ledger"]["entries"][1] = order["ledger"]["entries"][1], order["ledger"]["entries"][0]
        mutations.append(order)
        duplicate = copy.deepcopy(valid)
        duplicate["ledger"]["entries"][1] = copy.deepcopy(duplicate["ledger"]["entries"][0])
        mutations.append(duplicate)
        missing = copy.deepcopy(valid)
        missing["ledger"]["entries"].pop()
        mutations.append(missing)
        checksum = copy.deepcopy(valid)
        checksum["ledger"]["entries"][0]["sha256"] = "0" * 64
        mutations.append(checksum)
        for metadata in mutations:
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.LEDGER_INCONSISTENT)
        later = copy.deepcopy(valid)
        later["ledger"]["entries"].append({"order": 7, "version": "009", "filename": "009.sql", "sha256": "0" * 64})
        self.assertEqual(self.snapshot(later).status, authority.AuditStatus.SNAPSHOT_LATER)

    def test_ledger_state_is_explicit(self):
        for ledger in (None, {}, {"state": "unknown", "entries": []}, {"state": "absent", "entries": [{}]}):
            metadata = self.metadata()
            metadata["ledger"] = ledger
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.LEDGER_INCONSISTENT)

    def test_metadata_source_exception_is_generic_and_untrusted(self):
        source = mock.Mock()
        source.inspect_read_only.side_effect = RuntimeError("postgres://user:secret@host/db /private/file")
        with mock.patch.object(authority, "load_manifest", return_value=self.manifest), mock.patch.object(
            authority, "audit_canonical_migration_files", return_value=authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest)
        ):
            result = authority.audit_schema_metadata(source, self.identity)
        self.assertEqual(result.status, authority.AuditStatus.AUTHORITY_UNAVAILABLE)
        self.assertNotIn("secret", result.human_report())
        self.assertNotIn("private", result.machine_report())


class RedactionAndStatusTests(unittest.TestCase):
    def test_recursive_redaction_and_single_line_safety(self):
        payload = {
            "list": [{"api-key": "abc"}, "Authorization: Bearer token123"],
            "tuple": ("password=one user=two passphrase=three",),
            "set": {"token=four", "safe"},
            "url": "postgresql://name:p%40ss@host/db?api_key=five&user=six",
            "path": "/private/secret/file\nforged: yes",
        }
        result = authority.redact_value(payload)
        encoded = json.dumps(result, sort_keys=True)
        for secret in ("abc", "token123", "one", "two", "three", "four", "p%40ss", "five", "six", "/private/secret"):
            self.assertNotIn(secret, encoded)
        self.assertNotIn("\n", result["path"])
        self.assertIn("[REDACTED_URL]", result["url"])

    def test_reports_are_deterministic_versioned_and_status_cannot_conflict(self):
        result = authority.AuditResult(
            authority.AuditStatus.MIGRATION_FILES_VERIFIED,
            ("001",), ("007",), "009",
            (authority.Diagnostic("safe", "token=secret\nforged"),),
        )
        self.assertTrue(result.ok)
        self.assertEqual(result.machine_report(), result.machine_report())
        self.assertEqual(result.human_report(), result.human_report())
        self.assertEqual(json.loads(result.machine_report())["format_version"], 1)
        self.assertNotIn("secret", result.machine_report())
        self.assertNotIn("\nforged", result.human_report())
        with self.assertRaises(TypeError):
            authority.AuditResult("migration_files_verified", (), (), "009")
        with self.assertRaises(TypeError):
            authority.AuditResult(authority.AuditStatus.MIGRATION_FILES_INVALID, (), (), "009", ok=True)


class IntegrationSafetyTests(unittest.TestCase):
    def test_mutation_actions_remain_rejected(self):
        for action in ("apply", "migrate", "baseline", "bootstrap", "repair", "write", "other"):
            with self.assertRaises(authority.MutationForbiddenError):
                authority.reject_mutation(action)
        authority.reject_mutation("audit")

    def test_production_module_has_no_mutating_dependencies_or_sql(self):
        source = Path(authority.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = {
            alias.name.split(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        } | {
            (node.module or "").split(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom)
        }
        self.assertTrue(imports.isdisjoint({"subprocess", "socket", "urllib", "requests", "docker", "psycopg2", "sqlalchemy"}))
        self.assertNotIn("CREATE TABLE", source.upper())
        self.assertNotIn("ALTER TABLE", source.upper())

    def test_actual_api_and_wsgi_imports_do_not_invoke_verifier(self):
        dangerous = mock.Mock(side_effect=AssertionError("verifier invoked during startup"))
        old_path = list(sys.path)
        module_names = (
            "propertymanager_api", "wsgi", "db", "meter_schedule", "assets_api", "auth",
            "decimal_utils", "errors", "mapping_proposals",
        )
        saved = {name: sys.modules.pop(name) for name in module_names if name in sys.modules}
        try:
            sys.path.insert(0, str(API_DIR))
            with tempfile.TemporaryDirectory(prefix="pm-import-") as temp, mock.patch.dict(
                os.environ,
                {"PROPERTYMANAGER_DB_ENV_FILE": str(Path(temp) / "missing.env"), "PROPERTYMANAGER_AUTH_DISABLED": "1"},
                clear=False,
            ), mock.patch.object(authority, "main", dangerous), mock.patch.object(
                authority, "audit_canonical_migration_files", dangerous
            ), mock.patch.object(authority, "audit_schema_metadata", dangerous):
                api_spec = importlib.util.spec_from_file_location("propertymanager_api", API_DIR / "propertymanager_api.py")
                assert api_spec and api_spec.loader
                api_module = importlib.util.module_from_spec(api_spec)
                sys.modules["propertymanager_api"] = api_module
                api_spec.loader.exec_module(api_module)
                wsgi_spec = importlib.util.spec_from_file_location("wsgi", API_DIR / "wsgi.py")
                assert wsgi_spec and wsgi_spec.loader
                wsgi_module = importlib.util.module_from_spec(wsgi_spec)
                wsgi_spec.loader.exec_module(wsgi_module)
                self.assertIs(wsgi_module.application, api_module.app)
                dangerous.assert_not_called()
        finally:
            sys.path[:] = old_path
            for name in module_names:
                sys.modules.pop(name, None)
            sys.modules.update(saved)


if __name__ == "__main__":
    unittest.main()
