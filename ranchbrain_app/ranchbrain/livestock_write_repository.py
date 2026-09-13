"""DEV-only livestock write persistence adapter.

The coordinator must already have begun a transaction and set transaction-local
Ranch OS settings. This module does not parse identity, issue SET or RESET, open
ingress, or authorize the other four first-slice mutations.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Protocol

from ranchbrain.livestock_write_model import LivestockAnimalV1
from ranchbrain.tenancy import TenantContext


ANIMAL_CREATE_OPERATION = "ranchos.livestock.animal-create"
ANIMAL_CREATE_SQL_OPERATION = "animal_create"
CONFIRMATION_TTL = timedelta(minutes=2)


class LivestockPersistenceErrorCode(str, Enum):
    CONFIRMATION_INVALID = "livestock_confirmation_invalid"
    IDEMPOTENCY_CONFLICT = "livestock_idempotency_conflict"
    IDEMPOTENCY_AMBIGUOUS = "livestock_idempotency_ambiguous"


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
    animal: LivestockAnimalV1 | None = None


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
    def insert_audit(self, record: LivestockAuditRecord) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


class LivestockWriteRepository:
    """Persist allowlisted animal_create effects after transaction-local settings exist."""

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
            or stored.operation != ANIMAL_CREATE_OPERATION
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
    ) -> IdempotencyReservation:
        scope = ANIMAL_CREATE_OPERATION
        existing = session.load_idempotency(context.tenant_id, scope, identity)
        if existing is None:
            reserved = LivestockIdempotencyRecord(
                context.tenant_id,
                scope,
                identity,
                digest,
                ANIMAL_CREATE_SQL_OPERATION,
                "reserved",
                transaction_id,
            )
            session.insert_idempotency_reservation(reserved)
            return IdempotencyReservation(False, reserved)
        if existing.key_digest != digest:
            raise LivestockPersistenceError("idempotency identity reused with a different digest", LivestockPersistenceErrorCode.IDEMPOTENCY_CONFLICT)
        if existing.outcome not in {"committed", "replayed"} or existing.animal is None:
            raise LivestockPersistenceError("idempotency outcome is ambiguous", LivestockPersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS)
        return IdempotencyReservation(True, existing)

    def persist_animal(self, session: LivestockMutationSession, animal: LivestockAnimalV1) -> None:
        session.insert_animal(animal)

    def insert_audit(self, session: LivestockMutationSession, record: LivestockAuditRecord) -> None:
        session.insert_audit(record)

    def finalize_idempotency(self, session: LivestockMutationSession, record: LivestockIdempotencyRecord) -> None:
        session.finalize_idempotency(record)
