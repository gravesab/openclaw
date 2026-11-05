"""Ranch Finance v1 read contract: authorization, tenant binding, Personal block."""

from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone

import pytest

from ranchbrain.finance.model import (
    CategoryType,
    DomainCode,
    FinanceAccount,
    FinanceCategory,
    FinanceDomain,
    FinanceTransaction,
    RecordStatus,
)
from ranchbrain.finance.read_contract import (
    SCHEMA_VERSION,
    FinanceReadContract,
    FinanceReadError,
    FinanceReadErrorCode,
)
from ranchbrain.tenancy import (
    Role,
    Tenant,
    TenancyError,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
)

NOW = datetime(2026, 10, 15, 18, 0, tzinfo=timezone.utc)
DOMAINS = [
    FinanceDomain("d-personal", DomainCode.PERSONAL, "Personal", 0, True),
    FinanceDomain("d-ranch", DomainCode.RANCH, "Ranch", 1, True),
    FinanceDomain("d-zero", DomainCode.ZERO_G, "Zero-G LLC", 2, True),
]
ACCOUNTS = [
    FinanceAccount("acct-ranch", "Ranch checking", "checking", "d-ranch", "USD", "1234", True),
    FinanceAccount("acct-personal", "Personal card", "credit", "d-personal", "USD", None, True),
]
CATEGORIES = [
    FinanceCategory("cat-feed", "Feed", CategoryType.EXPENSE, "d-ranch", None, None, None, True),
    FinanceCategory("cat-groceries", "Groceries", CategoryType.EXPENSE, "d-personal", None, None, None, True),
    FinanceCategory("cat-shared", "Fees", CategoryType.EXPENSE, None, None, None, None, False),
]


def principal(pid="principal-a"):
    return VerifiedPrincipal(
        id=pid, principal_type="human", environment="development", lifecycle_state="active",
        assurance_profile="mfa-fresh", session_reference="s", valid_from=NOW - timedelta(minutes=5),
        valid_until=NOW + timedelta(minutes=5), correlation_id="req-1",
    )


def resolver(role=Role.VIEWER):
    return TenantContextResolver(
        environment="development",
        users=[User(id="user-a", principal_id="principal-a")],
        tenants=[Tenant(id="tenant-a", slug="a", display_name="A"), Tenant(id="tenant-b", slug="b", display_name="B")],
        memberships=[TenantMembership(tenant_id="tenant-a", user_id="user-a", role=role)],
    )


def tx(tid, amount, domain=DomainCode.RANCH, day=date(2026, 10, 3), category="cat-feed", account="acct-ranch"):
    return FinanceTransaction(
        id=tid, account_id=account, domain_code=domain, category_id=category, transfer_id=None,
        amount=amount, currency="USD", description=tid, transaction_date=day, record_status=RecordStatus.ACTIVE,
    )


class FakeRepository:
    def __init__(self, rows):
        self.rows = rows
        self.queries = []

    def revision(self):
        return "rev-1"

    def domains(self):
        return list(DOMAINS)

    def accounts(self):
        return list(ACCOUNTS)

    def categories(self):
        return list(CATEGORIES)

    def transactions_between(self, start, end, domain_codes, account_id):
        self.queries.append((start, end, domain_codes, account_id))
        return [
            r for r in self.rows
            if start <= r.transaction_date < end and r.domain_code in domain_codes
            and (account_id is None or r.account_id == account_id)
        ]

    def confirmed_transfer_ids(self, transfer_ids):
        return frozenset()


class Harness:
    def __init__(self, rows=(), role=Role.VIEWER):
        self.repository = FakeRepository(list(rows))
        self.opened = []

        @contextmanager
        def factory(context):
            self.opened.append(context)
            yield self.repository

        self.contract = FinanceReadContract(resolver=resolver(role), session_factory=factory, clock=lambda: NOW)


def test_summary_is_authorized_tenant_bound_and_versioned():
    h = Harness([tx("feed", "-40.00"), tx("groceries", "-99.00", domain=DomainCode.PERSONAL, category="cat-groceries")])
    response = h.contract.monthly_summary(principal=principal(), tenant_id="tenant-a", month="2026-10")
    assert response["schema_version"] == SCHEMA_VERSION
    assert response["server_revision"] == "rev-1"
    assert response["data"]["total_expenses"] == "40.00"
    [context] = h.opened
    assert (context.tenant_id, context.principal_id) == ("tenant-a", "principal-a")
    # "All" excludes the blocked Personal domain at the query, not after it.
    assert h.repository.queries[0][2] == frozenset({DomainCode.RANCH, DomainCode.ZERO_G})


@pytest.mark.parametrize("tenant_id, who", [("tenant-b", "principal-a"), (None, "principal-a"), ("tenant-a", "stranger")])
def test_unauthorized_requests_never_open_a_session(tenant_id, who):
    h = Harness([tx("feed", "-40.00")])
    with pytest.raises(TenancyError):
        h.contract.monthly_summary(principal=principal(who), tenant_id=tenant_id, month="2026-10")
    assert h.opened == []


def test_expired_principal_is_refused():
    h = Harness()
    h.contract._clock = lambda: NOW + timedelta(hours=1)
    with pytest.raises(TenancyError):
        h.contract.reference_data(principal=principal(), tenant_id="tenant-a")
    assert h.opened == []


@pytest.mark.parametrize("call", ["monthly_summary", "top_categories", "transactions"])
def test_personal_domain_is_refused_on_every_read(call):
    h = Harness()
    with pytest.raises(FinanceReadError) as err:
        getattr(h.contract, call)(principal=principal(), tenant_id="tenant-a", month="2026-10", domain="personal")
    assert err.value.code is FinanceReadErrorCode.PERSONAL_DOMAIN_BLOCKED
    assert h.opened == []


def test_unknown_domain_is_invalid():
    h = Harness()
    with pytest.raises(FinanceReadError) as err:
        h.contract.monthly_summary(principal=principal(), tenant_id="tenant-a", month="2026-10", domain="household")
    assert err.value.code is FinanceReadErrorCode.INVALID_DOMAIN


def test_personal_account_filter_is_not_found():
    h = Harness()
    with pytest.raises(FinanceReadError) as err:
        h.contract.monthly_summary(principal=principal(), tenant_id="tenant-a", month="2026-10", account_id="acct-personal")
    assert err.value.code is FinanceReadErrorCode.ACCOUNT_NOT_FOUND
    assert h.repository.queries == []


def test_reference_data_hides_personal_but_keeps_shared_and_inactive_categories():
    data = Harness().contract.reference_data(principal=principal(), tenant_id="tenant-a")["data"]
    assert [d["code"] for d in data["domains"]] == ["ranch", "zero_g"]
    assert [a["id"] for a in data["accounts"]] == ["acct-ranch"]
    assert sorted(c["id"] for c in data["categories"]) == ["cat-feed", "cat-shared"]


def test_top_categories_and_transactions_pages():
    rows = [tx(f"t{i}", "-10.00", day=date(2026, 10, i + 1)) for i in range(5)]
    h = Harness(rows)
    cats = h.contract.top_categories(principal=principal(), tenant_id="tenant-a", month="2026-10")["data"]
    assert cats[0]["name"] == "Feed" and cats[0]["amount"] == "50.00"
    page = h.contract.transactions(principal=principal(), tenant_id="tenant-a", month="2026-10", page=2, page_size=2)["data"]
    assert page["total"] == 5 and [i["id"] for i in page["items"]] == ["t2", "t1"]
    assert page["items"][0]["direction"] == "outflow" and page["items"][0]["amount"] == "-10.00"


@pytest.mark.parametrize("page, size", [(0, 10), (1, 0), (1, 201), (True, 10), ("1", 10)])
def test_bad_pagination_is_rejected_before_authorization(page, size):
    h = Harness()
    with pytest.raises(FinanceReadError) as err:
        h.contract.transactions(principal=principal(), tenant_id="tenant-a", month="2026-10", page=page, page_size=size)
    assert err.value.code is FinanceReadErrorCode.INVALID_PAGE
    assert h.opened == []
