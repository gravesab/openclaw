"""Ranch Finance v1 PostgreSQL read session (DEV-only).

Accepts an already-open PEP 249 connection; this module does not import a
PostgreSQL driver, call connect(), or read an environment URL. Each session is
one READ ONLY transaction as ranchos_dev_runtime with transaction-local
principal, tenant, and environment settings, and it always rolls back. Every
value is a bound parameter. Queries also filter on the selected tenant in
addition to row-level security.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date
from typing import Protocol
from uuid import UUID

from ranchbrain.finance.model import (
    CategoryType,
    DomainCode,
    FinanceAccount,
    FinanceCategory,
    FinanceDomain,
    FinanceTransaction,
    RecordStatus,
)
from ranchbrain.tenancy import TenantContext

_RUNTIME_ROLE = "ranchos_dev_runtime"
_TENANT = "ranchos.require_uuid_setting('ranchos.tenant_id')"


class _Cursor(Protocol):
    def execute(self, operation: str, parameters: tuple[object, ...] = ()) -> object: ...
    def fetchone(self) -> tuple[object, ...] | None: ...
    def fetchall(self) -> list[tuple[object, ...]]: ...
    def close(self) -> None: ...


class _Connection(Protocol):
    autocommit: bool

    def cursor(self) -> _Cursor: ...
    def rollback(self) -> None: ...


def _text(value: object) -> str:
    return str(value) if isinstance(value, UUID) else value  # type: ignore[return-value]


def _optional_text(value: object) -> str | None:
    return None if value is None else _text(value)


class FinancePgReadRepository:
    """Tenant-bound read repository over one open cursor."""

    def __init__(self, cursor: _Cursor):
        self._cursor = cursor

    def _all(self, sql: str, parameters: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
        self._cursor.execute(sql, parameters)
        return self._cursor.fetchall()

    def revision(self) -> str:
        self._cursor.execute(
            f"""
            SELECT greatest(
                       (SELECT max(updated_at) FROM ranchos.finance_domains WHERE tenant_id = {_TENANT}),
                       (SELECT max(updated_at) FROM ranchos.finance_accounts WHERE tenant_id = {_TENANT}),
                       (SELECT max(updated_at) FROM ranchos.finance_categories WHERE tenant_id = {_TENANT}),
                       (SELECT max(updated_at) FROM ranchos.finance_transfers WHERE tenant_id = {_TENANT}),
                       (SELECT max(updated_at) FROM ranchos.finance_transactions WHERE tenant_id = {_TENANT})
                   ),
                   (SELECT count(*) FROM ranchos.finance_transactions WHERE tenant_id = {_TENANT})
            """
        )
        row = self._cursor.fetchone()
        latest, count = (row or (None, 0))
        return f"{latest.isoformat() if latest is not None else 'empty'}|{count}"

    def domains(self) -> list[FinanceDomain]:
        rows = self._all(
            f"""
            SELECT id, code, name, sort_order, is_active
            FROM ranchos.finance_domains
            WHERE tenant_id = {_TENANT}
            ORDER BY sort_order, code
            """
        )
        return [FinanceDomain(_text(r[0]), DomainCode(r[1]), r[2], r[3], r[4]) for r in rows]

    def accounts(self) -> list[FinanceAccount]:
        rows = self._all(
            f"""
            SELECT id, name, account_type, default_domain_id, currency, last_four, is_active
            FROM ranchos.finance_accounts
            WHERE tenant_id = {_TENANT}
            ORDER BY lower(name), id
            """
        )
        return [
            FinanceAccount(_text(r[0]), r[1], r[2], _text(r[3]), str(r[4]), r[5], r[6])
            for r in rows
        ]

    def categories(self) -> list[FinanceCategory]:
        rows = self._all(
            f"""
            SELECT id, name, category_type, domain_id, parent_id, color, icon, is_active
            FROM ranchos.finance_categories
            WHERE tenant_id = {_TENANT}
            ORDER BY lower(name), id
            """
        )
        return [
            FinanceCategory(
                _text(r[0]), r[1], CategoryType(r[2]), _optional_text(r[3]), _optional_text(r[4]), r[5], r[6], r[7]
            )
            for r in rows
        ]

    def transactions_between(
        self,
        start: date,
        end: date,
        domain_codes: frozenset[DomainCode],
        account_id: str | None,
    ) -> list[FinanceTransaction]:
        codes = sorted(code.value for code in domain_codes)
        rows = self._all(
            f"""
            SELECT t.id, t.account_id, d.code, t.category_id, t.transfer_id, t.amount::text,
                   t.currency, t.description, t.transaction_date, t.record_status
            FROM ranchos.finance_transactions t
            JOIN ranchos.finance_domains d ON d.tenant_id = t.tenant_id AND d.id = t.domain_id
            WHERE t.tenant_id = {_TENANT}
              AND t.transaction_date >= %s
              AND t.transaction_date < %s
              AND d.code = ANY(%s)
              AND (%s::uuid IS NULL OR t.account_id = %s::uuid)
            ORDER BY t.transaction_date, t.id
            """,
            (start, end, codes, account_id, account_id),
        )
        return [
            FinanceTransaction(
                id=_text(r[0]),
                account_id=_text(r[1]),
                domain_code=DomainCode(r[2]),
                category_id=_optional_text(r[3]),
                transfer_id=_optional_text(r[4]),
                amount=r[5],
                currency=str(r[6]),
                description=r[7],
                transaction_date=r[8],
                record_status=RecordStatus(r[9]),
            )
            for r in rows
        ]

    def confirmed_transfer_ids(self, transfer_ids: frozenset[str]) -> frozenset[str]:
        if not transfer_ids:
            return frozenset()
        rows = self._all(
            f"""
            SELECT id FROM ranchos.finance_transfers
            WHERE tenant_id = {_TENANT} AND status = 'confirmed' AND id = ANY(%s::uuid[])
            """,
            (sorted(transfer_ids),),
        )
        return frozenset(_text(r[0]) for r in rows)


@contextmanager
def finance_read_session(connection: _Connection, context: TenantContext) -> Iterator[FinancePgReadRepository]:
    """One READ ONLY transaction bound to ``context``; always rolled back."""
    if getattr(connection, "autocommit", False):
        raise RuntimeError("finance read session requires a non-autocommit connection")
    cursor = connection.cursor()
    try:
        # The driver opens the transaction implicitly; this must be its first statement.
        cursor.execute("SET TRANSACTION READ ONLY")
        cursor.execute("SELECT set_config(%s, %s, true)", ("role", _RUNTIME_ROLE))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", context.principal_id))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", context.environment))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", context.tenant_id))
        yield FinancePgReadRepository(cursor)
    finally:
        try:
            connection.rollback()
        finally:
            cursor.close()
