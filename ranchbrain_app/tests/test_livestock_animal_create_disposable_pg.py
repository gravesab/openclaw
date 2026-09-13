"""Disposable-only animal_create coordinator proof through LivestockPgSession.

Creates and destroys a unix-socket-only temporary cluster for this process.
Does not read an environment database URL, reuse tools/** clients, or leave a
standing DEV database. Missing binaries or the test-local driver block the
proof; they are not treated as a pass.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from uuid import uuid4

from ranchbrain.livestock_mutation_coordinator import (
    LivestockAnimalCreateRequest,
    LivestockMutationCoordinator,
    LivestockMutationError,
    LivestockMutationErrorCode,
    canonical_animal_create_digest,
)
from ranchbrain.livestock_pg_session import LivestockPgSession
from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import AnimalCreateCommandV1
from ranchbrain.livestock_write_repository import LivestockConfirmationRecord, LivestockWriteRepository
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, User, VerifiedPrincipal

try:
    import psycopg2
except ImportError:
    psycopg2 = None


PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
POLICY_VERSION = "policy-v1"
VALIDATOR_VERSION = "validator-v1"


class LiveProofBlocked(RuntimeError):
    """Raised when the disposable live proof cannot run."""


class _PersistFailingSession:
    def __init__(self, session: LivestockPgSession):
        self._session = session

    def begin(self) -> None:
        self._session.begin()

    def set_local(self, *, principal_id: str, environment: str, tenant_id: str) -> None:
        self._session.set_local(principal_id=principal_id, environment=environment, tenant_id=tenant_id)

    def current_timestamp(self) -> datetime:
        return self._session.current_timestamp()

    def load_confirmation(self, confirmation_id: str):
        return self._session.load_confirmation(confirmation_id)

    def mark_confirmation_consumed(self, confirmation_id: str, consumed_at: datetime) -> None:
        self._session.mark_confirmation_consumed(confirmation_id, consumed_at)

    def load_idempotency(self, tenant_id: str, scope: str, identity: str):
        return self._session.load_idempotency(tenant_id, scope, identity)

    def insert_idempotency_reservation(self, record) -> None:
        self._session.insert_idempotency_reservation(record)

    def finalize_idempotency(self, record) -> None:
        self._session.finalize_idempotency(record)

    def insert_animal(self, animal) -> None:
        self._session.insert_animal(animal)
        raise RuntimeError("forced persist failure")

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


def _command(animal_id: str, now: datetime, display_name: str = "Juniper") -> AnimalCreateCommandV1:
    return AnimalCreateCommandV1(
        animal_id,
        display_name,
        "cattle",
        "beef",
        "angus",
        LivestockFactProvenance("fixture", animal_id, "fixture-v1", now),
    )


def _digest(tenant_id: str, command: AnimalCreateCommandV1, confirmation_id: str, identity: str) -> str:
    return canonical_animal_create_digest(
        tenant_id=tenant_id,
        command=command,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version=POLICY_VERSION,
        validator_version=VALIDATOR_VERSION,
    )


def _request(command: AnimalCreateCommandV1, confirmation: LivestockConfirmationRecord, identity: str) -> LivestockAnimalCreateRequest:
    return LivestockAnimalCreateRequest(command, confirmation, identity, POLICY_VERSION, VALIDATOR_VERSION)


class LivestockAnimalCreateDisposablePgTests(unittest.TestCase):
    _bindir: Path
    _workdir: Path | None
    _session_conn: object
    _inspect_conn: object

    @classmethod
    def setUpClass(cls) -> None:
        if psycopg2 is None:
            raise LiveProofBlocked("blocked: test-local driver unavailable")
        cls._bindir = _bindir()
        cls._workdir = Path(tempfile.mkdtemp(prefix="rpg", dir="/tmp"))
        cls._session_conn = None
        cls._inspect_conn = None
        try:
            cls._start_cluster()
            cls._session_conn = cls._connect()
            cls._inspect_conn = cls._connect()
            cls._seed_tenancy()
        except Exception:
            cls._destroy_cluster()
            raise

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
                str(app_root / "migrations" / "002_livestock_read_model_foundation.sql"),
            ],
        )
        if applied.returncode != 0:
            raise LiveProofBlocked("blocked: committed 001/002 apply failed")

    @classmethod
    def _connect(cls):
        workdir = cls._workdir
        if workdir is None or psycopg2 is None:
            raise LiveProofBlocked("blocked: disposable connection prerequisites missing")
        connection = psycopg2.connect(
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
        command: AnimalCreateCommandV1,
        identity: str,
        issued_at: datetime,
        consumed_at: datetime | None = None,
        command_digest: str | None = None,
    ) -> LivestockConfirmationRecord:
        expires_at = issued_at + timedelta(minutes=2)
        digest = command_digest if command_digest is not None else _digest(tenant_id, command, confirmation_id, identity)
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
                    "ranchos.livestock.animal-create",
                    command.id,
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
            "ranchos.livestock.animal-create",
            command.id,
            digest,
            POLICY_VERSION,
            VALIDATOR_VERSION,
            identity,
            issued_at,
            expires_at,
            consumed_at,
        )

    def _counts(self, tenant_id: str, principal_id: str) -> dict[str, int]:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_animals")
            animals = cursor.fetchone()[0]
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
        return {"animals": animals, "idempotency": idempotency, "consumed": consumed, "audit": audit}

    def _row_state(self, tenant_id: str, principal_id: str, animal_id: str, confirmation_id: str, identity: str) -> dict[str, object]:
        cursor = self._inspect_conn.cursor()
        try:
            self._set_local(cursor, principal_id, tenant_id)
            cursor.execute("SELECT COUNT(*) FROM ranchos.livestock_animals WHERE id = %s", (animal_id,))
            animals = cursor.fetchone()[0]
            cursor.execute(
                "SELECT outcome, result_animal_id FROM ranchos.livestock_idempotency WHERE identity = %s",
                (identity,),
            )
            idempotency = cursor.fetchone()
            cursor.execute(
                "SELECT consumed_at FROM ranchos.livestock_confirmations WHERE id = %s",
                (confirmation_id,),
            )
            confirmation = cursor.fetchone()
            cursor.execute(
                "SELECT COUNT(*) FROM ranchos.livestock_mutation_audit WHERE confirmation_id = %s",
                (confirmation_id,),
            )
            audit = cursor.fetchone()[0]
            self._inspect_conn.commit()
        except Exception:
            self._inspect_conn.rollback()
            raise
        finally:
            cursor.close()
        return {
            "animals": animals,
            "idempotency": None if idempotency is None else (idempotency[0], None if idempotency[1] is None else str(idempotency[1])),
            "consumed_at": None if confirmation is None else confirmation[0],
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

    def test_first_write_commits_animal_confirmation_audit_and_idempotency(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-first-{animal_id}"
        command = _command(animal_id, now)
        confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=confirmation_id,
            command=command,
            identity=identity,
            issued_at=now,
        )
        result = self._coordinator().create_animal(
            principal=_principal(PRINCIPAL_A, "corr-first", now),
            requested_tenant_id=TENANT_A,
            request=_request(command, confirmation, identity),
            session=self._session(),
            now=now,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.animal.id, animal_id)
        self.assertEqual(result.idempotency_outcome, "committed")
        state = self._row_state(TENANT_A, PRINCIPAL_A, animal_id, confirmation_id, identity)
        self.assertEqual(state["animals"], 1)
        self.assertEqual(state["idempotency"], ("committed", animal_id))
        self.assertIsNotNone(state["consumed_at"])
        self.assertEqual(state["audit"], 1)

    def test_exact_replay_does_not_consume_persist_or_audit_again(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-replay-{animal_id}"
        command = _command(animal_id, now, "Replay")
        confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=confirmation_id,
            command=command,
            identity=identity,
            issued_at=now,
        )
        coordinator = self._coordinator()
        first = coordinator.create_animal(
            principal=_principal(PRINCIPAL_A, "corr-replay", now),
            requested_tenant_id=TENANT_A,
            request=_request(command, confirmation, identity),
            session=self._session(),
            now=now,
        )
        after_first = self._row_state(TENANT_A, PRINCIPAL_A, animal_id, confirmation_id, identity)
        replayed = coordinator.create_animal(
            principal=_principal(PRINCIPAL_A, "corr-replay", now),
            requested_tenant_id=TENANT_A,
            request=_request(command, confirmation, identity),
            session=self._session(),
            now=now,
        )
        after_replay = self._row_state(TENANT_A, PRINCIPAL_A, animal_id, confirmation_id, identity)
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.animal.id, first.animal.id)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(after_replay["consumed_at"], after_first["consumed_at"])
        self.assertEqual(after_replay["animals"], 1)
        self.assertEqual(after_replay["audit"], 1)
        self.assertEqual(after_replay["idempotency"], ("committed", animal_id))

    def test_expired_used_and_unbound_confirmation_rolls_back(self) -> None:
        now = datetime.now(timezone.utc)
        coordinator = self._coordinator()
        cases = (
            ("expired", now - timedelta(minutes=3), None, None),
            ("used", now, now - timedelta(seconds=5), None),
            ("unbound", now, None, "not-the-canonical-digest"),
        )
        for label, issued_at, consumed_at, digest in cases:
            with self.subTest(label=label):
                animal_id = str(uuid4())
                confirmation_id = str(uuid4())
                identity = f"idem-{label}-{animal_id}"
                command = _command(animal_id, now, label)
                confirmation = self._insert_confirmation(
                    tenant_id=TENANT_A,
                    principal_id=PRINCIPAL_A,
                    user_id=USER_A,
                    confirmation_id=confirmation_id,
                    command=command,
                    identity=identity,
                    issued_at=issued_at,
                    consumed_at=consumed_at,
                    command_digest=digest,
                )
                before = self._counts(TENANT_A, PRINCIPAL_A)
                with self.assertRaises(LivestockMutationError) as raised:
                    coordinator.create_animal(
                        principal=_principal(PRINCIPAL_A, f"corr-{label}", now),
                        requested_tenant_id=TENANT_A,
                        request=_request(command, confirmation, identity),
                        session=self._session(),
                        now=now,
                    )
                self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
                after = self._counts(TENANT_A, PRINCIPAL_A)
                self.assertEqual(after["animals"], before["animals"])
                self.assertEqual(after["idempotency"], before["idempotency"])
                self.assertEqual(after["audit"], before["audit"])
                if consumed_at is None:
                    self.assertIsNone(self._confirmation_consumed_at(TENANT_A, PRINCIPAL_A, confirmation_id))

    def test_persist_failure_rolls_back(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-fail-{animal_id}"
        command = _command(animal_id, now, "Fail")
        confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=confirmation_id,
            command=command,
            identity=identity,
            issued_at=now,
        )
        before = self._counts(TENANT_A, PRINCIPAL_A)
        with self.assertRaises(LivestockMutationError) as raised:
            self._coordinator().create_animal(
                principal=_principal(PRINCIPAL_A, "corr-fail", now),
                requested_tenant_id=TENANT_A,
                request=_request(command, confirmation, identity),
                session=_PersistFailingSession(self._session()),
                now=now,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        after = self._counts(TENANT_A, PRINCIPAL_A)
        self.assertEqual(after, before)
        self.assertIsNone(self._confirmation_consumed_at(TENANT_A, PRINCIPAL_A, confirmation_id))

    def test_tenant_b_is_denied_and_isolated(self) -> None:
        now = datetime.now(timezone.utc)
        animal_id = str(uuid4())
        confirmation_id = str(uuid4())
        identity = f"idem-iso-{animal_id}"
        command = _command(animal_id, now, "Isolated")
        confirmation = self._insert_confirmation(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL_A,
            user_id=USER_A,
            confirmation_id=confirmation_id,
            command=command,
            identity=identity,
            issued_at=now,
        )
        self._coordinator().create_animal(
            principal=_principal(PRINCIPAL_A, "corr-iso-a", now),
            requested_tenant_id=TENANT_A,
            request=_request(command, confirmation, identity),
            session=self._session(),
            now=now,
        )
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["animals"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["idempotency"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["audit"], 0)
        session = self._session()
        session.begin()
        session.set_local(principal_id=PRINCIPAL_B, environment="development", tenant_id=TENANT_B)
        self.assertIsNone(session.load_confirmation(confirmation_id))
        self.assertIsNone(session.load_idempotency(TENANT_A, "ranchos.livestock.animal-create", identity))
        session.rollback()
        with self.assertRaises(LivestockMutationError) as raised:
            self._coordinator().create_animal(
                principal=_principal(PRINCIPAL_B, "corr-iso-b", now),
                requested_tenant_id=TENANT_B,
                request=_request(command, confirmation, identity),
                session=self._session(),
                now=now,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
        self.assertEqual(self._row_state(TENANT_A, PRINCIPAL_A, animal_id, confirmation_id, identity)["animals"], 1)
        self.assertEqual(self._row_state(TENANT_B, PRINCIPAL_B, animal_id, confirmation_id, identity)["animals"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["animals"], 0)
        self.assertEqual(self._counts(TENANT_B, PRINCIPAL_B)["audit"], 0)


if __name__ == "__main__":
    unittest.main()
