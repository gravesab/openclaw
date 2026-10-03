"""Disposable Postgres proof for Apple Card CSV recording.

Creates and destroys a unix-socket-only temporary cluster. Does not read a
database URL, reuse a shared DEV database, or leave the cluster behind.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import threading
import unittest

from ranchbrain.finance_apple_card_csv import PARSER_VERSION, parse_apple_card_csv
from ranchbrain.finance_csv_write_adapter import (
    apple_card_clearing_account_id,
    apple_card_clearing_account_request,
    record_apple_card_activities,
    record_apple_card_artifact,
)
from ranchbrain.finance_mutation_coordinator import FinanceMutationCoordinator
from ranchbrain.finance_pg_session import FinancePgSession
from ranchbrain.finance_write_repository import FinancePersistenceError, FinancePersistenceErrorCode, FinanceWriteRepository
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, User, VerifiedPrincipal


PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
NOW = datetime(2026, 6, 1, 12, tzinfo=timezone.utc)
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class LiveProofBlocked(RuntimeError):
    """Raised when the disposable cluster cannot be started."""


def _bindir() -> Path:
    candidates = [
        Path("/opt/homebrew/opt/postgresql@16/bin"),
        Path("/opt/homebrew/opt/postgresql@17/bin"),
        Path("/usr/local/opt/postgresql@16/bin"),
        Path("/usr/lib/postgresql/16/bin"),
    ]
    for directory in candidates:
        if all((directory / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return directory
    located = shutil.which("pg_ctl")
    if located:
        directory = Path(located).resolve().parent
        if all((directory / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return directory
    raise LiveProofBlocked("blocked: PostgreSQL binaries unavailable")


def _existing_psycopg2():
    try:
        import psycopg2
    except ImportError as error:
        raise LiveProofBlocked("blocked: psycopg2 unavailable") from error
    return psycopg2


def _pg_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in (
        "PGPORT",
        "PGHOST",
        "PGDATABASE",
        "PGUSER",
        "PGPASSWORD",
        "PGSERVICE",
        "DATABASE_URL",
        "RANCHOS_TENANCY_TEST_DATABASE_URL",
        "RANCHBRAIN_TENANT",
    ):
        env.pop(key, None)
    return env


def _run_pg(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, env=_pg_env())


def _principal(principal_id: str) -> VerifiedPrincipal:
    return VerifiedPrincipal(
        principal_id,
        "human",
        "development",
        "active",
        "mfa-fresh",
        "session-disposable",
        NOW - timedelta(minutes=5),
        NOW + timedelta(hours=1),
        "corr-apple-card",
    )


def _resolver() -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=[User(USER_A, PRINCIPAL_A), User(USER_B, PRINCIPAL_B)],
        tenants=[Tenant(TENANT_A, "tenant-a", "Tenant A"), Tenant(TENANT_B, "tenant-b", "Tenant B")],
        memberships=[
            TenantMembership(TENANT_A, USER_A, Role.OWNER),
            TenantMembership(TENANT_B, USER_B, Role.OWNER),
        ],
    )


class AppleCardCsvDisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path | None
    _psycopg2: object | None
    _session_conn: object | None
    _inspect_conn: object | None
    _blocked: str | None = None

    @classmethod
    def setUpClass(cls) -> None:
        cls._session_conn = None
        cls._inspect_conn = None
        cls._workdir = None
        try:
            cls._bindir = _bindir()
            cls._psycopg2 = _existing_psycopg2()
        except LiveProofBlocked as error:
            cls._blocked = str(error)
            return
        cls._workdir = Path(tempfile.mkdtemp(prefix="facsv", dir="/tmp"))
        try:
            cls._start_cluster()
            cls._session_conn = cls._connect()
            cls._inspect_conn = cls._connect()
            cls._seed_tenancy()
        except Exception as error:
            cls._destroy_cluster()
            cls._blocked = f"blocked: disposable apple card cluster setup failed: {error}"

    def setUp(self) -> None:
        if self._blocked:
            self.skipTest(self._blocked)
        self._session_conn.rollback()
        self._inspect_conn.rollback()

    @classmethod
    def tearDownClass(cls) -> None:
        cls._destroy_cluster()

    @classmethod
    def _start_cluster(cls) -> None:
        workdir = cls._workdir
        if workdir is None:
            raise LiveProofBlocked("blocked: disposable workdir missing")
        data_dir = workdir / "data"
        sock_dir = workdir / "s"
        sock_dir.mkdir()
        init = _run_pg(
            [str(cls._bindir / "initdb"), "-D", str(data_dir), "-U", "ranchos_boot", "--auth-local=trust", "--auth-host=reject"],
        )
        if init.returncode != 0:
            raise LiveProofBlocked("blocked: initdb failed")
        with (data_dir / "postgresql.conf").open("a", encoding="utf-8") as config:
            config.write(
                "\nlisten_addresses = ''\nport = 5432\n"
                f"unix_socket_directories = '{sock_dir}'\nunix_socket_permissions = 0700\n"
            )
        (data_dir / "pg_hba.conf").write_text(
            "\n".join(
                [
                    "local all ranchos_boot trust",
                    "local all ranchos_dev_migrator trust",
                    "local all ranchos_dev_runtime trust",
                    "host all all 127.0.0.1/32 reject",
                    "host all all ::1/128 reject",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        started = _run_pg([str(cls._bindir / "pg_ctl"), "-D", str(data_dir), "-l", str(workdir / "pg.log"), "-w", "-t", "20", "start"])
        if started.returncode != 0:
            raise LiveProofBlocked("blocked: pg_ctl start failed")
        boot = [str(cls._bindir / "psql"), "-h", str(sock_dir), "-p", "5432", "-U", "ranchos_boot", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        for statement in (
            "CREATE ROLE ranchos_dev_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "CREATE ROLE ranchos_dev_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "GRANT ranchos_dev_runtime TO ranchos_dev_migrator",
            "CREATE DATABASE ranchos_dev OWNER ranchos_dev_migrator",
            "REVOKE ALL ON DATABASE ranchos_dev FROM PUBLIC",
            "GRANT CONNECT ON DATABASE ranchos_dev TO ranchos_dev_migrator, ranchos_dev_runtime",
        ):
            provision = _run_pg([*boot, "-c", statement])
            if provision.returncode != 0:
                raise LiveProofBlocked("blocked: disposable role provision failed")
        app_root = Path(__file__).resolve().parents[1]
        applied = _run_pg(
            [
                str(cls._bindir / "psql"),
                "-h",
                str(sock_dir),
                "-p",
                "5432",
                "-U",
                "ranchos_dev_migrator",
                "-d",
                "ranchos_dev",
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                str(app_root / "migrations" / "001_ranch_os_tenancy_foundation.sql"),
                "-f",
                str(app_root / "migrations" / "005_finance_persistence_foundation.sql"),
            ]
        )
        if applied.returncode != 0:
            raise LiveProofBlocked("blocked: committed 001/005 apply failed")

    @classmethod
    def _connect(cls):
        workdir = cls._workdir
        if workdir is None or cls._psycopg2 is None:
            raise LiveProofBlocked("blocked: disposable connection prerequisites missing")
        connection = cls._psycopg2.connect(host=str(workdir / "s"), port=5432, user="ranchos_dev_migrator", dbname="ranchos_dev")
        connection.autocommit = False
        return connection

    @classmethod
    def _destroy_cluster(cls) -> None:
        for connection in (getattr(cls, "_session_conn", None), getattr(cls, "_inspect_conn", None)):
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass
        cls._session_conn = None
        cls._inspect_conn = None
        workdir = getattr(cls, "_workdir", None)
        if workdir is not None and getattr(cls, "_bindir", None) is not None:
            _run_pg([str(cls._bindir / "pg_ctl"), "-D", str(workdir / "data"), "-m", "immediate", "stop"])
            shutil.rmtree(workdir, ignore_errors=True)
        cls._workdir = None

    @classmethod
    def _seed_tenancy(cls) -> None:
        cursor = cls._inspect_conn.cursor()
        try:
            for principal_id, user_id, tenant_id, slug, label in (
                (PRINCIPAL_A, USER_A, TENANT_A, "tenant-a", "Tenant A"),
                (PRINCIPAL_B, USER_B, TENANT_B, "tenant-b", "Tenant B"),
            ):
                cls._set_local(cursor, principal_id, tenant_id)
                cursor.execute(
                    "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s)",
                    (tenant_id, slug, label, "active"),
                )
                cursor.execute(
                    "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
                    (user_id, principal_id, "active"),
                )
                cursor.execute(
                    "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
                    (tenant_id, user_id, "owner", "active"),
                )
                cls._inspect_conn.commit()
        except Exception:
            cls._inspect_conn.rollback()
            raise
        finally:
            cursor.close()

    @staticmethod
    def _set_local(cursor, principal_id: str, tenant_id: str) -> None:
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", principal_id))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", "development"))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", tenant_id))

    def _import_parsed(self, connection, parsed, idempotency_key: str):
        coordinator = FinanceMutationCoordinator(_resolver(), FinanceWriteRepository())
        coordinator.create_account(
            principal=_principal(PRINCIPAL_A),
            requested_tenant_id=TENANT_A,
            request=apple_card_clearing_account_request(parsed),
            session=FinancePgSession(connection),
            now=NOW,
        )
        session = FinancePgSession(connection)
        artifact = record_apple_card_artifact(
            session,
            TENANT_A,
            parsed,
            apple_card_clearing_account_id(parsed.artifact_hash),
            idempotency_key,
            principal=_principal(PRINCIPAL_A),
            resolver=_resolver(),
            now=NOW,
        )
        activities = record_apple_card_activities(
            FinancePgSession(connection),
            TENANT_A,
            parsed,
            apple_card_clearing_account_id(parsed.artifact_hash),
            principal=_principal(PRINCIPAL_A),
            resolver=_resolver(),
            now=NOW,
        )
        return artifact, activities

    def _sample(self):
        raw = (FIXTURES / "apple_card_sample_10.csv").read_bytes()
        return parse_apple_card_csv(raw, "apple_card_sample_10.csv", now=NOW)

    def _count_for_artifact(self, artifact_id: str) -> int:
        cursor = self._inspect_conn.cursor()
        try:
            cursor.execute("BEGIN")
            cursor.execute("SELECT set_config(%s, %s, true)", ("role", "ranchos_dev_runtime"))
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute(
                "SELECT COUNT(*) FROM ranchos.finance_source_activities WHERE source_artifact_id = %s",
                (artifact_id,),
            )
            count = cursor.fetchone()[0]
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return count

    def _runtime_update_denied(self, statement: str, params: tuple[object, ...]) -> None:
        cursor = self._inspect_conn.cursor()
        try:
            cursor.execute("BEGIN")
            cursor.execute("SELECT set_config(%s, %s, true)", ("role", "ranchos_dev_runtime"))
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            with self.assertRaises(Exception) as raised:
                cursor.execute(statement, params)
            self.assertEqual(getattr(raised.exception, "pgcode", None), "42501")
            self._inspect_conn.rollback()
        finally:
            cursor.close()

    def test_records_one_account_one_artifact_and_ten_activities(self) -> None:
        parsed = self._sample()
        artifact, activities = self._import_parsed(self._session_conn, parsed, parsed.artifact_hash)
        self.assertFalse(artifact.replayed)
        self.assertEqual(artifact.artifact_id, parsed.artifact_hash)
        self.assertFalse(activities.replayed)
        self.assertEqual(activities.activity_ids, tuple(row.external_id for row in parsed.activities))
        self.assertEqual(self._count_for_artifact(parsed.artifact_hash), 10)
        clearing_id = apple_card_clearing_account_id(parsed.artifact_hash)
        session = FinancePgSession(self._session_conn)
        session.begin()
        session.set_local(principal_id=PRINCIPAL_A, environment="development", tenant_id=TENANT_A)
        try:
            stored = session.lock_artifact(TENANT_A, parsed.artifact_hash)
            ledger = session.load_ledger(TENANT_A)
        finally:
            session.rollback()
        self.assertIsNotNone(stored)
        self.assertEqual(stored.kind, "statement_csv")
        self.assertEqual(stored.parser_version, PARSER_VERSION)
        self.assertEqual(stored.content_digest, parsed.artifact_hash)
        self.assertEqual(stored.original_filename, "apple_card_sample_10.csv")
        self.assertEqual(stored.account_id, clearing_id)
        account = next(item for item in ledger.accounts if item.id == clearing_id)
        self.assertEqual(account.institution, "Apple Card")
        self.assertEqual(account.account_type.value, "liability")
        recorded = [item for item in ledger.activities if item.source_account_id == clearing_id]
        self.assertEqual(len(recorded), 10)
        self.assertEqual({item.amount for item in recorded}, {row.amount for row in parsed.activities})
        other = FinancePgSession(self._session_conn)
        other.begin()
        other.set_local(principal_id=PRINCIPAL_B, environment="development", tenant_id=TENANT_B)
        try:
            hidden = other.load_ledger(TENANT_B)
            hidden_artifact = other.lock_artifact(TENANT_B, parsed.artifact_hash)
        finally:
            other.rollback()
        self.assertEqual(hidden.accounts, ())
        self.assertEqual(hidden.activities, ())
        self.assertIsNone(hidden_artifact)
        self._runtime_update_denied(
            "UPDATE ranchos.finance_accounts SET name = %s WHERE id = %s",
            ("changed", clearing_id),
        )
        self._runtime_update_denied(
            "UPDATE ranchos.finance_source_artifacts SET parser_version = %s WHERE id = %s",
            ("changed", parsed.artifact_hash),
        )
        self._runtime_update_denied(
            "UPDATE ranchos.finance_source_activities SET description = %s WHERE id = %s",
            ("changed", parsed.activities[0].external_id),
        )

    def test_replay_returns_same_ids_without_new_rows(self) -> None:
        parsed = self._sample()
        before = self._count_for_artifact(parsed.artifact_hash)
        first_artifact, first_activities = self._import_parsed(self._session_conn, parsed, parsed.artifact_hash)
        mid = self._count_for_artifact(parsed.artifact_hash)
        second_artifact, second_activities = self._import_parsed(self._session_conn, parsed, parsed.artifact_hash)
        after = self._count_for_artifact(parsed.artifact_hash)
        self.assertEqual(second_artifact.artifact_id, first_artifact.artifact_id)
        self.assertEqual(second_activities.activity_ids, first_activities.activity_ids)
        self.assertTrue(second_artifact.replayed)
        self.assertTrue(second_activities.replayed)
        self.assertEqual(after, mid)
        self.assertGreaterEqual(mid, before)
        self.assertEqual(mid, 10)

    def test_same_idempotency_key_with_different_content_conflicts(self) -> None:
        first = parse_apple_card_csv(
            b"Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n04/01/2024,04/01/2024,First hay,Store,Farm,Purchase,8.00,Alex Sample\n",
            "first.csv",
            now=NOW,
        )
        second = parse_apple_card_csv(
            b"Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n04/02/2024,04/02/2024,Second hay,Store,Farm,Purchase,9.00,Alex Sample\n",
            "second.csv",
            now=NOW,
        )
        self._import_parsed(self._session_conn, first, "shared-apple-card-key")
        before = self._count_for_artifact(first.artifact_hash)
        FinanceMutationCoordinator(_resolver(), FinanceWriteRepository()).create_account(
            principal=_principal(PRINCIPAL_A),
            requested_tenant_id=TENANT_A,
            request=apple_card_clearing_account_request(second),
            session=FinancePgSession(self._session_conn),
            now=NOW,
        )
        with self.assertRaises(FinancePersistenceError) as raised:
            record_apple_card_artifact(
                FinancePgSession(self._session_conn),
                TENANT_A,
                second,
                apple_card_clearing_account_id(second.artifact_hash),
                "shared-apple-card-key",
                principal=_principal(PRINCIPAL_A),
                resolver=_resolver(),
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinancePersistenceErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertEqual(self._count_for_artifact(first.artifact_hash), before)
        self.assertEqual(before, 1)
        self.assertEqual(self._count_for_artifact(second.artifact_hash), 0)

    def test_second_session_blocks_then_returns_the_same_ids(self) -> None:
        parsed = self._sample()
        first_artifact, first_activities = self._import_parsed(self._session_conn, parsed, parsed.artifact_hash)
        holder = self._connect()
        worker_conn = self._connect()
        try:
            held = FinancePgSession(holder)
            held.begin()
            held.set_local(principal_id=PRINCIPAL_A, environment="development", tenant_id=TENANT_A)
            self.assertIsNotNone(held.lock_artifact(TENANT_A, parsed.artifact_hash))
            outcome: dict[str, object] = {}

            def replay() -> None:
                try:
                    artifact, activities = self._import_parsed(worker_conn, parsed, parsed.artifact_hash)
                    outcome["artifact"] = artifact
                    outcome["activities"] = activities
                    outcome["done"] = True
                except Exception as error:
                    outcome["error"] = error

            worker = threading.Thread(target=replay, daemon=True)
            worker.start()
            worker.join(2)
            self.assertNotIn("error", outcome)
            self.assertFalse(outcome.get("done", False))
            holder.rollback()
            worker.join(20)
            self.assertTrue(outcome.get("done", False), outcome.get("error"))
            self.assertEqual(outcome["artifact"].artifact_id, first_artifact.artifact_id)
            self.assertTrue(outcome["artifact"].replayed)
            self.assertEqual(outcome["activities"].activity_ids, first_activities.activity_ids)
            self.assertEqual(self._count_for_artifact(parsed.artifact_hash), 10)
        finally:
            holder.close()
            worker_conn.close()


if __name__ == "__main__":
    unittest.main()
