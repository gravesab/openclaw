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

REPO_ROOT = Path(__file__).resolve().parents[3]
MIGRATION_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
MIGRATIONS = (
    "001_initial_schema.sql",
    "002_rich_task_model.sql",
    "003_part_quantity.sql",
    "004_task_origin.sql",
    "005_assets_and_meters.sql",
    "006_phase1_meter_audit.sql",
)
EXPECTED_VERSION = "006"
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
        cls._prove_container_identity()
        cls._wait_until_ready()

    @classmethod
    def tearDownClass(cls) -> None:
        if not getattr(cls, "container_id", ""):
            return
        try:
            cls._prove_container_identity()
        except (AssertionError, subprocess.CalledProcessError):
            return
        _run(["docker", "rm", "--force", cls.container_id], check=False)

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
        )
        return result.stdout.decode().strip()

    def test_001_through_006_build_expected_schema(self) -> None:
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
        self.assertEqual(applied, ["001", "002", "003", "004", "005", "006"])
        self.assertEqual(applied[-1], EXPECTED_VERSION)

        # The 005/006 rollout contract explicitly describes these migrations as
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


if __name__ == "__main__":
    unittest.main()
