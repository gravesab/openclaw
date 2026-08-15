#!/usr/bin/env python3
"""Apply the canonical PropertyManager migration chain in disposable PostgreSQL."""

from __future__ import annotations

import json
import shutil
import subprocess
import time
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
MIGRATION_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
MIGRATIONS = (
    "001_initial_schema.sql",
    "002_rich_task_model.sql",
    "003_part_quantity.sql",
    "004_task_origin.sql",
    "005_assets_and_meters.sql",
    "006_phase1_meter_audit.sql",
    "009_maintenance_proposals.sql",
)
EXPECTED_VERSION = "009"
IMAGE = "pgvector/pgvector:pg16"
TEST_LABEL = "ai.openclaw.test=propertymanager-migration-chain"


def _run(
    args: list[str],
    *,
    input_bytes: bytes | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        args,
        input=input_bytes,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


class PropertyManagerMigrationChainTests(unittest.TestCase):
    container_name: str
    container_id: str
    database_name: str
    database_user: str
    token: str

    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("docker") is None:
            raise unittest.SkipTest("Docker is required for the isolated migration-chain test")

        discovered = tuple(path.name for path in sorted(MIGRATION_DIR.glob("[0-9][0-9][0-9]_*.sql")))
        if discovered != MIGRATIONS:
            raise AssertionError(f"ambiguous migration chain: expected {MIGRATIONS}, found {discovered}")
        if MIGRATIONS[-1][:3] != EXPECTED_VERSION:
            raise AssertionError("expected migration version does not match the final migration filename")

        _run(["docker", "image", "inspect", IMAGE])
        cls.token = uuid.uuid4().hex[:12]
        cls.container_name = f"openclaw-pm-migration-test-{cls.token}"
        cls.database_name = f"pm_migration_test_{cls.token}"
        cls.database_user = f"pm_test_{cls.token}"
        cls.container_id = ""

        result = _run(
            [
                "docker",
                "run",
                "--detach",
                "--rm",
                "--pull=never",
                "--network=none",
                "--name",
                cls.container_name,
                "--label",
                TEST_LABEL,
                "--label",
                f"ai.openclaw.test-token={cls.token}",
                "--env",
                f"POSTGRES_DB={cls.database_name}",
                "--env",
                "POSTGRES_HOST_AUTH_METHOD=trust",
                "--env",
                f"POSTGRES_USER={cls.database_user}",
                IMAGE,
            ]
        )
        cls.container_id = result.stdout.decode().strip()
        try:
            cls._prove_container_identity()
            cls._wait_until_ready()
        except BaseException as setup_error:
            try:
                cls._remove_verified_container()
            except BaseException as cleanup_error:
                setup_error.add_note(f"disposable container cleanup also failed: {cleanup_error!r}")
            raise

    @classmethod
    def tearDownClass(cls) -> None:
        if not getattr(cls, "container_id", ""):
            return
        cls._remove_verified_container()

    @classmethod
    def _remove_verified_container(cls) -> None:
        """Remove only the exact disposable container whose identity is proven."""
        if not cls.container_id:
            return
        cls._prove_container_identity()
        container_id = cls.container_id
        result = _run(["docker", "rm", "--force", container_id], check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).decode(errors="replace").strip()
            raise RuntimeError(f"failed to remove verified test container {container_id}: {detail}")
        cls.container_id = ""

    @classmethod
    def _prove_container_identity(cls) -> None:
        result = _run(
            [
                "docker",
                "inspect",
                "--format",
                '{{json .}}',
                cls.container_id or cls.container_name,
            ]
        )
        metadata = json.loads(result.stdout)
        labels = metadata["Config"].get("Labels") or {}
        actual_name = str(metadata.get("Name") or "").removeprefix("/")
        if metadata.get("Id") != cls.container_id:
            raise AssertionError("refusing to use container whose ID changed")
        if actual_name != cls.container_name:
            raise AssertionError("refusing to use container whose name does not match")
        if labels.get("ai.openclaw.test") != "propertymanager-migration-chain":
            raise AssertionError("refusing to use container without the migration-test label")
        if labels.get("ai.openclaw.test-token") != cls.token:
            raise AssertionError("refusing to use container with a different test token")

    @classmethod
    def _wait_until_ready(cls) -> None:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            result = _run(
                [
                    "docker",
                    "exec",
                    cls.container_id,
                    "pg_isready",
                    "-U",
                    cls.database_user,
                    "-d",
                    cls.database_name,
                ],
                check=False,
            )
            if result.returncode == 0:
                return
            time.sleep(0.25)
        raise AssertionError("isolated PostgreSQL did not become ready")

    @classmethod
    def _psql(cls, sql: str) -> str:
        cls._prove_container_identity()
        result = _run(
            [
                "docker",
                "exec",
                "-i",
                cls.container_id,
                "psql",
                "-X",
                "-v",
                "ON_ERROR_STOP=1",
                "-U",
                cls.database_user,
                "-d",
                cls.database_name,
                "-At",
            ],
            input_bytes=sql.encode(),
            check=False,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).decode(errors="replace").strip()
            raise AssertionError(f"isolated psql command failed: {detail}")
        return result.stdout.decode().strip()

    def test_canonical_migrations_build_expected_schema(self) -> None:
        identity = self._psql(
            "SELECT current_database() || '|' || current_user || '|' || pg_is_in_recovery();"
        )
        self.assertEqual(identity, f"{self.database_name}|{self.database_user}|false")

        applied: list[str] = []
        for filename in MIGRATIONS:
            self._prove_container_identity()
            migration = (MIGRATION_DIR / filename).read_bytes()
            self._psql(migration.decode())
            applied.append(filename[:3])
        self.assertEqual(applied, ["001", "002", "003", "004", "005", "006", "009"])
        self.assertEqual(applied[-1], EXPECTED_VERSION)

        # The 005/006/009 rollout contract explicitly describes these migrations as
        # idempotent for future hosts. Reapply only that promised subset.
        for filename in MIGRATIONS[4:]:
            self._psql((MIGRATION_DIR / filename).read_text())

        tables = set(
            self._psql(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema='propertymanager' ORDER BY table_name;"
            ).splitlines()
        )
        self.assertEqual(
            tables,
            {
                "asset_meter",
                "asset_meter_reading",
                "asset_task_mapping_proposals",
                "assets",
                "maintenance_categories",
                "maintenance_completions",
                "maintenance_proposals",
                "maintenance_task_parts",
                "maintenance_task_photos",
                "maintenance_tasks",
            },
        )

        expected_columns = {
            "assets": {"meter_proposed_type", "meter_proposed_unit", "meter_activated_at"},
            "asset_meter": {"meter_epoch", "row_version"},
            "asset_meter_reading": {
                "previous_reading_id",
                "meter_type_at_entry",
                "unit_at_entry",
                "status",
                "operator_identity",
                "integration_identity",
                "idempotency_key",
                "meter_epoch",
                "corrects_reading_id",
            },
            "maintenance_completions": {"meter_value_at_completion", "meter_reading_id"},
            "maintenance_task_parts": {"quantity", "vendor", "notes"},
            "maintenance_tasks": {
                "kind",
                "manufacturer",
                "source_manual_name",
                "completion_history",
                "tools_required",
                "origin",
                "asset_id",
                "schedule_kind",
                "meter_interval_value",
                "meter_interval_unit",
                "last_done_meter_value",
                "next_due_meter_value",
            },
        }
        for table, columns in expected_columns.items():
            actual = set(
                self._psql(
                    "SELECT column_name FROM information_schema.columns "
                    f"WHERE table_schema='propertymanager' AND table_name='{table}' "
                    "ORDER BY ordinal_position;"
                ).splitlines()
            )
            self.assertTrue(columns <= actual, f"{table} missing {sorted(columns - actual)}")

        constraints = set(
            self._psql(
                "SELECT conname FROM pg_constraint c "
                "JOIN pg_namespace n ON n.oid=c.connamespace "
                "WHERE n.nspname='propertymanager' ORDER BY conname;"
            ).splitlines()
        )
        self.assertTrue(
            {
                "asset_meter_type_check",
                "asset_meter_reading_entry_method_check",
                "asset_meter_reading_correction_reason_check",
                "asset_meter_reading_status_check",
                "asset_task_mapping_proposals_status_check",
                "maintenance_categories_name_key",
                "maintenance_tasks_area_item_unique",
                "maintenance_tasks_kind_check",
                "maintenance_tasks_origin_check",
                "maintenance_tasks_schedule_kind_check",
            }
            <= constraints
        )


class MigrationContainerCleanupTests(unittest.TestCase):
    returned_id = "a" * 64
    token = "b" * 12

    def setUp(self) -> None:
        self.test_class = PropertyManagerMigrationChainTests
        self.test_class.container_id = ""

    def tearDown(self) -> None:
        self.test_class.container_id = ""

    def _run_result(
        self,
        args: list[str],
        *,
        input_bytes: bytes | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[bytes]:
        del input_bytes, check
        if args[:3] == ["docker", "image", "inspect"]:
            return subprocess.CompletedProcess(args, 0, b"[]", b"")
        if args[:2] == ["docker", "run"]:
            return subprocess.CompletedProcess(args, 0, f"{self.returned_id}\n".encode(), b"")
        if args[:3] == ["docker", "rm", "--force"]:
            return subprocess.CompletedProcess(args, 0, f"{self.returned_id}\n".encode(), b"")
        raise AssertionError(f"unexpected command: {args}")

    def _setup_patches(self):
        return (
            mock.patch.object(shutil, "which", return_value="/usr/bin/docker"),
            mock.patch.object(uuid, "uuid4", return_value=SimpleNamespace(hex=self.token * 3)),
            mock.patch(f"{__name__}._run", side_effect=self._run_result),
        )

    def test_readiness_failure_triggers_verified_cleanup_by_returned_id(self) -> None:
        which_patch, uuid_patch, run_patch = self._setup_patches()
        with (
            which_patch,
            uuid_patch,
            run_patch as run_mock,
            mock.patch.object(self.test_class, "_prove_container_identity") as prove,
            mock.patch.object(
                self.test_class,
                "_wait_until_ready",
                side_effect=RuntimeError("readiness failed"),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "readiness failed"):
                self.test_class.setUpClass()

        self.assertEqual(prove.call_count, 2)
        removal = [
            call.args[0]
            for call in run_mock.call_args_list
            if call.args[0][:3] == ["docker", "rm", "--force"]
        ]
        self.assertEqual(removal, [["docker", "rm", "--force", self.returned_id]])
        self.assertEqual(self.test_class.container_id, "")

    def test_identity_failure_never_removes_unverified_container(self) -> None:
        which_patch, uuid_patch, run_patch = self._setup_patches()
        with (
            which_patch,
            uuid_patch,
            run_patch as run_mock,
            mock.patch.object(
                self.test_class,
                "_prove_container_identity",
                side_effect=AssertionError("identity mismatch"),
            ),
        ):
            with self.assertRaisesRegex(AssertionError, "identity mismatch") as raised:
                self.test_class.setUpClass()

        self.assertFalse(
            any(call.args[0][:3] == ["docker", "rm", "--force"] for call in run_mock.call_args_list)
        )
        self.assertTrue(
            any("cleanup also failed" in note for note in getattr(raised.exception, "__notes__", []))
        )

    def test_unrelated_container_metadata_cannot_be_selected(self) -> None:
        self.test_class.token = self.token
        self.test_class.container_name = f"openclaw-pm-migration-test-{self.token}"
        self.test_class.container_id = self.returned_id
        unrelated = {
            "Id": "c" * 64,
            "Name": "/unrelated-container",
            "Config": {
                "Labels": {
                    "ai.openclaw.test": "something-else",
                    "ai.openclaw.test-token": "different-token",
                }
            },
        }

        def inspect_only(args, **_kwargs):
            if args[:2] == ["docker", "inspect"]:
                return subprocess.CompletedProcess(args, 0, json.dumps(unrelated).encode(), b"")
            raise AssertionError(f"removal must not be attempted: {args}")

        with mock.patch(f"{__name__}._run", side_effect=inspect_only) as run_mock:
            with self.assertRaisesRegex(AssertionError, "ID changed"):
                self.test_class._remove_verified_container()

        self.assertEqual(run_mock.call_count, 1)
        self.assertEqual(run_mock.call_args.args[0][-1], self.returned_id)

    def test_cleanup_failure_does_not_conceal_original_setup_failure(self) -> None:
        which_patch, uuid_patch, run_patch = self._setup_patches()
        with (
            which_patch,
            uuid_patch,
            run_patch,
            mock.patch.object(self.test_class, "_prove_container_identity"),
            mock.patch.object(
                self.test_class,
                "_wait_until_ready",
                side_effect=ValueError("original setup failure"),
            ),
            mock.patch.object(
                self.test_class,
                "_remove_verified_container",
                side_effect=RuntimeError("cleanup failure"),
            ),
        ):
            with self.assertRaisesRegex(ValueError, "original setup failure") as raised:
                self.test_class.setUpClass()

        self.assertTrue(
            any("cleanup failure" in note for note in getattr(raised.exception, "__notes__", []))
        )

    def test_successful_setup_and_teardown_remove_exact_container(self) -> None:
        which_patch, uuid_patch, run_patch = self._setup_patches()
        with (
            which_patch,
            uuid_patch,
            run_patch as run_mock,
            mock.patch.object(self.test_class, "_prove_container_identity") as prove,
            mock.patch.object(self.test_class, "_wait_until_ready") as wait,
        ):
            self.test_class.setUpClass()
            self.assertEqual(self.test_class.container_id, self.returned_id)
            self.test_class.tearDownClass()

        self.assertEqual(wait.call_count, 1)
        self.assertEqual(prove.call_count, 2)
        removal = [
            call.args[0]
            for call in run_mock.call_args_list
            if call.args[0][:3] == ["docker", "rm", "--force"]
        ]
        self.assertEqual(removal, [["docker", "rm", "--force", self.returned_id]])
        self.assertEqual(self.test_class.container_id, "")


if __name__ == "__main__":
    unittest.main()
