"""Transport-free Ranch Finance v1 read contract (Master Specification v1.1 §7.1).

Every call authorizes a server-derived VerifiedPrincipal for an explicit tenant
with Capability.FINANCE_READ before any data access. The repository is opened
for that resolved TenantContext only. The Personal domain is refused and
excluded from "All" until a per-user privacy policy is approved (Checkpoint 0
plan C5/D3). Responses carry a schema version and a server revision so clients
can invalidate stale caches.
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import AbstractContextManager
from dataclasses import asdict
from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Protocol

from ranchbrain.finance.model import (
    BLOCKED_DOMAINS,
    DomainCode,
    FinanceAccount,
    FinanceCategory,
    FinanceDomain,
    FinanceTransaction,
    direction,
)
from ranchbrain.finance.reporting import Month, monthly_summary, top_categories, utc_now
from ranchbrain.tenancy import Capability, TenantContext, TenantContextResolver, VerifiedPrincipal

SCHEMA_VERSION = "ranch-finance.v1"
MAX_PAGE_SIZE = 200


class FinanceReadErrorCode(str, Enum):
    INVALID_DOMAIN = "finance_invalid_domain"
    PERSONAL_DOMAIN_BLOCKED = "finance_personal_domain_blocked"
    INVALID_PAGE = "finance_invalid_page"
    ACCOUNT_NOT_FOUND = "finance_account_not_found"


class FinanceReadError(ValueError):
    def __init__(self, message: str, code: FinanceReadErrorCode):
        super().__init__(message)
        self.code = code


class FinanceReadRepository(Protocol):
    """Tenant-bound reads. Implementations must already be scoped to one tenant."""

    def revision(self) -> str: ...
    def domains(self) -> list[FinanceDomain]: ...
    def accounts(self) -> list[FinanceAccount]: ...
    def categories(self) -> list[FinanceCategory]: ...
    def transactions_between(
        self,
        start: date,
        end: date,
        domain_codes: frozenset[DomainCode],
        account_id: str | None,
    ) -> list[FinanceTransaction]: ...
    def confirmed_transfer_ids(self, transfer_ids: frozenset[str]) -> frozenset[str]: ...


SessionFactory = Callable[[TenantContext], AbstractContextManager[FinanceReadRepository]]


def _visible_domains(domain: str | None) -> frozenset[DomainCode]:
    requested = (domain or "all").strip().lower()
    allowed = frozenset(DomainCode) - BLOCKED_DOMAINS
    if requested == "all":
        return allowed
    try:
        code = DomainCode(requested)
    except ValueError:
        raise FinanceReadError("domain must be all, ranch, or zero_g", FinanceReadErrorCode.INVALID_DOMAIN) from None
    if code in BLOCKED_DOMAINS:
        raise FinanceReadError(
            "the Personal domain is unavailable until a privacy policy is approved",
            FinanceReadErrorCode.PERSONAL_DOMAIN_BLOCKED,
        )
    return frozenset({code})


def _jsonable(value: object) -> object:
    if isinstance(value, Decimal):
        return f"{value:.2f}" if value.as_tuple().exponent == -2 else str(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


class FinanceReadContract:
    def __init__(
        self,
        *,
        resolver: TenantContextResolver,
        session_factory: SessionFactory,
        clock: Callable[[], datetime] = utc_now,
    ):
        self._resolver = resolver
        self._session_factory = session_factory
        self._clock = clock

    def _context(self, principal: VerifiedPrincipal, tenant_id: str | None) -> TenantContext:
        # Authorization happens before any repository is opened.
        return self._resolver.resolve(
            principal=principal,
            requested_tenant_id=tenant_id,
            capability=Capability.FINANCE_READ,
            now=self._clock(),
        )

    @staticmethod
    def _envelope(revision: str, data: object) -> dict[str, object]:
        return {"schema_version": SCHEMA_VERSION, "server_revision": revision, "data": _jsonable(data)}

    @staticmethod
    def _visible_account(repository: FinanceReadRepository, account_id: str | None, domains: frozenset[DomainCode]) -> None:
        if account_id is None:
            return
        domain_by_id = {d.id: d.code for d in repository.domains()}
        for account in repository.accounts():
            if account.id == account_id and domain_by_id.get(account.default_domain_id) not in BLOCKED_DOMAINS:
                return
        raise FinanceReadError("account not found", FinanceReadErrorCode.ACCOUNT_NOT_FOUND)

    def monthly_summary(
        self,
        *,
        principal: VerifiedPrincipal,
        tenant_id: str | None,
        month: str,
        domain: str | None = "all",
        account_id: str | None = None,
    ) -> dict[str, object]:
        context = self._context(principal, tenant_id)
        domains = _visible_domains(domain)
        selected = Month.parse(month)
        with self._session_factory(context) as repository:
            self._visible_account(repository, account_id, domains)
            rows = repository.transactions_between(selected.first_day, selected.next_first_day, domains, account_id)
            transfer_ids = frozenset(row.transfer_id for row in rows if row.transfer_id is not None)
            confirmed = repository.confirmed_transfer_ids(transfer_ids)
            summary = monthly_summary(rows, selected, confirmed_transfer_ids=confirmed, now=self._clock())
            return self._envelope(repository.revision(), asdict(summary))

    def top_categories(
        self,
        *,
        principal: VerifiedPrincipal,
        tenant_id: str | None,
        month: str,
        domain: str | None = "all",
        account_id: str | None = None,
        limit: int = 5,
    ) -> dict[str, object]:
        context = self._context(principal, tenant_id)
        domains = _visible_domains(domain)
        selected = Month.parse(month)
        with self._session_factory(context) as repository:
            self._visible_account(repository, account_id, domains)
            rows = repository.transactions_between(selected.first_day, selected.next_first_day, domains, account_id)
            categories = {c.id: (c.name, c.category_type) for c in repository.categories()}
            totals = top_categories(rows, selected, categories=categories, limit=limit)
            return self._envelope(repository.revision(), [asdict(item) for item in totals])

    def transactions(
        self,
        *,
        principal: VerifiedPrincipal,
        tenant_id: str | None,
        month: str,
        domain: str | None = "all",
        account_id: str | None = None,
        page: int = 1,
        page_size: int = 50,
    ) -> dict[str, object]:
        if not isinstance(page, int) or isinstance(page, bool) or page < 1:
            raise FinanceReadError("page must be a positive integer", FinanceReadErrorCode.INVALID_PAGE)
        if not isinstance(page_size, int) or isinstance(page_size, bool) or not 1 <= page_size <= MAX_PAGE_SIZE:
            raise FinanceReadError(f"page_size must be 1..{MAX_PAGE_SIZE}", FinanceReadErrorCode.INVALID_PAGE)
        context = self._context(principal, tenant_id)
        domains = _visible_domains(domain)
        selected = Month.parse(month)
        with self._session_factory(context) as repository:
            self._visible_account(repository, account_id, domains)
            rows = repository.transactions_between(selected.first_day, selected.next_first_day, domains, account_id)
            ordered = sorted(rows, key=lambda row: (row.transaction_date, row.id), reverse=True)
            start = (page - 1) * page_size
            items = [
                {**asdict(row), "direction": direction(row.amount)}
                for row in ordered[start : start + page_size]
            ]
            data = {"page": page, "page_size": page_size, "total": len(ordered), "items": items}
            return self._envelope(repository.revision(), data)

    def reference_data(self, *, principal: VerifiedPrincipal, tenant_id: str | None) -> dict[str, object]:
        context = self._context(principal, tenant_id)
        with self._session_factory(context) as repository:
            domains = [d for d in repository.domains() if d.code not in BLOCKED_DOMAINS and d.is_active]
            visible_ids = {d.id for d in domains}
            accounts = [a for a in repository.accounts() if a.default_domain_id in visible_ids and a.is_active]
            # Inactive categories stay readable historically (Spec §5.3); domain-less ones are shared.
            categories = [
                c for c in repository.categories() if c.domain_id is None or c.domain_id in visible_ids
            ]
            data = {
                "domains": [asdict(d) for d in sorted(domains, key=lambda d: (d.sort_order, d.code.value))],
                "accounts": [asdict(a) for a in sorted(accounts, key=lambda a: a.name.lower())],
                "categories": [asdict(c) for c in sorted(categories, key=lambda c: c.name.lower())],
            }
            return self._envelope(repository.revision(), data)
