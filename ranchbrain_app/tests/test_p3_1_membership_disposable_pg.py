"""Disposable Postgres proof for migration 007 and resolve_principal.

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
import unittest

from ranchbrain.api.membership import PostgresMembershipStore
from ranchbrain.tenancy import Capability, TenancyError, TenancyErrorCode, VerifiedPrincipal


ISSUER = "https://accounts.google.com"
SUBJECT = "subject-1"
USER = "00000000-0000-0000-0000-000000000011"
USER_UUID = "00000000-0000-0000-0000-000000000001"
TENANT = "00000000-0000-0000-0000-0000000000a1"
OTHER_TENANT = "00000000-0000-0000-0000-0000000000b2"
SUSPENDED_USER = "00000000-0000-0000-0000-000000000012"
SUSPENDED_UUID = "00000000-0000-0000-0000-000000000002"
REVOKED_USER = "00000000-0000-0000-0000-000000000013"
REVOKED_UUID = "00000000-0000-0000-0000-000000000003"
NOW = datetime(2026, 10, 3, 12, tzinfo=timezone.utc)


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


def _psycopg2():
    try:
        import psycopg2
    except ImportError as error:
        raise LiveProofBlocked("blocked: psycopg2 unavailable") from error
    return psycopg2


def _env() -> dict[str, str]:
    env = os.environ.copy()
    for key in ("PGPORT", "PGHOST", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGSERVICE", "DATABASE_URL"):
        env.pop(key, None)
    return env


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, env=_env())


def _principal(subject: str) -> VerifiedPrincipal:
    now = datetime.now(timezone.utc)
    return VerifiedPrincipal(
        id=f"google-oidc:{subject}",
        principal_type="human",
        environment="dev",
        lifecycle_state="active",
        assurance_profile="mfa-fresh",
        session_reference="session-disposable",
        valid_from=now - timedelta(minutes=1),
        valid_until=now + timedelta(hours=1),
        correlation_id="corr-p31",
    )


class P31MembershipDisposablePgTests(unittest.TestCase):
    _blocked: str | None = None

    @classmethod
    def setUpClass(cls) -> None:
        cls._conn = None
        cls._workdir = None
        cls._bindir = None
        try:
            cls._bindir = _bindir()
            cls._pg = _psycopg2()
            cls._workdir = Path(tempfile.mkdtemp(prefix="ranchbrain-p31-"))
            cls._start()
            cls._conn = cls._connect("ranchos_dev_migrator")
            cls._seed()
        except Exception as error:
            cls._destroy()
            cls._blocked = f"blocked: disposable p31 cluster setup failed: {error}"

    def setUp(self) -> None:
        if self._blocked:
            self.skipTest(self._blocked)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._destroy()

    @classmethod
    def _start(cls) -> None:
        workdir = cls._workdir
        data = workdir / "data"
        sock = workdir / "s"
        sock.mkdir()
        if _run([str(cls._bindir / "initdb"), "-D", str(data), "-U", "ranchos_boot",
                 "--auth-local=trust", "--auth-host=reject"]).returncode != 0:
            raise LiveProofBlocked("blocked: initdb failed")
        with (data / "postgresql.conf").open("a", encoding="utf-8") as config:
            config.write(
                "\nlisten_addresses = ''\nport = 5432\n"
                f"unix_socket_directories = '{sock}'\nunix_socket_permissions = 0700\n"
            )
        (data / "pg_hba.conf").write_text(
            "local all ranchos_boot trust\n"
            "local all ranchos_dev_migrator trust\n"
            "local all ranchos_dev_runtime trust\n"
            "host all all 127.0.0.1/32 reject\n"
            "host all all ::1/128 reject\n",
            encoding="utf-8",
        )
        if _run([str(cls._bindir / "pg_ctl"), "-D", str(data), "-l", str(workdir / "pg.log"),
                 "-w", "-t", "20", "start"]).returncode != 0:
            raise LiveProofBlocked("blocked: pg_ctl start failed")
        boot = [str(cls._bindir / "psql"), "-h", str(sock), "-p", "5432", "-U", "ranchos_boot",
                "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        for statement in (
            "CREATE ROLE ranchos_dev_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "CREATE ROLE ranchos_dev_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            "GRANT ranchos_dev_runtime TO ranchos_dev_migrator",
            "CREATE DATABASE ranchos_dev OWNER ranchos_dev_migrator",
            "REVOKE ALL ON DATABASE ranchos_dev FROM PUBLIC",
            "GRANT CONNECT ON DATABASE ranchos_dev TO ranchos_dev_migrator, ranchos_dev_runtime",
        ):
            if _run([*boot, "-c", statement]).returncode != 0:
                raise LiveProofBlocked("blocked: role provision failed")
        app = Path(__file__).resolve().parents[1]
        applied = _run([
            str(cls._bindir / "psql"), "-h", str(sock), "-p", "5432",
            "-U", "ranchos_dev_migrator", "-d", "ranchos_dev", "-v", "ON_ERROR_STOP=1",
            "-f", str(app / "migrations" / "001_ranch_os_tenancy_foundation.sql"),
            "-f", str(app / "migrations" / "007_ranchbrain_api_membership.sql"),
        ])
        if applied.returncode != 0:
            raise LiveProofBlocked(f"blocked: 001/007 apply failed: {applied.stderr}")

    @classmethod
    def _connect(cls, user: str):
        conn = cls._pg.connect(host=str(cls._workdir / "s"), port=5432, user=user, dbname="ranchos_dev")
        conn.autocommit = False
        return conn

    @classmethod
    def _seed(cls) -> None:
        cursor = cls._conn.cursor()
        try:
            cls._insert_member(cursor, USER, USER_UUID, TENANT, "tenant-a", "active", SUBJECT, None)
            cls._insert_member(cursor, SUSPENDED_USER, SUSPENDED_UUID, TENANT, "tenant-a", "suspended", "suspended-sub", None)
            cls._insert_member(cursor, REVOKED_USER, REVOKED_UUID, TENANT, "tenant-a", "active", "revoked-sub", NOW)
            cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", OTHER_TENANT))
            cursor.execute(
                "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s)",
                (OTHER_TENANT, "tenant-b", "Tenant B", "active"),
            )
            cls._conn.commit()
        except Exception:
            cls._conn.rollback()
            raise
        finally:
            cursor.close()

    @classmethod
    def _insert_member(cls, cursor, user_id, principal_uuid, tenant_id, slug, status, subject, revoked_at):
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", principal_uuid))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", tenant_id))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", "dev"))
        cursor.execute(
            "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (id) DO NOTHING",
            (tenant_id, slug, slug, "active"),
        )
        cursor.execute(
            "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
            (user_id, principal_uuid, status),
        )
        cursor.execute(
            "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
            (tenant_id, user_id, "owner", "active"),
        )
        cursor.execute(
            "INSERT INTO ranchos.oidc_principal_links (issuer, subject, user_id, revoked_at) VALUES (%s, %s, %s, %s)",
            (ISSUER, subject, user_id, revoked_at),
        )

    @classmethod
    def _destroy(cls) -> None:
        conn = getattr(cls, "_conn", None)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
        workdir = getattr(cls, "_workdir", None)
        bindir = getattr(cls, "_bindir", None)
        if workdir is not None and bindir is not None:
            _run([str(bindir / "pg_ctl"), "-D", str(workdir / "data"), "-m", "immediate", "stop"])
            shutil.rmtree(workdir, ignore_errors=True)
        cls._workdir = None

    def _store(self) -> PostgresMembershipStore:
        def connect():
            conn = self._connect("ranchos_dev_runtime")
            conn.autocommit = True
            return conn
        return PostgresMembershipStore(connect)

    def test_resolve_returns_owner_context(self):
        context = self._store().resolve_principal(
            issuer=ISSUER, subject=SUBJECT, tenant_id=TENANT,
            principal=_principal(SUBJECT), capability=Capability.MEMORY_READ,
        )
        assert context.user_id == USER
        assert context.tenant_id == TENANT
        assert context.role.value == "owner"
        assert context.principal_id == f"google-oidc:{SUBJECT}"

    def test_denials_raise_the_same_code(self):
        store = self._store()
        cases = (
            ("missing-subject", TENANT),
            ("revoked-sub", TENANT),
            ("suspended-sub", TENANT),
            (SUBJECT, OTHER_TENANT),
        )
        for subject, tenant in cases:
            with self.subTest(subject=subject, tenant=tenant):
                with self.assertRaises(TenancyError) as raised:
                    store.resolve_principal(
                        issuer=ISSUER, subject=subject, tenant_id=tenant,
                        principal=_principal(subject), capability=Capability.MEMORY_READ,
                    )
                assert raised.exception.code == TenancyErrorCode.TENANT_NOT_AUTHORIZED

    def test_runtime_cannot_select_links(self):
        conn = self._connect("ranchos_dev_runtime")
        conn.autocommit = True
        try:
            cursor = conn.cursor()
            with self.assertRaises(Exception) as raised:
                cursor.execute("SELECT issuer, subject FROM ranchos.oidc_principal_links")
            assert getattr(raised.exception, "pgcode", None) == "42501"
        finally:
            conn.close()
