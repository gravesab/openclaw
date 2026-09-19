"""DEV-only finance PostgreSQL session adapter.

Accepts an already-open PEP 249 connection. This module does not import a
PostgreSQL driver, call connect(), read an environment URL, or use tools/**
clients. It implements coordinator session methods for chart, source, and
interpretation mutations.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Protocol
from uuid import UUID

from ranchbrain.finance_model import (
    Account,
    AccountType,
    AllocationDomain,
    AllocationLink,
    AllocationTargetType,
    FinanceLedger,
    Interpretation,
    JournalEntry,
    JournalLine,
    SourceActivity,
    Split,
)
from ranchbrain.finance_write_repository import (
    FinanceAuditRecord,
    FinanceFactProvenance,
    FinanceIdempotencyRecord,
    FinancePersistenceError,
    FinancePersistenceErrorCode,
    SourceArtifactRecord,
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


def _money(value: object) -> Decimal:
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _pgcode(error: BaseException) -> str | None:
    code = getattr(error, "pgcode", None)
    return code if isinstance(code, str) else None


def _reraise_missing(error: BaseException) -> None:
    if _pgcode(error) == "23503":
        raise FinancePersistenceError("finance write target is missing", FinancePersistenceErrorCode.TARGET_NOT_FOUND) from error
    raise error


def _reraise_correction_write(error: BaseException) -> None:
    if _pgcode(error) == "23505":
        raise FinancePersistenceError(
            "correction target is already reversed or superseded",
            FinancePersistenceErrorCode.INVALID_CORRECTION,
        ) from error
    _reraise_missing(error)


class FinancePgSession:
    """Transaction-local runtime session for disposable finance mutation proof."""

    def __init__(self, connection: _Connection):
        if getattr(connection, "autocommit", False):
            raise RuntimeError("finance session requires a non-autocommit connection")
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

    def load_idempotency(self, tenant_id: str, scope: str, identity: str) -> FinanceIdempotencyRecord | None:
        row = self._fetchone(
            """
            SELECT i.tenant_id, i.scope, i.identity, i.key_digest, i.operation, i.outcome,
                   i.transaction_id, i.result_account_id, i.result_artifact_id, i.result_activity_id,
                   i.result_interpretation_id
            FROM ranchos.finance_idempotency AS i
            WHERE i.tenant_id = %s AND i.scope = %s AND i.identity = %s
            """,
            (tenant_id, scope, identity),
        )
        if row is None:
            return None
        tenant = _text(row[0])
        account_id = _optional_text(row[7])
        artifact_id = _optional_text(row[8])
        activity_id = _optional_text(row[9])
        interpretation_id = _optional_text(row[10])
        return FinanceIdempotencyRecord(
            tenant,
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _text(row[4]),
            _text(row[5]),
            _text(row[6]),
            account_id,
            None if account_id is None else self.lock_account(tenant, account_id),
            artifact_id,
            None if artifact_id is None else self.lock_artifact(tenant, artifact_id),
            activity_id,
            None if activity_id is None else self.lock_activity(tenant, activity_id),
            interpretation_id,
            None if interpretation_id is None else self._load_interpretation(tenant, interpretation_id),
        )

    def insert_idempotency_reservation(self, record: FinanceIdempotencyRecord) -> bool:
        cursor = self._connection.cursor()
        try:
            cursor.execute(
            """
            INSERT INTO ranchos.finance_idempotency (
                tenant_id, scope, identity, key_digest, operation, outcome, transaction_id,
                result_account_id, result_artifact_id, result_activity_id, result_interpretation_id
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (tenant_id, scope, identity) DO NOTHING
            """,
            (
                record.tenant_id,
                record.scope,
                record.identity,
                record.key_digest,
                record.operation,
                record.outcome,
                record.transaction_id,
                record.result_account_id,
                record.result_artifact_id,
                record.result_activity_id,
                record.result_interpretation_id,
            ),
            )
            return cursor.rowcount == 1
        finally:
            cursor.close()

    def finalize_idempotency(self, record: FinanceIdempotencyRecord) -> None:
        self._execute_one(
            """
            UPDATE ranchos.finance_idempotency
            SET outcome = %s, result_account_id = %s, result_artifact_id = %s, result_activity_id = %s,
                result_interpretation_id = %s
            WHERE tenant_id = %s AND scope = %s AND identity = %s
            """,
            (
                record.outcome,
                record.result_account_id,
                record.result_artifact_id,
                record.result_activity_id,
                record.result_interpretation_id,
                record.tenant_id,
                record.scope,
                record.identity,
            ),
            "finance idempotency finalize did not update one row",
        )

    def insert_account(
        self,
        *,
        tenant_id: str,
        account: Account,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_accounts (
                    tenant_id, id, name, account_type, institution,
                    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
                    created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    account.id,
                    account.name,
                    account.account_type.value,
                    account.institution,
                    provenance.source_type,
                    provenance.source_id,
                    provenance.source_version,
                    provenance.observed_at,
                    created_by_user_id,
                    created_at,
                ),
                "finance account insert did not insert one row",
            )
        except Exception as error:
            _reraise_missing(error)

    def lock_account(self, tenant_id: str, account_id: str) -> Account | None:
        row = self._fetchone(
            """
            SELECT id, name, account_type, institution
            FROM ranchos.finance_accounts
            WHERE tenant_id = %s AND id = %s
            -- Finance references are immutable to the runtime role, so a
            -- plain read preserves least privilege without lock escalation.
            """,
            (tenant_id, account_id),
        )
        if row is None:
            return None
        return Account(_text(row[0]), _text(row[1]), AccountType(_text(row[2])), _optional_text(row[3]))

    def insert_artifact(
        self,
        *,
        tenant_id: str,
        artifact: SourceArtifactRecord,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_source_artifacts (
                    tenant_id, id, kind, original_filename, content_digest, media_type, byte_size, parser_version,
                    period_start, period_end, account_id,
                    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
                    created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    artifact.id,
                    artifact.kind,
                    artifact.original_filename,
                    artifact.content_digest,
                    artifact.media_type,
                    artifact.byte_size,
                    artifact.parser_version,
                    artifact.period_start,
                    artifact.period_end,
                    artifact.account_id,
                    provenance.source_type,
                    provenance.source_id,
                    provenance.source_version,
                    provenance.observed_at,
                    created_by_user_id,
                    created_at,
                ),
                "finance source artifact insert did not insert one row",
            )
        except Exception as error:
            _reraise_missing(error)

    def lock_artifact(self, tenant_id: str, artifact_id: str) -> SourceArtifactRecord | None:
        row = self._fetchone(
            """
            SELECT id, kind, original_filename, content_digest, media_type, byte_size, parser_version,
                   period_start, period_end, account_id
            FROM ranchos.finance_source_artifacts
            WHERE tenant_id = %s AND id = %s
            """,
            (tenant_id, artifact_id),
        )
        if row is None:
            return None
        return SourceArtifactRecord(
            _text(row[0]),
            _text(row[1]),
            _text(row[2]),
            _text(row[3]),
            _text(row[4]),
            int(row[5]),
            _text(row[6]),
            row[7] if isinstance(row[7], datetime) or row[7] is None else None,
            row[8] if isinstance(row[8], datetime) or row[8] is None else None,
            _optional_text(row[9]),
        )

    def insert_activity(
        self,
        *,
        tenant_id: str,
        activity: SourceActivity,
        artifact_id: str | None,
        provenance: FinanceFactProvenance,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_source_activities (
                    tenant_id, id, source_account_id, source_artifact_id, posted_at, description, amount,
                    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
                    created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    activity.id,
                    activity.source_account_id,
                    artifact_id,
                    activity.posted_at,
                    activity.description,
                    activity.amount,
                    provenance.source_type,
                    provenance.source_id,
                    provenance.source_version,
                    provenance.observed_at,
                    created_by_user_id,
                    created_at,
                ),
                "finance source activity insert did not insert one row",
            )
        except Exception as error:
            _reraise_missing(error)

    def lock_activity(self, tenant_id: str, activity_id: str) -> SourceActivity | None:
        row = self._fetchone(
            """
            SELECT id, source_account_id, posted_at, description, amount
            FROM ranchos.finance_source_activities
            WHERE tenant_id = %s AND id = %s
            """,
            (tenant_id, activity_id),
        )
        if row is None:
            return None
        return SourceActivity(_text(row[0]), _text(row[1]), row[2], _text(row[3]), _money(row[4]))

    def load_ledger(self, tenant_id: str) -> FinanceLedger:
        account_rows = self._fetchall(
            """
            SELECT id, name, account_type, institution
            FROM ranchos.finance_accounts
            WHERE tenant_id = %s
            ORDER BY id
            """,
            (tenant_id,),
        )
        activity_rows = self._fetchall(
            """
            SELECT id, source_account_id, posted_at, description, amount
            FROM ranchos.finance_source_activities
            WHERE tenant_id = %s
            ORDER BY posted_at, id
            """,
            (tenant_id,),
        )
        interpretation_rows = self._fetchall(
            """
            SELECT id
            FROM ranchos.finance_interpretations
            WHERE tenant_id = %s
            ORDER BY created_at, id
            """,
            (tenant_id,),
        )
        accounts = tuple(
            Account(_text(row[0]), _text(row[1]), AccountType(_text(row[2])), _optional_text(row[3]))
            for row in account_rows
        )
        activities = tuple(
            SourceActivity(_text(row[0]), _text(row[1]), row[2], _text(row[3]), _money(row[4]))
            for row in activity_rows
        )
        interpretations = tuple(self._load_interpretation(tenant_id, _text(row[0])) for row in interpretation_rows)
        return FinanceLedger(accounts, activities, interpretations)

    def insert_journal_entry(
        self,
        *,
        tenant_id: str,
        journal_id: str,
        recorded_at: datetime,
        reverses_journal_id: str | None,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_journal_entries (
                    tenant_id, id, recorded_at, reverses_journal_id, created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (tenant_id, journal_id, recorded_at, reverses_journal_id, created_by_user_id, created_at),
                "finance journal entry insert did not insert one row",
            )
        except Exception as error:
            _reraise_correction_write(error)

    def insert_journal_line(
        self,
        *,
        tenant_id: str,
        journal_id: str,
        line_no: int,
        account_id: str,
        debit: object,
        credit: object,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_journal_lines (
                    tenant_id, journal_entry_id, line_no, account_id, debit, credit
                ) VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (tenant_id, journal_id, line_no, account_id, debit, credit),
                "finance journal line insert did not insert one row",
            )
        except Exception as error:
            _reraise_missing(error)

    def insert_interpretation(
        self,
        *,
        tenant_id: str,
        interpretation: Interpretation,
        created_by_user_id: str,
        created_at: datetime,
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_interpretations (
                    tenant_id, id, source_activity_id, journal_entry_id, reverses_id, supersedes_id,
                    created_by_user_id, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    interpretation.id,
                    interpretation.source_activity_id,
                    interpretation.journal_entry.id,
                    interpretation.reverses_id,
                    interpretation.supersedes_id,
                    created_by_user_id,
                    created_at,
                ),
                "finance interpretation insert did not insert one row",
            )
        except Exception as error:
            _reraise_correction_write(error)

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
    ) -> None:
        try:
            self._execute_one(
                """
                INSERT INTO ranchos.finance_splits (
                    tenant_id, interpretation_id, split_no, amount, destination_account_id,
                    allocation_domain, allocation_target_type, allocation_target_id
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    tenant_id,
                    interpretation_id,
                    split_no,
                    amount,
                    destination_account_id,
                    allocation_domain,
                    allocation_target_type,
                    allocation_target_id,
                ),
                "finance split insert did not insert one row",
            )
        except Exception as error:
            _reraise_missing(error)

    def insert_audit(self, record: FinanceAuditRecord) -> None:
        self._execute_one(
            """
            INSERT INTO ranchos.finance_mutation_audit (
                tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id, correlation_id,
                policy_version, validator_version, idempotency_outcome, provenance_source_type, provenance_source_id,
                provenance_source_version, result_metadata, recorded_at
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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
                record.result_metadata,
                record.recorded_at,
            ),
            "finance mutation audit insert did not insert one row",
        )

    def commit(self) -> None:
        self._connection.commit()

    def rollback(self) -> None:
        self._connection.rollback()

    def _load_interpretation(self, tenant_id: str, interpretation_id: str) -> Interpretation:
        row = self._fetchone(
            """
            SELECT i.id, i.source_activity_id, i.journal_entry_id, i.reverses_id, i.supersedes_id,
                   j.recorded_at, j.reverses_journal_id
            FROM ranchos.finance_interpretations AS i
            JOIN ranchos.finance_journal_entries AS j
              ON j.tenant_id = i.tenant_id AND j.id = i.journal_entry_id
            WHERE i.tenant_id = %s AND i.id = %s
            """,
            (tenant_id, interpretation_id),
        )
        if row is None:
            raise FinancePersistenceError("finance interpretation is missing", FinancePersistenceErrorCode.TARGET_NOT_FOUND)
        line_rows = self._fetchall(
            """
            SELECT account_id, debit, credit
            FROM ranchos.finance_journal_lines
            WHERE tenant_id = %s AND journal_entry_id = %s
            ORDER BY line_no
            """,
            (tenant_id, _text(row[2])),
        )
        split_rows = self._fetchall(
            """
            SELECT amount, destination_account_id, allocation_domain, allocation_target_type, allocation_target_id
            FROM ranchos.finance_splits
            WHERE tenant_id = %s AND interpretation_id = %s
            ORDER BY split_no
            """,
            (tenant_id, interpretation_id),
        )
        journal = JournalEntry(
            _text(row[2]),
            row[5],
            tuple(JournalLine(_text(line[0]), _money(line[1]), _money(line[2])) for line in line_rows),
            _optional_text(row[6]),
        )
        splits = tuple(self._split_from_row(split) for split in split_rows)
        return Interpretation(
            _text(row[0]),
            _text(row[1]),
            splits,
            journal,
            _optional_text(row[3]),
            _optional_text(row[4]),
        )

    def _split_from_row(self, row: tuple[object, ...]) -> Split:
        domain = _optional_text(row[2])
        target_type = _optional_text(row[3])
        target_id = _optional_text(row[4]) or ""
        allocation = None
        if domain is not None and target_type is not None:
            allocation = AllocationLink(AllocationDomain(domain), AllocationTargetType(target_type), target_id)
        return Split(_money(row[0]), _text(row[1]), allocation)

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
