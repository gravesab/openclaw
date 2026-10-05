"""Record a parsed Apple Card CSV through the committed finance session and repository.

Advisory lock first, then require_tenant_id has already run. No new SQL beyond
FinancePgSession.lock_artifact, which takes
pg_advisory_xact_lock(hashtextextended(key, 0)) on
"{tenant_id}:finance:artifact:{artifact_hash}".
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import uuid4

from ranchbrain.finance_apple_card_csv import PARSER_VERSION, ParsedArtifact
from ranchbrain.finance_model import Account, AccountType, SourceActivity
from ranchbrain.finance_mutation_coordinator import (
    FinanceAccountCreateRequest,
    canonical_source_activity_digest,
    canonical_source_artifact_digest,
)
from ranchbrain.finance_write_repository import (
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
from ranchbrain.tenancy import (
    Capability,
    TenantContext,
    TenantContextResolver,
    VerifiedPrincipal,
    require_tenant_id,
)


PROVENANCE_SOURCE_TYPE = "apple_card_csv"
_REPOSITORY = FinanceWriteRepository()


@dataclass(frozen=True)
class AppleCardArtifactResult:
    artifact_id: str
    replayed: bool


@dataclass(frozen=True)
class AppleCardActivitiesResult:
    activity_ids: tuple[str, ...]
    replayed: bool


def apple_card_clearing_account_id(artifact_hash: str) -> str:
    return f"apple-card-clearing:{artifact_hash[:16]}"


def apple_card_source_observed_at(parsed: ParsedArtifact) -> datetime:
    dates = [row.transaction_date for row in parsed.activities]
    dates.extend(row.clearing_date for row in parsed.activities if row.clearing_date is not None)
    if not dates:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    latest = max(dates)
    return datetime(latest.year, latest.month, latest.day, tzinfo=timezone.utc)


def apple_card_clearing_account_request(parsed: ParsedArtifact) -> FinanceAccountCreateRequest:
    account_id = apple_card_clearing_account_id(parsed.artifact_hash)
    account = Account(account_id, "Apple Card", AccountType.LIABILITY, "Apple Card")
    provenance = FinanceFactProvenance(
        PROVENANCE_SOURCE_TYPE,
        parsed.artifact_hash,
        PARSER_VERSION,
        apple_card_source_observed_at(parsed),
    )
    return FinanceAccountCreateRequest(
        account,
        provenance,
        account_id,
        PARSER_VERSION,
        PARSER_VERSION,
    )


def record_apple_card_artifact(
    session: FinanceMutationSession,
    tenant_id: str,
    parsed: ParsedArtifact,
    clearing_account_id: str,
    idempotency_key: str,
    *,
    principal: VerifiedPrincipal,
    resolver: TenantContextResolver,
    now: datetime | None = None,
) -> AppleCardArtifactResult:
    tenant_id = require_tenant_id(tenant_id)
    _require_clearing_account(parsed, clearing_account_id)
    context = _admit(principal, resolver, tenant_id, now)
    artifact = _artifact_record(parsed, clearing_account_id)
    provenance = _artifact_provenance(parsed)
    digest = canonical_source_artifact_digest(
        tenant_id=tenant_id,
        artifact=artifact,
        provenance=provenance,
        idempotency_identity=idempotency_key,
        policy_version=PARSER_VERSION,
        validator_version=PARSER_VERSION,
    )

    def body(active: FinanceMutationSession, _locked: SourceArtifactRecord | None) -> AppleCardArtifactResult:
        trusted_now = active.current_timestamp()
        transaction_id = str(uuid4())
        reservation = _REPOSITORY.reserve_idempotency(
            active,
            context=context,
            identity=idempotency_key,
            digest=digest,
            transaction_id=transaction_id,
            operation=SOURCE_ARTIFACT_RECORD_OPERATION,
        )
        if reservation.replayed:
            stored = reservation.record.artifact
            if stored is None:
                raise FinancePersistenceError(
                    "replay is missing its original source artifact",
                    FinancePersistenceErrorCode.INVALID,
                )
            active.commit()
            return AppleCardArtifactResult(stored.id, True)
        if active.lock_account(tenant_id, clearing_account_id) is None:
            raise FinancePersistenceError("clearing account is missing", FinancePersistenceErrorCode.TARGET_NOT_FOUND)
        _REPOSITORY.persist_artifact(
            active,
            tenant_id=tenant_id,
            artifact=artifact,
            provenance=provenance,
            created_by_user_id=context.user_id,
            created_at=trusted_now,
        )
        _finish(
            active,
            context=context,
            transaction_id=transaction_id,
            operation=SOURCE_ARTIFACT_RECORD_OPERATION,
            target_id=artifact.id,
            provenance=provenance,
            recorded_at=trusted_now,
            identity=idempotency_key,
            digest=digest,
            result_artifact_id=artifact.id,
            artifact=artifact,
        )
        active.commit()
        return AppleCardArtifactResult(artifact.id, False)

    return _locked_transaction(session, context, tenant_id, parsed.artifact_hash, body)


def record_apple_card_activities(
    session: FinanceMutationSession,
    tenant_id: str,
    parsed: ParsedArtifact,
    clearing_account_id: str,
    *,
    principal: VerifiedPrincipal,
    resolver: TenantContextResolver,
    now: datetime | None = None,
) -> AppleCardActivitiesResult:
    tenant_id = require_tenant_id(tenant_id)
    _require_clearing_account(parsed, clearing_account_id)
    context = _admit(principal, resolver, tenant_id, now)

    def body(active: FinanceMutationSession, locked: SourceArtifactRecord | None) -> AppleCardActivitiesResult:
        if locked is None:
            raise FinancePersistenceError("source artifact is missing", FinancePersistenceErrorCode.TARGET_NOT_FOUND)
        if active.lock_account(tenant_id, clearing_account_id) is None:
            raise FinancePersistenceError("clearing account is missing", FinancePersistenceErrorCode.TARGET_NOT_FOUND)
        trusted_now = active.current_timestamp()
        observed_at = apple_card_source_observed_at(parsed)
        ids: list[str] = []
        inserted = False
        for row in parsed.activities:
            activity = SourceActivity(
                row.external_id,
                clearing_account_id,
                datetime(row.transaction_date.year, row.transaction_date.month, row.transaction_date.day, tzinfo=timezone.utc),
                row.description,
                row.amount,
            )
            provenance = FinanceFactProvenance(PROVENANCE_SOURCE_TYPE, row.external_id, PARSER_VERSION, observed_at)
            digest = canonical_source_activity_digest(
                tenant_id=tenant_id,
                activity=activity,
                artifact_id=parsed.artifact_hash,
                provenance=provenance,
                idempotency_identity=row.external_id,
                policy_version=PARSER_VERSION,
                validator_version=PARSER_VERSION,
            )
            transaction_id = str(uuid4())
            reservation = _REPOSITORY.reserve_idempotency(
                active,
                context=context,
                identity=row.external_id,
                digest=digest,
                transaction_id=transaction_id,
                operation=SOURCE_ACTIVITY_RECORD_OPERATION,
            )
            if reservation.replayed:
                stored = reservation.record.activity
                if stored is None:
                    raise FinancePersistenceError(
                        "replay is missing its original source activity",
                        FinancePersistenceErrorCode.INVALID,
                    )
                ids.append(stored.id)
                continue
            _REPOSITORY.persist_activity(
                active,
                tenant_id=tenant_id,
                activity=activity,
                artifact_id=parsed.artifact_hash,
                provenance=provenance,
                created_by_user_id=context.user_id,
                created_at=trusted_now,
            )
            _finish(
                active,
                context=context,
                transaction_id=transaction_id,
                operation=SOURCE_ACTIVITY_RECORD_OPERATION,
                target_id=activity.id,
                provenance=provenance,
                recorded_at=trusted_now,
                identity=row.external_id,
                digest=digest,
                result_activity_id=activity.id,
                activity=activity,
            )
            ids.append(activity.id)
            inserted = True
        active.commit()
        return AppleCardActivitiesResult(tuple(ids), not inserted)

    return _locked_transaction(session, context, tenant_id, parsed.artifact_hash, body)


def _require_clearing_account(parsed: ParsedArtifact, clearing_account_id: str) -> None:
    if clearing_account_id != apple_card_clearing_account_id(parsed.artifact_hash):
        raise FinancePersistenceError(
            "clearing account id does not match the artifact",
            FinancePersistenceErrorCode.INVALID,
        )


def _admit(
    principal: VerifiedPrincipal,
    resolver: TenantContextResolver,
    tenant_id: str,
    now: datetime | None,
) -> TenantContext:
    return resolver.resolve(
        principal=principal,
        requested_tenant_id=tenant_id,
        capability=Capability.FINANCE_SOURCE_WRITE,
        now=now or datetime.now(timezone.utc),
    )


def _artifact_record(parsed: ParsedArtifact, clearing_account_id: str) -> SourceArtifactRecord:
    return SourceArtifactRecord(
        parsed.artifact_hash,
        "statement_csv",
        parsed.filename,
        parsed.artifact_hash,
        "text/csv",
        parsed.byte_size,
        PARSER_VERSION,
        account_id=clearing_account_id,
    )


def _artifact_provenance(parsed: ParsedArtifact) -> FinanceFactProvenance:
    return FinanceFactProvenance(
        PROVENANCE_SOURCE_TYPE,
        parsed.artifact_hash,
        PARSER_VERSION,
        apple_card_source_observed_at(parsed),
    )


def _finish(
    session: FinanceMutationSession,
    *,
    context: TenantContext,
    transaction_id: str,
    operation: str,
    target_id: str,
    provenance: FinanceFactProvenance,
    recorded_at: datetime,
    identity: str,
    digest: str,
    result_artifact_id: str | None = None,
    artifact: SourceArtifactRecord | None = None,
    result_activity_id: str | None = None,
    activity: SourceActivity | None = None,
) -> None:
    _REPOSITORY.insert_audit(
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
            PARSER_VERSION,
            PARSER_VERSION,
            "committed",
            provenance.source_type,
            provenance.source_id,
            provenance.source_version,
            "recorded",
            recorded_at,
        ),
    )
    _REPOSITORY.finalize_idempotency(
        session,
        FinanceIdempotencyRecord(
            context.tenant_id,
            operation,
            identity,
            digest,
            operation,
            "committed",
            transaction_id,
            None,
            None,
            result_artifact_id,
            artifact,
            result_activity_id,
            activity,
            None,
            None,
        ),
    )


def _locked_transaction(session, context: TenantContext, tenant_id: str, artifact_hash: str, body):
    begun = False
    try:
        session.begin()
        begun = True
        session.set_local(principal_id=context.principal_id, environment=context.environment, tenant_id=tenant_id)
        locked = session.lock_artifact(tenant_id, artifact_hash)
        return body(session, locked)
    except Exception:
        if begun:
            try:
                session.rollback()
            except Exception:
                pass
        raise
