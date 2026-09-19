"""DEV-only livestock PostgreSQL session adapter.

Accepts an already-open PEP 249 connection. This module does not import a
PostgreSQL driver, call connect(), read an environment URL, or use tools/**
clients. It implements coordinator session methods for animal_create, identifier
assign/retire, and lifecycle record/correct.
"""

from __future__ import annotations

from datetime import datetime
from typing import Protocol
from uuid import UUID

from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import (
    AnimalIdentifierType,
    AnimalIdentifierV1,
    IdentifierRetirementReason,
    IdentifierRetirementV1,
    LifecycleCorrectionReason,
    LivestockAnimalV1,
    LivestockAuditInputV1,
    LivestockWriteOperation,
    RoutineLifecycleEventType,
    RoutineLifecycleEventV1,
)
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    IDENTIFIER_ASSIGN_OPERATION,
    IDENTIFIER_RETIRE_OPERATION,
    LIFECYCLE_CORRECT_OPERATION,
    LIFECYCLE_RECORD_OPERATION,
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockIdempotencyRecord,
    LivestockPersistenceError,
    LivestockPersistenceErrorCode,
)

_RUNTIME_ROLE = "ranchos_dev_runtime"


class _Cursor(Protocol):
    def execute(self, operation: str, parameters: tuple[object, ...] = ()) -> object: ...
    def fetchone(self) -> tuple[object, ...] | None: ...
    def fetchall(self) -> list[tuple[object, ...]]: ...
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


def _pgcode(error: BaseException) -> str | None:
    code = getattr(error, "pgcode", None)
    return code if isinstance(code, str) else None


def _reraise_identifier_write(error: BaseException) -> None:
    code = _pgcode(error)
    if code == "23505":
        raise LivestockPersistenceError(
            "identifier value is already active in this tenant",
            LivestockPersistenceErrorCode.IDENTIFIER_NOT_AVAILABLE,
        ) from error
    if code == "23503":
        raise LivestockPersistenceError("identifier write target is missing", LivestockPersistenceErrorCode.TARGET_NOT_FOUND) from error
    raise error


def _reraise_lifecycle_write(error: BaseException) -> None:
    code = _pgcode(error)
    if code == "23505":
        raise LivestockPersistenceError("lifecycle event is already superseded", LivestockPersistenceErrorCode.LIFECYCLE_INVALID) from error
    if code == "23514":
        raise LivestockPersistenceError("lifecycle correction must supersede one matching event", LivestockPersistenceErrorCode.LIFECYCLE_INVALID) from error
    if code == "23503":
        raise LivestockPersistenceError("lifecycle write target is missing", LivestockPersistenceErrorCode.TARGET_NOT_FOUND) from error
    raise error


def _reraise_retirement_write(error: BaseException) -> None:
    code = _pgcode(error)
    if code == "23505":
        raise LivestockPersistenceError("identifier is already retired", LivestockPersistenceErrorCode.IDENTIFIER_INVALID) from error
    if code == "23514":
        raise LivestockPersistenceError(
            "identifier retirement cannot precede assignment",
            LivestockPersistenceErrorCode.IDENTIFIER_INVALID,
        ) from error
    if code == "23503":
        raise LivestockPersistenceError("identifier write target is missing", LivestockPersistenceErrorCode.TARGET_NOT_FOUND) from error
    raise error


class LivestockPgSession:
    """Transaction-local runtime session for disposable livestock mutation proof."""

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
                   i.transaction_id, i.result_animal_id, i.result_identifier_id, i.result_retirement_id,
                   i.result_lifecycle_event_id,
                   a.id, a.display_name, a.species_code, a.production_type_code, a.breed_code,
                   a.provenance_source_type, a.provenance_source_id, a.provenance_source_version,
                   a.provenance_observed_at, a.created_by_user_id, a.created_at,
                   ident.id, ident.animal_id, ident.identifier_type, ident.normalized_value, ident.effective_at,
                   ident.provenance_source_type, ident.provenance_source_id, ident.provenance_source_version,
                   ident.provenance_observed_at, ident.created_by_user_id, ident.created_at,
                   ret.id, ret.identifier_id, ret.reason, ret.retired_at,
                   ret.provenance_source_type, ret.provenance_source_id, ret.provenance_source_version,
                   ret.provenance_observed_at, ret.created_by_user_id, ret.created_at,
                   ev.id, ev.animal_id, ev.event_type, ev.occurred_at, ev.supersedes_event_id, ev.correction_reason,
                   ev.provenance_source_type, ev.provenance_source_id, ev.provenance_source_version,
                   ev.provenance_observed_at, ev.created_by_user_id, ev.created_at,
                   aud.operation, aud.actor_user_id, aud.principal_id, aud.correlation_id, aud.recorded_at
            FROM ranchos.livestock_idempotency AS i
            LEFT JOIN ranchos.livestock_animals AS a
              ON a.tenant_id = i.tenant_id AND a.id = i.result_animal_id
            LEFT JOIN ranchos.animal_identifiers AS ident
              ON ident.tenant_id = i.tenant_id AND ident.id = i.result_identifier_id
            LEFT JOIN ranchos.animal_identifier_retirements AS ret
              ON ret.tenant_id = i.tenant_id AND ret.id = i.result_retirement_id
            LEFT JOIN ranchos.livestock_lifecycle_events AS ev
              ON ev.tenant_id = i.tenant_id AND ev.id = i.result_lifecycle_event_id
            LEFT JOIN ranchos.livestock_mutation_audit AS aud
              ON aud.tenant_id = i.tenant_id
             AND aud.transaction_id = i.transaction_id
             AND aud.operation = i.operation
            WHERE i.tenant_id = %s AND i.scope = %s AND i.identity = %s
            """,
            (tenant_id, scope, identity),
        )
        if row is None:
            return None
        tenant = _text(row[0])
        transaction_id = _text(row[6])
        replay_audit = None if row[55] is None else self._replay_audit(row[55:60])
        return LivestockIdempotencyRecord(
            tenant,
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _text(row[4]),
            _text(row[5]),
            transaction_id,
            _optional_text(row[7]),
            None if row[11] is None else self._animal_from_row(tenant, replay_audit, row[11:22]),
            _optional_text(row[8]),
            None if row[22] is None else self._identifier_from_row(tenant, replay_audit, row[22:33]),
            _optional_text(row[9]),
            None if row[33] is None else self._retirement_from_row(tenant, replay_audit, row[33:43]),
            _optional_text(row[10]),
            None if row[43] is None else self._event_from_row(tenant, replay_audit, row[43:55]),
        )

    def insert_idempotency_reservation(self, record: LivestockIdempotencyRecord) -> None:
        self._execute_one(
            """
            INSERT INTO ranchos.livestock_idempotency (
                tenant_id, scope, identity, key_digest, operation, outcome, transaction_id,
                result_animal_id, result_identifier_id, result_retirement_id, result_lifecycle_event_id
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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
                record.result_identifier_id,
                record.result_retirement_id,
                record.result_lifecycle_event_id,
            ),
            "livestock idempotency reserve did not insert one row",
        )

    def finalize_idempotency(self, record: LivestockIdempotencyRecord) -> None:
        self._execute_one(
            """
            UPDATE ranchos.livestock_idempotency
            SET outcome = %s, result_animal_id = %s, result_identifier_id = %s, result_retirement_id = %s,
                result_lifecycle_event_id = %s
            WHERE tenant_id = %s AND scope = %s AND identity = %s
            """,
            (
                record.outcome,
                record.result_animal_id,
                record.result_identifier_id,
                record.result_retirement_id,
                record.result_lifecycle_event_id,
                record.tenant_id,
                record.scope,
                record.identity,
            ),
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

    def lock_animal(self, tenant_id: str, animal_id: str) -> LivestockAnimalV1 | None:
        row = self._fetchone(
            """
            SELECT id, display_name, species_code, production_type_code, breed_code,
                   provenance_source_type, provenance_source_id, provenance_source_version,
                   provenance_observed_at, created_by_user_id, created_at
            FROM ranchos.livestock_animals
            WHERE tenant_id = %s AND id = %s
            """,
            (tenant_id, animal_id),
        )
        if row is None:
            return None
        return self._animal_from_row(tenant_id, tenant_id, row)

    def lock_identifier(self, tenant_id: str, identifier_id: str) -> AnimalIdentifierV1 | None:
        row = self._fetchone(
            """
            SELECT id, animal_id, identifier_type, normalized_value, effective_at,
                   provenance_source_type, provenance_source_id, provenance_source_version,
                   provenance_observed_at, created_by_user_id, created_at
            FROM ranchos.animal_identifiers
            WHERE tenant_id = %s AND id = %s
            """,
            (tenant_id, identifier_id),
        )
        if row is None:
            return None
        return self._identifier_from_row(tenant_id, tenant_id, row)

    def lock_active_identifier_slot(
        self,
        tenant_id: str,
        identifier_type: AnimalIdentifierType,
        normalized_value: str,
    ) -> None:
        # 002 grants SELECT/INSERT only, so SELECT FOR UPDATE/SHARE is unavailable.
        self._execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f"{tenant_id}:{identifier_type.value}:{normalized_value}",),
        )

    def load_identifiers_for_collision(
        self,
        tenant_id: str,
        identifier_type: AnimalIdentifierType,
        normalized_value: str,
    ) -> tuple[AnimalIdentifierV1, ...]:
        rows = self._fetchall(
            """
            SELECT id, animal_id, identifier_type, normalized_value, effective_at,
                   provenance_source_type, provenance_source_id, provenance_source_version,
                   provenance_observed_at, created_by_user_id, created_at
            FROM ranchos.animal_identifiers
            WHERE tenant_id = %s AND identifier_type = %s AND normalized_value = %s
            ORDER BY id
            """,
            (tenant_id, identifier_type.value, normalized_value),
        )
        return tuple(self._identifier_from_row(tenant_id, tenant_id, row) for row in rows)

    def load_retirements_for_identifiers(
        self,
        tenant_id: str,
        identifier_ids: tuple[str, ...],
    ) -> tuple[IdentifierRetirementV1, ...]:
        if not identifier_ids:
            return ()
        rows = self._fetchall(
            """
            SELECT id, identifier_id, reason, retired_at,
                   provenance_source_type, provenance_source_id, provenance_source_version,
                   provenance_observed_at, created_by_user_id, created_at
            FROM ranchos.animal_identifier_retirements
            WHERE tenant_id = %s AND identifier_id = ANY(%s::uuid[])
            ORDER BY id
            """,
            (tenant_id, list(identifier_ids)),
        )
        return tuple(self._retirement_from_row(tenant_id, tenant_id, row) for row in rows)

    def insert_identifier(self, identifier: AnimalIdentifierV1) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.animal_identifiers (
                    tenant_id, id, animal_id, identifier_type, normalized_value, effective_at,
                    provenance_source_type, provenance_source_id, provenance_source_version,
                    provenance_observed_at, created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    identifier.tenant_id,
                    identifier.id,
                    identifier.animal_id,
                    identifier.identifier_type.value,
                    identifier.normalized_value,
                    identifier.effective_at,
                    identifier.provenance.source_type,
                    identifier.provenance.source_id,
                    identifier.provenance.source_version,
                    identifier.provenance.observed_at,
                    identifier.audit.actor_user_id,
                    identifier.audit.recorded_at,
                ),
                "livestock identifier insert did not insert one row",
            )
        except Exception as error:
            _reraise_identifier_write(error)

    def insert_retirement(self, retirement: IdentifierRetirementV1) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.animal_identifier_retirements (
                    tenant_id, id, identifier_id, reason, retired_at,
                    provenance_source_type, provenance_source_id, provenance_source_version,
                    provenance_observed_at, created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    retirement.tenant_id,
                    retirement.id,
                    retirement.identifier_id,
                    retirement.reason.value,
                    retirement.retired_at,
                    retirement.provenance.source_type,
                    retirement.provenance.source_id,
                    retirement.provenance.source_version,
                    retirement.provenance.observed_at,
                    retirement.audit.actor_user_id,
                    retirement.audit.recorded_at,
                ),
                "livestock identifier retirement insert did not insert one row",
            )
        except Exception as error:
            _reraise_retirement_write(error)

    def lock_lifecycle_animal_history(self, tenant_id: str, animal_id: str) -> None:
        # 002 grants SELECT/INSERT only, so SELECT FOR UPDATE/SHARE is unavailable.
        self._execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f"{tenant_id}:lifecycle:{animal_id}",),
        )

    def load_lifecycle_events_for_animal(self, tenant_id: str, animal_id: str) -> tuple[RoutineLifecycleEventV1, ...]:
        rows = self._fetchall(
            """
            SELECT id, animal_id, event_type, occurred_at, supersedes_event_id, correction_reason,
                   provenance_source_type, provenance_source_id, provenance_source_version,
                   provenance_observed_at, created_by_user_id, created_at
            FROM ranchos.livestock_lifecycle_events
            WHERE tenant_id = %s AND animal_id = %s
            ORDER BY occurred_at, id
            """,
            (tenant_id, animal_id),
        )
        return tuple(self._event_from_row(tenant_id, tenant_id, row) for row in rows)

    def insert_lifecycle_event(self, event: RoutineLifecycleEventV1) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.livestock_lifecycle_events (
                    tenant_id, id, animal_id, event_type, occurred_at, supersedes_event_id, correction_reason,
                    provenance_source_type, provenance_source_id, provenance_source_version,
                    provenance_observed_at, created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    event.tenant_id,
                    event.id,
                    event.animal_id,
                    event.event_type.value,
                    event.occurred_at,
                    event.supersedes_event_id,
                    None if event.correction_reason is None else event.correction_reason.value,
                    event.provenance.source_type,
                    event.provenance.source_id,
                    event.provenance.source_version,
                    event.provenance.observed_at,
                    event.audit.actor_user_id,
                    event.audit.recorded_at,
                ),
                "livestock lifecycle event insert did not insert one row",
            )
        except Exception as error:
            _reraise_lifecycle_write(error)

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

    def _replay_audit(self, row: tuple[object, ...]) -> LivestockAuditInputV1:
        operation = {
            ANIMAL_CREATE_OPERATION: LivestockWriteOperation.ANIMAL_CREATE,
            IDENTIFIER_ASSIGN_OPERATION: LivestockWriteOperation.IDENTIFIER_ASSIGN,
            IDENTIFIER_RETIRE_OPERATION: LivestockWriteOperation.IDENTIFIER_RETIRE,
            LIFECYCLE_RECORD_OPERATION: LivestockWriteOperation.LIFECYCLE_RECORD,
            LIFECYCLE_CORRECT_OPERATION: LivestockWriteOperation.LIFECYCLE_CORRECT,
        }.get(_text(row[0]))
        if operation is None:
            raise RuntimeError("livestock replay audit operation is unknown")
        return LivestockAuditInputV1(
            operation,
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            row[4],
        )

    def _row_audit(
        self,
        operation: LivestockWriteOperation,
        actor_user_id: str,
        recorded_at: datetime,
        audit: LivestockAuditInputV1 | str | None,
    ) -> LivestockAuditInputV1:
        if isinstance(audit, LivestockAuditInputV1):
            return audit
        if audit is None:
            raise RuntimeError("livestock replay is missing original audit facts")
        if self._principal_id is None:
            raise RuntimeError("livestock load requires transaction-local principal")
        return LivestockAuditInputV1(operation, actor_user_id, self._principal_id, audit, recorded_at)

    def _animal_from_row(self, tenant_id: str, audit: LivestockAuditInputV1 | str | None, row: tuple[object, ...]) -> LivestockAnimalV1:
        return LivestockAnimalV1(
            _text(row[0]),
            tenant_id,
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _optional_text(row[4]),
            LivestockFactProvenance(_text(row[5]), _text(row[6]), _text(row[7]), row[8]),
            self._row_audit(LivestockWriteOperation.ANIMAL_CREATE, _text(row[9]), row[10], audit),
        )

    def _identifier_from_row(self, tenant_id: str, audit: LivestockAuditInputV1 | str | None, row: tuple[object, ...]) -> AnimalIdentifierV1:
        return AnimalIdentifierV1(
            _text(row[0]),
            tenant_id,
            _text(row[1]),
            AnimalIdentifierType(_text(row[2])),
            _text(row[3]),
            row[4],
            LivestockFactProvenance(_text(row[5]), _text(row[6]), _text(row[7]), row[8]),
            self._row_audit(LivestockWriteOperation.IDENTIFIER_ASSIGN, _text(row[9]), row[10], audit),
        )

    def _retirement_from_row(self, tenant_id: str, audit: LivestockAuditInputV1 | str | None, row: tuple[object, ...]) -> IdentifierRetirementV1:
        return IdentifierRetirementV1(
            _text(row[0]),
            tenant_id,
            _text(row[1]),
            IdentifierRetirementReason(_text(row[2])),
            row[3],
            LivestockFactProvenance(_text(row[4]), _text(row[5]), _text(row[6]), row[7]),
            self._row_audit(LivestockWriteOperation.IDENTIFIER_RETIRE, _text(row[8]), row[9], audit),
        )

    def _event_from_row(self, tenant_id: str, audit: LivestockAuditInputV1 | str | None, row: tuple[object, ...]) -> RoutineLifecycleEventV1:
        supersedes = _optional_text(row[4])
        reason = None if row[5] is None else LifecycleCorrectionReason(_text(row[5]))
        operation = LivestockWriteOperation.LIFECYCLE_RECORD if supersedes is None else LivestockWriteOperation.LIFECYCLE_CORRECT
        return RoutineLifecycleEventV1(
            _text(row[0]),
            tenant_id,
            _text(row[1]),
            RoutineLifecycleEventType(_text(row[2])),
            row[3],
            LivestockFactProvenance(_text(row[6]), _text(row[7]), _text(row[8]), row[9]),
            self._row_audit(operation, _text(row[10]), row[11], audit),
            supersedes,
            reason,
            None,
        )

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

    def _fetchall(self, operation: str, parameters: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
        cursor = self._connection.cursor()
        try:
            cursor.execute(operation, parameters)
            return list(cursor.fetchall())
        finally:
            cursor.close()
