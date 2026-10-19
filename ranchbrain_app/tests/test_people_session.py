"""People-session client-hint tests.

The client ranch hint is not authority: no hint, a blank hint, or a
hint matching the directory ranch all open the directory's session
through ``PeopleDirectory.sign_in``. Any other hint fails
``tenant_not_authorized`` before ``sign_in`` runs — the invited
person's ``principal_id`` stays empty and the store is untouched. A
matching hint never bypasses the directory's own sign-in failures.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.people_directory import PeopleDirectory
from ranchbrain.people_session import open_people_session
from ranchbrain.tenancy import (
    Capability,
    Role,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
    require_capability,
)

RANCH_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RANCH_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


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


class RecordingDirectory(PeopleDirectory):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.sign_in_calls = []

    def sign_in(self, email, principal, store):
        self.sign_in_calls.append((email, principal, store))
        return super().sign_in(email, principal, store)


def directory():
    recording = RecordingDirectory.with_owner(
        tenant_id=RANCH_A, name="Ranch owner", email="owner@ranchos.dev"
    )
    assert isinstance(recording, RecordingDirectory)
    return recording


@pytest.mark.parametrize("hint", [None, "", "   "])
def test_no_hint_issues_the_directory_ranch(hint):
    people = directory()
    store = FakeStore()
    people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)

    session, context = open_people_session(
        directory=people,
        email="sam@ranchos.dev",
        principal=principal(),
        store=store,
        client_tenant_id=hint,
    )

    assert session["tenant_id"] == RANCH_A
    assert context.tenant_id == RANCH_A
    assert context.role is Role.MANAGER
    require_capability(context, Capability.PROPERTY_READ)
    assert len(store.calls) == 1


@pytest.mark.parametrize("hint", [RANCH_A, f"  {RANCH_A}  "])
def test_matching_hint_issues_that_same_ranch_without_passing_the_hint(hint):
    people = directory()
    store = FakeStore()
    people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    mine = principal()

    session, context = open_people_session(
        directory=people,
        email="sam@ranchos.dev",
        principal=mine,
        store=store,
        client_tenant_id=hint,
    )

    assert session["tenant_id"] == RANCH_A
    assert len(store.calls) == 1
    assert len(people.sign_in_calls) == 1
    email, seen_principal, seen_store = people.sign_in_calls[0]
    assert email == "sam@ranchos.dev"
    assert seen_principal is mine
    assert seen_store is store


def test_different_hint_fails_before_sign_in_with_empty_principal_id():
    people = directory()
    store = FakeStore()
    sam = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)

    with pytest.raises(TenancyError) as denied:
        open_people_session(
            directory=people,
            email="sam@ranchos.dev",
            principal=principal(),
            store=store,
            client_tenant_id=RANCH_B,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert store.calls == []
    assert people.sign_in_calls == []
    assert sam.principal_id == ""


def test_unknown_email_plus_matching_hint_still_fails_before_issue():
    people = directory()
    store = FakeStore()

    with pytest.raises(TenancyError) as denied:
        open_people_session(
            directory=people,
            email="stranger@ranchos.dev",
            principal=principal(),
            store=store,
            client_tenant_id=RANCH_A,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert store.calls == []


def test_revoked_person_plus_matching_hint_still_fails_before_issue():
    people = directory()
    store = FakeStore()
    sam = people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    people.revoke(sam.user_id)

    with pytest.raises(TenancyError) as denied:
        open_people_session(
            directory=people,
            email="sam@ranchos.dev",
            principal=principal(),
            store=store,
            client_tenant_id=RANCH_A,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert store.calls == []


def test_wrong_principal_plus_matching_hint_still_fails_before_issue():
    people = directory()
    store = FakeStore()
    people.invite("Sam", "sam@ranchos.dev", Role.MANAGER)
    open_people_session(
        directory=people,
        email="sam@ranchos.dev",
        principal=principal("principal-one"),
        store=store,
        client_tenant_id=RANCH_A,
    )
    assert len(store.calls) == 1

    with pytest.raises(TenancyError) as denied:
        open_people_session(
            directory=people,
            email="sam@ranchos.dev",
            principal=principal("principal-two"),
            store=store,
            client_tenant_id=RANCH_A,
        )
    assert denied.value.code is TenancyErrorCode.TENANT_NOT_AUTHORIZED
    assert len(store.calls) == 1
