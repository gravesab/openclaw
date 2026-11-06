"""Disposable-only proof of 005_finance_v1_foundation.sql and the Finance v1 read path.

Creates and destroys a unix-socket-only temporary cluster for this process (same
harness as the livestock disposable proofs). Applies 001 + 005 as
ranchos_dev_migrator, then proves constraints, triggers, transfer pairing, grants,
append-only audit, two-tenant RLS through ranchos_dev_runtime, and the read
contract end to end. Never reads an environment database URL or touches a
standing database. Missing binaries or the test-local driver block the proof;
they are not treated as a pass.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import venv
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

from ranchbrain.finance.pg_session import finance_read_session
from ranchbrain.finance.read_contract import FinanceReadContract
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, User, VerifiedPrincipal

PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
DRIVER_SPEC = "psycopg2-binary==2.9.12"
NOW = datetime(2026, 10, 15, 18, 0, tzinfo=timezone.utc)
TABLES = (
    "finance_domains", "finance_accounts", "finance_categories",
    "finance_transfers", "finance_transactions", "finance_audit_events",
)


class LiveProofBlocked(RuntimeError):
    """The disposable proof could not run; this is not a pass."""


def _bindir() -> Path:
    for directory in (
        Path("/opt/homebrew/opt/postgresql@16/bin"),
        Path("/opt/homebrew/opt/postgresql@17/bin"),
        Path("/usr/local/opt/postgresql@16/bin"),
        Path("/usr/lib/postgresql/16/bin"),
    ):
        if all((directory / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return directory
    located = shutil.which("pg_ctl")
    if located:
        directory = Path(located).resolve().parent
        if all((directory / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return directory
    raise LiveProofBlocked("blocked: PostgreSQL binaries unavailable")


def _bindir_or_skip() -> Path:
    """Missing PostgreSQL skips locally; CI sets RANCHOS_REQUIRE_PG_PROOFS=1 so it fails loudly."""
    try:
        return _bindir()
    except LiveProofBlocked as error:
        if os.environ.get("RANCHOS_REQUIRE_PG_PROOFS") == "1":
            raise
        raise unittest.SkipTest(str(error)) from error


def _pg_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in ("PGPORT", "PGHOST", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGSERVICE",
                "DATABASE_URL", "RANCHOS_TENANCY_TEST_DATABASE_URL"):
        env.pop(key, None)
    return env


def _run_pg(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, env=_pg_env())


def _principal(principal_id: str) -> VerifiedPrincipal:
    return VerifiedPrincipal(
        id=principal_id, principal_type="human", environment="development", lifecycle_state="active",
        assurance_profile="mfa-fresh", session_reference="s", valid_from=NOW - timedelta(minutes=5),
        valid_until=NOW + timedelta(minutes=5), correlation_id="req-1",
    )


def _resolver() -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=[User(id=USER_A, principal_id=PRINCIPAL_A), User(id=USER_B, principal_id=PRINCIPAL_B)],
        tenants=[Tenant(id=TENANT_A, slug="a", display_name="A"), Tenant(id=TENANT_B, slug="b", display_name="B")],
        memberships=[
            TenantMembership(tenant_id=TENANT_A, user_id=USER_A, role=Role.VIEWER),
            TenantMembership(tenant_id=TENANT_B, user_id=USER_B, role=Role.VIEWER),
        ],
    )


class FinanceV1DisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path | None
    _psycopg2: object
    _conn: object

    @classmethod
    def setUpClass(cls) -> None:
        cls._bindir = _bindir_or_skip()
        cls._workdir = Path(tempfile.mkdtemp(prefix="rfpg", dir="/tmp"))
        cls._conn = None
        try:
            cls._psycopg2 = cls._install_driver()
            cls._start_cluster()
            cls._conn = cls._connect()
            cls._seed()
        except LiveProofBlocked:
            cls._destroy_cluster()
            raise
        except Exception as error:
            cls._destroy_cluster()
            raise LiveProofBlocked(f"blocked: disposable finance cluster setup failed: {error}") from error

    @classmethod
    def tearDownClass(cls) -> None:
        cls._destroy_cluster()

    # -- harness -----------------------------------------------------------

    @classmethod
    def _install_driver(cls):
        venv_dir = cls._workdir / "py"
        try:
            venv.create(venv_dir, with_pip=True, clear=True)
        except Exception as error:
            raise LiveProofBlocked("blocked: test-local driver venv unavailable") from error
        installed = subprocess.run(
            [str(venv_dir / "bin" / "pip"), "install", "--disable-pip-version-check", DRIVER_SPEC],
            check=False, capture_output=True, text=True,
        )
        sites = list((venv_dir / "lib").glob("python*/site-packages"))
        if installed.returncode != 0 or not sites:
            raise LiveProofBlocked("blocked: test-local driver unavailable")
        if str(sites[0]) not in sys.path:
            sys.path.insert(0, str(sites[0]))
        try:
            import psycopg2
        except ImportError as error:
            raise LiveProofBlocked("blocked: test-local driver unavailable") from error
        return psycopg2

    @classmethod
    def _psql(cls, user: str, database: str) -> list[str]:
        return [str(cls._bindir / "psql"), "-h", str(cls._workdir / "s"), "-p", "5432",
                "-U", user, "-d", database, "-v", "ON_ERROR_STOP=1"]

    @classmethod
    def _start_cluster(cls) -> None:
        data_dir = cls._workdir / "data"
        (cls._workdir / "s").mkdir()
        if _run_pg([str(cls._bindir / "initdb"), "-D", str(data_dir), "-U", "ranchos_boot",
                    "--auth-local=trust", "--auth-host=reject"]).returncode != 0:
            raise LiveProofBlocked("blocked: initdb failed")
        with (data_dir / "postgresql.conf").open("a", encoding="utf-8") as config:
            config.write(
                "\nlisten_addresses = ''\nport = 5432\n"
                f"unix_socket_directories = '{cls._workdir / 's'}'\nunix_socket_permissions = 0700\n"
            )
        (data_dir / "pg_hba.conf").write_text(
            "local all ranchos_boot trust\nlocal all ranchos_dev_migrator trust\n"
            "local all ranchos_dev_runtime trust\nhost all all 127.0.0.1/32 reject\nhost all all ::1/128 reject\n",
            encoding="utf-8",
        )
        if _run_pg([str(cls._bindir / "pg_ctl"), "-D", str(data_dir), "-l", str(cls._workdir / "pg.log"),
                    "-w", "-t", "20", "start"]).returncode != 0:
            raise LiveProofBlocked("blocked: pg_ctl start failed")
        for statement in (
            "CREATE ROLE ranchos_dev_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "CREATE ROLE ranchos_dev_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "GRANT ranchos_dev_runtime TO ranchos_dev_migrator",
            "CREATE DATABASE ranchos_dev OWNER ranchos_dev_migrator",
            "REVOKE ALL ON DATABASE ranchos_dev FROM PUBLIC",
            "GRANT CONNECT ON DATABASE ranchos_dev TO ranchos_dev_migrator, ranchos_dev_runtime",
        ):
            if _run_pg([*cls._psql("ranchos_boot", "postgres"), "-c", statement]).returncode != 0:
                raise LiveProofBlocked("blocked: disposable role provision failed")
        migrations = Path(__file__).resolve().parents[1] / "migrations"
        applied = _run_pg([
            *cls._psql("ranchos_dev_migrator", "ranchos_dev"),
            "-f", str(migrations / "001_ranch_os_tenancy_foundation.sql"),
            "-f", str(migrations / "005_finance_v1_foundation.sql"),
        ])
        if applied.returncode != 0:
            # The migration itself failing is a real failure, not a blocked proof.
            raise AssertionError(f"001/005 apply failed:\n{applied.stderr[-4000:]}")

    @classmethod
    def _connect(cls):
        connection = cls._psycopg2.connect(host=str(cls._workdir / "s"), port=5432,
                                           user="ranchos_dev_migrator", dbname="ranchos_dev")
        connection.autocommit = False
        return connection

    @classmethod
    def _destroy_cluster(cls) -> None:
        connection = getattr(cls, "_conn", None)
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass
        cls._conn = None
        workdir = getattr(cls, "_workdir", None)
        if workdir is not None:
            _run_pg([str(cls._bindir / "pg_ctl"), "-D", str(workdir / "data"), "-m", "immediate", "stop"])
            shutil.rmtree(workdir, ignore_errors=True)
        cls._workdir = None

    @staticmethod
    def _set_local(cursor, tenant_id: str, principal_id: str) -> None:
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", principal_id))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", "development"))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", tenant_id))

    @contextmanager
    def _tx(self, tenant_id: str = TENANT_A, principal_id: str = PRINCIPAL_A, *, runtime: bool = False, commit: bool = False):
        """One transaction as the migrator (or runtime role), tenant-bound; rolled back unless commit."""
        cursor = self._conn.cursor()
        try:
            if runtime:
                cursor.execute("SELECT set_config('role', 'ranchos_dev_runtime', true)")
            self._set_local(cursor, tenant_id, principal_id)
            yield cursor
            if commit:
                self._conn.commit()
            else:
                self._conn.rollback()
        except Exception:
            self._conn.rollback()
            raise
        finally:
            cursor.close()

    def _sqlstate(self, statement: str, params: tuple = (), **tx) -> str:
        with self.assertRaises(self._psycopg2.Error) as raised:
            with self._tx(commit=True, **tx) as cursor:
                cursor.execute(statement, params)
        return raised.exception.pgcode

    @classmethod
    def _seed(cls) -> None:
        cursor = cls._conn.cursor()
        try:
            for tenant, principal, user, slug in ((TENANT_A, PRINCIPAL_A, USER_A, "a"), (TENANT_B, PRINCIPAL_B, USER_B, "b")):
                cls._set_local(cursor, tenant, principal)
                cursor.execute("INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, 'active')",
                               (tenant, slug, slug.upper()))
                cursor.execute("INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, 'active')",
                               (user, principal))
                cursor.execute("INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) "
                               "VALUES (%s, %s, 'viewer', 'active')", (tenant, user))
                cursor.execute("SELECT ranchos.finance_seed_domains()")
                cursor.execute("SELECT ranchos.finance_seed_domains()")  # idempotent
                cursor.execute("SELECT id FROM ranchos.finance_domains WHERE code = 'ranch'")
                ranch = cursor.fetchone()[0]
                cursor.execute("SELECT id FROM ranchos.finance_domains WHERE code = 'personal'")
                personal = cursor.fetchone()[0]
                cursor.execute(
                    "INSERT INTO ranchos.finance_accounts (tenant_id, default_domain_id, name, account_type) "
                    "VALUES (%s, %s, 'Checking', 'checking'), (%s, %s, 'Savings', 'savings'), (%s, %s, 'Personal card', 'credit') "
                    "RETURNING id",
                    (tenant, ranch, tenant, ranch, tenant, personal),
                )
                checking, savings, card = (row[0] for row in cursor.fetchall())
                cursor.execute(
                    "INSERT INTO ranchos.finance_categories (tenant_id, domain_id, name, category_type) "
                    "VALUES (%s, %s, 'Feed', 'expense') RETURNING id", (tenant, ranch))
                feed = cursor.fetchone()[0]
                amount = "-40.00" if tenant == TENANT_A else "-7.00"
                rows = [
                    (checking, ranch, feed, amount, "Feed  store ", "2026-10-03"),
                    (checking, ranch, None, "1000.00", "Cattle sale", "2026-10-04"),
                    (card, personal, None, "-99.00", "Groceries", "2026-10-05"),
                ]
                for account, domain, category, value, desc, day in rows:
                    cursor.execute(
                        "INSERT INTO ranchos.finance_transactions (tenant_id, account_id, domain_id, category_id, amount, "
                        "currency, description, normalized_description, transaction_date, source_type, dedup_fingerprint) "
                        "VALUES (%s, %s, %s, %s, %s, 'USD', %s, 'client-supplied', %s, 'manual', 'fp')",
                        (tenant, account, domain, category, value, desc.strip(), day),
                    )
                cursor.execute(
                    "INSERT INTO ranchos.finance_transfers (tenant_id, from_account_id, to_account_id, transfer_date, "
                    "currency, amount, status) VALUES (%s, %s, %s, '2026-10-06', 'USD', 500.00, 'confirmed') RETURNING id",
                    (tenant, checking, savings))
                transfer = cursor.fetchone()[0]
                for account, value in ((checking, "-500.00"), (savings, "500.00")):
                    cursor.execute(
                        "INSERT INTO ranchos.finance_transactions (tenant_id, account_id, domain_id, transfer_id, amount, "
                        "currency, description, normalized_description, transaction_date, source_type, dedup_fingerprint) "
                        "VALUES (%s, %s, %s, %s, %s, 'USD', 'Move to savings', 'x', '2026-10-06', 'manual', 'fp')",
                        (tenant, account, ranch, transfer, value))
                cls._conn.commit()
                if tenant == TENANT_A:
                    cls.ids = {"ranch": ranch, "checking": checking, "savings": savings, "feed": feed}
        except Exception:
            cls._conn.rollback()
            raise
        finally:
            cursor.close()

    # -- proofs ------------------------------------------------------------

    def test_tables_are_migrator_owned_with_forced_rls(self):
        with self._tx() as cursor:
            cursor.execute(
                "SELECT c.relname, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity "
                "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = 'ranchos' AND c.relname = ANY(%s) ORDER BY 1", (list(TABLES),))
            rows = cursor.fetchall()
        self.assertEqual([r[0] for r in rows], sorted(TABLES))
        self.assertTrue(all(r[1:] == ("ranchos_dev_migrator", True, True) for r in rows))

    def test_seed_is_idempotent_and_codes_are_immutable(self):
        with self._tx() as cursor:
            cursor.execute("SELECT code FROM ranchos.finance_domains ORDER BY sort_order")
            self.assertEqual([r[0] for r in cursor.fetchall()], ["personal", "ranch", "zero_g"])
        state = self._sqlstate("UPDATE ranchos.finance_domains SET code = 'zero_g' WHERE code = 'ranch'")
        self.assertIn(state, {"23514", "23505"})

    def test_transaction_constraints(self):
        base = ("INSERT INTO ranchos.finance_transactions (tenant_id, account_id, domain_id, amount, currency, description, "
                "normalized_description, transaction_date, source_type, source_row_number, dedup_fingerprint) "
                "VALUES (%s, %s, %s, %s, %s, %s, 'x', '2026-10-09', %s, %s, 'fp')")
        ids = self.ids
        cases = {
            "zero amount": (TENANT_A, ids["checking"], ids["ranch"], "0.00", "USD", "Zero", "manual", None),
            "currency mismatch": (TENANT_A, ids["checking"], ids["ranch"], "-1.00", "EUR", "Euro", "manual", None),
            "csv without row": (TENANT_A, ids["checking"], ids["ranch"], "-1.00", "USD", "CSV", "csv", None),
            "untrimmed description": (TENANT_A, ids["checking"], ids["ranch"], "-1.00", "USD", " pad", "manual", None),
            "cross-tenant account": (TENANT_A, "00000000-0000-0000-0000-00000000dead", ids["ranch"], "-1.00", "USD",
                                     "Ghost", "manual", None),
        }
        for name, params in cases.items():
            with self.subTest(name):
                self.assertIn(self._sqlstate(base, params), {"23514", "23503"})

    def test_normalized_description_is_derived_not_client_supplied(self):
        with self._tx() as cursor:
            cursor.execute("SELECT normalized_description FROM ranchos.finance_transactions WHERE description = 'Feed  store'")
            self.assertEqual(cursor.fetchone()[0], "feed store")

    def test_confirmed_transfer_requires_exactly_two_opposite_rows(self):
        ids = self.ids
        with self.assertRaises(self._psycopg2.Error) as raised:
            with self._tx(commit=True) as cursor:
                cursor.execute(
                    "INSERT INTO ranchos.finance_transfers (tenant_id, from_account_id, to_account_id, transfer_date, "
                    "currency, amount, status) VALUES (%s, %s, %s, '2026-10-07', 'USD', 25.00, 'confirmed') RETURNING id",
                    (TENANT_A, ids["checking"], ids["savings"]))
                transfer = cursor.fetchone()[0]
                cursor.execute(
                    "INSERT INTO ranchos.finance_transactions (tenant_id, account_id, domain_id, transfer_id, amount, "
                    "currency, description, normalized_description, transaction_date, source_type, dedup_fingerprint) "
                    "VALUES (%s, %s, %s, %s, -25.00, 'USD', 'Half', 'x', '2026-10-07', 'manual', 'fp')",
                    (TENANT_A, ids["checking"], ids["ranch"], transfer))
        self.assertEqual(raised.exception.pgcode, "23514")

    def test_runtime_is_read_only_and_audit_is_append_only(self):
        self.assertEqual(self._sqlstate(
            "INSERT INTO ranchos.finance_accounts (tenant_id, default_domain_id, name, account_type) "
            "VALUES (%s, %s, 'Sneaky', 'cash')", (TENANT_A, self.ids["ranch"]), runtime=True), "42501")
        self.assertEqual(self._sqlstate(
            "UPDATE ranchos.finance_transactions SET notes = 'x'", runtime=True), "42501")
        with self._tx(runtime=True, commit=True) as cursor:
            cursor.execute(
                "INSERT INTO ranchos.finance_audit_events (tenant_id, actor_user_id, principal_id, action, object_type, "
                "object_id, correlation_id) VALUES (%s, %s, %s, 'read', 'account', %s, 'req-1')",
                (TENANT_A, USER_A, PRINCIPAL_A, self.ids["checking"]))
        self.assertEqual(self._sqlstate("DELETE FROM ranchos.finance_audit_events", runtime=True), "42501")
        # Even the owning migrator cannot rewrite audit history.
        self.assertEqual(self._sqlstate("UPDATE ranchos.finance_audit_events SET action = 'edited'"), "42501")

    def test_runtime_sees_only_its_tenant(self):
        for tenant, principal, expected in ((TENANT_A, PRINCIPAL_A, Decimal("-40.00")), (TENANT_B, PRINCIPAL_B, Decimal("-7.00"))):
            with self._tx(tenant, principal, runtime=True) as cursor:
                cursor.execute("SELECT DISTINCT tenant_id::text FROM ranchos.finance_transactions")
                self.assertEqual([r[0] for r in cursor.fetchall()], [tenant])
                cursor.execute("SELECT amount FROM ranchos.finance_transactions WHERE category_id IS NOT NULL")
                self.assertEqual([r[0] for r in cursor.fetchall()], [expected])
        self.assertEqual(self._sqlstate("SELECT count(*) FROM ranchos.finance_accounts", tenant_id="",
                                        runtime=True), "22023")

    def test_read_contract_end_to_end_excludes_personal_and_transfers(self):
        @contextmanager
        def factory(context):
            with finance_read_session(self._conn, context) as repository:
                yield repository

        contract = FinanceReadContract(resolver=_resolver(), session_factory=factory, clock=lambda: NOW)
        summary = contract.monthly_summary(principal=_principal(PRINCIPAL_A), tenant_id=TENANT_A, month="2026-10")["data"]
        self.assertEqual((summary["total_income"], summary["total_expenses"], summary["net"]),
                         ("1000.00", "40.00", "960.00"))
        self.assertEqual((summary["transaction_count"], summary["transfer_count"]), (2, 1))
        top = contract.top_categories(principal=_principal(PRINCIPAL_A), tenant_id=TENANT_A, month="2026-10")["data"]
        self.assertEqual([(t["name"], t["amount"]) for t in top], [("Feed", "40.00")])
        other = contract.monthly_summary(principal=_principal(PRINCIPAL_B), tenant_id=TENANT_B, month="2026-10")["data"]
        self.assertEqual(other["total_expenses"], "7.00")


if __name__ == "__main__":
    unittest.main()
