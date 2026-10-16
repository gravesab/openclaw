#!/usr/bin/env python3
"""PropertyManager two-ranch tenancy proof on a disposable database.

Unit tests cover tenant-context resolution with no database. Database tests
build a unix-socket-only temporary PostgreSQL cluster for this process,
apply the ranchos tenancy foundation plus PropertyManager migrations
001-014 as the DEV migrator role, seed two ranches, and prove ranch A
cannot list, read, insert, update, or delete ranch B rows.

Fail-closed harness: missing PostgreSQL binaries, an unavailable driver,
or any setup failure raises instead of skipping. Nothing here touches the
live DEV database, the API, or Production: the cluster listens on no TCP
socket and the workdir is removed afterwards.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import venv
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from tools.property_manager.tenancy import (
    Capability,
    Role,
    TenancyError,
    TenancyErrorCode,
    TenantMembership,
    VerifiedPrincipal,
    open_session,
    require_capability,
)
from tools.property_manager.tenant_repository import TenantSession
from tools.property_manager import tenant_repository as repo

REPO_ROOT = Path(__file__).resolve().parents[3]
PM_DB_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
PM_MIGRATIONS = (
    "001_initial_schema.sql",
    "002_rich_task_model.sql",
    "003_part_quantity.sql",
    "004_task_origin.sql",
    "005_assets_and_meters.sql",
    "006_phase1_meter_audit.sql",
    "009_maintenance_proposals.sql",
    "010_handbook_ingestion_v1.sql",
    "011_work_request_intake.sql",
    "012_asset_manual_parts.sql",
    "013_asset_placed_in_service_date.sql",
    "014_propertymanager_tenancy.sql",
)
RANCHOS_FOUNDATION = REPO_ROOT / "ranchbrain_app" / "migrations" / "001_ranch_os_tenancy_foundation.sql"

BOOTSTRAP_TENANT = "11111111-1111-4111-8111-111111111111"
TENANT_B = "22222222-2222-4222-8222-222222222222"
USER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
USER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
USER_VIEWER = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
USER_MULTI = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
PRINCIPAL_A = "a0000000-0000-4000-8000-000000000001"
PRINCIPAL_B = "b0000000-0000-4000-8000-000000000002"
PRINCIPAL_VIEWER = "c0000000-0000-4000-8000-000000000003"
PRINCIPAL_MULTI = "d0000000-0000-4000-8000-000000000004"

PM_TABLES = (
    "maintenance_categories",
    "maintenance_tasks",
    "maintenance_completions",
    "maintenance_task_parts",
    "maintenance_task_photos",
    "assets",
    "asset_meter",
    "asset_meter_reading",
    "asset_task_mapping_proposals",
    "maintenance_proposals",
    "asset_manual",
    "asset_manual_version",
    "asset_manual_chunk",
    "asset_manual_state_event",
    "maintenance_attachment_operations",
    "maintenance_task_intake_events",
    "asset_manual_part",
)

DRIVER_SPEC = "psycopg2-binary==2.9.12"
ENVIRONMENT = "development"


def _principal(principal_id: str, correlation_id: str) -> VerifiedPrincipal:
    now = datetime.now(timezone.utc)
    return VerifiedPrincipal(
        id=principal_id,
        principal_type="human",
        environment=ENVIRONMENT,
        lifecycle_state="active",
        assurance_profile="mfa-fresh",
        session_reference="session-test",
        valid_from=now - timedelta(minutes=5),
        valid_until=now + timedelta(hours=1),
        correlation_id=correlation_id,
    )


class TenantContextUnitTests(unittest.TestCase):
    def test_single_membership_needs_no_hint(self) -> None:
        principal = _principal(PRINCIPAL_A, "corr-1")
        context = open_session(
            principal=principal,
            user_id=USER_A,
            memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
            environment=ENVIRONMENT,
            requested_tenant_id=None,
        )
        self.assertEqual(context.tenant_id, str(UUID(BOOTSTRAP_TENANT)))
        self.assertEqual(context.role, Role.OWNER)

    def test_single_membership_rejects_wrong_hint(self) -> None:
        principal = _principal(PRINCIPAL_A, "corr-2")
        with self.assertRaises(TenancyError) as raised:
            open_session(
                principal=principal,
                user_id=USER_A,
                memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
                environment=ENVIRONMENT,
                requested_tenant_id=TENANT_B,
            )
        self.assertEqual(raised.exception.code, TenancyErrorCode.TENANT_NOT_AUTHORIZED)

    def test_multi_membership_requires_explicit_selection(self) -> None:
        principal = _principal(PRINCIPAL_MULTI, "corr-3")
        memberships = [
            TenantMembership(BOOTSTRAP_TENANT, USER_MULTI, Role.MANAGER, "active"),
            TenantMembership(TENANT_B, USER_MULTI, Role.VIEWER, "active"),
        ]
        with self.assertRaises(TenancyError) as raised:
            open_session(
                principal=principal, user_id=USER_MULTI, memberships=memberships,
                environment=ENVIRONMENT, requested_tenant_id=None,
            )
        self.assertEqual(raised.exception.code, TenancyErrorCode.TENANT_CONTEXT_INVALID)
        chosen = open_session(
            principal=principal, user_id=USER_MULTI, memberships=memberships,
            environment=ENVIRONMENT, requested_tenant_id=TENANT_B,
        )
        self.assertEqual(chosen.tenant_id, str(UUID(TENANT_B)))
        self.assertEqual(chosen.role, Role.VIEWER)

    def test_suspended_revoked_and_missing_memberships_deny(self) -> None:
        principal = _principal(PRINCIPAL_A, "corr-4")
        for status in ("suspended", "revoked"):
            with self.subTest(status=status):
                with self.assertRaises(TenancyError):
                    open_session(
                        principal=principal,
                        user_id=USER_A,
                        memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, status)],
                        environment=ENVIRONMENT,
                        requested_tenant_id=BOOTSTRAP_TENANT,
                    )
        with self.assertRaises(TenancyError):
            open_session(
                principal=principal, user_id=USER_A, memberships=[],
                environment=ENVIRONMENT, requested_tenant_id=BOOTSTRAP_TENANT,
            )

    def test_stale_and_invalid_principals_deny(self) -> None:
        now = datetime.now(timezone.utc)
        stale = VerifiedPrincipal(
            id=PRINCIPAL_A,
            principal_type="human",
            environment=ENVIRONMENT,
            lifecycle_state="active",
            assurance_profile="mfa-fresh",
            session_reference="session-test",
            valid_from=now - timedelta(hours=2),
            valid_until=now - timedelta(hours=1),
            correlation_id="corr-5",
        )
        with self.assertRaises(TenancyError):
            open_session(
                principal=stale,
                user_id=USER_A,
                memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
                environment=ENVIRONMENT,
                requested_tenant_id=BOOTSTRAP_TENANT,
                now=now,
            )
        with self.assertRaises(TenancyError):
            VerifiedPrincipal(
                id="",
                principal_type="human",
                environment=ENVIRONMENT,
                lifecycle_state="active",
                assurance_profile="mfa-fresh",
                session_reference="session-test",
                valid_from=now,
                valid_until=now + timedelta(hours=1),
                correlation_id="corr-6",
            )

    def test_capability_matrix(self) -> None:
        principal = _principal(PRINCIPAL_A, "corr-7")
        owner = open_session(
            principal=principal,
            user_id=USER_A,
            memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
            environment=ENVIRONMENT,
            requested_tenant_id=None,
        )
        require_capability(owner, Capability.PROPERTY_READ)
        require_capability(owner, Capability.PROPERTY_WRITE)
        require_capability(owner, Capability.PROPERTY_ADMIN)
        manager = open_session(
            principal=_principal(PRINCIPAL_B, "corr-8"),
            user_id=USER_B,
            memberships=[TenantMembership(TENANT_B, USER_B, Role.MANAGER, "active")],
            environment=ENVIRONMENT,
            requested_tenant_id=None,
        )
        require_capability(manager, Capability.PROPERTY_READ)
        require_capability(manager, Capability.PROPERTY_WRITE)
        with self.assertRaises(TenancyError) as raised:
            require_capability(manager, Capability.PROPERTY_ADMIN)
        self.assertEqual(raised.exception.code, TenancyErrorCode.CAPABILITY_FORBIDDEN)
        viewer = open_session(
            principal=_principal(PRINCIPAL_VIEWER, "corr-9"),
            user_id=USER_VIEWER,
            memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_VIEWER, Role.VIEWER, "active")],
            environment=ENVIRONMENT,
            requested_tenant_id=None,
        )
        require_capability(viewer, Capability.PROPERTY_READ)
        with self.assertRaises(TenancyError):
            require_capability(viewer, Capability.PROPERTY_WRITE)

    def test_session_binds_environment_and_principal(self) -> None:
        principal = _principal(PRINCIPAL_A, "corr-10")
        with self.assertRaises(TenancyError):
            open_session(
                principal=principal,
                user_id=USER_A,
                memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
                environment="production",
                requested_tenant_id=BOOTSTRAP_TENANT,
            )
        session = open_session(
            principal=principal,
            user_id=USER_A,
            memberships=[TenantMembership(BOOTSTRAP_TENANT, USER_A, Role.OWNER, "active")],
            environment=ENVIRONMENT,
            requested_tenant_id=BOOTSTRAP_TENANT,
        )
        self.assertEqual(session.principal_id, str(UUID(PRINCIPAL_A)))
        self.assertEqual(session.environment, ENVIRONMENT)
        self.assertEqual(session.correlation_id, "corr-10")


class DisposableProofBlocked(RuntimeError):
    """Raised when the disposable tenancy proof cannot run. Never a pass."""


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
    raise DisposableProofBlocked("blocked: PostgreSQL binaries unavailable")


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
        "PROPERTYMANAGER_DB_HOST",
        "PROPERTYMANAGER_DB_PORT",
        "PROPERTYMANAGER_DB_NAME",
        "PROPERTYMANAGER_DB_USER",
        "PROPERTYMANAGER_DB_PASSWORD",
        "OPENCLAW_DB_HOST",
        "OPENCLAW_DB_PORT",
        "OPENCLAW_DB_NAME",
        "OPENCLAW_DB_USER",
        "OPENCLAW_DB_PASSWORD",
    ):
        env.pop(key, None)
    return env


def _run_pg(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command, input=input_text, check=False, capture_output=True, text=True, env=_pg_env()
    )


def _import_driver():
    try:
        import psycopg2  # noqa: F401

        return __import__("psycopg2")
    except ImportError:
        pass
    workdir = Path(tempfile.mkdtemp(prefix="pm-tenancy-driver"))
    try:
        venv_dir = workdir / "py"
        try:
            venv.create(venv_dir, with_pip=True, clear=True)
        except Exception as error:
            raise DisposableProofBlocked("blocked: test-local driver venv unavailable") from error
        installed = subprocess.run(
            [str(venv_dir / "bin" / "pip"), "install", "--disable-pip-version-check", DRIVER_SPEC],
            check=False,
            capture_output=True,
            text=True,
        )
        if installed.returncode != 0:
            raise DisposableProofBlocked("blocked: test-local driver unavailable")
        sites = list((venv_dir / "lib").glob("python*/site-packages"))
        if not sites:
            raise DisposableProofBlocked("blocked: test-local driver unavailable")
        if str(sites[0]) not in sys.path:
            sys.path.insert(0, str(sites[0]))
        try:
            import psycopg2
        except ImportError as error:
            raise DisposableProofBlocked("blocked: test-local driver unavailable") from error
        return psycopg2
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


class PropertyManagerTenancyDisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path
    _sockdir: str
    _dbname: str
    _psycopg2: object

    ASSET_A = "a0000001-0000-4000-8000-000000000001"
    ASSET_B = "b0000001-0000-4000-8000-000000000002"
    TASK_A = "a0000002-0000-4000-8000-000000000001"
    TASK_B = "b0000002-0000-4000-8000-000000000002"
    READING_A = "a0000003-0000-4000-8000-000000000001"
    COMPLETION_A = "a0000004-0000-4000-8000-000000000001"

    @classmethod
    def setUpClass(cls) -> None:
        cls._bindir = _bindir()
        cls._psycopg2 = _import_driver()
        cls._workdir = Path(tempfile.mkdtemp(prefix="pm-tenancy-pg"))
        cls._sockdir = str(cls._workdir / "s")
        cls._dbname = "pm_tenancy_proof"
        os.mkdir(cls._sockdir)
        try:
            cls._start_cluster()
            cls._create_roles()
            cls._apply_foundation()
            cls._apply_pm_chain()
            cls._apply_tenancy_migration()
            cls._seed_second_ranch()
            cls._seed_ranch_rows()
        except DisposableProofBlocked:
            cls._destroy_cluster()
            raise
        except Exception as error:
            cls._destroy_cluster()
            raise DisposableProofBlocked(f"blocked: disposable tenancy setup failed: {error}") from error

    @classmethod
    def tearDownClass(cls) -> None:
        cls._destroy_cluster()

    @classmethod
    def _destroy_cluster(cls) -> None:
        workdir = getattr(cls, "_workdir", None)
        bindir = getattr(cls, "_bindir", None)
        try:
            if workdir is not None and bindir is not None:
                data_dir = workdir / "data"
                if (data_dir / "PG_VERSION").is_file():
                    _run_pg([str(bindir / "pg_ctl"), "-D", str(data_dir), "-w", "-t", "10", "stop"])
        finally:
            if workdir is not None:
                shutil.rmtree(workdir, ignore_errors=True)

    @classmethod
    def _start_cluster(cls) -> None:
        data_dir = cls._workdir / "data"
        started = _run_pg(
            [
                str(cls._bindir / "initdb"),
                "-D",
                str(data_dir),
                "-U",
                "ranchos_boot",
                "--auth-local=trust",
                "--auth-host=reject",
            ]
        )
        if started.returncode != 0:
            raise DisposableProofBlocked("blocked: initdb failed")
        with (data_dir / "postgresql.conf").open("a", encoding="utf-8") as config:
            config.write(
                "\nlisten_addresses = ''\n"
                "port = 5432\n"
                f"unix_socket_directories = '{cls._sockdir}'\n"
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
        up = _run_pg(
            [
                str(cls._bindir / "pg_ctl"),
                "-D",
                str(data_dir),
                "-l",
                str(cls._workdir / "pg.log"),
                "-w",
                "-t",
                "20",
                "start",
            ]
        )
        if up.returncode != 0:
            raise DisposableProofBlocked("blocked: pg_ctl start failed")
        created = _run_pg(
            [
                str(cls._bindir / "psql"),
                "-h",
                cls._sockdir,
                "-U",
                "ranchos_boot",
                "-d",
                "postgres",
                "-X",
                "-c",
                f"CREATE DATABASE {cls._dbname}",
            ]
        )
        if created.returncode != 0:
            raise DisposableProofBlocked("blocked: disposable database creation failed")

    @classmethod
    def _connect(cls, dbname: str | None = None):
        return cls._psycopg2.connect(
            host=cls._sockdir, dbname=dbname or cls._dbname, user="ranchos_boot"
        )

    @classmethod
    def _apply_sql_file(cls, connection, path: Path, *, preamble: str = "") -> None:
        connection.autocommit = True
        try:
            with connection.cursor() as cursor:
                cursor.execute(preamble + path.read_text(encoding="utf-8"))
        finally:
            connection.autocommit = False

    @classmethod
    def _create_roles(cls) -> None:
        connection = cls._connect()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute("CREATE ROLE ranchos_dev_migrator NOLOGIN")
                cursor.execute("CREATE ROLE ranchos_dev_runtime NOLOGIN")
                cursor.execute("GRANT CREATE ON DATABASE %s TO ranchos_dev_migrator" % cls._dbname)
                cursor.execute("GRANT ranchos_dev_runtime TO ranchos_dev_migrator")
        finally:
            connection.close()

    @classmethod
    def _apply_foundation(cls) -> None:
        connection = cls._connect()
        try:
            cls._apply_sql_file(
                connection, RANCHOS_FOUNDATION, preamble="SET ROLE ranchos_dev_migrator;"
            )
        finally:
            connection.close()

    @classmethod
    def _apply_pm_chain(cls) -> None:
        discovered = tuple(sorted(path.name for path in PM_DB_DIR.glob("[0-9][0-9][0-9]_*.sql")))
        if discovered != PM_MIGRATIONS:
            raise DisposableProofBlocked(f"ambiguous migration chain: {discovered!r}")
        connection = cls._connect()
        try:
            for filename in PM_MIGRATIONS:
                if filename == "014_propertymanager_tenancy.sql":
                    continue
                if filename == "011_work_request_intake.sql":
                    # Same grandfathered legacy row the chain test uses: 002
                    # allowed it, 011 kept it readable, 014 must keep it too.
                    connection.autocommit = True
                    with connection.cursor() as cursor:
                        cursor.execute("SET ROLE ranchos_dev_migrator")
                        cursor.execute(
                            "INSERT INTO propertymanager.maintenance_tasks"
                            " (id, area, item, warning_days, critical_days, last_done, next_due, kind)"
                            " VALUES ('00000000-0000-0000-0000-000000000099', 'Legacy', 'Work request',"
                            " 0, 0, now(), now(), 'Work Request')"
                        )
                cls._apply_sql_file(
                    connection,
                    PM_DB_DIR / filename,
                    preamble="SET ROLE ranchos_dev_migrator;",
                )
        finally:
            connection.close()

    @classmethod
    def _apply_tenancy_migration(cls) -> None:
        connection = cls._connect()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute("SET ROLE ranchos_dev_migrator")
                cursor.execute("SET ranchos.tenant_id = '%s'" % BOOTSTRAP_TENANT)
                cursor.execute(
                    "INSERT INTO ranchos.tenants (id, slug, display_name, status)"
                    " VALUES (%s, 'bootstrap-ranch', 'Bootstrap Ranch', 'active')",
                    (BOOTSTRAP_TENANT,),
                )
            cls._apply_sql_file(
                connection,
                PM_DB_DIR / "014_propertymanager_tenancy.sql",
                preamble=(
                    "SET ROLE ranchos_dev_migrator;"
                    "SET app.pm_tenancy_014_apply = 'apply-dev-only';"
                    "SET app.bootstrap_tenant_id = '%s';" % BOOTSTRAP_TENANT
                ),
            )
        finally:
            connection.close()

    @classmethod
    def _seed_second_ranch(cls) -> None:
        connection = cls._connect()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute("SET ROLE ranchos_dev_migrator")
                cursor.execute("SET ranchos.tenant_id = '%s'" % TENANT_B)
                cursor.execute(
                    "INSERT INTO ranchos.tenants (id, slug, display_name, status)"
                    " VALUES (%s, 'second-ranch', 'Second Ranch', 'active')",
                    (TENANT_B,),
                )
                for user_id, principal_id in (
                    (USER_A, PRINCIPAL_A),
                    (USER_B, PRINCIPAL_B),
                    (USER_VIEWER, PRINCIPAL_VIEWER),
                    (USER_MULTI, PRINCIPAL_MULTI),
                ):
                    cursor.execute("SET ranchos.principal_id = '%s'" % principal_id)
                    cursor.execute(
                        "INSERT INTO ranchos.users (id, principal_id, status)"
                        " VALUES (%s, %s, 'active')",
                        (user_id, principal_id),
                    )
                for tenant_id, user_id, role in (
                    (BOOTSTRAP_TENANT, USER_A, "owner"),
                    (TENANT_B, USER_B, "owner"),
                    (BOOTSTRAP_TENANT, USER_VIEWER, "viewer"),
                    (BOOTSTRAP_TENANT, USER_MULTI, "manager"),
                    (TENANT_B, USER_MULTI, "viewer"),
                ):
                    cursor.execute("SET ranchos.tenant_id = '%s'" % tenant_id)
                    cursor.execute(
                        "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)"
                        " VALUES (%s, %s, %s, 'active')",
                        (tenant_id, user_id, role),
                    )
        finally:
            connection.close()

    @classmethod
    def _context(cls, principal_id, correlation_id, user_id, memberships, requested):
        return open_session(
            principal=_principal(principal_id, correlation_id),
            user_id=user_id,
            memberships=[
                TenantMembership(tenant_id, user_id, role, "active")
                for tenant_id, role in memberships
            ],
            environment=ENVIRONMENT,
            requested_tenant_id=requested,
        )

    @classmethod
    def _runtime_connection(cls, dbname=None):
        """A runtime-role connection: RLS enforced, grants proven.

        The harness connects as the bootstrap superuser over the private
        socket, then SET ROLEs to the runtime role for the whole session,
        exactly like a pooled application connection owned by that role.
        """
        connection = cls._connect(dbname)
        # SET ROLE inside a transaction is transactional: a later ROLLBACK
        # would silently restore the superuser and bypass RLS. Commit it
        # under autocommit first so the runtime role sticks for the session.
        connection.autocommit = True
        with connection.cursor() as cursor:
            cursor.execute("SET ROLE ranchos_dev_runtime")
        connection.autocommit = False
        return connection

    @classmethod
    def _seed_ranch_rows(cls) -> None:
        owner_a = cls._context(PRINCIPAL_A, "seed-a", USER_A, [(BOOTSTRAP_TENANT, Role.OWNER)], None)
        owner_b = cls._context(PRINCIPAL_B, "seed-b", USER_B, [(TENANT_B, Role.OWNER)], None)
        connection = cls._runtime_connection()
        try:
            with TenantSession(connection, owner_a) as session:
                repo.create_asset(
                    session, asset_id=cls.ASSET_A, external_id="asset-a-1",
                    name="Barn A", qr_token="qr-a-1",
                )
                repo.create_task(
                    session, task_id=cls.TASK_A, area="Barn", item="Inspect roof",
                    warning_days=7, critical_days=1, asset_id=cls.ASSET_A,
                )
                repo.record_reading(session, reading_id=cls.READING_A, asset_id=cls.ASSET_A, value=100)
                repo.record_completion(session, completion_id=cls.COMPLETION_A, task_id=cls.TASK_A, note="done")
            connection.commit()
            with TenantSession(connection, owner_b) as session:
                repo.create_asset(
                    session, asset_id=cls.ASSET_B, external_id="asset-b-1",
                    name="Barn B", qr_token="qr-b-1",
                )
                repo.create_task(
                    session, task_id=cls.TASK_B, area="Barn", item="Inspect roof",
                    warning_days=7, critical_days=1, asset_id=cls.ASSET_B,
                )
            connection.commit()
        finally:
            connection.close()

    def _owner_a(self):
        return self._context(PRINCIPAL_A, "ctx-a", USER_A, [(BOOTSTRAP_TENANT, Role.OWNER)], None)

    def _owner_b(self):
        return self._context(PRINCIPAL_B, "ctx-b", USER_B, [(TENANT_B, Role.OWNER)], None)

    def _viewer_a(self):
        return self._context(
            PRINCIPAL_VIEWER, "ctx-v", USER_VIEWER, [(BOOTSTRAP_TENANT, Role.VIEWER)], None
        )

    def test_rls_posture_on_every_tenant_table(self) -> None:
        connection = self._connect()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute("SET ROLE ranchos_dev_migrator")
                cursor.execute(
                    "SELECT c.relname, pg_get_userbyid(c.relowner), c.relrowsecurity,"
                    " c.relforcerowsecurity, count(p.polname)"
                    " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                    " LEFT JOIN pg_policy p ON p.polrelid = c.oid"
                    " WHERE n.nspname = 'propertymanager' AND c.relkind = 'r'"
                    " GROUP BY c.relname, c.relowner, c.relrowsecurity, c.relforcerowsecurity"
                )
                posture = {row[0]: row[1:] for row in cursor.fetchall()}
                self.assertEqual(set(posture), set(PM_TABLES))
                for table in PM_TABLES:
                    owner, enabled, forced, policies = posture[table]
                    self.assertEqual(owner, "ranchos_dev_migrator", table)
                    self.assertTrue(enabled, table)
                    self.assertTrue(forced, table)
                    self.assertGreaterEqual(policies, 1, table)
                cursor.execute(
                    "SELECT a.attname FROM pg_attribute a"
                    " JOIN pg_class c ON c.oid = a.attrelid"
                    " JOIN pg_namespace n ON n.oid = c.relnamespace"
                    " WHERE n.nspname = 'propertymanager' AND c.relkind = 'r'"
                    " AND a.attname = 'tenant_id' AND NOT a.attnotnull"
                )
                self.assertEqual(cursor.fetchall(), [])
                cursor.execute("SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ranchos_dev_runtime'")
                self.assertEqual(cursor.fetchone(), (False,))
                cursor.execute(
                    "SELECT conname FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace"
                    " WHERE n.nspname = 'propertymanager' AND conname IN"
                    " ('maintenance_categories_name_key', 'maintenance_tasks_area_item_unique',"
                    "  'assets_external_id_key', 'assets_qr_token_key')"
                )
                self.assertEqual(cursor.fetchall(), [])
        finally:
            connection.close()

    def test_ranch_a_cannot_list_or_read_ranch_b(self) -> None:
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, self._owner_a()) as session:
                asset_ids = {str(row[0]) for row in repo.list_assets(session)}
                self.assertIn(str(UUID(self.ASSET_A)), asset_ids)
                self.assertNotIn(str(UUID(self.ASSET_B)), asset_ids)
                self.assertIsNone(repo.get_asset(session, asset_id=self.ASSET_B))
                task_ids = {str(row[0]) for row in repo.list_tasks(session)}
                self.assertIn(str(UUID(self.TASK_A)), task_ids)
                self.assertNotIn(str(UUID(self.TASK_B)), task_ids)
                self.assertIsNone(repo.get_task(session, task_id=self.TASK_B))
                self.assertEqual(repo.list_readings(session, asset_id=self.ASSET_B), [])
                self.assertEqual(repo.list_completions(session, task_id=self.TASK_B), [])
            connection.commit()
        finally:
            connection.close()

    def test_ranch_a_cannot_insert_update_or_delete_ranch_b(self) -> None:
        connection = self._runtime_connection()
        try:
            with self.assertRaises(self._psycopg2.errors.InsufficientPrivilege):
                with TenantSession(connection, self._owner_a()):
                    with connection.cursor() as cursor:
                        cursor.execute(
                            "INSERT INTO propertymanager.assets (tenant_id, id, external_id, name, qr_token)"
                            " VALUES (%s, %s, 'x-b', 'Smuggled', 'qr-x')",
                            (TENANT_B, "c0000001-0000-4000-8000-000000000099"),
                        )
            connection.rollback()
            with TenantSession(connection, self._owner_a()) as session:
                updated = repo.update_asset_name(session, asset_id=self.ASSET_B, name="Renamed B")
                self.assertEqual(updated, 0)
                deleted = repo.delete_asset(session, asset_id=self.ASSET_B)
                self.assertEqual(deleted, 0)
                still_there = repo.get_asset(session, asset_id=self.ASSET_A)
                self.assertIsNotNone(still_there)
            connection.commit()
            with TenantSession(connection, self._owner_b()) as session:
                asset_b = repo.get_asset(session, asset_id=self.ASSET_B)
                self.assertIsNotNone(asset_b)
                self.assertEqual(asset_b[2], "Barn B")
            connection.commit()
        finally:
            connection.close()

    def test_cross_ranch_foreign_keys_fail(self) -> None:
        connection = self._runtime_connection()
        try:
            with self.assertRaises(self._psycopg2.errors.ForeignKeyViolation):
                with TenantSession(connection, self._owner_a()) as session:
                    repo.create_task(
                        session, task_id="c0000002-0000-4000-8000-000000000099",
                        area="Barn", item="Cross link", warning_days=1, critical_days=1,
                        asset_id=self.ASSET_B,
                    )
            connection.rollback()
            with self.assertRaises(self._psycopg2.errors.ForeignKeyViolation):
                with TenantSession(connection, self._owner_a()) as session:
                    repo.record_reading(
                        session, reading_id="c0000003-0000-4000-8000-000000000099",
                        asset_id=self.ASSET_B, value=5,
                    )
            connection.rollback()
            with self.assertRaises(self._psycopg2.errors.ForeignKeyViolation):
                with TenantSession(connection, self._owner_b()) as session:
                    repo.record_completion(
                        session, completion_id="c0000004-0000-4000-8000-000000000099",
                        task_id=self.TASK_A, note="cross",
                    )
            connection.rollback()
        finally:
            connection.close()

    def test_unfiltered_query_still_cannot_cross_ranches(self) -> None:
        # Deliberately unfiltered SQL through a plain cursor on the same
        # transaction: the repository offers no raw-SQL surface, so the
        # proof runs the adversary query directly.
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, self._owner_a()):
                with connection.cursor() as cursor:
                    cursor.execute("SELECT id FROM propertymanager.assets ORDER BY name")
                    found = {str(row[0]) for row in cursor.fetchall()}
                    self.assertIn(str(UUID(self.ASSET_A)), found)
                    self.assertNotIn(str(UUID(self.ASSET_B)), found)
                    cursor.execute("SELECT id FROM propertymanager.maintenance_tasks ORDER BY area, item")
                    found = {str(row[0]) for row in cursor.fetchall()}
                    self.assertIn(str(UUID(self.TASK_A)), found)
                    self.assertNotIn(str(UUID(self.TASK_B)), found)
            connection.commit()
        finally:
            connection.close()

    def test_missing_or_malformed_tenant_setting_fails_closed(self) -> None:
        connection = self._runtime_connection()
        try:
            with connection.cursor() as cursor:
                with self.assertRaises(self._psycopg2.errors.InvalidParameterValue):
                    cursor.execute("SELECT count(*) FROM propertymanager.assets")
                connection.rollback()
                cursor.execute("SET LOCAL ranchos.tenant_id = 'not-a-uuid'")
                with self.assertRaises(self._psycopg2.errors.InvalidParameterValue):
                    cursor.execute("SELECT count(*) FROM propertymanager.assets")
                connection.rollback()
        finally:
            connection.close()

    def test_viewer_reads_but_cannot_write(self) -> None:
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, self._viewer_a()) as session:
                self.assertEqual(len(repo.list_assets(session)), 1)
                with self.assertRaises(TenancyError) as raised:
                    repo.create_asset(
                        session, asset_id="c0000005-0000-4000-8000-000000000099",
                        external_id="asset-v", name="Viewer asset", qr_token="qr-v",
                    )
                self.assertEqual(raised.exception.code, TenancyErrorCode.CAPABILITY_FORBIDDEN)
            connection.commit()
        finally:
            connection.close()

    def test_only_owners_can_delete_assets(self) -> None:
        manager_a = self._context(
            PRINCIPAL_MULTI, "ctx-del-m", USER_MULTI,
            [(BOOTSTRAP_TENANT, Role.MANAGER), (TENANT_B, Role.VIEWER)], BOOTSTRAP_TENANT,
        )
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, manager_a) as session:
                with self.assertRaises(TenancyError) as raised:
                    repo.delete_asset(session, asset_id=self.ASSET_A)
                self.assertEqual(raised.exception.code, TenancyErrorCode.CAPABILITY_FORBIDDEN)
            connection.commit()
            with TenantSession(connection, self._viewer_a()) as session:
                with self.assertRaises(TenancyError) as raised:
                    repo.delete_asset(session, asset_id=self.ASSET_A)
                self.assertEqual(raised.exception.code, TenancyErrorCode.CAPABILITY_FORBIDDEN)
            connection.commit()
            doomed = "d0000001-0000-4000-8000-000000000001"
            with TenantSession(connection, self._owner_a()) as session:
                repo.create_asset(
                    session, asset_id=doomed, external_id="asset-doomed",
                    name="Doomed", qr_token="qr-doomed",
                )
                self.assertEqual(repo.delete_asset(session, asset_id=doomed), 1)
                self.assertIsNone(repo.get_asset(session, asset_id=doomed))
            connection.commit()
        finally:
            connection.close()

    def test_multi_membership_user_selects_explicitly(self) -> None:
        selected_b = self._context(
            PRINCIPAL_MULTI, "ctx-m", USER_MULTI,
            [(BOOTSTRAP_TENANT, Role.MANAGER), (TENANT_B, Role.VIEWER)], TENANT_B,
        )
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, selected_b) as session:
                asset_ids = {str(row[0]) for row in repo.list_assets(session)}
                self.assertEqual(asset_ids, {str(UUID(self.ASSET_B))})
            connection.commit()
        finally:
            connection.close()

    def test_legacy_work_request_survives_tenancy(self) -> None:
        legacy_id = "00000000-0000-0000-0000-000000000099"
        connection = self._runtime_connection()
        try:
            with TenantSession(connection, self._owner_a()):
                with connection.cursor() as cursor:
                    cursor.execute(
                        "SELECT intake_state, tenant_id FROM propertymanager.maintenance_tasks WHERE id = %s",
                        (legacy_id,),
                    )
                    row = cursor.fetchone()
                self.assertIsNotNone(row)
                self.assertIsNone(row[0])
                self.assertEqual(str(row[1]), str(UUID(BOOTSTRAP_TENANT)))
            connection.commit()
            with self.assertRaises(self._psycopg2.errors.CheckViolation):
                with TenantSession(connection, self._owner_a()):
                    with connection.cursor() as cursor:
                        cursor.execute(
                            "INSERT INTO propertymanager.maintenance_tasks"
                            " (tenant_id, id, area, item, warning_days, critical_days, last_done, next_due, kind)"
                            " VALUES (%s, %s, 'New', 'Work request', 0, 0, now(), now(), 'Work Request')",
                            (BOOTSTRAP_TENANT, "c0000006-0000-4000-8000-000000000099"),
                        )
            connection.rollback()
        finally:
            connection.close()

    def test_bootstrap_backfill_is_idempotent(self) -> None:
        updates = [
            "UPDATE propertymanager.%s SET tenant_id = '%s' WHERE tenant_id IS NULL" % (table, BOOTSTRAP_TENANT)
            for table in PM_TABLES
        ]
        # Replay as the bootstrap superuser so RLS cannot hide unscoped rows:
        # zero matches here proves no NULL tenant_id survived anywhere.
        connection = self._connect()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                for statement in updates:
                    cursor.execute(statement)
                    self.assertEqual(cursor.rowcount, 0, statement)
                cursor.execute(
                    "SELECT count(*) FROM propertymanager.maintenance_categories WHERE tenant_id = %s",
                    (BOOTSTRAP_TENANT,),
                )
                self.assertGreaterEqual(cursor.fetchone()[0], 8)
        finally:
            connection.close()

    def test_tenancy_migration_refuses_without_guards(self) -> None:
        migration = (PM_DB_DIR / "014_propertymanager_tenancy.sql").read_text(encoding="utf-8")
        cases = [
            ("wrong role", "SET ROLE ranchos_dev_runtime;", "SET app.pm_tenancy_014_apply = 'apply-dev-only';"
             "SET app.bootstrap_tenant_id = '%s';" % BOOTSTRAP_TENANT, "ranchos_dev_migrator"),
            ("missing apply setting", "SET ROLE ranchos_dev_migrator;",
             "SET app.bootstrap_tenant_id = '%s';" % BOOTSTRAP_TENANT, "app.pm_tenancy_014_apply"),
            ("missing bootstrap", "SET ROLE ranchos_dev_migrator;",
             "SET app.pm_tenancy_014_apply = 'apply-dev-only';", "app.bootstrap_tenant_id"),
            ("malformed bootstrap", "SET ROLE ranchos_dev_migrator;",
             "SET app.pm_tenancy_014_apply = 'apply-dev-only';SET app.bootstrap_tenant_id = 'nope';",
             "not a UUID"),
            ("unknown bootstrap", "SET ROLE ranchos_dev_migrator;",
             "SET app.pm_tenancy_014_apply = 'apply-dev-only';"
             "SET app.bootstrap_tenant_id = '99999999-9999-4999-8999-999999999999';",
             "must reference an active"),
        ]
        for index, (label, role_sql, settings_sql, expected) in enumerate(cases):
            with self.subTest(label):
                dbname = f"pm_tenancy_refuse_{index}"
                setup = self._connect("postgres")
                try:
                    setup.autocommit = True
                    with setup.cursor() as cursor:
                        cursor.execute(f"CREATE DATABASE {dbname} TEMPLATE {self._dbname}")
                finally:
                    setup.close()
                attempt = self._connect(dbname)
                try:
                    attempt.autocommit = True
                    with attempt.cursor() as cursor:
                        with self.assertRaises(self._psycopg2.Error) as raised:
                            cursor.execute(role_sql + settings_sql + migration)
                    self.assertIn(expected, str(raised.exception))
                finally:
                    attempt.close()
                verify = self._connect(dbname)
                try:
                    verify.autocommit = True
                    with verify.cursor() as cursor:
                        cursor.execute(
                            "SELECT count(*) FROM information_schema.columns "
                            "WHERE table_schema = 'propertymanager' AND column_name = 'tenant_id'"
                        )
                        # The refused migration rolled back: pre-existing tenant columns
                        # from the template stay, but nothing new was created.
                        self.assertEqual(cursor.fetchone()[0], len(PM_TABLES))
                finally:
                    verify.close()
                    teardown = self._connect("postgres")
                    try:
                        teardown.autocommit = True
                        with teardown.cursor() as cursor:
                            cursor.execute(f"DROP DATABASE {dbname}")
                    finally:
                        teardown.close()


    def test_migration_setting_does_not_leak_to_later_transactions(self) -> None:
        dbname = "pm_tenancy_setting_leak"
        setup = self._connect("postgres")
        try:
            setup.autocommit = True
            with setup.cursor() as cursor:
                cursor.execute(f"CREATE DATABASE {dbname}")
                cursor.execute(f"GRANT CREATE ON DATABASE {dbname} TO ranchos_dev_migrator")
        finally:
            setup.close()
        try:
            build = self._connect(dbname)
            try:
                self._apply_sql_file(
                    build, RANCHOS_FOUNDATION, preamble="SET ROLE ranchos_dev_migrator;"
                )
                build.autocommit = True
                with build.cursor() as cursor:
                    cursor.execute("SET ROLE ranchos_dev_migrator")
                    cursor.execute("SET ranchos.tenant_id = '%s'" % BOOTSTRAP_TENANT)
                    cursor.execute(
                        "INSERT INTO ranchos.tenants (id, slug, display_name, status)"
                        " VALUES (%s, 'bootstrap-ranch', 'Bootstrap Ranch', 'active')",
                        (BOOTSTRAP_TENANT,),
                    )
                for filename in PM_MIGRATIONS:
                    if filename == "014_propertymanager_tenancy.sql":
                        continue
                    self._apply_sql_file(
                        build, PM_DB_DIR / filename, preamble="SET ROLE ranchos_dev_migrator;"
                    )
            finally:
                build.close()
            migration = (PM_DB_DIR / "014_propertymanager_tenancy.sql").read_text(encoding="utf-8")
            apply = self._connect(dbname)
            try:
                apply.autocommit = True
                with apply.cursor() as cursor:
                    cursor.execute(
                        "SET ROLE ranchos_dev_migrator;"
                        "SET app.pm_tenancy_014_apply = 'apply-dev-only';"
                        "SET app.bootstrap_tenant_id = '%s';" % BOOTSTRAP_TENANT + migration
                    )
                # Same connection, later transaction: the bootstrap tenant
                # must not leak. (Postgres may leave an empty placeholder
                # for the custom variable; what matters is that no ranch
                # is visible and guarded reads fail closed.)
                with apply.cursor() as cursor:
                    cursor.execute("SELECT current_setting('ranchos.tenant_id', true)")
                    leaked = cursor.fetchone()[0]
                    self.assertNotEqual(leaked, BOOTSTRAP_TENANT)
                    self.assertNotEqual(leaked, str(UUID(BOOTSTRAP_TENANT)))
                    with self.assertRaises(self._psycopg2.errors.InvalidParameterValue):
                        cursor.execute("SELECT ranchos.require_uuid_setting('ranchos.tenant_id')")
                    cursor.execute(
                        "SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid"
                        " JOIN pg_namespace n ON n.oid = c.relnamespace"
                        " WHERE n.nspname = 'propertymanager'"
                    )
                    self.assertEqual(cursor.fetchone()[0], len(PM_TABLES))
            finally:
                apply.close()
        finally:
            teardown = self._connect("postgres")
            try:
                teardown.autocommit = True
                with teardown.cursor() as cursor:
                    cursor.execute(f"DROP DATABASE {dbname}")
            finally:
                teardown.close()


if __name__ == "__main__":
    unittest.main()
