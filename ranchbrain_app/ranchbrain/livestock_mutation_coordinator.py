"""DEV-only animal_create mutation coordinator.

Transport-free. Receives a server-derived VerifiedPrincipal and an injected
TenantContextResolver. The coordinator owns one transaction, SET LOCAL, CF-2
consumption, and idempotency. It does not implement ingress, a principal
verifier, HTTP, or the other four first-slice mutations.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from hashlib import sha256
from json import dumps
from typing import assert_never
from uuid import UUID, uuid4

from ranchbrain.livestock_write_model import AnimalCreateCommandV1, LivestockAnimalV1, create_animal
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockIdempotencyRecord,
    LivestockMutationSession,
    LivestockPersistenceError,
    LivestockPersistenceErrorCode,
    LivestockWriteRepository,
)
from ranchbrain.tenancy import Capability, TenantContextResolver, TenancyError, VerifiedPrincipal


class LivestockMutationErrorCode(str, Enum):
    ADMISSION_DENIED = "livestock_mutation_admission_denied"
    PRINCIPAL_ID_INVALID = "livestock_mutation_principal_id_invalid"
    CONFIRMATION_INVALID = "livestock_mutation_confirmation_invalid"
    IDEMPOTENCY_CONFLICT = "livestock_mutation_idempotency_conflict"
    TRANSACTION_FAILED = "livestock_mutation_transaction_failed"


class LivestockMutationError(PermissionError):
    def __init__(self, message: str, code: LivestockMutationErrorCode):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class LivestockAnimalCreateRequest:
    command: AnimalCreateCommandV1
    confirmation: LivestockConfirmationRecord
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class LivestockAnimalCreateResult:
    animal: LivestockAnimalV1
    replayed: bool
    transaction_id: str
    confirmation_id: str
    idempotency_outcome: str


def _require_uuid(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise LivestockMutationError(f"{field_name} must be a UUID", LivestockMutationErrorCode.PRINCIPAL_ID_INVALID)
    try:
        parsed = UUID(value)
    except ValueError as error:
        raise LivestockMutationError(f"{field_name} must be a UUID", LivestockMutationErrorCode.PRINCIPAL_ID_INVALID) from error
    if str(parsed) != value:
        raise LivestockMutationError(f"{field_name} must be a UUID", LivestockMutationErrorCode.PRINCIPAL_ID_INVALID)
    return value


def canonical_animal_create_digest(
    *,
    tenant_id: str,
    command: AnimalCreateCommandV1,
    confirmation_id: str,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    payload = {
        "breed_code": command.breed_code,
        "confirmation_id": confirmation_id,
        "display_name": command.display_name,
        "id": command.id,
        "idempotency_identity": idempotency_identity,
        "operation": ANIMAL_CREATE_OPERATION,
        "policy_version": policy_version,
        "production_type_code": command.production_type_code,
        "provenance_observed_at": command.provenance.observed_at.isoformat(),
        "provenance_source_id": command.provenance.source_id,
        "provenance_source_type": command.provenance.source_type,
        "provenance_source_version": command.provenance.source_version,
        "species_code": command.species_code,
        "tenant_id": tenant_id,
        "validator_version": validator_version,
    }
    canonical = dumps(payload, separators=(",", ":"), sort_keys=True)
    return sha256(canonical.encode("utf-8")).hexdigest()


class LivestockMutationCoordinator:
    def __init__(self, resolver: TenantContextResolver, repository: LivestockWriteRepository):
        self._resolver = resolver
        self._repository = repository

    def create_animal(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: LivestockAnimalCreateRequest,
        session: LivestockMutationSession,
        now: datetime | None = None,
    ) -> LivestockAnimalCreateResult:
        current_time = now or datetime.now(timezone.utc)
        if not isinstance(principal, VerifiedPrincipal):
            raise LivestockMutationError("animal_create requires a server-derived verified principal", LivestockMutationErrorCode.ADMISSION_DENIED)
        _require_uuid(principal.id, "VerifiedPrincipal.id")
        if not requested_tenant_id:
            raise LivestockMutationError("an explicit tenant selection is required", LivestockMutationErrorCode.ADMISSION_DENIED)
        if (
            not request.idempotency_identity.strip()
            or not request.policy_version.strip()
            or not request.validator_version.strip()
            or not request.confirmation.id.strip()
        ):
            raise LivestockMutationError("animal_create requires policy, validator, confirmation id, and idempotency identity", LivestockMutationErrorCode.ADMISSION_DENIED)

        try:
            context = self._resolver.resolve(
                principal=principal,
                requested_tenant_id=requested_tenant_id,
                capability=Capability.LIVESTOCK_ANIMAL_WRITE,
                now=current_time,
            )
        except TenancyError as error:
            raise LivestockMutationError(str(error), LivestockMutationErrorCode.ADMISSION_DENIED) from error
        digest = canonical_animal_create_digest(
            tenant_id=context.tenant_id,
            command=request.command,
            confirmation_id=request.confirmation.id,
            idempotency_identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
        )

        begun = False
        try:
            session.begin()
            begun = True
            session.set_local(principal_id=context.principal_id, environment=context.environment, tenant_id=context.tenant_id)
            trusted_now = session.current_timestamp()
            transaction_id = str(uuid4())
            reservation = self._repository.reserve_idempotency(
                session,
                context=context,
                identity=request.idempotency_identity,
                digest=digest,
                transaction_id=transaction_id,
            )
            if reservation.replayed:
                if reservation.record.animal is None:
                    raise LivestockMutationError("replay is missing its original animal", LivestockMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return LivestockAnimalCreateResult(
                    reservation.record.animal,
                    True,
                    reservation.record.transaction_id,
                    request.confirmation.id,
                    "replayed",
                )

            self._repository.consume_confirmation(
                session,
                confirmation_id=request.confirmation.id,
                context=context,
                digest=digest,
                idempotency_identity=request.idempotency_identity,
                target_manifest=request.command.id,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                now=trusted_now,
            )
            animal = create_animal(context, request.command, trusted_now)
            self._repository.persist_animal(session, animal)
            self._repository.insert_audit(
                session,
                LivestockAuditRecord(
                    str(uuid4()),
                    context.tenant_id,
                    transaction_id,
                    ANIMAL_CREATE_OPERATION,
                    animal.id,
                    context.user_id,
                    context.principal_id,
                    context.correlation_id,
                    request.policy_version,
                    request.validator_version,
                    "committed",
                    animal.provenance.source_type,
                    animal.provenance.source_id,
                    animal.provenance.source_version,
                    request.confirmation.id,
                    "created",
                    trusted_now,
                ),
            )
            self._repository.finalize_idempotency(
                session,
                LivestockIdempotencyRecord(
                    context.tenant_id,
                    ANIMAL_CREATE_OPERATION,
                    request.idempotency_identity,
                    digest,
                    ANIMAL_CREATE_OPERATION,
                    "committed",
                    transaction_id,
                    animal.id,
                    animal,
                ),
            )
            session.commit()
            return LivestockAnimalCreateResult(animal, False, transaction_id, request.confirmation.id, "committed")
        except LivestockPersistenceError as error:
            if begun:
                session.rollback()
            mapped = self._map_persistence_error(error)
            raise LivestockMutationError(str(error), mapped) from error
        except LivestockMutationError:
            if begun:
                session.rollback()
            raise
        except Exception as error:
            if begun:
                session.rollback()
            raise LivestockMutationError("animal_create transaction failed", LivestockMutationErrorCode.TRANSACTION_FAILED) from error

    def _map_persistence_error(self, error: LivestockPersistenceError) -> LivestockMutationErrorCode:
        match error.code:
            case LivestockPersistenceErrorCode.IDEMPOTENCY_CONFLICT:
                return LivestockMutationErrorCode.IDEMPOTENCY_CONFLICT
            case LivestockPersistenceErrorCode.CONFIRMATION_INVALID:
                return LivestockMutationErrorCode.CONFIRMATION_INVALID
            case LivestockPersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS:
                return LivestockMutationErrorCode.TRANSACTION_FAILED
            case _ as unreachable:
                assert_never(unreachable)
