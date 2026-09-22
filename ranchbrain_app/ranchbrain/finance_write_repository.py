"""DEV-only finance write persistence adapter.

The coordinator must already have begun a transaction and set transaction-local
Ranch OS settings. This module does not parse identity, issue SET or RESET, or
open ingress.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Protocol

from ranchbrain.finance_model import Account, FinanceLedger, Interpretation, SourceActivity
from ranchbrain.tenancy import TenantContext


ACCOUNT_CREATE_OPERATION = "ranchos.finance.account-create"
SOURCE_ARTIFACT_RECORD_OPERATION = "ranchos.finance.source-artifact-record"
SOURCE_ACTIVITY_RECORD_OPERATION = "ranchos.finance.source-activity-record"
INTERPRETATION_POST_OPERATION = "ranchos.finance.interpretation-post"
INTERPRETATION_REVERSE_OPERATION = "ranchos.finance.interpretation-reverse"
INTERPRETATION_SUPERSEDE_OPERATION = "ranchos.finance.interpretation-supersede"

INTERPRETATION_OPERATIONS = frozenset(
    {
        INTERPRETATION_POST_OPERATION,
        INTERPRETATION_REVERSE_OPERATION,
        INTERPRETATION_SUPERSEDE_OPERATION,
    }
)


class FinancePersistenceErrorCode(str, Enum):
    IDEMPOTENCY_CONFLICT = "finance_idempotency_conflict"
    IDEMPOTENCY_AMBIGUOUS = "finance_idempotency_ambiguous"
    TARGET_NOT_FOUND = "finance_target_not_found"
    INVALID = "finance_persistence_invalid"
    INVALID_CORRECTION = "finance_invalid_correction"


class FinancePersistenceError(RuntimeError):
    def __init__(self, message: str, code: FinancePersistenceErrorCode):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class FinanceFactProvenance:
    source_type: str
    source_id: str
    source_version: str
    observed_at: datetime

    def __post_init__(self) -> None:
        if not self.source_type.strip() or not self.source_id.strip() or not self.source_version.strip():
            raise FinancePersistenceError("finance provenance is required", FinancePersistenceErrorCode.INVALID)
        if not isinstance(self.observed_at, datetime) or self.observed_at.tzinfo is None or self.observed_at.utcoffset() is None:
            raise FinancePersistenceError("finance provenance observed_at must be timezone-aware", FinancePersistenceErrorCode.INVALID)


@dataclass(frozen=True)
class SourceArtifactRecord:
    id: str
    kind: str
    original_filename: str
    content_digest: str
    media_type: str
    byte_size: int
    parser_version: str
    period_start: datetime | None = None
    period_end: datetime | None = None
    account_id: str | None = None

    def __post_init__(self) -> None:
        if self.kind not in {"statement_csv", "receipt"}:
            raise FinancePersistenceError("source artifact kind is invalid", FinancePersistenceErrorCode.INVALID)
        if not self.id.strip() or not self.original_filename.strip() or not self.content_digest.strip():
            raise FinancePersistenceError("source artifact metadata is required", FinancePersistenceErrorCode.INVALID)
        if not self.media_type.strip() or not self.parser_version.strip():
            raise FinancePersistenceError("source artifact metadata is required", FinancePersistenceErrorCode.INVALID)
        if not isinstance(self.byte_size, int) or self.byte_size < 0:
            raise FinancePersistenceError("source artifact byte_size must be a non-negative integer", FinancePersistenceErrorCode.INVALID)
        if (self.period_start is None) != (self.period_end is None):
            raise FinancePersistenceError("source artifact period window must be complete", FinancePersistenceErrorCode.INVALID)
        if self.period_start is not None and self.period_end is not None and self.period_start > self.period_end:
            raise FinancePersistenceError("source artifact period window is invalid", FinancePersistenceErrorCode.INVALID)
        if self.account_id is not None and not self.account_id.strip():
            raise FinancePersistenceError("source artifact account id must be omitted or non-empty", FinancePersistenceErrorCode.INVALID)


@dataclass(frozen=True)
class FinanceIdempotencyRecord:
    tenant_id: str
    scope: str
    identity: str
    key_digest: str
    operation: str
    outcome: str
    transaction_id: str
    result_account_id: str | None = None
    account: Account | None = None
    result_artifact_id: str | None = None
    artifact: SourceArtifactRecord | None = None
    result_activity_id: str | None = None
    activity: SourceActivity | None = None
    result_interpretation_id: str | None = None
    interpretation: Interpretation | None = None


@dataclass(frozen=True)
class FinanceAuditRecord:
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
    result_metadata: str
    recorded_at: datetime


@dataclass(frozen=True)
class IdempotencyReservation:
    replayed: bool
    record: FinanceIdempotencyRecord


class FinanceMutationSession(Protocol):
    """Injected unit of work. Coordinator owns SET LOCAL; repository never does."""

    def begin(self) -> None: ...
    def set_local(self, *, principal_id: str, environment: str, tenant_id: str) -> None: ...
    def current_timestamp(self) -> datetime: ...
    def load_idempotency(self, tenant_id: str, scope: str, identity: str) -> FinanceIdempotencyRecord | None: ...
    def insert_idempotency_reservation(self, record: FinanceIdempotencyRecord) -> bool: ...
    def finalize_idempotency(self, record: FinanceIdempotencyRecord) -> None: ...
    def insert_account(
        self,
        *,
        tenant_id: str,
        account: Account,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None: ...
    def lock_account(self, tenant_id: str, account_id: str) -> Account | None: ...
    def insert_artifact(
        self,
        *,
        tenant_id: str,
        artifact: SourceArtifactRecord,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None: ...
    def lock_artifact(self, tenant_id: str, artifact_id: str) -> SourceArtifactRecord | None: ...
    def insert_activity(
        self,
        *,
        tenant_id: str,
        activity: SourceActivity,
        artifact_id: str | None,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None: ...
    def lock_activity(self, tenant_id: str, activity_id: str) -> SourceActivity | None: ...
    def load_ledger(self, tenant_id: str) -> FinanceLedger: ...
    def insert_journal_entry(
        self,
        *,
        tenant_id: str,
        journal_id: str,
        recorded_at: datetime,
        reverses_journal_id: str | None,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None: ...
    def insert_journal_line(
        self,
        *,
        tenant_id: str,
        journal_id: str,
        line_no: int,
        account_id: str,
        debit: object,
        credit: object,
    ) -> None: ...
    def insert_interpretation(
        self,
        *,
        tenant_id: str,
        interpretation: Interpretation,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None: ...
    def insert_split(
        self,
        *,
        tenant_id: str,
        interpretation_id: str,
        split_no: int,
        amount: object,
        destination_account_id: str,
        allocation_domain: str | None,
        allocation_target_type: str | None,
        allocation_target_id: str | None,
    ) -> None: ...
    def insert_audit(self, record: FinanceAuditRecord) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


def _pgcode(error: BaseException) -> str | None:
    code = getattr(error, "pgcode", None)
    return code if isinstance(code, str) else None


def _committed_result_is_exact(record: FinanceIdempotencyRecord) -> bool:
    match record.operation:
        case operation if operation == ACCOUNT_CREATE_OPERATION:
            return (
                record.result_account_id is not None
                and record.account is not None
                and record.account.id == record.result_account_id
                and record.result_artifact_id is None
                and record.artifact is None
                and record.result_activity_id is None
                and record.activity is None
                and record.result_interpretation_id is None
                and record.interpretation is None
            )
        case operation if operation == SOURCE_ARTIFACT_RECORD_OPERATION:
            return (
                record.result_artifact_id is not None
                and record.artifact is not None
                and record.artifact.id == record.result_artifact_id
                and record.result_account_id is None
                and record.account is None
                and record.result_activity_id is None
                and record.activity is None
                and record.result_interpretation_id is None
                and record.interpretation is None
            )
        case operation if operation == SOURCE_ACTIVITY_RECORD_OPERATION:
            return (
                record.result_activity_id is not None
                and record.activity is not None
                and record.activity.id == record.result_activity_id
                and record.result_account_id is None
                and record.account is None
                and record.result_artifact_id is None
                and record.artifact is None
                and record.result_interpretation_id is None
                and record.interpretation is None
            )
        case operation if operation in INTERPRETATION_OPERATIONS:
            return (
                record.result_interpretation_id is not None
                and record.interpretation is not None
                and record.interpretation.id == record.result_interpretation_id
                and record.result_account_id is None
                and record.account is None
                and record.result_artifact_id is None
                and record.artifact is None
                and record.result_activity_id is None
                and record.activity is None
            )
        case _ as unreachable:
            _ = unreachable
            return False


class FinanceWriteRepository:
    """Persist allowlisted first-slice finance effects after transaction-local settings exist."""

    def reserve_idempotency(
        self,
        session: FinanceMutationSession,
        *,
        context: TenantContext,
        identity: str,
        digest: str,
        transaction_id: str,
        operation: str,
    ) -> IdempotencyReservation:
        existing = session.load_idempotency(context.tenant_id, operation, identity)
        if existing is None:
            reserved = FinanceIdempotencyRecord(
                context.tenant_id,
                operation,
                identity,
                digest,
                operation,
                "reserved",
                transaction_id,
            )
            if session.insert_idempotency_reservation(reserved):
                return IdempotencyReservation(False, reserved)
            existing = session.load_idempotency(context.tenant_id, operation, identity)
            if (
                existing is not None
                and existing.key_digest == digest
                and existing.operation == operation
                and existing.scope == operation
                and existing.outcome == "committed"
                and _committed_result_is_exact(existing)
            ):
                return IdempotencyReservation(True, existing)
            raise FinancePersistenceError(
                "idempotency identity reused with a different digest",
                FinancePersistenceErrorCode.IDEMPOTENCY_CONFLICT,
            )
        if existing.key_digest != digest or existing.operation != operation or existing.scope != operation:
            raise FinancePersistenceError("idempotency identity reused with a different digest", FinancePersistenceErrorCode.IDEMPOTENCY_CONFLICT)
        if existing.outcome != "committed" or not _committed_result_is_exact(existing):
            raise FinancePersistenceError("idempotency outcome is ambiguous", FinancePersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS)
        return IdempotencyReservation(True, existing)

    def persist_account(
        self,
        session: FinanceMutationSession,
        *,
        tenant_id: str,
        account: Account,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        session.insert_account(
            tenant_id=tenant_id,
            account=account,
            provenance=provenance,
            created_by_user_id=created_by_user_id,
            created_at=created_at,
        )

    def persist_artifact(
        self,
        session: FinanceMutationSession,
        *,
        tenant_id: str,
        artifact: SourceArtifactRecord,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        session.insert_artifact(
            tenant_id=tenant_id,
            artifact=artifact,
            provenance=provenance,
            created_by_user_id=created_by_user_id,
            created_at=created_at,
        )

    def persist_activity(
        self,
        session: FinanceMutationSession,
        *,
        tenant_id: str,
        activity: SourceActivity,
        artifact_id: str | None,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        session.insert_activity(
            tenant_id=tenant_id,
            activity=activity,
            artifact_id=artifact_id,
            provenance=provenance,
            created_by_user_id=created_by_user_id,
            created_at=created_at,
        )

    def persist_interpretation(
        self,
        session: FinanceMutationSession,
        *,
        tenant_id: str,
        interpretation: Interpretation,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        journal = interpretation.journal_entry
        try:
            session.insert_journal_entry(
                tenant_id=tenant_id,
                journal_id=journal.id,
                recorded_at=journal.recorded_at,
                reverses_journal_id=journal.reverses_journal_id,
                created_by_user_id=created_by_user_id,
                created_at=created_at,
            )
            for line_no, line in enumerate(journal.lines):
                session.insert_journal_line(
                    tenant_id=tenant_id,
                    journal_id=journal.id,
                    line_no=line_no,
                    account_id=line.account_id,
                    debit=line.debit,
                    credit=line.credit,
                )
            session.insert_interpretation(
                tenant_id=tenant_id,
                interpretation=interpretation,
                created_by_user_id=created_by_user_id,
                created_at=created_at,
            )
            for split_no, split in enumerate(interpretation.splits):
                allocation = split.allocation
                session.insert_split(
                    tenant_id=tenant_id,
                    interpretation_id=interpretation.id,
                    split_no=split_no,
                    amount=split.amount,
                    destination_account_id=split.destination_account_id,
                    allocation_domain=None if allocation is None else allocation.domain.value,
                    allocation_target_type=None if allocation is None else allocation.target_type.value,
                    allocation_target_id=None if allocation is None or not allocation.target_id else allocation.target_id,
                )
        except FinancePersistenceError:
            raise
        except Exception as error:
            if _pgcode(error) == "23505":
                raise FinancePersistenceError(
                    "correction target is already reversed or superseded",
                    FinancePersistenceErrorCode.INVALID_CORRECTION,
                ) from error
            raise

    def insert_audit(self, session: FinanceMutationSession, record: FinanceAuditRecord) -> None:
        session.insert_audit(record)

    def finalize_idempotency(self, session: FinanceMutationSession, record: FinanceIdempotencyRecord) -> None:
        if record.outcome != "committed" or record.scope != record.operation or not _committed_result_is_exact(record):
            raise FinancePersistenceError("idempotency outcome is ambiguous", FinancePersistenceErrorCode.IDEMPOTENCY_AMBIGUOUS)
        session.finalize_idempotency(record)
