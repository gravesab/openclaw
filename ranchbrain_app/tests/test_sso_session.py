"""Single sign-on session tests: one sign-in opens one ranch session.

One verified principal plus that principal's memberships yields one
:class:`TenantContext`. The same session object authorizes property,
livestock, and finance capability checks; no second login object, no
per-app user, and no per-app membership is created.
"""

from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.tenancy import (
    Capability,
    Role,
    TenantContext,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
    open_session,
    require_capability,
)


NOW = datetime(2026, 10, 16, 12, tzinfo=timezone.utc)

RANCH_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RANCH_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
USER_NEW = "00000000-0000-4000-8000-000000000001"


def principal(**overrides):
    values = {
        "id": "principal-new",
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": "session-new",
        "valid_from": NOW - timedelta(minutes=5),
        "valid_until": NOW + timedelta(hours=1),
        "correlation_id": "request-new",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


def membership(tenant_id=RANCH_A, user_id=USER_NEW, role=Role.OWNER, status="active"):
    return TenantMembership(tenant_id=tenant_id, user_id=user_id, role=role, status=status)


def test_brand_new_ranch_owner_session_authorizes_all_three_apps():
    session = open_session(
        principal=principal(),
        user_id=USER_NEW,
        memberships=[membership()],
        environment="development",
        now=NOW,
    )
    assert isinstance(session, TenantContext)
    assert session.tenant_id == RANCH_A
    assert session.role is Role.OWNER
    # One session object, no second login: property, livestock, and finance
    # all authorize against it.
    require_capability(session, Capability.PROPERTY_READ)
    require_capability(session, Capability.LIVESTOCK_READ)
    require_capability(session, Capability.FINANCE_READ)


def test_second_ranch_id_is_rejected_as_the_session_tenant():
    with pytest.raises(TenancyError) as denied:
        open_session(
            principal=principal(),
            user_id=USER_NEW,
            memberships=[membership()],
            environment="development",
            requested_tenant_id=RANCH_B,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_manager_session_cannot_delete_but_viewer_session_can_read_property():
    manager = open_session(
        principal=principal(),
        user_id=USER_NEW,
        memberships=[membership(role=Role.MANAGER)],
        environment="development",
        now=NOW,
    )
    require_capability(manager, Capability.PROPERTY_READ)
    require_capability(manager, Capability.PROPERTY_WRITE)
    with pytest.raises(TenancyError) as denied:
        require_capability(manager, Capability.PROPERTY_ADMIN)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN

    viewer = open_session(
        principal=principal(),
        user_id=USER_NEW,
        memberships=[membership(role=Role.VIEWER)],
        environment="development",
        now=NOW,
    )
    require_capability(viewer, Capability.PROPERTY_READ)
    with pytest.raises(TenancyError) as denied:
        require_capability(viewer, Capability.PROPERTY_WRITE)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN


def test_more_than_one_membership_requires_an_explicit_ranch_choice():
    memberships = [
        membership(tenant_id=RANCH_A, role=Role.MANAGER),
        membership(tenant_id=RANCH_B, role=Role.VIEWER),
    ]
    with pytest.raises(TenancyError, match="explicit tenant selection"):
        open_session(
            principal=principal(),
            user_id=USER_NEW,
            memberships=memberships,
            environment="development",
            now=NOW,
        )
    chosen = open_session(
        principal=principal(),
        user_id=USER_NEW,
        memberships=memberships,
        environment="development",
        requested_tenant_id=RANCH_B,
        now=NOW,
    )
    assert chosen.tenant_id == RANCH_B
    assert chosen.role is Role.VIEWER


@pytest.mark.parametrize("status", ["suspended", "revoked", "inactive"])
def test_missing_suspended_or_revoked_membership_fails_closed(status):
    with pytest.raises(TenancyError) as denied:
        open_session(
            principal=principal(),
            user_id=USER_NEW,
            memberships=[membership(status=status)],
            environment="development",
            requested_tenant_id=RANCH_A,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    with pytest.raises(TenancyError) as denied:
        open_session(
            principal=principal(),
            user_id=USER_NEW,
            memberships=[],
            environment="development",
            requested_tenant_id=RANCH_A,
            now=NOW,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_principal_from_another_environment_gets_no_session():
    with pytest.raises(TenancyError, match="not active"):
        open_session(
            principal=principal(environment="production"),
            user_id=USER_NEW,
            memberships=[membership()],
            environment="development",
            now=NOW,
        )
