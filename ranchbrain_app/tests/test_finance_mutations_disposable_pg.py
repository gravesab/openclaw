"""Disposable-only finance coordinator proof through FinancePgSession.

Creates and destroys a unix-socket-only temporary cluster for this process.
Does not read an environment database URL, reuse tools/** clients, install
dependencies, or leave a standing DEV database. Missing binaries or an
unavailable psycopg2 driver skip the proof; that skip is a remaining proof
gap, not a pass or a failure.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from uuid import uuid4

from ranchbrain.finance_model import (
    Account,
    AccountType,
    AllocationDomain,
    AllocationLink,
    AllocationTargetType,
    Interpretation,
    SourceActivity,
    Split,
    expense_journal_from_splits,
    reverse_journal_lines,
)
from ranchbrain.finance_mutation_coordinator import (
    FinanceAccountCreateRequest,
    FinanceInterpretationPostRequest,
    FinanceInterpretationReverseRequest,
    FinanceInterpretationSupersedeRequest,
    FinanceMutationCoordinator,
    FinanceMutationError,
    FinanceMutationErrorCode,
    FinanceSourceActivityRequest,
)
from ranchbrain.finance_pg_session import FinancePgSession
from ranchbrain.finance_write_repository import FinanceFactProvenance, FinanceWriteRepository
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, User, VerifiedPrincipal


PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
PRINCIPAL_C = "00000000-0000-0000-0000-000000000003"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
USER_C = "00000000-0000-0000-0000-000000000013"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
POLICY_VERSION = "policy-v1"
VALIDATOR_VERSION = "validator-v1"
NOW_OFFSET = timedelta(minutes=5)


class LiveProofBlocked(RuntimeError):
    """Raised when the disposable live proof cannot run."""


class _PersistFailingSession:
    def __init__(self, session: FinancePgSession):
        self._session = session

    def begin(self) -> None:
        self._session.begin()

    def set_local(self, *, principal_id: str, environment: str, tenant_id: str) -> None:
        self._session.set_local(principal_id=principal_id, environment=environment, tenant_id=tenant_id)

    def current_timestamp(self) -> datetime:
        return self._session.current_timestamp()

    def load_idempotency(self, tenant_id: str, scope: str, identity: str):
        return self._session.load_idempotency(tenant_id, scope, identity)

    def insert_idempotency_reservation(self, record) -> None:
        self._session.insert_idempotency_reservation(record)

    def finalize_idempotency(self, record) -> None:
        self._session.finalize_idempotency(record)

    def insert_account(self, **kwargs) -> None:
        self._session.insert_account(**kwargs)
        raise RuntimeError("forced persist failure")

    def lock_account(self, tenant_id: str, account_id: str):
        return self._session.lock_account(tenant_id, account_id)

    def insert_artifact(self, **kwargs) -> None:
        self._session.insert_artifact(**kwargs)

    def lock_artifact(self, tenant_id: str, artifact_id: str):
        return self._session.lock_artifact(tenant_id, artifact_id)

    def insert_activity(self, **kwargs) -> None:
        self._session.insert_activity(**kwargs)

    def lock_activity(self, tenant_id: str, activity_id: str):
        return self._session.lock_activity(tenant_id, activity_id)

    def load_ledger(self, tenant_id: str):
        return self._session.load_ledger(tenant_id)

    def insert_journal_entry(self, **kwargs) -> None:
        self._session.insert_journal_entry(**kwargs)

    def insert_journal_line(self, **kwargs) -> None:
        self._session.insert_journal_line(**kwargs)

    def insert_interpretation(self, **kwargs) -> None:
        self._session.insert_interpretation(**kwargs)

    def insert_split(self, **kwargs) -> None:
        self._session.insert_split(**kwargs)

    def insert_audit(self, record) -> None:
        self._session.insert_audit(record)

    def commit(self) -> None:
        self._session.commit()

    def rollback(self) -> None:
        self._session.rollback()


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
    ):
        env.pop(key, None)
    return env


def _run_pg(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, env=_pg_env())


def _principal(principal_id: str, correlation_id: str, now: datetime) -> VerifiedPrincipal:
    return VerifiedPrincipal(
        id=principal_id,
        principal_type="human",
        environment="development",
        lifecycle_state="active",
        assurance_profile="mfa-fresh",
        session_reference="session-disposable",
        valid_from=now - NOW_OFFSET,
        valid_until=now + timedelta(hours=1),
        correlation_id=correlation_id,
    )


def _resolver() -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=[User(USER_A, PRINCIPAL_A), User(USER_B, PRINCIPAL_B), User(USER_C, PRINCIPAL_C)],
        tenants=[Tenant(TENANT_A, "tenant-a", "Tenant A"), Tenant(TENANT_B, "tenant-b", "Tenant B")],
        memberships=[
            TenantMembership(TENANT_A, USER_A, Role.OWNER),
            TenantMembership(TENANT_A, USER_C, Role.OWNER),
            TenantMembership(TENANT_B, USER_B, Role.OWNER),
        ],
    )


def _manager_resolver() -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=[User(USER_A, PRINCIPAL_A)],
        tenants=[Tenant(TENANT_A, "tenant-a", "Tenant A")],
        memberships=[TenantMembership(TENANT_A, USER_A, Role.MANAGER)],
    )


class FinanceMutationsDisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path | None
    _psycopg2: object | None
    _session_conn: object | None
    _inspect_conn: object | None
    _blocked: str | None = None
    _driver_blocked: str | None = None

    @classmethod
    def setUpClass(cls) -> None:
        try:
            cls._bindir = _bindir()
        except LiveProofBlocked as error:
            cls._blocked = str(error)
            return
        cls._psycopg2 = None
        cls._driver_blocked = None
        try:
            cls._psycopg2 = _existing_psycopg2()
        except LiveProofBlocked as error:
            cls._driver_blocked = str(error)
        cls._workdir = Path(tempfile.mkdtemp(prefix="rpg", dir="/tmp"))
        cls._session_conn = None
        cls._inspect_conn = None
        try:
            cls._start_cluster()
            cls._rls_proof = cls._run_sql_proof("two_tenant_finance_isolation.sql")
            cls._immutability_proof = cls._run_sql_proof("finance_post_commit_immutability.sql")
            if cls._psycopg2 is None:
                return
            cls._session_conn = cls._connect()
            cls._inspect_conn = cls._connect()
            cls._seed_tenancy()
        except LiveProofBlocked as error:
            cls._destroy_cluster()
            cls._blocked = str(error)
        except Exception as error:
            cls._destroy_cluster()
            cls._blocked = f"blocked: disposable finance cluster setup failed: {error}"

    def setUp(self) -> None:
        if self._blocked:
            self.skipTest(self._blocked)
        if self._testMethodName not in {
            "test_rls_proof_sql_is_rollback_only_and_two_tenant",
            "test_post_commit_immutability_sql_rejects_appended_posted_facts",
        } and self._psycopg2 is None:
            self.skipTest(self._driver_blocked or "blocked: psycopg2 unavailable")

    @classmethod
    def tearDownClass(cls) -> None:
        if getattr(cls, "_workdir", None) is not None:
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
                "\nlisten_addresses = ''\n"
                "port = 5432\n"
                f"unix_socket_directories = '{sock_dir}'\n"
                "unix_socket_permissions = 0700\n"
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
        started = _run_pg(
            [str(cls._bindir / "pg_ctl"), "-D", str(data_dir), "-l", str(workdir / "pg.log"), "-w", "-t", "20", "start"],
        )
        if started.returncode != 0:
            raise LiveProofBlocked("blocked: pg_ctl start failed")
        boot = [
            str(cls._bindir / "psql"),
            "-h",
            str(sock_dir),
            "-p",
            "5432",
            "-U",
            "ranchos_boot",
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
        ]
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
            ],
        )
        if applied.returncode != 0:
            raise LiveProofBlocked(f"blocked: committed 001/005 apply failed: {applied.stderr}")

    @classmethod
    def _connect(cls):
        workdir = cls._workdir
        if workdir is None:
            raise LiveProofBlocked("blocked: disposable connection prerequisites missing")
        connection = cls._psycopg2.connect(
            host=str(workdir / "s"),
            port=5432,
            user="ranchos_dev_migrator",
            dbname="ranchos_dev",
        )
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
        if workdir is not None:
            _run_pg(
                [str(cls._bindir / "pg_ctl"), "-D", str(workdir / "data"), "-m", "immediate", "stop"],
            )
            shutil.rmtree(workdir, ignore_errors=True)
        cls._workdir = None

    @classmethod
    def _seed_tenancy(cls) -> None:
        cursor = cls._inspect_conn.cursor()
        try:
            cls._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute("SELECT 1 FROM ranchos.tenants WHERE id = %s", (TENANT_A,))
            if cursor.fetchone() is None:
                cursor.execute(
                    "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s)",
                    (TENANT_A, "tenant-a", "Tenant A", "active"),
                )
            cursor.execute("SELECT 1 FROM ranchos.users WHERE id = %s", (USER_A,))
            if cursor.fetchone() is None:
                cursor.execute(
                    "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
                    (USER_A, PRINCIPAL_A, "active"),
                )
            cursor.execute(
                "SELECT 1 FROM ranchos.tenant_memberships WHERE tenant_id = %s AND user_id = %s",
                (TENANT_A, USER_A),
            )
            if cursor.fetchone() is None:
                cursor.execute(
                    "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
                    (TENANT_A, USER_A, "owner", "active"),
                )
            cls._inspect_conn.commit()
            cls._set_local(cursor, PRINCIPAL_C, TENANT_A)
            cursor.execute(
                "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
                (USER_C, PRINCIPAL_C, "active"),
            )
            cursor.execute(
                "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
                (TENANT_A, USER_C, "owner", "active"),
            )
            cls._inspect_conn.commit()
            cls._set_local(cursor, PRINCIPAL_B, TENANT_B)
            cursor.execute(
                "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s)",
                (TENANT_B, "tenant-b", "Tenant B", "active"),
            )
            cursor.execute(
                "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
                (USER_B, PRINCIPAL_B, "active"),
            )
            cursor.execute(
                "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
                (TENANT_B, USER_B, "owner", "active"),
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

    def _coordinator(self, resolver=None) -> FinanceMutationCoordinator:
        return FinanceMutationCoordinator(resolver or _resolver(), FinanceWriteRepository())

    def _session(self) -> FinancePgSession:
        return FinancePgSession(self._session_conn)

    def _counts(self, tenant_id: str, principal_id: str) -> dict[str, int]:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT COUNT(*) FROM ranchos.finance_accounts")
            accounts = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.finance_source_activities")
            activities = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.finance_interpretations")
            interpretations = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.finance_idempotency")
            idempotency = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.finance_mutation_audit")
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return {
            "accounts": accounts,
            "activities": activities,
            "interpretations": interpretations,
            "idempotency": idempotency,
            "audit": audit,
        }

    @classmethod
    def _run_sql_proof(cls, filename: str) -> subprocess.CompletedProcess[str]:
        workdir = cls._workdir
        proof = Path(__file__).resolve().parent / "rls" / filename
        return _run_pg(
            [
                str(cls._bindir / "psql"),
                "-h",
                str(workdir / "s"),
                "-p",
                "5432",
                "-U",
                "ranchos_dev_migrator",
                "-d",
                "ranchos_dev",
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                str(proof),
            ],
        )

    def test_rls_proof_sql_is_rollback_only_and_two_tenant(self) -> None:
        ran = self._rls_proof
        self.assertEqual(ran.returncode, 0, ran.stderr)
        sql = (Path(__file__).resolve().parent / "rls" / "two_tenant_finance_isolation.sql").read_text(encoding="utf-8")
        self.assertIn("Tenant A cross-tenant finance interpretation write was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance reverse was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance supersede was accepted", sql)
        self.assertIn("zero-line journal interpretation was accepted", sql)
        self.assertIn("one-line journal interpretation was accepted", sql)
        self.assertIn("supersede without reversal was accepted", sql)
        self.assertNotRegex(sql, r"(?m)^COMMIT;")

    def test_post_commit_immutability_sql_rejects_appended_posted_facts(self) -> None:
        isolation = (Path(__file__).resolve().parent / "rls" / "two_tenant_finance_isolation.sql").read_text(
            encoding="utf-8"
        )
        self.assertIn("Rollback-only", isolation)
        self.assertIn("ROLLBACK", isolation)
        self.assertNotRegex(isolation, r"(?m)^COMMIT;")
        sql = (Path(__file__).resolve().parent / "rls" / "finance_post_commit_immutability.sql").read_text(
            encoding="utf-8"
        )
        self.assertIn("SET LOCAL ROLE ranchos_dev_runtime", sql)
        self.assertIn("COMMIT;", sql)
        self.assertLess(sql.index("COMMIT;"), sql.index("extra balanced journal lines were accepted"))
        self.assertIn("posted journal lines are immutable", sql)
        self.assertIn("posted splits are immutable", sql)
        self.assertIn("SQLSTATE '23514'", sql)
        ran = self._immutability_proof
        self.assertEqual(ran.returncode, 0, ran.stderr)
        output = f"{ran.stdout}\n{ran.stderr}"
        self.assertIn("finance post-commit immutability: extra journal lines denied", output)
        self.assertIn("finance post-commit immutability: extra split denied", output)
        self.assertIn("finance post-commit immutability: original posting unchanged", output)

    def test_first_write_commits_account_audit_and_idempotency(self) -> None:
        now = datetime.now(timezone.utc)
        account = Account(f"acct-{uuid4()}", "Checking", AccountType.ASSET, "BancFirst")
        result = self._coordinator().create_account(
            principal=_principal(PRINCIPAL_A, "corr-first", now),
            requested_tenant_id=TENANT_A,
            request=FinanceAccountCreateRequest(
                account,
                FinanceFactProvenance("fixture", account.id, "fixture-v1", now),
                f"idem-{account.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.account.id, account.id)
        counts = self._counts(TENANT_A, PRINCIPAL_A)
        self.assertGreaterEqual(counts["accounts"], 1)
        self.assertGreaterEqual(counts["idempotency"], 1)
        self.assertGreaterEqual(counts["audit"], 1)

    def test_exact_replay_does_not_persist_or_audit_again(self) -> None:
        now = datetime.now(timezone.utc)
        account = Account(f"acct-{uuid4()}", "Replay", AccountType.ASSET)
        request = FinanceAccountCreateRequest(
            account,
            FinanceFactProvenance("fixture", account.id, "fixture-v1", now),
            f"idem-{account.id}",
            POLICY_VERSION,
            VALIDATOR_VERSION,
        )
        coordinator = self._coordinator()
        first = coordinator.create_account(
            principal=_principal(PRINCIPAL_A, "corr-replay", now),
            requested_tenant_id=TENANT_A,
            request=request,
            session=self._session(),
            now=now,
        )
        after_first = self._counts(TENANT_A, PRINCIPAL_A)
        replayed = coordinator.create_account(
            principal=_principal(PRINCIPAL_A, "corr-replay", now),
            requested_tenant_id=TENANT_A,
            request=request,
            session=self._session(),
            now=now,
        )
        after_replay = self._counts(TENANT_A, PRINCIPAL_A)
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(after_replay, after_first)

    def test_persist_failure_rolls_back(self) -> None:
        now = datetime.now(timezone.utc)
        before = self._counts(TENANT_A, PRINCIPAL_A)
        account = Account(f"acct-{uuid4()}", "Fail", AccountType.ASSET)
        with self.assertRaises(FinanceMutationError) as raised:
            self._coordinator().create_account(
                principal=_principal(PRINCIPAL_A, "corr-fail", now),
                requested_tenant_id=TENANT_A,
                request=FinanceAccountCreateRequest(
                    account,
                    FinanceFactProvenance("fixture", account.id, "fixture-v1", now),
                    f"idem-{account.id}",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=_PersistFailingSession(self._session()),
                now=now,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.TRANSACTION_FAILED)
        self.assertEqual(self._counts(TENANT_A, PRINCIPAL_A), before)

    def test_tenant_b_is_isolated_and_second_owner_can_reverse(self) -> None:
        now = datetime.now(timezone.utc)
        checking = Account(f"acct-{uuid4()}", "Checking", AccountType.ASSET)
        groceries = Account(f"exp-{uuid4()}", "Groceries", AccountType.EXPENSE)
        coordinator = self._coordinator()
        for account in (checking, groceries):
            coordinator.create_account(
                principal=_principal(PRINCIPAL_A, f"corr-{account.id}", now),
                requested_tenant_id=TENANT_A,
                request=FinanceAccountCreateRequest(
                    account,
                    FinanceFactProvenance("fixture", account.id, "fixture-v1", now),
                    f"idem-{account.id}",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=self._session(),
                now=now,
            )
        activity = SourceActivity(f"act-{uuid4()}", checking.id, now, "Store", Decimal("-12.00"))
        coordinator.record_source_activity(
            principal=_principal(PRINCIPAL_A, "corr-activity", now),
            requested_tenant_id=TENANT_A,
            request=FinanceSourceActivityRequest(
                activity,
                FinanceFactProvenance("fixture", activity.id, "fixture-v1", now),
                f"idem-{activity.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        splits = (
            Split(
                Decimal("-12.00"),
                groceries.id,
                AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.NONE),
            ),
        )
        interpretation = Interpretation(
            f"interp-{uuid4()}",
            activity.id,
            splits,
            expense_journal_from_splits(f"journal-{uuid4()}", now, checking.id, splits),
        )
        coordinator.post_interpretation(
            principal=_principal(PRINCIPAL_A, "corr-post", now),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationPostRequest(
                interpretation,
                FinanceFactProvenance("fixture", interpretation.id, "fixture-v1", now),
                f"idem-{interpretation.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["accounts"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["interpretations"], 0)
        manager = FinanceMutationCoordinator(_manager_resolver(), FinanceWriteRepository())
        with self.assertRaises(FinanceMutationError) as raised:
            manager.reverse_interpretation(
                principal=_principal(PRINCIPAL_A, "corr-manager", now),
                requested_tenant_id=TENANT_A,
                request=FinanceInterpretationReverseRequest(
                    interpretation.id,
                    f"rev-{uuid4()}",
                    FinanceFactProvenance("fixture", interpretation.id, "fixture-v1", now),
                    f"idem-manager-{interpretation.id}",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=self._session(),
                now=now,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)
        reversed_result = coordinator.reverse_interpretation(
            principal=_principal(PRINCIPAL_C, "corr-second-owner", now),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationReverseRequest(
                interpretation.id,
                f"rev-{uuid4()}",
                FinanceFactProvenance("fixture", interpretation.id, "fixture-v1", now),
                f"idem-reverse-{interpretation.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        self.assertEqual(reversed_result.interpretation.reverses_id, interpretation.id)
        self.assertEqual(
            reversed_result.interpretation.journal_entry.lines,
            reverse_journal_lines(interpretation.journal_entry.lines),
        )
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["interpretations"], 0)

    def test_posted_journal_and_splits_are_immutable_after_commit(self) -> None:
        interpretation = self._post_grocery()
        checking_id = interpretation.journal_entry.lines[1].account_id
        groceries_id = interpretation.splits[0].destination_account_id
        cursor = self._inspect_conn.cursor()
        try:
            self._begin_runtime(cursor)
            cursor.execute(
                """
                INSERT INTO ranchos.finance_journal_lines (
                    tenant_id, journal_entry_id, line_no, account_id, debit, credit
                ) VALUES (%s, %s, %s, %s, %s, %s), (%s, %s, %s, %s, %s, %s)
                """,
                (
                    TENANT_A, interpretation.journal_entry.id, 2, groceries_id, Decimal("1.00"), Decimal("0.00"),
                    TENANT_A, interpretation.journal_entry.id, 3, checking_id, Decimal("0.00"), Decimal("1.00"),
                ),
            )
            with self.assertRaises(Exception) as raised:
                self._inspect_conn.commit()
            self.assertEqual(getattr(raised.exception, "pgcode", None), "23514")
            self._inspect_conn.rollback()
        finally:
            cursor.close()
        cursor = self._inspect_conn.cursor()
        try:
            self._begin_runtime(cursor)
            cursor.execute(
                """
                INSERT INTO ranchos.finance_splits (
                    tenant_id, interpretation_id, split_no, amount, destination_account_id,
                    allocation_domain, allocation_target_type, allocation_target_id
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (TENANT_A, interpretation.id, 1, Decimal("-1.00"), groceries_id, "household", "none", None),
            )
            with self.assertRaises(Exception) as raised:
                self._inspect_conn.commit()
            self.assertEqual(getattr(raised.exception, "pgcode", None), "23514")
            self._inspect_conn.rollback()
        finally:
            cursor.close()
        loaded = self._load_interpretation(interpretation.id)
        self.assertEqual(len(loaded.journal_entry.lines), 2)
        self.assertEqual(loaded.journal_entry.lines, interpretation.journal_entry.lines)
        self.assertEqual(len(loaded.splits), 1)
        self.assertEqual(loaded.splits, interpretation.splits)

    def test_interpretation_journal_must_be_complete_at_commit(self) -> None:
        interpretation = self._post_grocery()
        activity_id = interpretation.source_activity_id
        groceries_id = interpretation.splits[0].destination_account_id
        checking_id = interpretation.journal_entry.lines[1].account_id
        self._assert_commit_check_violation(lambda cursor: self._insert_posting(cursor, activity_id, groceries_id, checking_id, line_count=0))
        self._assert_commit_check_violation(lambda cursor: self._insert_posting(cursor, activity_id, groceries_id, checking_id, line_count=1))
        control_id = self._insert_and_commit_posting(activity_id, groceries_id, checking_id, line_count=2)
        loaded = self._load_interpretation(control_id)
        self.assertEqual(len(loaded.journal_entry.lines), 2)
        self.assertEqual(loaded.journal_entry.lines[0].debit, loaded.journal_entry.lines[1].credit)

    def test_supersession_requires_paired_reversal(self) -> None:
        original = self._post_grocery()
        groceries_id = original.splits[0].destination_account_id
        checking_id = original.journal_entry.lines[1].account_id
        self._assert_commit_check_violation(
            lambda cursor: self._insert_posting(
                cursor,
                original.source_activity_id,
                groceries_id,
                checking_id,
                line_count=2,
                supersedes_id=original.id,
            )
        )
        now = datetime.now(timezone.utc)
        splits = (
            Split(
                Decimal("-12.00"),
                groceries_id,
                AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.NONE),
            ),
        )
        replacement = Interpretation(
            f"interp-{uuid4()}",
            original.source_activity_id,
            splits,
            expense_journal_from_splits(f"journal-{uuid4()}", now, checking_id, splits),
            supersedes_id=original.id,
        )
        result = self._coordinator().supersede_interpretation(
            principal=_principal(PRINCIPAL_A, "corr-supersede", now),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationSupersedeRequest(
                replacement,
                FinanceFactProvenance("fixture", replacement.id, "fixture-v1", now),
                f"idem-{replacement.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        self.assertEqual(result.interpretation.id, replacement.id)
        loaded = self._load_interpretation(replacement.id)
        self.assertEqual(loaded.supersedes_id, original.id)
        reversal = next(item for item in self._load_ledger().interpretations if item.reverses_id == original.id)
        self.assertEqual(reversal.journal_entry.lines, reverse_journal_lines(original.journal_entry.lines))

    def _post_grocery(self):
        now = datetime.now(timezone.utc)
        checking = Account(f"acct-{uuid4()}", "Checking", AccountType.ASSET)
        groceries = Account(f"exp-{uuid4()}", "Groceries", AccountType.EXPENSE)
        coordinator = self._coordinator()
        for account in (checking, groceries):
            coordinator.create_account(
                principal=_principal(PRINCIPAL_A, f"corr-{account.id}", now),
                requested_tenant_id=TENANT_A,
                request=FinanceAccountCreateRequest(
                    account,
                    FinanceFactProvenance("fixture", account.id, "fixture-v1", now),
                    f"idem-{account.id}",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=self._session(),
                now=now,
            )
        activity = SourceActivity(f"act-{uuid4()}", checking.id, now, "Store", Decimal("-12.00"))
        coordinator.record_source_activity(
            principal=_principal(PRINCIPAL_A, f"corr-{activity.id}", now),
            requested_tenant_id=TENANT_A,
            request=FinanceSourceActivityRequest(
                activity,
                FinanceFactProvenance("fixture", activity.id, "fixture-v1", now),
                f"idem-{activity.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        splits = (
            Split(
                Decimal("-12.00"),
                groceries.id,
                AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.NONE),
            ),
        )
        interpretation = Interpretation(
            f"interp-{uuid4()}",
            activity.id,
            splits,
            expense_journal_from_splits(f"journal-{uuid4()}", now, checking.id, splits),
        )
        coordinator.post_interpretation(
            principal=_principal(PRINCIPAL_A, f"corr-{interpretation.id}", now),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationPostRequest(
                interpretation,
                FinanceFactProvenance("fixture", interpretation.id, "fixture-v1", now),
                f"idem-{interpretation.id}",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=self._session(),
            now=now,
        )
        return interpretation

    def _begin_runtime(self, cursor) -> None:
        cursor.execute("SELECT set_config(%s, %s, true)", ("role", "ranchos_dev_runtime"))
        self._set_local(cursor, PRINCIPAL_A, TENANT_A)

    def _load_ledger(self):
        session = self._session()
        session.begin()
        session.set_local(principal_id=PRINCIPAL_A, environment="development", tenant_id=TENANT_A)
        try:
            return session.load_ledger(TENANT_A)
        finally:
            session.rollback()

    def _load_interpretation(self, interpretation_id: str):
        loaded = next(item for item in self._load_ledger().interpretations if item.id == interpretation_id)
        return loaded

    def _insert_posting(self, cursor, activity_id, groceries_id, checking_id, *, line_count, supersedes_id=None) -> str:
        journal_id = f"journal-{uuid4()}"
        interpretation_id = f"interp-{uuid4()}"
        cursor.execute(
            """
            INSERT INTO ranchos.finance_journal_entries (
                tenant_id, id, recorded_at, created_by_user_id
            ) VALUES (%s, %s, CURRENT_TIMESTAMP, %s)
            """,
            (TENANT_A, journal_id, USER_A),
        )
        if line_count >= 1:
            cursor.execute(
                """
                INSERT INTO ranchos.finance_journal_lines (
                    tenant_id, journal_entry_id, line_no, account_id, debit, credit
                ) VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (TENANT_A, journal_id, 0, groceries_id, Decimal("12.00"), Decimal("0.00")),
            )
        if line_count >= 2:
            cursor.execute(
                """
                INSERT INTO ranchos.finance_journal_lines (
                    tenant_id, journal_entry_id, line_no, account_id, debit, credit
                ) VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (TENANT_A, journal_id, 1, checking_id, Decimal("0.00"), Decimal("12.00")),
            )
        cursor.execute(
            """
            INSERT INTO ranchos.finance_interpretations (
                tenant_id, id, source_activity_id, journal_entry_id, supersedes_id, created_by_user_id
            ) VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (TENANT_A, interpretation_id, activity_id, journal_id, supersedes_id, USER_A),
        )
        cursor.execute(
            """
            INSERT INTO ranchos.finance_splits (
                tenant_id, interpretation_id, split_no, amount, destination_account_id,
                allocation_domain, allocation_target_type, allocation_target_id
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (TENANT_A, interpretation_id, 0, Decimal("-12.00"), groceries_id, "household", "none", None),
        )
        return interpretation_id

    def _assert_commit_check_violation(self, write) -> None:
        cursor = self._inspect_conn.cursor()
        try:
            self._begin_runtime(cursor)
            write(cursor)
            with self.assertRaises(Exception) as raised:
                self._inspect_conn.commit()
            self.assertEqual(getattr(raised.exception, "pgcode", None), "23514")
            self._inspect_conn.rollback()
        finally:
            cursor.close()

    def _insert_and_commit_posting(self, activity_id, groceries_id, checking_id, *, line_count) -> str:
        cursor = self._inspect_conn.cursor()
        try:
            self._begin_runtime(cursor)
            interpretation_id = self._insert_posting(cursor, activity_id, groceries_id, checking_id, line_count=line_count)
            self._inspect_conn.commit()
            return interpretation_id
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()


if __name__ == "__main__":
    unittest.main()
