"""DEV-only livestock mutation coordinator.

Transport-free. Receives a server-derived VerifiedPrincipal and an injected
TenantContextResolver. The coordinator owns one transaction, SET LOCAL, CF-2
consumption, and idempotency for animal_create plus identifier assign/retire.
It does not implement ingress, a principal verifier, HTTP, lifecycle
mutations, or confirmation issuance.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from hashlib import sha256
from json import dumps
from typing import NoReturn, assert_never
from uuid import UUID, uuid4

from ranchbrain.livestock_write_model import (
    AnimalCreateCommandV1,
    AnimalIdentifierV1,
    IdentifierAssignCommandV1,
    IdentifierRetireCommandV1,
    IdentifierRetirementV1,
    LivestockAnimalV1,
    LivestockWriteError,
    LivestockWriteErrorCode,
    assign_identifier,
    create_animal,
    retire_identifier,
)
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    IDENTIFIER_ASSIGN_OPERATION,
    IDENTIFIER_RETIRE_OPERATION,
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockIdempotencyRecord,
    LivestockMutationSession,
    LivestockPersistenceError,
    LivestockPersistenceErrorCode,
    LivestockWriteRepository,
)
from ranchbrain.tenancy import Capability, TenantContext, TenantContextResolver, TenancyError, VerifiedPrincipal


class LivestockMutationErrorCode(str, Enum):
    ADMISSION_DENIED = "livestock_mutation_admission_denied"
    PRINCIPAL_ID_INVALID = "livestock_mutation_principal_id_invalid"
    CONFIRMATION_INVALID = "livestock_mutation_confirmation_invalid"
    IDEMPOTENCY_CONFLICT = "livestock_mutation_idempotency_conflict"
    IDENTIFIER_NOT_AVAILABLE = "livestock_mutation_identifier_not_available"
    IDENTIFIER_INVALID = "livestock_mutation_identifier_invalid"
    TARGET_NOT_FOUND = "livestock_mutation_target_not_found"
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


@dataclass(frozen=True)
class LivestockIdentifierAssignRequest:
    command: IdentifierAssignCommandV1
    confirmation: LivestockConfirmationRecord
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class LivestockIdentifierAssignResult:
    identifier: AnimalIdentifierV1
    replayed: bool
    transaction_id: str
    confirmation_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class LivestockIdentifierRetireRequest:
    command: IdentifierRetireCommandV1
    confirmation: LivestockConfirmationRecord
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class LivestockIdentifierRetireResult:
    retirement: IdentifierRetirementV1
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


def _canonical_digest(payload: dict[str, object]) -> str:
    canonical = dumps(payload, separators=(",", ":"), sort_keys=True)
    return sha256(canonical.encode("utf-8")).hexdigest()


def canonical_animal_create_digest(
    *,
    tenant_id: str,
    command: AnimalCreateCommandV1,
    confirmation_id: str,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
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
    )


def canonical_identifier_assign_digest(
    *,
    tenant_id: str,
    command: IdentifierAssignCommandV1,
    confirmation_id: str,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "animal_id": command.animal_id,
            "confirmation_id": confirmation_id,
            "effective_at": command.effective_at.isoformat(),
            "id": command.id,
            "idempotency_identity": idempotency_identity,
            "identifier_type": command.identifier_type.value,
            "normalized_value": command.normalized_value,
            "operation": IDENTIFIER_ASSIGN_OPERATION,
            "policy_version": policy_version,
            "provenance_observed_at": command.provenance.observed_at.isoformat(),
            "provenance_source_id": command.provenance.source_id,
            "provenance_source_type": command.provenance.source_type,
            "provenance_source_version": command.provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


def canonical_identifier_retire_digest(
    *,
    tenant_id: str,
    command: IdentifierRetireCommandV1,
    confirmation_id: str,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "confirmation_id": confirmation_id,
            "id": command.id,
            "idempotency_identity": idempotency_identity,
            "identifier_id": command.identifier_id,
            "operation": IDENTIFIER_RETIRE_OPERATION,
            "policy_version": policy_version,
            "provenance_observed_at": command.provenance.observed_at.isoformat(),
            "provenance_source_id": command.provenance.source_id,
            "provenance_source_type": command.provenance.source_type,
            "provenance_source_version": command.provenance.source_version,
            "reason": command.reason.value,
            "retired_at": command.retired_at.isoformat(),
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


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
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.LIVESTOCK_ANIMAL_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            confirmation_id=request.confirmation.id,
            now=current_time,
        )
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
                operation=ANIMAL_CREATE_OPERATION,
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
                operation=ANIMAL_CREATE_OPERATION,
            )
            animal = create_animal(context, request.command, trusted_now)
            self._repository.persist_animal(session, animal)
            self._repository.insert_audit(
                session,
                self._audit_record(
                    context=context,
                    transaction_id=transaction_id,
                    operation=ANIMAL_CREATE_OPERATION,
                    target_id=animal.id,
                    policy_version=request.policy_version,
                    validator_version=request.validator_version,
                    provenance_source_type=animal.provenance.source_type,
                    provenance_source_id=animal.provenance.source_id,
                    provenance_source_version=animal.provenance.source_version,
                    confirmation_id=request.confirmation.id,
                    result_metadata="created",
                    recorded_at=trusted_now,
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
        except Exception as error:
            self._abort(session, begun, error)

    def assign_identifier(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: LivestockIdentifierAssignRequest,
        session: LivestockMutationSession,
        now: datetime | None = None,
    ) -> LivestockIdentifierAssignResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.LIVESTOCK_IDENTIFIER_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            confirmation_id=request.confirmation.id,
            now=current_time,
        )
        digest = canonical_identifier_assign_digest(
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
                operation=IDENTIFIER_ASSIGN_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.identifier is None:
                    raise LivestockMutationError("replay is missing its original identifier", LivestockMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return LivestockIdentifierAssignResult(
                    reservation.record.identifier,
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
                operation=IDENTIFIER_ASSIGN_OPERATION,
            )
            if session.lock_animal(context.tenant_id, request.command.animal_id) is None:
                raise LivestockMutationError("identifier assignment animal is missing", LivestockMutationErrorCode.TARGET_NOT_FOUND)
            session.lock_active_identifier_slot(
                context.tenant_id,
                request.command.identifier_type,
                request.command.normalized_value,
            )
            existing = session.load_identifiers_for_collision(
                context.tenant_id,
                request.command.identifier_type,
                request.command.normalized_value,
            )
            retirements = session.load_retirements_for_identifiers(context.tenant_id, tuple(item.id for item in existing))
            identifier = assign_identifier(context, request.command, existing, retirements, trusted_now)
            self._repository.persist_identifier(session, identifier)
            self._repository.insert_audit(
                session,
                self._audit_record(
                    context=context,
                    transaction_id=transaction_id,
                    operation=IDENTIFIER_ASSIGN_OPERATION,
                    target_id=identifier.id,
                    policy_version=request.policy_version,
                    validator_version=request.validator_version,
                    provenance_source_type=identifier.provenance.source_type,
                    provenance_source_id=identifier.provenance.source_id,
                    provenance_source_version=identifier.provenance.source_version,
                    confirmation_id=request.confirmation.id,
                    result_metadata="assigned",
                    recorded_at=trusted_now,
                ),
            )
            self._repository.finalize_idempotency(
                session,
                LivestockIdempotencyRecord(
                    context.tenant_id,
                    IDENTIFIER_ASSIGN_OPERATION,
                    request.idempotency_identity,
                    digest,
                    IDENTIFIER_ASSIGN_OPERATION,
                    "committed",
                    transaction_id,
                    None,
                    None,
                    identifier.id,
                    identifier,
                ),
            )
            session.commit()
            return LivestockIdentifierAssignResult(identifier, False, transaction_id, request.confirmation.id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def retire_identifier(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: LivestockIdentifierRetireRequest,
        session: LivestockMutationSession,
        now: datetime | None = None,
    ) -> LivestockIdentifierRetireResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.LIVESTOCK_IDENTIFIER_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            confirmation_id=request.confirmation.id,
            now=current_time,
        )
        digest = canonical_identifier_retire_digest(
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
                operation=IDENTIFIER_RETIRE_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.retirement is None:
                    raise LivestockMutationError("replay is missing its original retirement", LivestockMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return LivestockIdentifierRetireResult(
                    reservation.record.retirement,
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
                target_manifest=request.command.identifier_id,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                now=trusted_now,
                operation=IDENTIFIER_RETIRE_OPERATION,
            )
            identifier = session.lock_identifier(context.tenant_id, request.command.identifier_id)
            if identifier is None:
                raise LivestockMutationError("identifier retirement target is missing", LivestockMutationErrorCode.TARGET_NOT_FOUND)
            existing_retirements = session.load_retirements_for_identifiers(context.tenant_id, (identifier.id,))
            retirement = retire_identifier(context, request.command, identifier, existing_retirements, trusted_now)
            self._repository.persist_retirement(session, retirement)
            self._repository.insert_audit(
                session,
                self._audit_record(
                    context=context,
                    transaction_id=transaction_id,
                    operation=IDENTIFIER_RETIRE_OPERATION,
                    target_id=retirement.id,
                    policy_version=request.policy_version,
                    validator_version=request.validator_version,
                    provenance_source_type=retirement.provenance.source_type,
                    provenance_source_id=retirement.provenance.source_id,
                    provenance_source_version=retirement.provenance.source_version,
                    confirmation_id=request.confirmation.id,
                    result_metadata="retired",
                    recorded_at=trusted_now,
                ),
            )
            self._repository.finalize_idempotency(
                session,
                LivestockIdempotencyRecord(
                    context.tenant_id,
                    IDENTIFIER_RETIRE_OPERATION,
                    request.idempotency_identity,
                    digest,
                    IDENTIFIER_RETIRE_OPERATION,
                    "committed",
                    transaction_id,
                    None,
                    None,
                    None,
                    None,
                    retirement.id,
                    retirement,
                ),
            )
            session.commit()
            return LivestockIdentifierRetireResult(retirement, False, transaction_id, request.confirmation.id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def _admit(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        capability: Capability,
        identity: str,
        policy_version: str,
        validator_version: str,
        confirmation_id: str,
        now: datetime,
    ) -> TenantContext:
        if not isinstance(principal, VerifiedPrincipal):
            raise LivestockMutationError("livestock mutation requires a server-derived verified principal", LivestockMutationErrorCode.ADMISSION_DENIED)
        _require_uuid(principal.id, "VerifiedPrincipal.id")
        if not requested_tenant_id:
            raise LivestockMutationError("an explicit tenant selection is required", LivestockMutationErrorCode.ADMISSION_DENIED)
        if not identity.strip() or not policy_version.strip() or not validator_version.strip() or not confirmation_id.strip():
            raise LivestockMutationError(
                "livestock mutation requires policy, validator, confirmation id, and idempotency identity",
                LivestockMutationErrorCode.ADMISSION_DENIED,
            )
        try:
            return self._resolver.resolve(
                principal=principal,
                requested_tenant_id=requested_tenant_id,
                capability=capability,
                now=now,
            )
        except TenancyError as error:
            raise LivestockMutationError(str(error), LivestockMutationErrorCode.ADMISSION_DENIED) from error

    def _audit_record(
        self,
        *,
        context: TenantContext,
        transaction_id: str,
        operation: str,
        target_id: str,
        policy_version: str,
        validator_version: str,
        provenance_source_type: str,
        provenance_source_id: str,
        provenance_source_version: str,
        confirmation_id: str,
        result_metadata: str,
        recorded_at: datetime,
    ) -> LivestockAuditRecord:
        return LivestockAuditRecord(
            str(uuid4()),
            context.tenant_id,
            transaction_id,
            operation,
            target_id,
            context.user_id,
            context.principal_id,
            context.correlation_id,
            policy_version,
            validator_version,
            "committed",
            provenance_source_type,
            provenance_source_id,
            provenance_source_version,
            confirmation_id,
            result_metadata,
            recorded_at,
        )

    def _abort(self, session: LivestockMutationSession, begun: bool, error: Exception) -> NoReturn:
        if begun:
            session.rollback()
        if isinstance(error, LivestockMutationError):
            raise error
        if isinstance(error, LivestockWriteError):
            raise LivestockMutationError(str(error), self._map_write_error(error)) from error
        if isinstance(error, LivestockPersistenceError):
            raise LivestockMutationError(str(error), self._map_persistence_error(error)) from error
        raise LivestockMutationError("livestock mutation transaction failed", LivestockMutationErrorCode.TRANSACTION_FAILED) from error

    def _map_write_error(self, error: LivestockWriteError) -> LivestockMutationErrorCode:
        match error.code:
            case LivestockWriteErrorCode.IDENTIFIER_NOT_AVAILABLE:
                return LivestockMutationErrorCode.IDENTIFIER_NOT_AVAILABLE
            case LivestockWriteErrorCode.INVALID:
                return LivestockMutationErrorCode.IDENTIFIER_INVALID
            case LivestockWriteErrorCode.FORBIDDEN:
                return LivestockMutationErrorCode.ADMISSION_DENIED
            case LivestockWriteErrorCode.CONTEXT_MISMATCH:
                return LivestockMutationErrorCode.TRANSACTION_FAILED
            case LivestockWriteErrorCode.CONFIRMATION_REQUIRED:
                return LivestockMutationErrorCode.TRANSACTION_FAILED
            case _ as unreachable:
                assert_never(unreachable)

    def _map_persistence_error(self, error: LivestockPersistenceError) -> LivestockMutationErrorCode:
        match error.code:
            case LivestockPersistenceErrorCode.IDEMPOTENCY_CONFLICT:
                return LivestockMutationErrorCode.IDEMPOTENCY_CONFLICT
            case LivestockPersistenceErrorCode.CONFIRMATION_INVALID:
                return LivestockMutationErrorCode.CONFIRMATION_INVALID
            case LivestockPersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS:
                return LivestockMutationErrorCode.TRANSACTION_FAILED
            case LivestockPersistenceErrorCode.IDENTIFIER_NOT_AVAILABLE:
                return LivestockMutationErrorCode.IDENTIFIER_NOT_AVAILABLE
            case LivestockPersistenceErrorCode.IDENTIFIER_INVALID:
                return LivestockMutationErrorCode.IDENTIFIER_INVALID
            case LivestockPersistenceErrorCode.TARGET_NOT_FOUND:
                return LivestockMutationErrorCode.TARGET_NOT_FOUND
            case _ as unreachable:
                assert_never(unreachable)
