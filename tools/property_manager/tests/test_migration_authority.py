#!/usr/bin/env python3
"""Focused tests for the audit-only PropertyManager migration verifier."""

from __future__ import annotations

import ast
import copy
import importlib
import inspect
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.property_manager.db import migration_authority as authority

REPO_ROOT = Path(__file__).resolve().parents[3]
CANONICAL_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
CANONICAL_MANIFEST = CANONICAL_DIR / "migration_authority.json"


class FixtureMetadataSource:
    def __init__(self, metadata):
        self.metadata = metadata
        self.calls = 0

    def inspect_read_only(self):
        self.calls += 1
        return copy.deepcopy(self.metadata)


class MigrationAuthorityTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="pm-authority-")
        self.root = Path(self.temp_dir.name)
        self.migration_dir = self.root / "db"
        self.migration_dir.mkdir()
        self.manifest_path = self.migration_dir / "migration_authority.json"
        shutil.copy2(CANONICAL_MANIFEST, self.manifest_path)
        manifest = authority.load_manifest(CANONICAL_MANIFEST)
        for spec in manifest.canonical:
            shutil.copy2(CANONICAL_DIR / spec.filename, self.migration_dir / spec.filename)
        self.manifest = authority.load_manifest(self.manifest_path)
        self.expected_identity = authority.ExpectedIdentity("pm_fixture", "isolated-test")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def valid_metadata(self, *, include_ledger: bool = False):
        metadata = {
            "identity": {
                "proven": True,
                "database_name": self.expected_identity.database_name,
                "environment": self.expected_identity.environment,
            },
            "declared_version": "006",
            "schema": {
                "tables": list(self.manifest.required_tables),
                "columns": {
                    table: list(columns)
                    for table, columns in self.manifest.required_columns.items()
                },
                "constraints": list(self.manifest.required_constraints),
            },
            "ledger_entries": [],
        }
        if include_ledger:
            metadata["ledger_entries"] = [
                {"version": spec.version, "sha256": spec.sha256}
                for spec in self.manifest.canonical
            ]
        return metadata

    def audit_metadata(self, metadata):
        source = FixtureMetadataSource(metadata)
        result = authority.audit_schema_metadata(
            source,
            self.expected_identity,
            migration_dir=self.migration_dir,
            manifest_path=self.manifest_path,
        )
        self.assertEqual(source.calls, 1)
        return result


class MigrationFileAuthorityTests(MigrationAuthorityTestCase):
    def test_valid_canonical_001_through_006_files(self) -> None:
        result = authority.audit_migration_files(self.migration_dir, self.manifest_path)
        self.assertTrue(result.ok)
        self.assertEqual(result.status, "verified_001_006")
        self.assertEqual(result.canonical_versions, ("001", "002", "003", "004", "005", "006"))
        self.assertEqual(result.reserved_versions, ("007", "008"))
        self.assertEqual(result.next_canonical_version, "009")

    def test_each_canonical_checksum_change_is_rejected(self) -> None:
        for spec in self.manifest.canonical:
            with self.subTest(version=spec.version):
                path = self.migration_dir / spec.filename
                original = path.read_bytes()
                path.write_bytes(original + b"\n-- altered by test\n")
                try:
                    result = authority.audit_migration_files(
                        self.migration_dir, self.manifest_path
                    )
                    self.assertFalse(result.ok)
                    self.assertEqual(result.status, "checksum_drift")
                    self.assertIn("checksum_drift", {item.code for item in result.diagnostics})
                finally:
                    path.write_bytes(original)

    def test_missing_migration_is_rejected(self) -> None:
        (self.migration_dir / self.manifest.canonical[2].filename).unlink()
        result = authority.audit_migration_files(self.migration_dir, self.manifest_path)
        self.assertEqual(result.status, "ambiguous_authority")
        self.assertIn("missing_migration", {item.code for item in result.diagnostics})

    def test_duplicate_version_is_rejected(self) -> None:
        shutil.copy2(
            self.migration_dir / "001_initial_schema.sql",
            self.migration_dir / "001_duplicate.sql",
        )
        result = authority.audit_migration_files(self.migration_dir, self.manifest_path)
        self.assertEqual(result.status, "ambiguous_authority")
        self.assertIn("duplicate_version", {item.code for item in result.diagnostics})

    def test_renamed_migration_is_rejected(self) -> None:
        (self.migration_dir / "002_rich_task_model.sql").rename(
            self.migration_dir / "002_renamed.sql"
        )
        result = authority.audit_migration_files(self.migration_dir, self.manifest_path)
        self.assertEqual(result.status, "ambiguous_authority")
        self.assertIn("renamed_migration", {item.code for item in result.diagnostics})

    def test_misordered_manifest_is_rejected(self) -> None:
        raw = json.loads(self.manifest_path.read_text())
        raw["canonical_migrations"][0], raw["canonical_migrations"][1] = (
            raw["canonical_migrations"][1],
            raw["canonical_migrations"][0],
        )
        self.manifest_path.write_text(json.dumps(raw))
        result = authority.audit_migration_files(self.migration_dir, self.manifest_path)
        self.assertEqual(result.status, "ambiguous_authority")
        self.assertIn("manifest_invalid", {item.code for item in result.diagnostics})

    def test_unexpected_007_008_and_009_or_higher_are_rejected(self) -> None:
        for version in ("007", "008", "009", "123"):
            with self.subTest(version=version):
                path = self.migration_dir / f"{version}_unexpected.sql"
                path.write_text("SELECT 1;\n")
                try:
                    result = authority.audit_migration_files(
                        self.migration_dir, self.manifest_path
                    )
                    self.assertEqual(result.status, "unexpected_later_schema")
                    codes = {item.code for item in result.diagnostics}
                    expected = (
                        "reserved_version_present" if version in {"007", "008"} else "unexpected_version"
                    )
                    self.assertIn(expected, codes)
                finally:
                    path.unlink()

    def test_reserved_numbers_are_forbidden_by_manifest_contract(self) -> None:
        raw = json.loads(self.manifest_path.read_text())
        raw["reserved_versions"][0]["status"] = "canonical"
        self.manifest_path.write_text(json.dumps(raw))
        with self.assertRaisesRegex(authority.AuthorityConfigurationError, "not forbidden"):
            authority.load_manifest(self.manifest_path)


class SchemaMetadataAuditTests(MigrationAuthorityTestCase):
    def test_verified_001_through_006_schema_without_ledger(self) -> None:
        result = self.audit_metadata(self.valid_metadata())
        self.assertTrue(result.ok)
        self.assertEqual(result.status, "verified_001_006")

    def test_verified_schema_with_matching_supplied_ledger(self) -> None:
        result = self.audit_metadata(self.valid_metadata(include_ledger=True))
        self.assertTrue(result.ok)

    def test_partial_schema_metadata(self) -> None:
        metadata = self.valid_metadata()
        metadata["schema"]["tables"].remove("maintenance_tasks")
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "partial_schema")
        self.assertIn("table:maintenance_tasks", result.human_report())

    def test_lower_declared_schema_version_is_partial(self) -> None:
        metadata = self.valid_metadata()
        metadata["declared_version"] = "005"
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "partial_schema")
        self.assertIn("partial_declared_version", {item.code for item in result.diagnostics})

    def test_ambiguous_schema_metadata(self) -> None:
        metadata = self.valid_metadata()
        metadata["schema"]["tables"].append(metadata["schema"]["tables"][0])
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "ambiguous_schema")

    def test_unexplained_schema_objects_are_ambiguous(self) -> None:
        metadata = self.valid_metadata()
        metadata["unexplained_schema_objects"] = True
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "ambiguous_schema")

    def test_unverified_database_identity_fails_closed(self) -> None:
        metadata = self.valid_metadata()
        metadata["identity"]["proven"] = False
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "identity_unavailable")
        self.assertFalse(result.ok)

    def test_wrong_database_identity_fails_closed(self) -> None:
        metadata = self.valid_metadata()
        metadata["identity"]["database_name"] = "development"
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "identity_unavailable")
        self.assertIn("identity_mismatch", {item.code for item in result.diagnostics})

    def test_unavailable_metadata_fails_closed_and_redacts_exception(self) -> None:
        source = mock.Mock()
        source.inspect_read_only.side_effect = RuntimeError(
            "postgresql://admin:topsecret@example/db password=hunter2"
        )
        result = authority.audit_schema_metadata(
            source,
            self.expected_identity,
            migration_dir=self.migration_dir,
            manifest_path=self.manifest_path,
        )
        report = result.human_report()
        self.assertEqual(result.status, "identity_unavailable")
        self.assertNotIn("topsecret", report)
        self.assertNotIn("hunter2", report)
        self.assertNotIn("example/db", report)
        self.assertIn("[REDACTED_URL]", report)
        self.assertIn("[REDACTED]", report)

    def test_unknown_higher_ledger_version_is_rejected(self) -> None:
        metadata = self.valid_metadata(include_ledger=True)
        metadata["ledger_entries"].append({"version": "010", "sha256": "0" * 64})
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "unexpected_later_schema")
        self.assertIn("unexpected_ledger_version", {item.code for item in result.diagnostics})

    def test_supplied_ledger_checksum_mismatch_is_rejected(self) -> None:
        metadata = self.valid_metadata(include_ledger=True)
        metadata["ledger_entries"][3]["sha256"] = "0" * 64
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "checksum_drift")
        self.assertIn("ledger_checksum_drift", {item.code for item in result.diagnostics})

    def test_partial_supplied_ledger_is_rejected(self) -> None:
        metadata = self.valid_metadata(include_ledger=True)
        metadata["ledger_entries"].pop()
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "partial_schema")

    def test_concurrent_migration_activity_fails_closed(self) -> None:
        metadata = self.valid_metadata()
        metadata["concurrent_migration_activity"] = True
        result = self.audit_metadata(metadata)
        self.assertEqual(result.status, "ambiguous_schema")
        self.assertIn("concurrent_activity", {item.code for item in result.diagnostics})


class AuditOnlySafetyTests(MigrationAuthorityTestCase):
    def test_credentials_passwords_tokens_and_urls_are_redacted(self) -> None:
        diagnostic = authority.Diagnostic(
            "sample",
            "postgresql://admin:secret@example/db password=hunter2 token=abc123",
        )
        result = authority.AuditResult(
            status="identity_unavailable",
            ok=False,
            canonical_versions=("001",),
            reserved_versions=("007", "008"),
            next_canonical_version="009",
            diagnostics=(diagnostic,),
            identity={
                "database_name": "fixture",
                "database_url": "postgresql://admin:secret@example/db",
                "password": "hunter2",
            },
        )
        for report in (result.human_report(), result.machine_report()):
            self.assertNotIn("secret", report)
            self.assertNotIn("hunter2", report)
            self.assertNotIn("abc123", report)
            self.assertNotIn("example/db", report)
            self.assertIn("[REDACTED]", report)

    def test_mutation_and_apply_requests_are_rejected(self) -> None:
        authority.reject_mutation("audit")
        for action in sorted(authority.MUTATING_ACTIONS | {"execute-sql"}):
            with self.subTest(action=action):
                with self.assertRaises(authority.MutationForbiddenError):
                    authority.reject_mutation(action)
        with self.assertRaises(SystemExit):
            authority.build_parser().parse_args(["--action", "apply"])

    def test_module_import_performs_no_file_or_metadata_audit(self) -> None:
        with (
            mock.patch.object(Path, "read_text", side_effect=AssertionError("unexpected read")),
            mock.patch.object(Path, "read_bytes", side_effect=AssertionError("unexpected read")),
        ):
            importlib.reload(authority)

    def test_api_import_and_startup_do_not_reference_verifier(self) -> None:
        for relative in (
            "tools/property_manager/api/propertymanager_api.py",
            "tools/property_manager/api/wsgi.py",
            "tools/property_manager/api/run_api.sh",
            "tools/property_manager/api/run_wsgi.sh",
        ):
            text = (REPO_ROOT / relative).read_text()
            self.assertNotIn("migration_authority", text, relative)

    def test_verifier_has_no_database_write_or_sql_execution_dependency(self) -> None:
        source = inspect.getsource(authority)
        tree = ast.parse(source)
        imports = {
            alias.name.split(".", 1)[0]
            for node in ast.walk(tree)
            if isinstance(node, (ast.Import, ast.ImportFrom))
            for alias in node.names
        }
        self.assertTrue({"subprocess", "psycopg", "psycopg2", "sqlalchemy"}.isdisjoint(imports))
        for forbidden_sql in ("INSERT INTO", "CREATE TABLE", "ALTER TABLE"):
            self.assertNotIn(forbidden_sql, source)
        self.assertFalse(hasattr(authority, "apply_migrations"))
        self.assertFalse(hasattr(authority, "write_ledger"))

    def test_machine_readable_output_is_deterministic(self) -> None:
        result_a = self.audit_metadata(self.valid_metadata(include_ledger=True))
        result_b = self.audit_metadata(self.valid_metadata(include_ledger=True))
        self.assertEqual(result_a.machine_report(), result_b.machine_report())
        self.assertEqual(
            json.loads(result_a.machine_report()),
            json.loads(result_b.machine_report()),
        )

    def test_cli_without_metadata_fails_closed(self) -> None:
        with mock.patch("builtins.print") as output:
            exit_code = authority.main(
                [
                    "--manifest",
                    str(self.manifest_path),
                    "--migration-dir",
                    str(self.migration_dir),
                    "--format",
                    "json",
                ]
            )
        self.assertEqual(exit_code, 1)
        self.assertEqual(json.loads(output.call_args.args[0])["status"], "identity_unavailable")

    def test_cli_reports_checksum_drift_before_missing_identity(self) -> None:
        path = self.migration_dir / "006_phase1_meter_audit.sql"
        path.write_bytes(path.read_bytes() + b"\n-- drift\n")
        with mock.patch("builtins.print") as output:
            exit_code = authority.main(
                [
                    "--manifest",
                    str(self.manifest_path),
                    "--migration-dir",
                    str(self.migration_dir),
                    "--format",
                    "json",
                ]
            )
        self.assertEqual(exit_code, 1)
        self.assertEqual(json.loads(output.call_args.args[0])["status"], "checksum_drift")


if __name__ == "__main__":
    unittest.main()
