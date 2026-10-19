"""Single sign-on membership loading tests.

`open_session_from_store` binds a verified principal to the server snapshot
of users and memberships, then opens the one ranch session through
`open_session`. The caller supplies no membership list of its own: a
client-style list naming another ranch can never reach the function, so it
can never open that ranch.
"""

import inspect
from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.tenancy import (
    Capability,
    Role,
    TenantContext,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    User,
    VerifiedPrincipal,
    open_session_from_store,
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


def test_one_active_membership_opens_that_ranch_with_no_hint():
    session = open_session_from_store(
        principal=principal(),
        users=[User(id=USER_MINE, principal_id="principal-mine")],
        memberships=[
            TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
        ],
        environment="development",
        now=NOW,
    )
    assert isinstance(session, TenantContext)
    assert session.tenant_id == RANCH_A
    assert session.role is Role.OWNER
    require_capability(session, Capability.PROPERTY_READ)
    require_capability(session, Capability.LIVESTOCK_READ)
    require_capability(session, Capability.FINANCE_READ)


def test_several_memberships_require_a_matching_hint():
    users = [User(id=USER_MINE, principal_id="principal-mine")]
    memberships = [
        TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.MANAGER),
        TenantMembership(tenant_id=RANCH_B, user_id=USER_MINE, role=Role.VIEWER),
    ]
    with pytest.raises(TenancyError, match="explicit tenant selection"):
        open_session_from_store(
            principal=principal(),
            users=users,
            memberships=memberships,
            environment="development",
            now=NOW,
        )
    chosen = open_session_from_store(
        principal=principal(),
        users=users,
        memberships=memberships,
        environment="development",
        requested_tenant_id=RANCH_B,
        now=NOW,
    )
    assert chosen.tenant_id == RANCH_B
    assert chosen.role is Role.VIEWER


@pytest.mark.parametrize(
    ("users", "memberships"),
    [
        ([], [TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER)]),
        (
            [User(id=USER_MINE, principal_id="principal-mine", status="inactive")],
            [TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER)],
        ),
        (
            [User(id=USER_MINE, principal_id="principal-mine")],
            [],
        ),
        (
            [User(id=USER_MINE, principal_id="principal-mine")],
            [TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER, status="revoked")],
        ),
    ],
)
def test_missing_or_inactive_user_or_membership_fails_closed(users, memberships):
    with pytest.raises(TenancyError) as denied:
        open_session_from_store(
            principal=principal(),
            users=users,
            memberships=memberships,
            environment="development",
            requested_tenant_id=RANCH_A,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_hint_for_a_ranch_not_in_the_snapshot_fails_closed():
    with pytest.raises(TenancyError) as denied:
        open_session_from_store(
            principal=principal(),
            users=[User(id=USER_MINE, principal_id="principal-mine")],
            memberships=[
                TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
            ],
            environment="development",
            requested_tenant_id=RANCH_B,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_another_persons_snapshot_rows_are_ignored():
    users = [
        User(id=USER_MINE, principal_id="principal-mine"),
        User(id=USER_THEIRS, principal_id="principal-theirs"),
    ]
    memberships = [
        TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
        TenantMembership(tenant_id=RANCH_B, user_id=USER_THEIRS, role=Role.OWNER),
    ]
    session = open_session_from_store(
        principal=principal(),
        users=users,
        memberships=memberships,
        environment="development",
        now=NOW,
    )
    assert session.tenant_id == RANCH_A
    assert session.user_id == USER_MINE
    with pytest.raises(TenancyError) as denied:
        open_session_from_store(
            principal=principal(),
            users=users,
            memberships=memberships,
            environment="development",
            requested_tenant_id=RANCH_B,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_client_supplied_membership_list_has_no_parameter_to_enter():
    parameters = set(inspect.signature(open_session_from_store).parameters)
    assert parameters == {
        "principal",
        "users",
        "memberships",
        "environment",
        "requested_tenant_id",
        "now",
    }
