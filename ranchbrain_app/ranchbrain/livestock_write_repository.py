"""DEV-only livestock write persistence adapter.

The coordinator must already have begun a transaction and set transaction-local
Ranch OS settings. This module does not parse identity, issue SET or RESET, or
open ingress.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Protocol

from ranchbrain.livestock_write_model import (
    AnimalIdentifierType,
    AnimalIdentifierV1,
    IdentifierRetirementV1,
    LivestockAnimalV1,
    RoutineLifecycleEventV1,
)
from ranchbrain.tenancy import TenantContext


ANIMAL_CREATE_OPERATION = "ranchos.livestock.animal-create"
IDENTIFIER_ASSIGN_OPERATION = "ranchos.livestock.identifier-assign"
IDENTIFIER_RETIRE_OPERATION = "ranchos.livestock.identifier-retire"
LIFECYCLE_RECORD_OPERATION = "ranchos.livestock.lifecycle-record"
LIFECYCLE_CORRECT_OPERATION = "ranchos.livestock.lifecycle-correct"
CONFIRMATION_TTL = timedelta(minutes=2)


class LivestockPersistenceErrorCode(str, Enum):
    CONFIRMATION_INVALID = "livestock_confirmation_invalid"
    IDEMPOTENCY_CONFLICT = "livestock_idempotency_conflict"
    IDEMPOTENCY_AMBIGUOUS = "livestock_idempotency_ambiguous"
    IDENTIFIER_NOT_AVAILABLE = "livestock_identifier_not_available"
    IDENTIFIER_INVALID = "livestock_identifier_invalid"
    LIFECYCLE_INVALID = "livestock_lifecycle_invalid"
    TARGET_NOT_FOUND = "livestock_target_not_found"


class LivestockPersistenceError(RuntimeError):
    def __init__(self, message: str, code: LivestockPersistenceErrorCode):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class LivestockConfirmationRecord:
    id: str
    tenant_id: str
    actor_user_id: str
    principal_id: str
    operation: str
    target_manifest: str
    command_digest: str
    policy_version: str
    validator_version: str
    idempotency_identity: str
    issued_at: datetime
    expires_at: datetime
    consumed_at: datetime | None = None


@dataclass(frozen=True)
class LivestockIdempotencyRecord:
    tenant_id: str
    scope: str
    identity: str
    key_digest: str
    operation: str
    outcome: str
    transaction_id: str
    result_animal_id: str | None = None
    animal: LivestockAnimalV1 | None = None
    result_identifier_id: str | None = None
    identifier: AnimalIdentifierV1 | None = None
    result_retirement_id: str | None = None
    retirement: IdentifierRetirementV1 | None = None
    result_lifecycle_event_id: str | None = None
    event: RoutineLifecycleEventV1 | None = None


@dataclass(frozen=True)
class LivestockAuditRecord:
    id: str
    tenant_id: str
    transaction_id: str
    operation: str
    targets: str
    actor_user_id: str
    principal_id: str
    correlation_id: str
    policy_version: str
    validator_version: str
    idempotency_outcome: str
    provenance_source_type: str
    provenance_source_id: str
    provenance_source_version: str
    confirmation_id: str
    result_metadata: str
    recorded_at: datetime


@dataclass(frozen=True)
class IdempotencyReservation:
    replayed: bool
    record: LivestockIdempotencyRecord


class LivestockMutationSession(Protocol):
    """Injected unit of work. Coordinator owns SET LOCAL; repository never does."""

    def begin(self) -> None: ...
    def set_local(self, *, principal_id: str, environment: str, tenant_id: str) -> None: ...
    def current_timestamp(self) -> datetime: ...
    def load_confirmation(self, confirmation_id: str) -> LivestockConfirmationRecord | None: ...
    def mark_confirmation_consumed(self, confirmation_id: str, consumed_at: datetime) -> None: ...
    def load_idempotency(self, tenant_id: str, scope: str, identity: str) -> LivestockIdempotencyRecord | None: ...
    def insert_idempotency_reservation(self, record: LivestockIdempotencyRecord) -> None: ...
    def finalize_idempotency(self, record: LivestockIdempotencyRecord) -> None: ...
    def insert_animal(self, animal: LivestockAnimalV1) -> None: ...
    def lock_animal(self, tenant_id: str, animal_id: str) -> LivestockAnimalV1 | None: ...
    def lock_identifier(self, tenant_id: str, identifier_id: str) -> AnimalIdentifierV1 | None: ...
    def lock_active_identifier_slot(
        self,
        tenant_id: str,
        identifier_type: AnimalIdentifierType,
        normalized_value: str,
    ) -> None: ...
    def load_identifiers_for_collision(
        self,
        tenant_id: str,
        identifier_type: AnimalIdentifierType,
        normalized_value: str,
    ) -> tuple[AnimalIdentifierV1, ...]: ...
    def load_retirements_for_identifiers(
        self,
        tenant_id: str,
        identifier_ids: tuple[str, ...],
    ) -> tuple[IdentifierRetirementV1, ...]: ...
    def insert_identifier(self, identifier: AnimalIdentifierV1) -> None: ...
    def insert_retirement(self, retirement: IdentifierRetirementV1) -> None: ...
    def lock_lifecycle_animal_history(self, tenant_id: str, animal_id: str) -> None: ...
    def load_lifecycle_events_for_animal(self, tenant_id: str, animal_id: str) -> tuple[RoutineLifecycleEventV1, ...]: ...
    def insert_lifecycle_event(self, event: RoutineLifecycleEventV1) -> None: ...
    def insert_audit(self, record: LivestockAuditRecord) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


def _committed_result_is_exact(record: LivestockIdempotencyRecord) -> bool:
    match record.operation:
        case operation if operation == ANIMAL_CREATE_OPERATION:
            return (
                record.result_animal_id is not None
                and record.animal is not None
                and record.animal.id == record.result_animal_id
                and record.result_identifier_id is None
                and record.identifier is None
                and record.result_retirement_id is None
                and record.retirement is None
                and record.result_lifecycle_event_id is None
                and record.event is None
            )
        case operation if operation == IDENTIFIER_ASSIGN_OPERATION:
            return (
                record.result_identifier_id is not None
                and record.identifier is not None
                and record.identifier.id == record.result_identifier_id
                and record.result_animal_id is None
                and record.animal is None
                and record.result_retirement_id is None
                and record.retirement is None
                and record.result_lifecycle_event_id is None
                and record.event is None
            )
        case operation if operation == IDENTIFIER_RETIRE_OPERATION:
            return (
                record.result_retirement_id is not None
                and record.retirement is not None
                and record.retirement.id == record.result_retirement_id
                and record.result_animal_id is None
                and record.animal is None
                and record.result_identifier_id is None
                and record.identifier is None
                and record.result_lifecycle_event_id is None
                and record.event is None
            )
        case operation if operation in (LIFECYCLE_RECORD_OPERATION, LIFECYCLE_CORRECT_OPERATION):
            return (
                record.result_lifecycle_event_id is not None
                and record.event is not None
                and record.event.id == record.result_lifecycle_event_id
                and record.result_animal_id is None
                and record.animal is None
                and record.result_identifier_id is None
                and record.identifier is None
                and record.result_retirement_id is None
                and record.retirement is None
            )
        case _ as unreachable:
            _ = unreachable
            return False


class LivestockWriteRepository:
    """Persist allowlisted first-slice livestock effects after transaction-local settings exist."""

    def consume_confirmation(
        self,
        session: LivestockMutationSession,
        *,
        confirmation_id: str,
        context: TenantContext,
        digest: str,
        idempotency_identity: str,
        target_manifest: str,
        policy_version: str,
        validator_version: str,
        now: datetime,
        operation: str,
    ) -> None:
        stored = session.load_confirmation(confirmation_id)
        if stored is None:
            raise LivestockPersistenceError("confirmation is not present", LivestockPersistenceErrorCode.CONFIRMATION_INVALID)
        if stored.consumed_at is not None:
            raise LivestockPersistenceError("confirmation is already consumed", LivestockPersistenceErrorCode.CONFIRMATION_INVALID)
        if stored.expires_at != stored.issued_at + CONFIRMATION_TTL:
            raise LivestockPersistenceError("confirmation expiry is not the trusted two-minute ttl", LivestockPersistenceErrorCode.CONFIRMATION_INVALID)
        if now > stored.expires_at:
            raise LivestockPersistenceError("confirmation is expired", LivestockPersistenceErrorCode.CONFIRMATION_INVALID)
        if (
            stored.tenant_id != context.tenant_id
            or stored.actor_user_id != context.user_id
            or stored.principal_id != context.principal_id
            or stored.operation != operation
            or stored.command_digest != digest
            or stored.idempotency_identity != idempotency_identity
            or stored.target_manifest != target_manifest
            or stored.policy_version != policy_version
            or stored.validator_version != validator_version
        ):
            raise LivestockPersistenceError("confirmation is not bound to the admitted request", LivestockPersistenceErrorCode.CONFIRMATION_INVALID)
        session.mark_confirmation_consumed(stored.id, now)

    def reserve_idempotency(
        self,
        session: LivestockMutationSession,
        *,
        context: TenantContext,
        identity: str,
        digest: str,
        transaction_id: str,
        operation: str,
    ) -> IdempotencyReservation:
        existing = session.load_idempotency(context.tenant_id, operation, identity)
        if existing is None:
            reserved = LivestockIdempotencyRecord(
                context.tenant_id,
                operation,
                identity,
                digest,
                operation,
                "reserved",
                transaction_id,
            )
            session.insert_idempotency_reservation(reserved)
            return IdempotencyReservation(False, reserved)
        if existing.key_digest != digest or existing.operation != operation or existing.scope != operation:
            raise LivestockPersistenceError("idempotency identity reused with a different digest", LivestockPersistenceErrorCode.IDEMPOTENCY_CONFLICT)
        if existing.outcome != "committed" or not _committed_result_is_exact(existing):
            raise LivestockPersistenceError("idempotency outcome is ambiguous", LivestockPersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS)
        return IdempotencyReservation(True, existing)

    def persist_animal(self, session: LivestockMutationSession, animal: LivestockAnimalV1) -> None:
        session.insert_animal(animal)

    def persist_identifier(self, session: LivestockMutationSession, identifier: AnimalIdentifierV1) -> None:
        session.insert_identifier(identifier)

    def persist_retirement(self, session: LivestockMutationSession, retirement: IdentifierRetirementV1) -> None:
        session.insert_retirement(retirement)

    def persist_lifecycle_event(self, session: LivestockMutationSession, event: RoutineLifecycleEventV1) -> None:
        session.insert_lifecycle_event(event)

    def insert_audit(self, session: LivestockMutationSession, record: LivestockAuditRecord) -> None:
        session.insert_audit(record)

    def finalize_idempotency(self, session: LivestockMutationSession, record: LivestockIdempotencyRecord) -> None:
        if record.outcome != "committed" or record.scope != record.operation or not _committed_result_is_exact(record):
            raise LivestockPersistenceError("idempotency outcome is ambiguous", LivestockPersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS)
        session.finalize_idempotency(record)
