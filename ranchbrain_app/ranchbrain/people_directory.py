"""In-memory server directory for one ranch's people.

An owner invites a person by name and email and picks one role for the
whole ranch. That invitation is the membership Jarvis uses at sign-in:
:func:`sign_in` binds the verified principal to the invited email on
first sign-in and issues the ranch session through
:func:`ranchbrain.sso_clients.jarvis_login`. Nothing here sends email,
opens a network connection, or writes Postgres.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from ranchbrain.sso_clients import jarvis_login
from ranchbrain.tenancy import (
    Role,
    TenantContext,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    User,
    VerifiedPrincipal,
)

STATUS_ACTIVE = "active"
STATUS_REVOKED = "revoked"


@dataclass
class DirectoryPerson:
    """One invited person on this ranch."""

    user_id: str
    name: str
    email: str
    role: Role
    status: str = STATUS_ACTIVE
    principal_id: str = ""


@dataclass
class PeopleDirectory:
    """One ranch's people, held in memory under a fixed tenant id."""

    tenant_id: str
    actor_user_id: str = ""
    people: list[DirectoryPerson] = field(default_factory=list)

    @classmethod
    def with_owner(cls, *, tenant_id: str, name: str, email: str) -> "PeopleDirectory":
        """Bootstrap a directory whose actor is its first owner."""
        directory = cls(tenant_id=tenant_id)
        owner = DirectoryPerson(
            user_id=str(uuid.uuid4()),
            name=name.strip(),
            email=email.strip().lower(),
            role=Role.OWNER,
        )
        directory.people.append(owner)
        directory.actor_user_id = owner.user_id
        return directory

    @property
    def can_manage(self) -> bool:
        """True only when the actor has one active owner membership."""
        mine = [p for p in self.people if p.user_id == self.actor_user_id and p.status == STATUS_ACTIVE]
        return len(mine) == 1 and mine[0].role is Role.OWNER

    @property
    def active_people(self) -> list[DirectoryPerson]:
        """Everyone not revoked. Revoked people are absent from this list."""
        return [p for p in self.people if p.status != STATUS_REVOKED]

    def invite(self, name: str, email: str, role: Role = Role.MANAGER) -> DirectoryPerson:
        """Add one person. Only an owner may invite."""
        if not self.can_manage:
            raise TenancyError(
                "only an owner can change who has access",
                TenancyErrorCode.CAPABILITY_FORBIDDEN,
            )
        clean_name = name.strip()
        if not clean_name:
            raise TenancyError("invited person requires a name")
        clean_email = email.strip().lower()
        if not _is_valid_email(clean_email):
            raise TenancyError(f"invited email {email.strip()!r} is invalid")
        if any(p.email.lower() == clean_email and p.status != STATUS_REVOKED for p in self.people):
            raise TenancyError(f"email {clean_email!r} is already on this ranch")
        person = DirectoryPerson(
            user_id=str(uuid.uuid4()),
            name=clean_name,
            email=clean_email,
            role=role,
        )
        self.people.append(person)
        return person

    def change_role(self, user_id: str, role: Role) -> None:
        """Change one active person's ranch-wide role."""
        if not self.can_manage:
            raise TenancyError(
                "only an owner can change who has access",
                TenancyErrorCode.CAPABILITY_FORBIDDEN,
            )
        person = self._active_person(user_id)
        if person.role is Role.OWNER and role is not Role.OWNER and self._owner_count() == 1:
            raise TenancyError("the ranch must keep at least one owner")
        person.role = role

    def revoke(self, user_id: str) -> None:
        """Remove one active person from this ranch."""
        if not self.can_manage:
            raise TenancyError(
                "only an owner can change who has access",
                TenancyErrorCode.CAPABILITY_FORBIDDEN,
            )
        person = self._active_person(user_id)
        if person.role is Role.OWNER and self._owner_count() == 1:
            raise TenancyError("the ranch must keep at least one owner")
        person.status = STATUS_REVOKED

    def snapshots(self) -> tuple[list[User], list[TenantMembership]]:
        """User and TenantMembership rows in the shape jarvis_login accepts.

        An invited person with no principal id is not a User yet. An
        active bound person contributes one active User plus one active
        membership on this ranch. A revoked person has no active
        membership.
        """
        users = [
            User(id=p.user_id, principal_id=p.principal_id)
            for p in self.people
            if p.status == STATUS_ACTIVE and p.principal_id
        ]
        memberships = [
            TenantMembership(tenant_id=self.tenant_id, user_id=p.user_id, role=p.role)
            for p in self.people
            if p.status == STATUS_ACTIVE and p.principal_id
        ]
        return users, memberships

    def sign_in(self, email: str, principal: VerifiedPrincipal, store: object) -> tuple[object, TenantContext]:
        """Sign in with a verified email and issue this ranch's session.

        The email is the verified sign-in email, never a tenant hint:
        there is no ``requested_tenant_id`` parameter. Unknown or
        revoked emails, an email already bound to a different
        principal, and a principal already bound to a different active
        person all fail before the store is touched. The first sign-in
        binds ``principal.id`` onto the invited person only when the
        session is issued: if ``jarvis_login`` raises, a bind this call
        just wrote is cleared. Later sign-ins with the same principal
        issue again without a second person.
        """
        clean_email = email.strip().lower()
        person = next(
            (p for p in self.people if p.status != STATUS_REVOKED and p.email.lower() == clean_email),
            None,
        )
        if person is None:
            raise TenancyError(
                "sign-in email is not on this ranch",
                TenancyErrorCode.TENANT_NOT_AUTHORIZED,
            )
        if person.principal_id and person.principal_id != principal.id:
            raise TenancyError(
                "sign-in email is already bound to a different sign-in",
                TenancyErrorCode.TENANT_NOT_AUTHORIZED,
            )
        if any(
            p is not person and p.status != STATUS_REVOKED and p.principal_id == principal.id
            for p in self.people
        ):
            raise TenancyError(
                "sign-in is already bound to a different person on this ranch",
                TenancyErrorCode.TENANT_NOT_AUTHORIZED,
            )
        wrote_bind = False
        if not person.principal_id:
            person.principal_id = principal.id
            wrote_bind = True
        users, memberships = self.snapshots()
        try:
            return jarvis_login(
                principal=principal,
                users=users,
                memberships=memberships,
                environment=principal.environment,
                store=store,
            )
        except Exception:
            if wrote_bind:
                person.principal_id = ""
            raise

    def _active_person(self, user_id: str) -> DirectoryPerson:
        person = next((p for p in self.people if p.user_id == user_id and p.status != STATUS_REVOKED), None)
        if person is None:
            raise TenancyError("person is not on this ranch")
        return person

    def _owner_count(self) -> int:
        return sum(1 for p in self.people if p.status != STATUS_REVOKED and p.role is Role.OWNER)


def _is_valid_email(email: str) -> bool:
    """Trimmed, lowercased: one @, non-empty local part, dot in domain."""
    parts = email.split("@")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return False
    return "." in parts[1]
