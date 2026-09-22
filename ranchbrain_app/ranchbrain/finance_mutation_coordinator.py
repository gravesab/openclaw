"""DEV-only finance mutation coordinator.

Transport-free. Receives a server-derived VerifiedPrincipal and an injected
TenantContextResolver. The coordinator owns one transaction, SET LOCAL, and
idempotency for chart, source, and interpretation mutations. It does not
implement ingress, a principal verifier, HTTP, connectors, or money movement.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from hashlib import sha256
from json import dumps
from typing import NoReturn, assert_never
from uuid import UUID, uuid4

from ranchbrain.finance_model import (
    Account,
    FinanceError,
    Interpretation,
    SourceActivity,
    reverse_interpretation as build_reversal,
)
from ranchbrain.finance_write_repository import (
    ACCOUNT_CREATE_OPERATION,
    INTERPRETATION_POST_OPERATION,
    INTERPRETATION_REVERSE_OPERATION,
    INTERPRETATION_SUPERSEDE_OPERATION,
    SOURCE_ACTIVITY_RECORD_OPERATION,
    SOURCE_ARTIFACT_RECORD_OPERATION,
    FinanceAuditRecord,
    FinanceFactProvenance,
    FinanceIdempotencyRecord,
    FinanceMutationSession,
    FinancePersistenceError,
    FinancePersistenceErrorCode,
    FinanceWriteRepository,
    SourceArtifactRecord,
)
from ranchbrain.tenancy import Capability, TenantContext, TenantContextResolver, TenancyError, VerifiedPrincipal


class FinanceMutationErrorCode(str, Enum):
    ADMISSION_DENIED = "finance_mutation_admission_denied"
    PRINCIPAL_ID_INVALID = "finance_mutation_principal_id_invalid"
    IDEMPOTENCY_CONFLICT = "finance_mutation_idempotency_conflict"
    TARGET_NOT_FOUND = "finance_mutation_target_not_found"
    INVALID = "finance_mutation_invalid"
    INVALID_CORRECTION = "finance_mutation_invalid_correction"
    TRANSACTION_FAILED = "finance_mutation_transaction_failed"


class FinanceMutationError(PermissionError):
    def __init__(self, message: str, code: FinanceMutationErrorCode):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class FinanceAccountCreateRequest:
    account: Account
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class FinanceAccountCreateResult:
    account: Account
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class FinanceSourceArtifactRequest:
    artifact: SourceArtifactRecord
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class FinanceSourceArtifactResult:
    artifact: SourceArtifactRecord
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class FinanceSourceActivityRequest:
    activity: SourceActivity
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str
    artifact_id: str | None = None


@dataclass(frozen=True)
class FinanceSourceActivityResult:
    activity: SourceActivity
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class FinanceInterpretationPostRequest:
    interpretation: Interpretation
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class FinanceInterpretationPostResult:
    interpretation: Interpretation
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class FinanceInterpretationReverseRequest:
    original_id: str
    new_id: str
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class FinanceInterpretationReverseResult:
    interpretation: Interpretation
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


@dataclass(frozen=True)
class FinanceInterpretationSupersedeRequest:
    replacement: Interpretation
    provenance: FinanceFactProvenance
    idempotency_identity: str
    policy_version: str
    validator_version: str


@dataclass(frozen=True)
class FinanceInterpretationSupersedeResult:
    interpretation: Interpretation
    replayed: bool
    transaction_id: str
    idempotency_outcome: str


def _require_uuid(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FinanceMutationError(f"{field_name} must be a UUID", FinanceMutationErrorCode.PRINCIPAL_ID_INVALID)
    try:
        parsed = UUID(value)
    except ValueError as error:
        raise FinanceMutationError(f"{field_name} must be a UUID", FinanceMutationErrorCode.PRINCIPAL_ID_INVALID) from error
    if str(parsed) != value:
        raise FinanceMutationError(f"{field_name} must be a UUID", FinanceMutationErrorCode.PRINCIPAL_ID_INVALID)
    return value


def _canonical_digest(payload: dict[str, object]) -> str:
    canonical = dumps(payload, separators=(",", ":"), sort_keys=True)
    return sha256(canonical.encode("utf-8")).hexdigest()


def _allocation_payload(allocation) -> dict[str, object] | None:
    if allocation is None:
        return None
    return {
        "domain": allocation.domain.value,
        "target_id": allocation.target_id,
        "target_type": allocation.target_type.value,
    }


def canonical_account_create_digest(
    *,
    tenant_id: str,
    account: Account,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "account_id": account.id,
            "account_type": account.account_type.value,
            "idempotency_identity": idempotency_identity,
            "institution": account.institution,
            "name": account.name,
            "operation": ACCOUNT_CREATE_OPERATION,
            "policy_version": policy_version,
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


def canonical_source_artifact_digest(
    *,
    tenant_id: str,
    artifact: SourceArtifactRecord,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "account_id": artifact.account_id,
            "artifact_id": artifact.id,
            "byte_size": artifact.byte_size,
            "content_digest": artifact.content_digest,
            "idempotency_identity": idempotency_identity,
            "kind": artifact.kind,
            "media_type": artifact.media_type,
            "operation": SOURCE_ARTIFACT_RECORD_OPERATION,
            "original_filename": artifact.original_filename,
            "parser_version": artifact.parser_version,
            "period_end": None if artifact.period_end is None else artifact.period_end.isoformat(),
            "period_start": None if artifact.period_start is None else artifact.period_start.isoformat(),
            "policy_version": policy_version,
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


def canonical_source_activity_digest(
    *,
    tenant_id: str,
    activity: SourceActivity,
    artifact_id: str | None,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "activity_id": activity.id,
            "amount": str(activity.amount),
            "artifact_id": artifact_id,
            "description": activity.description,
            "idempotency_identity": idempotency_identity,
            "operation": SOURCE_ACTIVITY_RECORD_OPERATION,
            "policy_version": policy_version,
            "posted_at": activity.posted_at.isoformat(),
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "source_account_id": activity.source_account_id,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


def _interpretation_payload(interpretation: Interpretation) -> dict[str, object]:
    return {
        "id": interpretation.id,
        "journal": {
            "id": interpretation.journal_entry.id,
            "lines": [
                {"account_id": line.account_id, "credit": str(line.credit), "debit": str(line.debit)}
                for line in interpretation.journal_entry.lines
            ],
            "recorded_at": interpretation.journal_entry.recorded_at.isoformat(),
            "reverses_journal_id": interpretation.journal_entry.reverses_journal_id,
        },
        "reverses_id": interpretation.reverses_id,
        "source_activity_id": interpretation.source_activity_id,
        "splits": [
            {
                "allocation": _allocation_payload(split.allocation),
                "amount": str(split.amount),
                "destination_account_id": split.destination_account_id,
            }
            for split in interpretation.splits
        ],
        "supersedes_id": interpretation.supersedes_id,
    }


def canonical_interpretation_post_digest(
    *,
    tenant_id: str,
    interpretation: Interpretation,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    payload = _interpretation_payload(interpretation)
    payload.update(
        {
            "idempotency_identity": idempotency_identity,
            "operation": INTERPRETATION_POST_OPERATION,
            "policy_version": policy_version,
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )
    return _canonical_digest(payload)


def canonical_interpretation_reverse_digest(
    *,
    tenant_id: str,
    original_id: str,
    new_id: str,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    return _canonical_digest(
        {
            "idempotency_identity": idempotency_identity,
            "new_id": new_id,
            "operation": INTERPRETATION_REVERSE_OPERATION,
            "original_id": original_id,
            "policy_version": policy_version,
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )


def canonical_interpretation_supersede_digest(
    *,
    tenant_id: str,
    replacement: Interpretation,
    provenance: FinanceFactProvenance,
    idempotency_identity: str,
    policy_version: str,
    validator_version: str,
) -> str:
    payload = _interpretation_payload(replacement)
    payload.update(
        {
            "idempotency_identity": idempotency_identity,
            "operation": INTERPRETATION_SUPERSEDE_OPERATION,
            "policy_version": policy_version,
            "provenance_observed_at": provenance.observed_at.isoformat(),
            "provenance_source_id": provenance.source_id,
            "provenance_source_type": provenance.source_type,
            "provenance_source_version": provenance.source_version,
            "tenant_id": tenant_id,
            "validator_version": validator_version,
        }
    )
    return _canonical_digest(payload)


class FinanceMutationCoordinator:
    def __init__(self, resolver: TenantContextResolver, repository: FinanceWriteRepository):
        self._resolver = resolver
        self._repository = repository

    def create_account(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceAccountCreateRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceAccountCreateResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_CHART_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_account_create_digest(
            tenant_id=context.tenant_id,
            account=request.account,
            provenance=request.provenance,
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
                operation=ACCOUNT_CREATE_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.account is None:
                    raise FinanceMutationError("replay is missing its original account", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceAccountCreateResult(
                    reservation.record.account,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            self._repository.persist_account(
                session,
                tenant_id=context.tenant_id,
                account=request.account,
                provenance=request.provenance,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=ACCOUNT_CREATE_OPERATION,
                target_id=request.account.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="created",
                identity=request.idempotency_identity,
                digest=digest,
                result_account_id=request.account.id,
                account=request.account,
            )
            session.commit()
            return FinanceAccountCreateResult(request.account, False, transaction_id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def record_source_artifact(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceSourceArtifactRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceSourceArtifactResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_SOURCE_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_source_artifact_digest(
            tenant_id=context.tenant_id,
            artifact=request.artifact,
            provenance=request.provenance,
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
                operation=SOURCE_ARTIFACT_RECORD_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.artifact is None:
                    raise FinanceMutationError("replay is missing its original source artifact", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceSourceArtifactResult(
                    reservation.record.artifact,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            if request.artifact.account_id is not None and session.lock_account(context.tenant_id, request.artifact.account_id) is None:
                raise FinanceMutationError("source artifact account is missing", FinanceMutationErrorCode.TARGET_NOT_FOUND)
            self._repository.persist_artifact(
                session,
                tenant_id=context.tenant_id,
                artifact=request.artifact,
                provenance=request.provenance,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=SOURCE_ARTIFACT_RECORD_OPERATION,
                target_id=request.artifact.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="recorded",
                identity=request.idempotency_identity,
                digest=digest,
                result_artifact_id=request.artifact.id,
                artifact=request.artifact,
            )
            session.commit()
            return FinanceSourceArtifactResult(request.artifact, False, transaction_id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def record_source_activity(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceSourceActivityRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceSourceActivityResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_SOURCE_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_source_activity_digest(
            tenant_id=context.tenant_id,
            activity=request.activity,
            artifact_id=request.artifact_id,
            provenance=request.provenance,
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
                operation=SOURCE_ACTIVITY_RECORD_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.activity is None:
                    raise FinanceMutationError("replay is missing its original source activity", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceSourceActivityResult(
                    reservation.record.activity,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            if session.lock_account(context.tenant_id, request.activity.source_account_id) is None:
                raise FinanceMutationError("source activity account is missing", FinanceMutationErrorCode.TARGET_NOT_FOUND)
            if request.artifact_id is not None and session.lock_artifact(context.tenant_id, request.artifact_id) is None:
                raise FinanceMutationError("source activity artifact is missing", FinanceMutationErrorCode.TARGET_NOT_FOUND)
            self._repository.persist_activity(
                session,
                tenant_id=context.tenant_id,
                activity=request.activity,
                artifact_id=request.artifact_id,
                provenance=request.provenance,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=SOURCE_ACTIVITY_RECORD_OPERATION,
                target_id=request.activity.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="recorded",
                identity=request.idempotency_identity,
                digest=digest,
                result_activity_id=request.activity.id,
                activity=request.activity,
            )
            session.commit()
            return FinanceSourceActivityResult(request.activity, False, transaction_id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def post_interpretation(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceInterpretationPostRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceInterpretationPostResult:
        if request.interpretation.reverses_id is not None or request.interpretation.supersedes_id is not None:
            raise FinanceMutationError(
                "interpretation corrections must use the dedicated correction operations",
                FinanceMutationErrorCode.INVALID_CORRECTION,
            )
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_INTERPRETATION_WRITE,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_interpretation_post_digest(
            tenant_id=context.tenant_id,
            interpretation=request.interpretation,
            provenance=request.provenance,
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
                operation=INTERPRETATION_POST_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.interpretation is None:
                    raise FinanceMutationError("replay is missing its original interpretation", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceInterpretationPostResult(
                    reservation.record.interpretation,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            if session.lock_activity(context.tenant_id, request.interpretation.source_activity_id) is None:
                raise FinanceMutationError("interpretation source activity is missing", FinanceMutationErrorCode.TARGET_NOT_FOUND)
            ledger = session.load_ledger(context.tenant_id)
            ledger.with_interpretation(request.interpretation)
            self._repository.persist_interpretation(
                session,
                tenant_id=context.tenant_id,
                interpretation=request.interpretation,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=INTERPRETATION_POST_OPERATION,
                target_id=request.interpretation.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="posted",
                identity=request.idempotency_identity,
                digest=digest,
                result_interpretation_id=request.interpretation.id,
                interpretation=request.interpretation,
            )
            session.commit()
            return FinanceInterpretationPostResult(request.interpretation, False, transaction_id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def reverse_interpretation(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceInterpretationReverseRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceInterpretationReverseResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_INTERPRETATION_CORRECT,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_interpretation_reverse_digest(
            tenant_id=context.tenant_id,
            original_id=request.original_id,
            new_id=request.new_id,
            provenance=request.provenance,
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
                operation=INTERPRETATION_REVERSE_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.interpretation is None:
                    raise FinanceMutationError("replay is missing its original reversal", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceInterpretationReverseResult(
                    reservation.record.interpretation,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            ledger = session.load_ledger(context.tenant_id)
            reversal = build_reversal(ledger.interpretations, request.original_id, request.new_id, trusted_now)
            ledger.with_interpretation(reversal)
            self._repository.persist_interpretation(
                session,
                tenant_id=context.tenant_id,
                interpretation=reversal,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=INTERPRETATION_REVERSE_OPERATION,
                target_id=reversal.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="reversed",
                identity=request.idempotency_identity,
                digest=digest,
                result_interpretation_id=reversal.id,
                interpretation=reversal,
            )
            session.commit()
            return FinanceInterpretationReverseResult(reversal, False, transaction_id, "committed")
        except Exception as error:
            self._abort(session, begun, error)

    def supersede_interpretation(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        request: FinanceInterpretationSupersedeRequest,
        session: FinanceMutationSession,
        now: datetime | None = None,
    ) -> FinanceInterpretationSupersedeResult:
        current_time = now or datetime.now(timezone.utc)
        context = self._admit(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.FINANCE_INTERPRETATION_CORRECT,
            identity=request.idempotency_identity,
            policy_version=request.policy_version,
            validator_version=request.validator_version,
            now=current_time,
        )
        digest = canonical_interpretation_supersede_digest(
            tenant_id=context.tenant_id,
            replacement=request.replacement,
            provenance=request.provenance,
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
                operation=INTERPRETATION_SUPERSEDE_OPERATION,
            )
            if reservation.replayed:
                if reservation.record.interpretation is None:
                    raise FinanceMutationError("replay is missing its original supersession", FinanceMutationErrorCode.TRANSACTION_FAILED)
                session.commit()
                return FinanceInterpretationSupersedeResult(
                    reservation.record.interpretation,
                    True,
                    reservation.record.transaction_id,
                    "replayed",
                )
            if session.lock_activity(context.tenant_id, request.replacement.source_activity_id) is None:
                raise FinanceMutationError("interpretation source activity is missing", FinanceMutationErrorCode.TARGET_NOT_FOUND)
            ledger = session.load_ledger(context.tenant_id)
            next_ledger = ledger.with_supersession(request.replacement)
            added = next_ledger.interpretations[len(ledger.interpretations) :]
            for interpretation in added:
                self._repository.persist_interpretation(
                    session,
                    tenant_id=context.tenant_id,
                    interpretation=interpretation,
                    created_by_user_id=context.user_id,
                    created_at=trusted_now,
                )
            self._commit_effect(
                session,
                context=context,
                transaction_id=transaction_id,
                operation=INTERPRETATION_SUPERSEDE_OPERATION,
                target_id=request.replacement.id,
                provenance=request.provenance,
                policy_version=request.policy_version,
                validator_version=request.validator_version,
                recorded_at=trusted_now,
                result_metadata="superseded",
                identity=request.idempotency_identity,
                digest=digest,
                result_interpretation_id=request.replacement.id,
                interpretation=request.replacement,
            )
            session.commit()
            return FinanceInterpretationSupersedeResult(request.replacement, False, transaction_id, "committed")
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
        now: datetime,
    ) -> TenantContext:
        if not isinstance(principal, VerifiedPrincipal):
            raise FinanceMutationError("finance mutation requires a server-derived verified principal", FinanceMutationErrorCode.ADMISSION_DENIED)
        _require_uuid(principal.id, "VerifiedPrincipal.id")
        if not requested_tenant_id:
            raise FinanceMutationError("an explicit tenant selection is required", FinanceMutationErrorCode.ADMISSION_DENIED)
        if not identity.strip() or not policy_version.strip() or not validator_version.strip():
            raise FinanceMutationError(
                "finance mutation requires policy, validator, and idempotency identity",
                FinanceMutationErrorCode.ADMISSION_DENIED,
            )
        try:
            return self._resolver.resolve(
                principal=principal,
                requested_tenant_id=requested_tenant_id,
                capability=capability,
                now=now,
            )
        except TenancyError as error:
            raise FinanceMutationError(str(error), FinanceMutationErrorCode.ADMISSION_DENIED) from error

    def _commit_effect(
        self,
        session: FinanceMutationSession,
        *,
        context: TenantContext,
        transaction_id: str,
        operation: str,
        target_id: str,
        provenance: FinanceFactProvenance,
        policy_version: str,
        validator_version: str,
        recorded_at: datetime,
        result_metadata: str,
        identity: str,
        digest: str,
        result_account_id: str | None = None,
        account: Account | None = None,
        result_artifact_id: str | None = None,
        artifact: SourceArtifactRecord | None = None,
        result_activity_id: str | None = None,
        activity: SourceActivity | None = None,
        result_interpretation_id: str | None = None,
        interpretation: Interpretation | None = None,
    ) -> None:
        self._repository.insert_audit(
            session,
            FinanceAuditRecord(
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
                provenance.source_type,
                provenance.source_id,
                provenance.source_version,
                result_metadata,
                recorded_at,
            ),
        )
        self._repository.finalize_idempotency(
            session,
            FinanceIdempotencyRecord(
                context.tenant_id,
                operation,
                identity,
                digest,
                operation,
                "committed",
                transaction_id,
                result_account_id,
                account,
                result_artifact_id,
                artifact,
                result_activity_id,
                activity,
                result_interpretation_id,
                interpretation,
            ),
        )

    def _abort(self, session: FinanceMutationSession, begun: bool, error: Exception) -> NoReturn:
        if begun:
            session.rollback()
        if isinstance(error, FinanceMutationError):
            raise error
        if isinstance(error, FinanceError):
            raise FinanceMutationError(str(error), FinanceMutationErrorCode.INVALID) from error
        if isinstance(error, FinancePersistenceError):
            raise FinanceMutationError(str(error), self._map_persistence_error(error)) from error
        raise FinanceMutationError("finance mutation transaction failed", FinanceMutationErrorCode.TRANSACTION_FAILED) from error

    def _map_persistence_error(self, error: FinancePersistenceError) -> FinanceMutationErrorCode:
        match error.code:
            case FinancePersistenceErrorCode.IDEMPOTENCY_CONFLICT:
                return FinanceMutationErrorCode.IDEMPOTENCY_CONFLICT
            case FinancePersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS:
                return FinanceMutationErrorCode.TRANSACTION_FAILED
            case FinancePersistenceErrorCode.TARGET_NOT_FOUND:
                return FinanceMutationErrorCode.TARGET_NOT_FOUND
            case FinancePersistenceErrorCode.INVALID:
                return FinanceMutationErrorCode.INVALID
            case FinancePersistenceErrorCode.INVALID_CORRECTION:
                return FinanceMutationErrorCode.INVALID_CORRECTION
            case _ as unreachable:
                assert_never(unreachable)
