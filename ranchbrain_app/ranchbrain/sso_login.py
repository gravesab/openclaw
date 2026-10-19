"""Single sign-on login: one verified sign-in issues one ranch session.

:func:`login` resolves the session from the server snapshot first and only
then asks the injected session store to issue. The tenant id passed to the
store is the one from the resolved context, never the raw client hint.
"""

from __future__ import annotations

from datetime import datetime
from typing import Iterable, Protocol, TypeVar

from ranchbrain.tenancy import (
    TenantContext,
    TenantMembership,
    User,
    VerifiedPrincipal,
    open_session_from_store,
)

IssuedSessionT = TypeVar("IssuedSessionT")


class SessionStore(Protocol[IssuedSessionT]):
    """Persists one issued session. Implemented by the deployed adapter."""

    def issue(self, *, principal: VerifiedPrincipal, tenant_id: str) -> IssuedSessionT: ...


def login(
    *,
    principal: VerifiedPrincipal,
    users: Iterable[User],
    memberships: Iterable[TenantMembership],
    environment: str,
    store: SessionStore[IssuedSessionT],
    requested_tenant_id: str | None = None,
    now: datetime | None = None,
) -> tuple[IssuedSessionT, TenantContext]:
    """Resolve the ranch session, then issue it through the store.

    A hint that is not one of the principal's loaded memberships fails
    inside session resolution, before the store is called.
    """

    context = open_session_from_store(
        principal=principal,
        users=users,
        memberships=memberships,
        environment=environment,
        requested_tenant_id=requested_tenant_id,
        now=now,
    )
    return store.issue(principal=principal, tenant_id=context.tenant_id), context
