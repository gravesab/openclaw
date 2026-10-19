"""Single sign-on login tests.

`login` resolves the one ranch session from the server snapshot and only
then asks the injected session store to issue. The tenant id passed to
`issue` comes from the resolved context; a hint that is not a loaded
membership fails before the store is touched.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.sso_login import login
from ranchbrain.tenancy import (
    Capability,
    Role,
    TenantContext,
    TenantMembership,
    TenancyError,
    User,
    VerifiedPrincipal,
    require_capability,
)


NOW = datetime(2026, 10, 16, 12, tzinfo=timezone.utc)

RANCH_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RANCH_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
USER_MINE = "00000000-0000-4000-8000-000000000001"
USER_THEIRS = "00000000-0000-4000-8000-000000000002"


def principal(**overrides):
    values = {
        "id": "principal-mine",
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": "session-mine",
        "valid_from": NOW - timedelta(minutes=5),
        "valid_until": NOW + timedelta(hours=1),
        "correlation_id": "request-mine",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


@dataclass
class FakeStore:
    calls: list = field(default_factory=list)

    def issue(self, *, principal, tenant_id):
        self.calls.append({"principal": principal, "tenant_id": tenant_id})
        return {"session": "issued", "tenant_id": tenant_id}


def test_one_membership_and_no_hint_issues_that_ranch():
    store = FakeStore()
    session, context = login(
        principal=principal(),
        users=[User(id=USER_MINE, principal_id="principal-mine")],
        memberships=[
            TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
        ],
        environment="development",
        store=store,
        now=NOW,
    )
    assert session == {"session": "issued", "tenant_id": RANCH_A}
    assert isinstance(context, TenantContext)
    assert context.tenant_id == RANCH_A
    assert store.calls == [{"principal": principal(), "tenant_id": RANCH_A}]
    require_capability(context, Capability.PROPERTY_READ)
    require_capability(context, Capability.LIVESTOCK_READ)
    require_capability(context, Capability.FINANCE_READ)


def test_matching_hint_issues_the_chosen_ranch():
    store = FakeStore()
    session, context = login(
        principal=principal(),
        users=[User(id=USER_MINE, principal_id="principal-mine")],
        memberships=[
            TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.MANAGER),
            TenantMembership(tenant_id=RANCH_B, user_id=USER_MINE, role=Role.VIEWER),
        ],
        environment="development",
        store=store,
        requested_tenant_id=RANCH_B,
        now=NOW,
    )
    assert context.tenant_id == RANCH_B
    assert store.calls == [{"principal": principal(), "tenant_id": RANCH_B}]


def test_several_memberships_and_no_hint_fail_before_issue():
    store = FakeStore()
    with pytest.raises(TenancyError, match="explicit tenant selection"):
        login(
            principal=principal(),
            users=[User(id=USER_MINE, principal_id="principal-mine")],
            memberships=[
                TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.MANAGER),
                TenantMembership(tenant_id=RANCH_B, user_id=USER_MINE, role=Role.VIEWER),
            ],
            environment="development",
            store=store,
            now=NOW,
        )
    assert store.calls == []


def test_hint_for_another_persons_ranch_fails_before_issue():
    store = FakeStore()
    with pytest.raises(TenancyError):
        login(
            principal=principal(),
            users=[
                User(id=USER_MINE, principal_id="principal-mine"),
                User(id=USER_THEIRS, principal_id="principal-theirs"),
            ],
            memberships=[
                TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
                TenantMembership(tenant_id=RANCH_B, user_id=USER_THEIRS, role=Role.OWNER),
            ],
            environment="development",
            store=store,
            requested_tenant_id=RANCH_B,
            now=NOW,
        )
    assert store.calls == []


def test_stale_principal_fails_before_issue():
    store = FakeStore()
    with pytest.raises(TenancyError, match="not active"):
        login(
            principal=principal(
                valid_from=NOW - timedelta(hours=2),
                valid_until=NOW - timedelta(hours=1),
            ),
            users=[User(id=USER_MINE, principal_id="principal-mine")],
            memberships=[
                TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
            ],
            environment="development",
            store=store,
            now=NOW,
        )
    assert store.calls == []
