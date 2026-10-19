"""RanchOS single-product SSO client tests.

One Jarvis sign-in issues one ranch session; each of the seven RanchOS
components then authorizes against that same session object. A session
bound to a different ranch, or an unknown component name, fails closed.
The role on the returned context still gates changes. The non-Jarvis
components never touch the session store's ``issue``.
"""

import inspect
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.sso_clients import (
    COMPONENTS,
    SIGN_IN_COMPONENT,
    authorize,
    jarvis_login,
)
from ranchbrain.tenancy import (
    Capability,
    Role,
    TenantContext,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    User,
    VerifiedPrincipal,
    require_capability,
)

NOW = datetime(2026, 10, 16, 12, tzinfo=timezone.utc)

RANCH_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RANCH_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
USER_MINE = "00000000-0000-4000-8000-000000000001"

EXPECTED_COMPONENTS = (
    "property_manager",
    "livestock",
    "finance",
    "ranchos_app",
    "ranchos_tv",
    "dashboard",
    "jarvis",
)


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


def owner_login(role=Role.OWNER, ranch_id=RANCH_A, requested=None, memberships=None):
    store = FakeStore()
    rows = memberships if memberships is not None else [
        TenantMembership(tenant_id=ranch_id, user_id=USER_MINE, role=role),
    ]
    session, context = jarvis_login(
        principal=principal(),
        users=[User(id=USER_MINE, principal_id="principal-mine")],
        memberships=rows,
        environment="development",
        store=store,
        requested_tenant_id=requested,
        now=NOW,
    )
    return store, session, context


def test_sign_in_component_is_jarvis():
    assert SIGN_IN_COMPONENT == "jarvis"
    assert tuple(COMPONENTS) == EXPECTED_COMPONENTS


def test_one_login_issues_once_and_every_component_authorizes_same_session():
    store, session, context = owner_login()
    assert len(store.calls) == 1
    assert store.calls[0]["tenant_id"] == RANCH_A
    for component in EXPECTED_COMPONENTS:
        assert authorize(session, context, component) is context
    assert len(store.calls) == 1


def test_second_ranch_session_is_rejected():
    _, session_a, _ = owner_login()
    memberships = [
        TenantMembership(tenant_id=RANCH_A, user_id=USER_MINE, role=Role.OWNER),
        TenantMembership(tenant_id=RANCH_B, user_id=USER_MINE, role=Role.OWNER),
    ]
    store, _, context_b = owner_login(memberships=memberships, requested=RANCH_B)
    assert len(store.calls) == 1
    with pytest.raises(TenancyError) as denied:
        authorize(session_a, context_b, "property_manager")
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


@pytest.mark.parametrize("component", ["unknown", "", "PropertyManager", "jarvis2", None])
def test_unknown_component_fails_closed(component):
    _, session, context = owner_login()
    with pytest.raises(TenancyError) as denied:
        authorize(session, context, component)
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED


def test_viewer_cannot_write_and_manager_cannot_delete():
    _, _, viewer = owner_login(role=Role.VIEWER)
    authorized_viewer = authorize({"session": "issued", "tenant_id": RANCH_A}, viewer, "property_manager")
    assert authorized_viewer is viewer
    with pytest.raises(TenancyError) as denied:
        require_capability(authorized_viewer, Capability.PROPERTY_WRITE)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN

    _, _, manager = owner_login(role=Role.MANAGER)
    authorized_manager = authorize({"session": "issued", "tenant_id": RANCH_A}, manager, "dashboard")
    require_capability(authorized_manager, Capability.PROPERTY_WRITE)
    with pytest.raises(TenancyError) as denied:
        require_capability(authorized_manager, Capability.PROPERTY_ADMIN)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN


def test_owner_reads_across_property_livestock_and_finance():
    _, session, context = owner_login(role=Role.OWNER)
    for component in EXPECTED_COMPONENTS:
        same = authorize(session, context, component)
        assert isinstance(same, TenantContext)
        require_capability(same, Capability.PROPERTY_READ)
        require_capability(same, Capability.LIVESTOCK_READ)
        require_capability(same, Capability.FINANCE_READ)


def test_non_jarvis_components_do_not_call_issue():
    source = inspect.getsource(authorize)
    assert "issue(" not in source
    assert "login(" not in source

    @dataclass
    class StrictStore:
        calls: list = field(default_factory=list)

        def issue(self, *, principal, tenant_id):
            self.calls.append((principal, tenant_id))
            raise AssertionError("non-Jarvis component must not call issue")

    _, session, context = owner_login()
    strict = StrictStore()
    assert strict.calls == []
    for component in EXPECTED_COMPONENTS:
        if component == SIGN_IN_COMPONENT:
            continue
        assert authorize(session, context, component) is context
    assert strict.calls == []
