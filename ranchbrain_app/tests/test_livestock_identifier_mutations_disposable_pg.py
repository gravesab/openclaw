"""Disposable-only identifier assign/retire coordinator proof through LivestockPgSession.

Creates and destroys a unix-socket-only temporary cluster and a temporary
psycopg2-binary==2.9.12 venv for this process. Does not read an environment
database URL, reuse tools/** clients, or leave a standing DEV database. Missing
binaries or the test-local driver block the proof; they are not treated as a pass.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from uuid import uuid4
import venv

from ranchbrain.livestock_mutation_coordinator import (
    LivestockAnimalCreateRequest,
    LivestockIdentifierAssignRequest,
    LivestockIdentifierRetireRequest,
    LivestockMutationCoordinator,
    LivestockMutationError,
    LivestockMutationErrorCode,
    canonical_animal_create_digest,
    canonical_identifier_assign_digest,
    canonical_identifier_retire_digest,
)
from ranchbrain.livestock_pg_session import LivestockPgSession
from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import (
    AnimalCreateCommandV1,
    AnimalIdentifierType,
    IdentifierAssignCommandV1,
    IdentifierRetireCommandV1,
    IdentifierRetirementReason,
)
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    IDENTIFIER_ASSIGN_OPERATION,
    IDENTIFIER_RETIRE_OPERATION,
    LivestockConfirmationRecord,
    LivestockWriteRepository,
)
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, User, VerifiedPrincipal


PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
POLICY_VERSION = "policy-v1"
VALIDATOR_VERSION = "validator-v1"
DRIVER_SPEC = "psycopg2-binary==2.9.12"


class LiveProofBlocked(RuntimeError):
    """Raised when the disposable live proof cannot run."""


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
        valid_from=now - timedelta(minutes=5),
        valid_until=now + timedelta(hours=1),
        correlation_id=correlation_id,
    )


def _resolver() -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=[User(USER_A, PRINCIPAL_A), User(USER_B, PRINCIPAL_B)],
        tenants=[Tenant(TENANT_A, "tenant-a", "Tenant A"), Tenant(TENANT_B, "tenant-b", "Tenant B")],
        memberships=[
            TenantMembership(TENANT_A, USER_A, Role.MANAGER),
            TenantMembership(TENANT_B, USER_B, Role.MANAGER),
        ],
    )


def _animal_command(animal_id: str, now: datetime, display_name: str = "Juniper") -> AnimalCreateCommandV1:
    return AnimalCreateCommandV1(
        animal_id,
        display_name,
        "cattle",
        "beef",
        "angus",
        LivestockFactProvenance("fixture", animal_id, "fixture-v1", now),
    )


def _assign_command(identifier_id: str, animal_id: str, now: datetime, value: str = "RB-104") -> IdentifierAssignCommandV1:
    return IdentifierAssignCommandV1(
        identifier_id,
        animal_id,
        AnimalIdentifierType.EAR_TAG,
        value,
        now,
        LivestockFactProvenance("fixture", identifier_id, "fixture-v1", now),
    )


def _retire_command(retirement_id: str, identifier_id: str, now: datetime) -> IdentifierRetireCommandV1:
    return IdentifierRetireCommandV1(
        retirement_id,
        identifier_id,
        IdentifierRetirementReason.REPLACED,
        now + timedelta(minutes=1),
        LivestockFactProvenance("fixture", retirement_id, "fixture-v1", now),
    )


class LivestockIdentifierMutationsDisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path | None
    _psycopg2: object
    _session_conn: object
    _inspect_conn: object

    @classmethod
    def setUpClass(cls) -> None:
        cls._bindir = _bindir()
        cls._workdir = Path(tempfile.mkdtemp(prefix="rid", dir="/tmp"))
        cls._session_conn = None
        cls._inspect_conn = None
        try:
            cls._psycopg2 = cls._install_driver()
            cls._start_cluster()
            cls._session_conn = cls._connect()
            cls._inspect_conn = cls._connect()
            cls._seed_tenancy()
        except LiveProofBlocked:
            cls._destroy_cluster()
            raise
        except Exception as error:
            cls._destroy_cluster()
            raise LiveProofBlocked(f"blocked: disposable identifier cluster setup failed: {error}") from error

    @classmethod
    def tearDownClass(cls) -> None:
        cls._destroy_cluster()

    @classmethod
    def _install_driver(cls):
        workdir = cls._workdir
        if workdir is None:
            raise LiveProofBlocked("blocked: disposable workdir missing")
        venv_dir = workdir / "py"
        try:
            venv.create(venv_dir, with_pip=True, clear=True)
        except Exception as error:
            raise LiveProofBlocked("blocked: test-local driver venv unavailable") from error
        pip = venv_dir / "bin" / "pip"
        installed = subprocess.run(
            [str(pip), "install", "--disable-pip-version-check", DRIVER_SPEC],
            check=False,
            capture_output=True,
            text=True,
        )
        if installed.returncode != 0:
            raise LiveProofBlocked("blocked: test-local driver unavailable")
        sites = list((venv_dir / "lib").glob("python*/site-packages"))
        if not sites:
            raise LiveProofBlocked("blocked: test-local driver unavailable")
        site_packages = str(sites[0])
        if site_packages not in sys.path:
            sys.path.insert(0, site_packages)
        try:
            import psycopg2
        except ImportError as error:
            raise LiveProofBlocked("blocked: test-local driver unavailable") from error
        return psycopg2

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
        migrator = [
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
        ]
        applied = _run_pg(
            [
                *migrator,
                "-f",
                str(app_root / "migrations" / "001_ranch_os_tenancy_foundation.sql"),
                "-f",
                str(app_root / "migrations" / "002_livestock_read_model_foundation.sql"),
                "-f",
                str(app_root / "migrations" / "003_livestock_identifier_idempotency_outcomes.sql"),
                "-f",
                str(app_root / "migrations" / "004_livestock_lifecycle_idempotency_outcomes.sql"),
            ],
        )
        if applied.returncode != 0:
            detail = (applied.stderr or applied.stdout or "").strip()
            raise LiveProofBlocked(f"blocked: committed 001/002/003/004 apply failed: {detail}")

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
            cursor.execute(
                "INSERT INTO ranchos.tenants (id, slug, display_name, status) VALUES (%s, %s, %s, %s)",
                (TENANT_A, "tenant-a", "Tenant A", "active"),
            )
            cursor.execute(
                "INSERT INTO ranchos.users (id, principal_id, status) VALUES (%s, %s, %s)",
                (USER_A, PRINCIPAL_A, "active"),
            )
            cursor.execute(
                "INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status) VALUES (%s, %s, %s, %s)",
                (TENANT_A, USER_A, "manager", "active"),
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
                (TENANT_B, USER_B, "manager", "active"),
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

    def _coordinator(self) -> LivestockMutationCoordinator:
        return LivestockMutationCoordinator(_resolver(), LivestockWriteRepository())

    def _session(self) -> LivestockPgSession:
        return LivestockPgSession(self._session_conn)

    def _insert_confirmation(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        user_id: str,
        confirmation_id: str,
        operation: str,
        target_manifest: str,
        digest: str,
        identity: str,
        issued_at: datetime,
        consumed_at: datetime | None = None,
    ) -> LivestockConfirmationRecord:
        expires_at = issued_at + timedelta(minutes=2)
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute(
                """
                INSERT INTO ranchos.livestock_confirmations (
                    tenant_id, id, actor_user_id, principal_id, operation, target_manifest,
                    command_digest, policy_version, validator_version, idempotency_identity,
                    issued_at, expires_at, consumed_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    confirmation_id,
                    user_id,
                    principal_id,
                    operation,
                    target_manifest,
                    digest,
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                    identity,
                    issued_at,
                    expires_at,
                    consumed_at,
                ),
            )
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return LivestockConfirmationRecord(
            confirmation_id,
            tenant_id,
            user_id,
            principal_id,
            operation,
            target_manifest,
            digest,
            POLICY_VERSION,
            VALIDATOR_VERSION,
            identity,
            issued_at,
            expires_at,
            consumed_at,
        )

    def _create_animal(self, tenant_id: str, principal_id: str, user_id: str, now: datetime, display_name: str) -> str:
        animal_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-animal-{animal_id}"
        command = _animal_command(animal_id, now, display_name)
        digest = canonical_animal_create_digest(
            tenant_id=tenant_id,
            command=command,
            confirmation_id=confirmation_id,
            idempotency_identity=identity,
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        confirmation = self._insert_confirmation(
            tenant_id=tenant_id,
            principal_id=principal_id,
            user_id=user_id,
            confirmation_id=confirmation_id,
            operation=ANIMAL_CREATE_OPERATION,
            target_manifest=command.id,
            digest=digest,
            identity=identity,
            issued_at=now,
        )
        result = self._coordinator().create_animal(
            principal=_principal(principal_id, f"corr-animal-{animal_id}", now),
            requested_tenant_id=tenant_id,
            request=LivestockAnimalCreateRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
            session=self._session(),
            now=now,
        )
        self.assertEqual(result.animal.id, animal_id)
        return animal_id

    def _assign(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        user_id: str,
        animal_id: str,
        now: datetime,
        value: str = "RB-104",
        identifier_id: str | None = None,
        identity: str | None = None,
        session: LivestockPgSession | None = None,
        issued_at: datetime | None = None,
        consumed_at: datetime | None = None,
        digest: str | None = None,
    ):
        identifier_id = identifier_id or str(uuid4())
        confirmation_id = str(uuid4())
        identity = identity or f"idem-assign-{identifier_id}"
        command = _assign_command(identifier_id, animal_id, now, value)
        computed = canonical_identifier_assign_digest(
            tenant_id=tenant_id,
            command=command,
            confirmation_id=confirmation_id,
            idempotency_identity=identity,
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        confirmation = self._insert_confirmation(
            tenant_id=tenant_id,
            principal_id=principal_id,
            user_id=user_id,
            confirmation_id=confirmation_id,
            operation=IDENTIFIER_ASSIGN_OPERATION,
            target_manifest=command.id,
            digest=computed if digest is None else digest,
            identity=identity,
            issued_at=issued_at or now,
            consumed_at=consumed_at,
        )
        return self._coordinator().assign_identifier(
            principal=_principal(principal_id, f"corr-assign-{identifier_id}", now),
            requested_tenant_id=tenant_id,
            request=LivestockIdentifierAssignRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
            session=session or self._session(),
            now=now,
        ), command, confirmation, identity

    def _retire(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        user_id: str,
        identifier_id: str,
        now: datetime,
        session: LivestockPgSession | None = None,
    ):
        retirement_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-retire-{retirement_id}"
        command = _retire_command(retirement_id, identifier_id, now)
        digest = canonical_identifier_retire_digest(
            tenant_id=tenant_id,
            command=command,
            confirmation_id=confirmation_id,
            idempotency_identity=identity,
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        confirmation = self._insert_confirmation(
            tenant_id=tenant_id,
            principal_id=principal_id,
            user_id=user_id,
            confirmation_id=confirmation_id,
            operation=IDENTIFIER_RETIRE_OPERATION,
            target_manifest=command.identifier_id,
            digest=digest,
            identity=identity,
            issued_at=now,
        )
        return self._coordinator().retire_identifier(
            principal=_principal(principal_id, f"corr-retire-{retirement_id}", now),
            requested_tenant_id=tenant_id,
            request=LivestockIdentifierRetireRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
            session=session or self._session(),
            now=now,
        ), command, confirmation, identity

    def _counts(self, tenant_id: str, principal_id: str) -> dict[str, int]:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT COUNT(*) FROM ranchos.animal_identifiers")
            identifiers = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.animal_identifier_retirements")
            retirements = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_idempotency")
            idempotency = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_confirmations WHERE consumed_at IS NOT NULL")
            consumed = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_mutation_audit")
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return {
            "identifiers": identifiers,
            "retirements": retirements,
            "idempotency": idempotency,
            "consumed": consumed,
            "audit": audit,
        }

    def _identifier_state(self, tenant_id: str, principal_id: str, identifier_id: str, identity: str) -> dict[str, object]:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT COUNT(*) FROM ranchos.animal_identifiers WHERE id = %s", (identifier_id,))
            identifiers = cursor.fetchone()[0]
            cursor.execute(
                "SELECT outcome, result_identifier_id, result_retirement_id FROM ranchos.livestock_idempotency WHERE identity = %s",
                (identity,),
            )
            idempotency = cursor.fetchone()
            cursor.execute(
                "SELECT COUNT(*) FROM ranchos.livestock_mutation_audit WHERE targets = %s",
                (identifier_id,),
            )
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return {
            "identifiers": identifiers,
            "idempotency": None
            if idempotency is None
            else (
                idempotency[0],
                None if idempotency[1] is None else str(idempotency[1]),
                None if idempotency[2] is None else str(idempotency[2]),
            ),
            "audit": audit,
        }

    def _confirmation_consumed_at(self, tenant_id: str, principal_id: str, confirmation_id: str) -> datetime | None:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT consumed_at FROM ranchos.livestock_confirmations WHERE id = %s", (confirmation_id,))
            row = cursor.fetchone()
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return None if row is None else row[0]

    def test_assign_first_write_and_exact_replay(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = self._create_animal(TENANT_A, PRINCIPAL_A, USER_A, now, "Assign")
        first, command, confirmation, identity = self._assign(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            animal_id=animal_id,
            now=now,
        )
        self.assertFalse(first.replayed)
        self.assertEqual(first.identifier.animal_id, animal_id)
        state = self._identifier_state(TENANT_A, PRINCIPAL_A, command.id, identity)
        self.assertEqual(state["identifiers"], 1)
        self.assertEqual(state["idempotency"], ("committed", command.id, None))
        self.assertIsNotNone(self._confirmation_consumed_at(TENANT_A, PRINCIPAL_A, confirmation.id))
        self.assertEqual(state["audit"], 1)

        replayed = self._coordinator().assign_identifier(
            principal=_principal(PRINCIPAL_A, "corr-assign-replay", now),
            requested_tenant_id=TENANT_A,
            request=LivestockIdentifierAssignRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
            session=self._session(),
            now=now,
        )
        after = self._identifier_state(TENANT_A, PRINCIPAL_A, command.id, identity)
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.identifier.id, first.identifier.id)
        self.assertEqual(replayed.identifier.audit, first.identifier.audit)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(after["identifiers"], 1)
        self.assertEqual(after["audit"], 1)
        self.assertEqual(after["idempotency"], ("committed", command.id, None))

    def test_retire_first_write_and_exact_replay(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = self._create_animal(TENANT_A, PRINCIPAL_A, USER_A, now, "Retire")
        assigned, assign_command, _, _ = self._assign(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            animal_id=animal_id,
            now=now,
            value="RB-RETIRE",
        )
        first, command, confirmation, identity = self._retire(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            identifier_id=assigned.identifier.id,
            now=now,
        )
        self.assertFalse(first.replayed)
        self.assertEqual(first.retirement.identifier_id, assign_command.id)
        self.assertEqual(first.retirement.provenance.source_type, "fixture")
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute(
                "SELECT outcome, result_retirement_id FROM ranchos.livestock_idempotency WHERE identity = %s",
                (identity,),
            )
            row = cursor.fetchone()
            cursor.execute("SELECT COUNT(*) FROM ranchos.animal_identifier_retirements WHERE id = %s", (command.id,))
            retirements = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_mutation_audit WHERE confirmation_id = %s", (confirmation.id,))
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        finally:
            cursor.close()
        self.assertEqual(retirements, 1)
        self.assertEqual(row[0], "committed")
        self.assertEqual(str(row[1]), command.id)
        self.assertEqual(audit, 1)

        replayed = self._coordinator().retire_identifier(
            principal=_principal(PRINCIPAL_A, "corr-retire-replay", now),
            requested_tenant_id=TENANT_A,
            request=LivestockIdentifierRetireRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
            session=self._session(),
            now=now,
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.retirement.id, first.retirement.id)
        self.assertEqual(replayed.retirement.audit, first.retirement.audit)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute("SELECT COUNT(*) FROM ranchos.animal_identifier_retirements WHERE id = %s", (command.id,))
            retirements = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_mutation_audit WHERE confirmation_id = %s", (confirmation.id,))
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        finally:
            cursor.close()
        self.assertEqual(retirements, 1)
        self.assertEqual(audit, 1)

    def test_cf2_rejection_rolls_back_assign(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = self._create_animal(TENANT_A, PRINCIPAL_A, USER_A, now, "CF2")
        before = self._counts(TENANT_A, PRINCIPAL_A)
        cases = (
            ("expired", now - timedelta(minutes=3), None, None),
            ("used", now, now - timedelta(seconds=5), None),
            ("unbound", now, None, "not-the-canonical-digest"),
        )
        for label, issued_at, consumed_at, digest in cases:
            with self.subTest(label=label):
                with self.assertRaises(LivestockMutationError) as raised:
                    self._assign(
                        tenant_id=TENANT_A,
                        principal_id=PRINCIPAL_A,
                        user_id=USER_A,
                        animal_id=animal_id,
                        now=now,
                        value=f"RB-{label}",
                        issued_at=issued_at,
                        consumed_at=consumed_at,
                        digest=digest,
                    )
                self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
                after = self._counts(TENANT_A, PRINCIPAL_A)
                self.assertEqual(after["identifiers"], before["identifiers"])
                self.assertEqual(after["retirements"], before["retirements"])
                self.assertEqual(after["audit"], before["audit"])

    def test_tenant_b_is_denied_and_isolated(self) -> None:
        now = datetime.now(timezone.utc)
        animal_a = self._create_animal(TENANT_A, PRINCIPAL_A, USER_A, now, "IsoA")
        assigned, command, confirmation, identity = self._assign(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            animal_id=animal_a,
            now=now,
            value="RB-ISO",
        )
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["identifiers"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["retirements"], 0)
        session = self._session()
        session.begin()
        session.set_local(principal_id=PRINCIPAL_B, environment="development", tenant_id=TENANT_B)
        self.assertIsNone(session.load_confirmation(confirmation.id))
        self.assertIsNone(session.load_idempotency(TENANT_A, IDENTIFIER_ASSIGN_OPERATION, identity))
        self.assertIsNone(session.lock_identifier(TENANT_A, assigned.identifier.id))
        session.rollback()
        with self.assertRaises(LivestockMutationError) as raised:
            self._coordinator().assign_identifier(
                principal=_principal(PRINCIPAL_B, "corr-iso-b", now),
                requested_tenant_id=TENANT_B,
                request=LivestockIdentifierAssignRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
                session=self._session(),
                now=now,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
        self.assertEqual(self._identifier_state(TENANT_A, PRINCIPAL_A, command.id, identity)["identifiers"], 1)
        self.assertEqual(self._identifier_state(TENANT_B, PRINCIPAL_B, command.id, identity)["identifiers"], 0)

    def test_concurrent_assign_one_wins_then_reuse_after_retire(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = self._create_animal(TENANT_A, PRINCIPAL_A, USER_A, now, "Race")
        first_id = str(uuid4())
        second_id = str(uuid4())
        first_confirmation_id = str(uuid4())
        second_confirmation_id = str(uuid4())
        first_identity = f"idem-race-{first_id}"
        second_identity = f"idem-race-{second_id}"
        first_command = _assign_command(first_id, animal_id, now, "RB-RACE")
        second_command = _assign_command(second_id, animal_id, now, "RB-RACE")
        first_confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=first_confirmation_id,
            operation=IDENTIFIER_ASSIGN_OPERATION,
            target_manifest=first_command.id,
            digest=canonical_identifier_assign_digest(
                tenant_id=TENANT_A,
                command=first_command,
                confirmation_id=first_confirmation_id,
                idempotency_identity=first_identity,
                policy_version=POLICY_VERSION,
                validator_version=VALIDATOR_VERSION,
            ),
            identity=first_identity,
            issued_at=now,
        )
        second_confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=second_confirmation_id,
            operation=IDENTIFIER_ASSIGN_OPERATION,
            target_manifest=second_command.id,
            digest=canonical_identifier_assign_digest(
                tenant_id=TENANT_A,
                command=second_command,
                confirmation_id=second_confirmation_id,
                idempotency_identity=second_identity,
                policy_version=POLICY_VERSION,
                validator_version=VALIDATOR_VERSION,
            ),
            identity=second_identity,
            issued_at=now,
        )
        results = []
        errors = []

        def worker(command, confirmation, identity, correlation):
            connection = self._connect()
            try:
                result = self._coordinator().assign_identifier(
                    principal=_principal(PRINCIPAL_A, correlation, now),
                    requested_tenant_id=TENANT_A,
                    request=LivestockIdentifierAssignRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION),
                    session=LivestockPgSession(connection),
                    now=now,
                )
                results.append(result)
            except LivestockMutationError as error:
                errors.append(error)
            finally:
                connection.close()

        threads = [
            threading.Thread(target=worker, args=(first_command, first_confirmation, first_identity, "corr-race-1")),
            threading.Thread(target=worker, args=(second_command, second_confirmation, second_identity, "corr-race-2")),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(results), 1)
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].code, LivestockMutationErrorCode.IDENTIFIER_NOT_AVAILABLE)
        winner = results[0].identifier
        self.assertEqual(winner.normalized_value, "RB-RACE")
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute("SELECT id FROM ranchos.animal_identifiers WHERE normalized_value = %s ORDER BY id", ("RB-RACE",))
            assignment_ids = [str(row[0]) for row in cursor.fetchall()]
            self._inspect_conn.commit()
        finally:
            cursor.close()
        self.assertEqual(assignment_ids, [winner.id])

        retired, _, _, _ = self._retire(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            identifier_id=winner.id,
            now=now,
        )
        self.assertEqual(retired.retirement.identifier_id, winner.id)
        reused, reuse_command, _, _ = self._assign(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            animal_id=animal_id,
            now=now + timedelta(minutes=2),
            value="RB-RACE",
        )
        self.assertNotEqual(reused.identifier.id, winner.id)
        self.assertEqual(reused.identifier.id, reuse_command.id)
        self.assertEqual(reused.identifier.normalized_value, "RB-RACE")
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, PRINCIPAL_A, TENANT_A)
            cursor.execute("SELECT id FROM ranchos.animal_identifiers WHERE normalized_value = %s ORDER BY created_at, id", ("RB-RACE",))
            assignment_ids = [str(row[0]) for row in cursor.fetchall()]
            self._inspect_conn.commit()
        finally:
            cursor.close()
        self.assertEqual(len(assignment_ids), 2)
        self.assertIn(winner.id, assignment_ids)
        self.assertIn(reused.identifier.id, assignment_ids)


if __name__ == "__main__":
    unittest.main()
