"""DEV-only in-memory immutable write contracts for the first Livestock slice.

These pure functions receive an already server-derived ``TenantContext``. They
do not parse identity, persist records, expose transport, or create a repository
boundary. This module does not authorize persistence, migrations, database/RLS
work, runtime integration, device work, or Production. A future authoritative
mutation adapter must resolve capability and apply the resulting immutable
records atomically with its audit sink.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Iterable

from ranchbrain.livestock_read_model import BREED_SPECIES, PRODUCTION_TYPES_BY_SPECIES, LivestockFactProvenance
from ranchbrain.tenancy import Capability, ROLE_CAPABILITIES, TenantContext


class LivestockWriteErrorCode(str, Enum):
    FORBIDDEN = "livestock_write_forbidden"
    INVALID = "livestock_write_invalid"
    IDENTIFIER_NOT_AVAILABLE = "livestock_identifier_not_available"
    CONFIRMATION_REQUIRED = "livestock_lifecycle_confirmation_required"
    CONTEXT_MISMATCH = "livestock_write_context_mismatch"


class LivestockWriteError(PermissionError):
    def __init__(self, message: str, code: LivestockWriteErrorCode):
        super().__init__(message)
        self.code = code


class LivestockWriteOperation(str, Enum):
    ANIMAL_CREATE = "animal_create"
    IDENTIFIER_ASSIGN = "identifier_assign"
    IDENTIFIER_RETIRE = "identifier_retire"
    LIFECYCLE_RECORD = "lifecycle_record"
    LIFECYCLE_CORRECT = "lifecycle_correct"


class AnimalIdentifierType(str, Enum):
    EAR_TAG = "ear_tag"
    RFID = "rfid"
    BRAND = "brand"
    REGISTRY_NUMBER = "registry_number"


class IdentifierRetirementReason(str, Enum):
    REPLACED = "replaced"
    LOST = "lost"
    INVALID = "invalid"
    DUPLICATE = "duplicate"


class RoutineLifecycleEventType(str, Enum):
    INTAKE = "intake"
    TAGGED = "tagged"
    WEIGHT_RECORDED = "weight_recorded"


class LifecycleCorrectionReason(str, Enum):
    INCORRECT_TIME = "incorrect_time"
    INCORRECT_VALUE = "incorrect_value"
    DUPLICATE_ENTRY = "duplicate_entry"


def _require_aware(value: object, field_name: str) -> None:
    try:
        is_aware = isinstance(value, datetime) and value.tzinfo is not None and value.utcoffset() is not None
    except (TypeError, ValueError):
        is_aware = False
    if not is_aware:
        raise LivestockWriteError(f"{field_name} must be timezone-aware", LivestockWriteErrorCode.INVALID)


def _require_capability(context: TenantContext, capability: Capability) -> None:
    if capability not in ROLE_CAPABILITIES.get(context.role, frozenset()):
        raise LivestockWriteError("tenant context lacks the required livestock capability", LivestockWriteErrorCode.FORBIDDEN)


def _require_tenant(context: TenantContext, tenant_id: str) -> None:
    if tenant_id != context.tenant_id:
        raise LivestockWriteError("livestock write record is outside the resolved tenant", LivestockWriteErrorCode.CONTEXT_MISMATCH)


@dataclass(frozen=True)
class LivestockAuditInputV1:
    operation: LivestockWriteOperation
    actor_user_id: str
    principal_id: str
    correlation_id: str
    recorded_at: datetime

    def __post_init__(self) -> None:
        if not all(isinstance(value, str) and value.strip() for value in (self.actor_user_id, self.principal_id, self.correlation_id)):
            raise LivestockWriteError("audit input requires resolved actor references", LivestockWriteErrorCode.INVALID)
        _require_aware(self.recorded_at, "audit recorded_at")


def audit_input(context: TenantContext, operation: LivestockWriteOperation, recorded_at: datetime) -> LivestockAuditInputV1:
    """Bind immutable audit facts to the resolved context, never caller claims."""

    return LivestockAuditInputV1(operation, context.user_id, context.principal_id, context.correlation_id, recorded_at)


@dataclass(frozen=True)
class AnimalCreateCommandV1:
    id: str
    display_name: str
    species_code: str
    production_type_code: str
    breed_code: str | None
    provenance: LivestockFactProvenance

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id.strip() or not isinstance(self.display_name, str) or not self.display_name.strip():
            raise LivestockWriteError("animal creation requires stable id and display name", LivestockWriteErrorCode.INVALID)
        if self.species_code not in PRODUCTION_TYPES_BY_SPECIES:
            raise LivestockWriteError("animal species is not in the controlled catalog", LivestockWriteErrorCode.INVALID)
        if self.production_type_code not in PRODUCTION_TYPES_BY_SPECIES[self.species_code]:
            raise LivestockWriteError("animal production type is not valid for its species", LivestockWriteErrorCode.INVALID)
        if self.breed_code is not None and BREED_SPECIES.get(self.breed_code) != self.species_code:
            raise LivestockWriteError("animal breed is not valid for its species", LivestockWriteErrorCode.INVALID)


@dataclass(frozen=True)
class LivestockAnimalV1:
    id: str
    tenant_id: str
    display_name: str
    species_code: str
    production_type_code: str
    breed_code: str | None
    provenance: LivestockFactProvenance
    audit: LivestockAuditInputV1


def create_animal(context: TenantContext, command: AnimalCreateCommandV1, recorded_at: datetime) -> LivestockAnimalV1:
    _require_capability(context, Capability.LIVESTOCK_ANIMAL_WRITE)
    return LivestockAnimalV1(
        command.id,
        context.tenant_id,
        command.display_name,
        command.species_code,
        command.production_type_code,
        command.breed_code,
        command.provenance,
        audit_input(context, LivestockWriteOperation.ANIMAL_CREATE, recorded_at),
    )


@dataclass(frozen=True)
class IdentifierAssignCommandV1:
    id: str
    animal_id: str
    identifier_type: AnimalIdentifierType
    normalized_value: str
    effective_at: datetime
    provenance: LivestockFactProvenance

    def __post_init__(self) -> None:
        if not all(isinstance(value, str) and value.strip() for value in (self.id, self.animal_id, self.normalized_value)):
            raise LivestockWriteError("identifier assignment requires stable references", LivestockWriteErrorCode.INVALID)
        if not isinstance(self.identifier_type, AnimalIdentifierType):
            raise LivestockWriteError("identifier type is not in the controlled catalog", LivestockWriteErrorCode.INVALID)
        _require_aware(self.effective_at, "identifier effective_at")


@dataclass(frozen=True)
class AnimalIdentifierV1:
    id: str
    tenant_id: str
    animal_id: str
    identifier_type: AnimalIdentifierType
    normalized_value: str
    effective_at: datetime
    provenance: LivestockFactProvenance
    audit: LivestockAuditInputV1


@dataclass(frozen=True)
class IdentifierRetireCommandV1:
    id: str
    identifier_id: str
    reason: IdentifierRetirementReason
    retired_at: datetime
    provenance: LivestockFactProvenance

    def __post_init__(self) -> None:
        if not all(isinstance(value, str) and value.strip() for value in (self.id, self.identifier_id)):
            raise LivestockWriteError("identifier retirement requires stable references", LivestockWriteErrorCode.INVALID)
        if not isinstance(self.reason, IdentifierRetirementReason):
            raise LivestockWriteError("identifier retirement reason is not in the controlled catalog", LivestockWriteErrorCode.INVALID)
        if not isinstance(self.provenance, LivestockFactProvenance):
            raise LivestockWriteError("identifier retirement requires fact provenance", LivestockWriteErrorCode.INVALID)
        _require_aware(self.retired_at, "identifier retired_at")


@dataclass(frozen=True)
class IdentifierRetirementV1:
    id: str
    tenant_id: str
    identifier_id: str
    reason: IdentifierRetirementReason
    retired_at: datetime
    provenance: LivestockFactProvenance
    audit: LivestockAuditInputV1

    def __post_init__(self) -> None:
        if not self.id or not self.identifier_id or not isinstance(self.reason, IdentifierRetirementReason):
            raise LivestockWriteError("identifier retirement requires controlled references and reason", LivestockWriteErrorCode.INVALID)
        if not isinstance(self.provenance, LivestockFactProvenance):
            raise LivestockWriteError("identifier retirement requires fact provenance", LivestockWriteErrorCode.INVALID)
        _require_aware(self.retired_at, "identifier retired_at")


def _active_identifier_ids(retirements: Iterable[IdentifierRetirementV1]) -> set[str]:
    return {retirement.identifier_id for retirement in retirements}


def assign_identifier(
    context: TenantContext,
    command: IdentifierAssignCommandV1,
    existing_identifiers: Iterable[AnimalIdentifierV1],
    retirements: Iterable[IdentifierRetirementV1],
    recorded_at: datetime,
) -> AnimalIdentifierV1:
    """Enforce active tenant/type/value uniqueness; retired values may be reused."""

    _require_capability(context, Capability.LIVESTOCK_IDENTIFIER_WRITE)
    existing = tuple(existing_identifiers)
    retirements = tuple(retirements)
    for identifier in existing:
        _require_tenant(context, identifier.tenant_id)
    for retirement in retirements:
        _require_tenant(context, retirement.tenant_id)
    retired_ids = _active_identifier_ids(retirements)
    collision = any(
        identifier.id not in retired_ids
        and identifier.identifier_type is command.identifier_type
        and identifier.normalized_value == command.normalized_value
        for identifier in existing
    )
    if collision:
        raise LivestockWriteError("identifier value is already active in this tenant", LivestockWriteErrorCode.IDENTIFIER_NOT_AVAILABLE)
    return AnimalIdentifierV1(
        command.id,
        context.tenant_id,
        command.animal_id,
        command.identifier_type,
        command.normalized_value,
        command.effective_at,
        command.provenance,
        audit_input(context, LivestockWriteOperation.IDENTIFIER_ASSIGN, recorded_at),
    )


def retire_identifier(
    context: TenantContext,
    command: IdentifierRetireCommandV1,
    identifier: AnimalIdentifierV1,
    existing_retirements: Iterable[IdentifierRetirementV1],
    recorded_at: datetime,
) -> IdentifierRetirementV1:
    _require_capability(context, Capability.LIVESTOCK_IDENTIFIER_WRITE)
    _require_tenant(context, identifier.tenant_id)
    if command.identifier_id != identifier.id:
        raise LivestockWriteError("identifier retirement is not bound to the loaded assignment", LivestockWriteErrorCode.CONTEXT_MISMATCH)
    if any(retirement.identifier_id == identifier.id for retirement in existing_retirements):
        raise LivestockWriteError("identifier is already retired", LivestockWriteErrorCode.INVALID)
    if command.retired_at < identifier.effective_at:
        raise LivestockWriteError("identifier retirement cannot precede assignment", LivestockWriteErrorCode.INVALID)
    return IdentifierRetirementV1(
        command.id,
        context.tenant_id,
        identifier.id,
        command.reason,
        command.retired_at,
        command.provenance,
        audit_input(context, LivestockWriteOperation.IDENTIFIER_RETIRE, recorded_at),
    )


@dataclass(frozen=True)
class LifecycleCorrectionConfirmationV1:
    id: str
    approved_by_user_id: str
    correlation_id: str
    approved_at: datetime

    def __post_init__(self) -> None:
        if not self.id or not self.approved_by_user_id or not self.correlation_id:
            raise LivestockWriteError("lifecycle correction confirmation requires stable references", LivestockWriteErrorCode.INVALID)
        _require_aware(self.approved_at, "confirmation approved_at")


@dataclass(frozen=True)
class RoutineLifecycleEventCommandV1:
    id: str
    animal_id: str
    event_type: RoutineLifecycleEventType
    occurred_at: datetime
    provenance: LivestockFactProvenance
    supersedes_event_id: str | None = None
    correction_reason: LifecycleCorrectionReason | None = None
    confirmation: LifecycleCorrectionConfirmationV1 | None = None

    def __post_init__(self) -> None:
        if not self.id or not self.animal_id or not isinstance(self.event_type, RoutineLifecycleEventType):
            raise LivestockWriteError("routine lifecycle event requires controlled references and taxonomy", LivestockWriteErrorCode.INVALID)
        _require_aware(self.occurred_at, "lifecycle occurred_at")
        correction = self.supersedes_event_id is not None
        if correction != (self.correction_reason is not None):
            raise LivestockWriteError("lifecycle corrections require a superseded event and controlled reason", LivestockWriteErrorCode.INVALID)
        if correction != (self.confirmation is not None):
            raise LivestockWriteError("lifecycle corrections require confirmation", LivestockWriteErrorCode.CONFIRMATION_REQUIRED)


@dataclass(frozen=True)
class RoutineLifecycleEventV1:
    id: str
    tenant_id: str
    animal_id: str
    event_type: RoutineLifecycleEventType
    occurred_at: datetime
    provenance: LivestockFactProvenance
    audit: LivestockAuditInputV1
    supersedes_event_id: str | None = None
    correction_reason: LifecycleCorrectionReason | None = None
    confirmation: LifecycleCorrectionConfirmationV1 | None = None


def record_routine_lifecycle_event(
    context: TenantContext,
    command: RoutineLifecycleEventCommandV1,
    existing_events: Iterable[RoutineLifecycleEventV1],
    recorded_at: datetime,
) -> RoutineLifecycleEventV1:
    """Append a routine event or owner-confirmed correction; never overwrite history."""

    _require_capability(context, Capability.LIVESTOCK_LIFECYCLE_WRITE)
    existing = tuple(existing_events)
    for event in existing:
        _require_tenant(context, event.tenant_id)
        if event.animal_id != command.animal_id:
            raise LivestockWriteError("lifecycle history is not for the requested animal", LivestockWriteErrorCode.CONTEXT_MISMATCH)

    if command.supersedes_event_id is None:
        # Superseded events are historical facts, not part of effective ordering.
        superseded_event_ids = {event.supersedes_event_id for event in existing if event.supersedes_event_id is not None}
        prior_times = [event.occurred_at for event in existing if event.id not in superseded_event_ids]
        if prior_times and command.occurred_at <= max(prior_times):
            raise LivestockWriteError("routine lifecycle events must append in occurred-time order", LivestockWriteErrorCode.INVALID)
        operation = LivestockWriteOperation.LIFECYCLE_RECORD
    else:
        _require_capability(context, Capability.LIVESTOCK_LIFECYCLE_CORRECT)
        target = next((event for event in existing if event.id == command.supersedes_event_id), None)
        if target is None or target.event_type is not command.event_type:
            raise LivestockWriteError("lifecycle correction must supersede one matching event", LivestockWriteErrorCode.INVALID)
        if any(event.supersedes_event_id == target.id for event in existing):
            raise LivestockWriteError("lifecycle event is already superseded", LivestockWriteErrorCode.INVALID)
        confirmation = command.confirmation
        if confirmation is None or confirmation.approved_by_user_id != context.user_id or confirmation.correlation_id != context.correlation_id:
            raise LivestockWriteError("lifecycle correction confirmation is not bound to the resolved context", LivestockWriteErrorCode.CONFIRMATION_REQUIRED)
        if confirmation.approved_at > recorded_at or recorded_at <= target.audit.recorded_at:
            raise LivestockWriteError("lifecycle correction confirmation timing is invalid", LivestockWriteErrorCode.INVALID)
        operation = LivestockWriteOperation.LIFECYCLE_CORRECT

    return RoutineLifecycleEventV1(
        command.id,
        context.tenant_id,
        command.animal_id,
        command.event_type,
        command.occurred_at,
        command.provenance,
        audit_input(context, operation, recorded_at),
        command.supersedes_event_id,
        command.correction_reason,
        command.confirmation,
    )
