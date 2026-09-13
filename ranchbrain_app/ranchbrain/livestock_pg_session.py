"""DEV-only animal_create PostgreSQL session adapter.

Accepts an already-open PEP 249 connection. This module does not import a
PostgreSQL driver, call connect(), read an environment URL, or use tools/**
clients. It implements only the coordinator session methods needed for
animal_create.
"""

from __future__ import annotations

from datetime import datetime
from typing import Protocol
from uuid import UUID

from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import LivestockAnimalV1, LivestockAuditInputV1, LivestockWriteOperation
from ranchbrain.livestock_write_repository import (
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockIdempotencyRecord,
)

_RUNTIME_ROLE = "ranchos_dev_runtime"


class _Cursor(Protocol):
    def execute(self, operation: str, parameters: tuple[object, ...] = ()) -> object: ...
    def fetchone(self) -> tuple[object, ...] | None: ...
    def close(self) -> None: ...
    rowcount: int


class _Connection(Protocol):
    autocommit: bool

    def cursor(self) -> _Cursor: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


def _text(value: object) -> str:
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, str):
        return value
    raise TypeError("expected a UUID or text value")


def _optional_text(value: object) -> str | None:
    if value is None:
        return None
    return _text(value)


class LivestockPgSession:
    """Transaction-local runtime session for disposable animal_create proof."""

    def __init__(self, connection: _Connection):
        if getattr(connection, "autocommit", False):
            raise RuntimeError("livestock session requires a non-autocommit connection")
        self._connection = connection
        self._principal_id: str | None = None

    def begin(self) -> None:
        self._execute("BEGIN")
        self._execute("SELECT set_config(%s, %s, true)", ("role", _RUNTIME_ROLE))

    def set_local(self, *, principal_id: str, environment: str, tenant_id: str) -> None:
        self._principal_id = principal_id
        self._execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", principal_id))
        self._execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", environment))
        self._execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", tenant_id))

    def current_timestamp(self) -> datetime:
        value = self._fetchone("SELECT CURRENT_TIMESTAMP")[0]
        if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
            raise RuntimeError("CURRENT_TIMESTAMP did not return a timezone-aware datetime")
        return value

    def load_confirmation(self, confirmation_id: str) -> LivestockConfirmationRecord | None:
        row = self._fetchone(
            """
            SELECT id, tenant_id, actor_user_id, principal_id, operation, target_manifest,
                   command_digest, policy_version, validator_version, idempotency_identity,
                   issued_at, expires_at, consumed_at
            FROM ranchos.livestock_confirmations
            WHERE id = %s
            """,
            (confirmation_id,),
        )
        if row is None:
            return None
        return LivestockConfirmationRecord(
            _text(row[0]),
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _text(row[4]),
            _text(row[5]),
            _text(row[6]),
            _text(row[7]),
            _text(row[8]),
            _text(row[9]),
            row[10],
            row[11],
            row[12],
        )

    def mark_confirmation_consumed(self, confirmation_id: str, consumed_at: datetime) -> None:
        self._execute_one(
            """
            UPDATE ranchos.livestock_confirmations
            SET consumed_at = %s
            WHERE id = %s
            """,
            (consumed_at, confirmation_id),
            "livestock confirmation consume did not update one row",
        )

    def load_idempotency(self, tenant_id: str, scope: str, identity: str) -> LivestockIdempotencyRecord | None:
        row = self._fetchone(
            """
            SELECT i.tenant_id, i.scope, i.identity, i.key_digest, i.operation, i.outcome,
                   i.transaction_id, i.result_animal_id,
                   a.id, a.display_name, a.species_code, a.production_type_code, a.breed_code,
                   a.provenance_source_type, a.provenance_source_id, a.provenance_source_version,
                   a.provenance_observed_at, a.created_by_user_id, a.created_at
            FROM ranchos.livestock_idempotency AS i
            LEFT JOIN ranchos.livestock_animals AS a
              ON a.tenant_id = i.tenant_id AND a.id = i.result_animal_id
            WHERE i.tenant_id = %s AND i.scope = %s AND i.identity = %s
            """,
            (tenant_id, scope, identity),
        )
        if row is None:
            return None
        animal = None
        if row[8] is not None:
            if self._principal_id is None:
                raise RuntimeError("idempotency replay requires transaction-local principal")
            animal = LivestockAnimalV1(
                _text(row[8]),
                _text(row[0]),
                _text(row[9]),
                _text(row[10]),
                _text(row[11]),
                _optional_text(row[12]),
                LivestockFactProvenance(_text(row[13]), _text(row[14]), _text(row[15]), row[16]),
                LivestockAuditInputV1(
                    LivestockWriteOperation.ANIMAL_CREATE,
                    _text(row[17]),
                    self._principal_id,
                    _text(row[6]),
                    row[18],
                ),
            )
        return LivestockIdempotencyRecord(
            _text(row[0]),
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _text(row[4]),
            _text(row[5]),
            _text(row[6]),
            _optional_text(row[7]),
            animal,
        )

    def insert_idempotency_reservation(self, record: LivestockIdempotencyRecord) -> None:
        self._execute_one(
            """
            INSERT INTO ranchos.livestock_idempotency (
                tenant_id, scope, identity, key_digest, operation, outcome, transaction_id, result_animal_id
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                record.tenant_id,
                record.scope,
                record.identity,
                record.key_digest,
                record.operation,
                record.outcome,
                record.transaction_id,
                record.result_animal_id,
            ),
            "livestock idempotency reserve did not insert one row",
        )

    def finalize_idempotency(self, record: LivestockIdempotencyRecord) -> None:
        self._execute_one(
            """
            UPDATE ranchos.livestock_idempotency
            SET outcome = %s, result_animal_id = %s
            WHERE tenant_id = %s AND scope = %s AND identity = %s
            """,
            (record.outcome, record.result_animal_id, record.tenant_id, record.scope, record.identity),
            "livestock idempotency finalize did not update one row",
        )

    def insert_animal(self, animal: LivestockAnimalV1) -> None:
        self._execute_one(
            """
            INSERT INTO ranchos.livestock_animals (
                tenant_id, id, display_name, species_code, production_type_code, breed_code, status,
                provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
                created_by_user_id, created_at
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                animal.tenant_id,
                animal.id,
                animal.display_name,
                animal.species_code,
                animal.production_type_code,
                animal.breed_code,
                "active",
                animal.provenance.source_type,
                animal.provenance.source_id,
                animal.provenance.source_version,
                animal.provenance.observed_at,
                animal.audit.actor_user_id,
                animal.audit.recorded_at,
            ),
            "livestock animal insert did not insert one row",
        )

    def insert_audit(self, record: LivestockAuditRecord) -> None:
        self._execute_one(
            """
            INSERT INTO ranchos.livestock_mutation_audit (
                tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id,
                correlation_id, policy_version, validator_version, idempotency_outcome,
                provenance_source_type, provenance_source_id, provenance_source_version,
                confirmation_id, result_metadata, recorded_at
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                record.tenant_id,
                record.id,
                record.transaction_id,
                record.operation,
                record.targets,
                record.actor_user_id,
                record.principal_id,
                record.correlation_id,
                record.policy_version,
                record.validator_version,
                record.idempotency_outcome,
                record.provenance_source_type,
                record.provenance_source_id,
                record.provenance_source_version,
                record.confirmation_id,
                record.result_metadata,
                record.recorded_at,
            ),
            "livestock audit insert did not insert one row",
        )

    def commit(self) -> None:
        self._connection.commit()

    def rollback(self) -> None:
        self._connection.rollback()

    def _execute(self, operation: str, parameters: tuple[object, ...] = ()) -> None:
        cursor = self._connection.cursor()
        try:
            cursor.execute(operation, parameters)
        finally:
            cursor.close()

    def _execute_one(self, operation: str, parameters: tuple[object, ...], message: str) -> None:
        cursor = self._connection.cursor()
        try:
            cursor.execute(operation, parameters)
            if cursor.rowcount != 1:
                raise RuntimeError(message)
        finally:
            cursor.close()

    def _fetchone(self, operation: str, parameters: tuple[object, ...] = ()) -> tuple[object, ...] | None:
        cursor = self._connection.cursor()
        try:
            cursor.execute(operation, parameters)
            return cursor.fetchone()
        finally:
            cursor.close()
