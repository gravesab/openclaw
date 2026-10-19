"""Server people-directory tests.

An owner invites by name, email, and ranch-wide role; that invitation
is the membership Jarvis uses at sign-in. sign_in binds the verified
principal on first use and issues through sso_clients.jarvis_login —
never sso_login.login directly, and never before the email and binding
checks pass.
"""

import inspect
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.people_directory import PeopleDirectory
from ranchbrain.sso_clients import COMPONENTS, authorize
from ranchbrain.tenancy import (
    Capability,
    Role,
    TenantContext,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
    require_capability,
)

RANCH_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def principal(pid="principal-one", **overrides):
    now = datetime.now(timezone.utc)
    values = {
        "id": pid,
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": f"session-{pid}",
        "valid_from": now - timedelta(minutes=5),
        "valid_until": now + timedelta(hours=1),
        "correlation_id": f"request-{pid}",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


@dataclass
class FakeStore:
    calls: list = field(default_factory=list)

    def issue(self, *, principal, tenant_id):
        self.calls.append({"principal": principal, "tenant_id": tenant_id})
        return {"session": "issued", "tenant_id": tenant_id}


def directory():
    return PeopleDirectory.with_owner(
        tenant_id=RANCH_A, name="Ranch owner", email="owner@ranchos.dev"
    )


def test_owner_invite_then_manager_sign_in_across_all_seven_components():
    people = directory()
    store = FakeStore()
    invited = people.invite("Sam Rivera", "Sam@Ranchos.dev", Role.MANAGER)

    session, context = people.sign_in("sam@ranchos.dev", principal(), store)

    assert len(store.calls) == 1
    assert store.calls[0]["tenant_id"] == RANCH_A
    assert isinstance(context, TenantContext)
    assert context.tenant_id == RANCH_A
    assert context.role is Role.MANAGER
    assert tuple(COMPONENTS) == (
        "property_manager", "livestock", "finance",
        "ranchos_app", "ranchos_tv", "dashboard", "jarvis",
    )
    for component in COMPONENTS:
        assert authorize(session, context, component) is context
    require_capability(context, Capability.PROPERTY_READ)
    require_capability(context, Capability.LIVESTOCK_READ)
    require_capability(context, Capability.FINANCE_READ)
    assert invited.principal_id == "principal-one"


def test_viewer_denied_property_write_and_manager_denied_property_admin():
    people = directory()
    store = FakeStore()
    people.invite("Vi", "vi@ranchos.dev", Role.VIEWER)
    people.invite("Mo", "mo@ranchos.dev", Role.MANAGER)

    _, viewer = people.sign_in("vi@ranchos.dev", principal("principal-vi"), store)
    with pytest.raises(TenancyError) as denied:
        require_capability(viewer, Capability.PROPERTY_WRITE)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN

    _, manager = people.sign_in("mo@ranchos.dev", principal("principal-mo"), store)
    require_capability(manager, Capability.PROPERTY_WRITE)
    with pytest.raises(TenancyError) as denied:
        require_capability(manager, Capability.PROPERTY_ADMIN)
    assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN


def test_role_change_applies_to_next_sign_in_without_second_person():
    people = directory()
    store = FakeStore()
    invited = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)

    _, first = people.sign_in("sam@ranchos.dev", principal(), store)
    assert first.role is Role.MANAGER

    people.change_role(invited.user_id, Role.VIEWER)
    _, second = people.sign_in("sam@ranchos.dev", principal(), store)
    assert second.role is Role.VIEWER
    assert len(store.calls) == 2
    assert len(people.active_people) == 2


def test_duplicate_email_fails_closed_case_insensitively():
    people = directory()
    people.invite("Sam", "sam@ranchos.dev", Role.VIEWER)
    with pytest.raises(TenancyError) as denied:
        people.invite("Other Sam", "SAM@ranchos.dev", Role.VIEWER)
    assert denied.value.code is TenancyErrorCode.TENANT_CONTEXT_INVALID
    assert len(people.active_people) == 2


def test_revoked_email_may_be_invited_again():
    people = directory()
    first = people.invite("Sam", "sam@ranchos.dev", Role.VIEWER)
    people.revoke(first.user_id)
    assert all(p.email != "sam@ranchos.dev" for p in people.active_people)
    second = people.invite("Sam Again", "SAM@ranchos.dev", Role.MANAGER)
    assert second.user_id != first.user_id
    assert second.role is Role.MANAGER


@pytest.mark.parametrize("name", ["", "   "])
def test_invalid_name_fails_closed(name):
    people = directory()
    with pytest.raises(TenancyError) as denied:
        people.invite(name, "sam@ranchos.dev", Role.VIEWER)
    assert denied.value.code is TenancyErrorCode.TENANT_CONTEXT_INVALID


@pytest.mark.parametrize("email", ["sam", "sam@", "@ranchos.dev", "sam@ranchos", "  "])
def test_invalid_email_fails_closed(email):
    people = directory()
    with pytest.raises(TenancyError) as denied:
        people.invite("Sam", email, Role.VIEWER)
    assert denied.value.code is TenancyErrorCode.TENANT_CONTEXT_INVALID


def test_manager_or_viewer_actor_cannot_manage():
    people = directory()
    manager = people.invite("Mo", "mo@ranchos.dev", Role.MANAGER)
    viewer = people.invite("Vi", "vi@ranchos.dev", Role.VIEWER)
    owner_id = people.actor_user_id
    for actor in (manager.user_id, viewer.user_id):
        people.actor_user_id = actor
        assert not people.can_manage
        with pytest.raises(TenancyError) as denied:
            people.invite("No", "no@ranchos.dev", Role.VIEWER)
        assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN
        with pytest.raises(TenancyError) as denied:
            people.change_role(owner_id, Role.VIEWER)
        assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN
        with pytest.raises(TenancyError) as denied:
            people.revoke(owner_id)
        assert denied.value.code is TenancyErrorCode.CAPABILITY_FORBIDDEN
    people.actor_user_id = owner_id
    assert people.can_manage


def test_revoke_before_sign_in_fails_sign_in_with_zero_issue_calls():
    people = directory()
    store = FakeStore()
    invited = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    people.revoke(invited.user_id)
    with pytest.raises(TenancyError) as denied:
        people.sign_in("sam@ranchos.dev", principal(), store)
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert store.calls == []


def test_unknown_email_fails_before_issue():
    people = directory()
    store = FakeStore()
    with pytest.raises(TenancyError) as denied:
        people.sign_in("stranger@ranchos.dev", principal(), store)
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert store.calls == []


def test_sole_owner_cannot_be_revoked_or_demoted():
    people = directory()
    owner_id = people.actor_user_id
    with pytest.raises(TenancyError):
        people.revoke(owner_id)
    with pytest.raises(TenancyError):
        people.change_role(owner_id, Role.MANAGER)
    assert len(people.active_people) == 1


def test_either_of_two_owners_may_be_demoted_or_removed():
    people = directory()
    store = FakeStore()
    first_owner = people.actor_user_id
    second = people.invite("Jo", "jo@ranchos.dev", Role.OWNER)

    people.change_role(second.user_id, Role.MANAGER)
    assert sum(1 for p in people.active_people if p.role is Role.OWNER) == 1
    people.change_role(second.user_id, Role.OWNER)
    people.revoke(first_owner)
    assert [p.user_id for p in people.active_people] == [second.user_id]

    session, context = people.sign_in("jo@ranchos.dev", principal("principal-jo"), store)
    assert context.role is Role.OWNER
    assert len(store.calls) == 1
    assert session["tenant_id"] == RANCH_A


def test_second_principal_blocked_from_bound_email_before_issue():
    people = directory()
    store = FakeStore()
    people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    people.sign_in("sam@ranchos.dev", principal("principal-one"), store)
    assert len(store.calls) == 1
    with pytest.raises(TenancyError) as denied:
        people.sign_in("sam@ranchos.dev", principal("principal-two"), store)
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert len(store.calls) == 1


def test_unknown_person_ids_fail_closed():
    people = directory()
    with pytest.raises(TenancyError):
        people.change_role("no-such-user", Role.VIEWER)
    with pytest.raises(TenancyError):
        people.revoke("no-such-user")


def test_snapshots_match_jarvis_login_shape():
    people = directory()
    users, memberships = people.snapshots()
    assert users == [] and memberships == []

    invited = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    users, memberships = people.snapshots()
    assert users == [] and memberships == []

    people.sign_in("sam@ranchos.dev", principal(), FakeStore())
    users, memberships = people.snapshots()
    assert [(u.id, u.principal_id, u.status) for u in users] == [
        (invited.user_id, "principal-one", "active")
    ]
    assert [(m.tenant_id, m.user_id, m.role, m.status) for m in memberships] == [
        (RANCH_A, invited.user_id, Role.MANAGER, "active")
    ]

    people.revoke(invited.user_id)
    users, memberships = people.snapshots()
    assert memberships == [] and all(m.status == "active" for m in memberships)


def test_sign_in_goes_through_jarvis_login_only():
    import ranchbrain.people_directory as module

    source = inspect.getsource(module.PeopleDirectory.sign_in)
    assert "jarvis_login(" in source
    assert "sso_login" not in source


def test_second_email_blocked_for_bound_principal_and_first_person_still_signs_in():
    people = directory()
    store = FakeStore()
    people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    jo = people.invite("Jo", "jo@ranchos.dev", Role.MANAGER)

    people.sign_in("sam@ranchos.dev", principal("principal-one"), store)
    assert len(store.calls) == 1

    with pytest.raises(TenancyError) as denied:
        people.sign_in("jo@ranchos.dev", principal("principal-one"), store)
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert len(store.calls) == 1
    assert jo.principal_id == ""

    _, again = people.sign_in("sam@ranchos.dev", principal("principal-one"), store)
    assert again.role is Role.MANAGER
    assert len(store.calls) == 2


def test_inactive_principal_first_sign_in_leaves_principal_id_empty():
    people = directory()
    store = FakeStore()
    sam = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)

    now = datetime.now(timezone.utc)
    stale = principal(
        "principal-stale",
        valid_from=now - timedelta(hours=2),
        valid_until=now - timedelta(hours=1),
    )
    with pytest.raises(TenancyError):
        people.sign_in("sam@ranchos.dev", stale, store)
    assert store.calls == []
    assert sam.principal_id == ""

    _, context = people.sign_in("sam@ranchos.dev", principal("principal-one"), store)
    assert context.role is Role.MANAGER
    assert sam.principal_id == "principal-one"
    assert len(store.calls) == 1
