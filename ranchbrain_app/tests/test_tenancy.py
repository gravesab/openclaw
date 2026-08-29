from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.tenancy import (
    Capability,
    Role,
    Tenant,
    TenantContextResolver,
    TenantMembership,
    TenancyError,
    User,
    VerifiedPrincipal,
)


NOW = datetime(2026, 8, 27, 14, tzinfo=timezone.utc)


def principal(**overrides):
    values = {
        "id": "principal-a",
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": "session-a",
        "valid_from": NOW - timedelta(minutes=5),
        "valid_until": NOW + timedelta(minutes=5),
        "correlation_id": "request-a",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


def resolver(memberships=None, users=None, tenants=None):
    return TenantContextResolver(
        environment="development",
        users=users or [User(id="user-a", principal_id="principal-a")],
        tenants=tenants or [Tenant(id="tenant-a", slug="a", display_name="A"), Tenant(id="tenant-b", slug="b", display_name="B")],
        memberships=memberships or [TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.VIEWER)],
    )


def test_resolves_explicit_active_membership_with_read_capability():
    context = resolver().resolve(
        principal=principal(),
        requested_tenant_id="tenant-a",
        capability=Capability.TV_TODAY_READ,
        now=NOW,
    )
    assert context.tenant_id == "tenant-a"
    assert context.principal_id == "principal-a"
    assert context.role is Role.VIEWER


def test_rejects_missing_tenant_instead_of_using_a_default():
    with pytest.raises(TenancyError, match="explicit tenant"):
        resolver().resolve(principal=principal(), requested_tenant_id=None, capability=Capability.MEMORY_READ, now=NOW)


def test_rejects_cross_tenant_selection():
    with pytest.raises(TenancyError, match="not authorized"):
        resolver().resolve(principal=principal(), requested_tenant_id="tenant-b", capability=Capability.MEMORY_READ, now=NOW)


@pytest.mark.parametrize("change", [{"environment": "production"}, {"lifecycle_state": "revoked"}, {"valid_until": NOW}])
def test_rejects_wrong_environment_revoked_or_expired_principal(change):
    with pytest.raises(TenancyError, match="not active"):
        resolver().resolve(principal=principal(**change), requested_tenant_id="tenant-a", capability=Capability.MEMORY_READ, now=NOW)


def test_rejects_ambiguous_active_memberships():
    memberships = [
        TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.VIEWER),
        TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.OWNER),
    ]
    with pytest.raises(TenancyError, match="ambiguous"):
        resolver(memberships).resolve(principal=principal(), requested_tenant_id="tenant-a", capability=Capability.MEMORY_READ, now=NOW)


@pytest.mark.parametrize(
    ("users", "tenants", "memberships"),
    [
        ([User(id="user-a", principal_id="principal-a", status="inactive")], None, None),
        (None, [Tenant(id="tenant-a", slug="a", display_name="A", status="inactive")], None),
        (None, None, [TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.VIEWER, status="inactive")]),
    ],
)
def test_rejects_inactive_user_tenant_or_membership(users, tenants, memberships):
    with pytest.raises(TenancyError, match="not authorized|missing"):
        resolver(users=users, tenants=tenants, memberships=memberships).resolve(
            principal=principal(), requested_tenant_id="tenant-a", capability=Capability.LIVESTOCK_READ, now=NOW
        )


@pytest.mark.parametrize("selected_tenant", ["tenant-a", "tenant-b"])
def test_dual_member_can_explicitly_select_either_authorized_tenant(selected_tenant):
    memberships = [
        TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.VIEWER),
        TenantMembership(tenant_id="tenant-b", user_id="user-a", role=Role.VIEWER),
    ]
    context = resolver(memberships=memberships).resolve(
        principal=principal(), requested_tenant_id=selected_tenant, capability=Capability.LIVESTOCK_READ, now=NOW
    )
    assert context.tenant_id == selected_tenant


@pytest.mark.parametrize(
    "change",
    [
        {"id": ""},
        {"environment": ""},
        {"valid_from": datetime(2026, 8, 27, 14)},
        {"valid_until": datetime(2026, 8, 27, 15)},
        {"valid_from": NOW, "valid_until": NOW},
        {"valid_from": NOW + timedelta(minutes=1), "valid_until": NOW},
    ],
)
def test_malformed_principal_construction_fails_with_tenancy_error(change):
    with pytest.raises(TenancyError):
        principal(**change)


def test_malformed_current_time_fails_with_tenancy_error_not_datetime_error():
    with pytest.raises(TenancyError, match="timezone-aware"):
        resolver().resolve(
            principal=principal(), requested_tenant_id="tenant-a", capability=Capability.LIVESTOCK_READ, now=datetime(2026, 8, 27, 14)
        )
