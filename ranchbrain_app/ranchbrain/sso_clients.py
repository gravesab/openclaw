"""RanchOS single-product single sign-on clients.

RanchOS is one product. Its components are Property Manager, Livestock,
Finance, the RanchOS app, the RanchOS TV app, the dashboard, and Jarvis.
An invited person signs in once and can open every component for that
ranch; the membership role still decides what they can change.

Jarvis is the sign-in component: :func:`jarvis_login` is the one path in
this module that calls :func:`ranchbrain.sso_login.login` (which issues
the session through the store). Every component — Jarvis included —
opens its view of the same session through :func:`authorize`, which
never touches the session store and therefore never calls ``issue``.
"""

from __future__ import annotations

from datetime import datetime
from typing import Iterable, TypeVar

from ranchbrain.sso_login import SessionStore, login
from ranchbrain.tenancy import (
    TenantContext,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    User,
    VerifiedPrincipal,
)

IssuedSessionT = TypeVar("IssuedSessionT")

SIGN_IN_COMPONENT = "jarvis"

COMPONENTS: tuple[str, ...] = (
    "property_manager",
    "livestock",
    "finance",
    "ranchos_app",
    "ranchos_tv",
    "dashboard",
    "jarvis",
)


def jarvis_login(
    *,
    principal: VerifiedPrincipal,
    users: Iterable[User],
    memberships: Iterable[TenantMembership],
    environment: str,
    store: SessionStore[IssuedSessionT],
    requested_tenant_id: str | None = None,
    now: datetime | None = None,
) -> tuple[IssuedSessionT, TenantContext]:
    """Sign in once through Jarvis and issue the one ranch session."""

    return login(
        principal=principal,
        users=users,
        memberships=memberships,
        environment=environment,
        store=store,
        requested_tenant_id=requested_tenant_id,
        now=now,
    )


def authorize(
    session: object,
    context: TenantContext,
    component: str,
) -> TenantContext:
    """Authorize one component against the already-issued ranch session.

    Returns the same :class:`TenantContext` object it was given. A
    session bound to a different ranch, or a component name outside
    :data:`COMPONENTS`, fails closed. Role checks stay with
    :func:`ranchbrain.tenancy.require_capability` on the returned
    context. This function takes no store and issues nothing.
    """

    if component not in COMPONENTS:
        raise TenancyError(
            f"unknown RanchOS component {component!r}",
            TenancyErrorCode.TENANT_NOT_AUTHORIZED,
        )
    if not isinstance(context, TenantContext):
        raise TenancyError("component authorization requires a tenant context")
    session_tenant_id = _session_tenant_id(session)
    if session_tenant_id != context.tenant_id:
        raise TenancyError(
            "session ranch does not match the authorization context",
            TenancyErrorCode.TENANT_NOT_AUTHORIZED,
        )
    return context


def _session_tenant_id(session: object) -> str:
    if isinstance(session, dict):
        tenant_id = session.get("tenant_id")
    else:
        tenant_id = getattr(session, "tenant_id", None)
    if not isinstance(tenant_id, str) or not tenant_id.strip():
        raise TenancyError("session carries no ranch binding")
    return tenant_id
