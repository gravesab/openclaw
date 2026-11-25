"""Open a people-directory session with a client ranch hint that is not authority.

``open_people_session`` is the pure check the live ``POST /v1/session``
handler will call later. The hint (the same fact as the
``X-Ranch-Tenant`` header) never chooses the ranch: a missing, blank,
or matching hint delegates straight to
``PeopleDirectory.sign_in``, and any other hint fails closed before
``sign_in`` runs. Nothing here touches the network or storage.
"""

from __future__ import annotations

from ranchbrain.people_directory import PeopleDirectory
from ranchbrain.tenancy import (
    TenantContext,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
)


def open_people_session(
    *,
    directory: PeopleDirectory,
    email: str,
    principal: VerifiedPrincipal,
    store: object,
    client_tenant_id: str | None = None,
) -> tuple[object, TenantContext]:
    """Open this directory's ranch session, checking an optional client hint.

    ``None`` or a blank hint means no hint. A hint that equals
    ``directory.tenant_id`` after stripping also proceeds. Both call
    ``directory.sign_in(email, principal, store)`` — the hint is never
    passed into ``sign_in``, ``jarvis_login``, or ``sso_login.login``,
    so the directory's own failures (unknown email, revoked person,
    wrong or inactive principal, principal bound elsewhere) still
    apply. Any other hint raises ``tenant_not_authorized`` before
    ``sign_in`` runs.
    """
    if client_tenant_id is not None and client_tenant_id.strip():
        if client_tenant_id.strip() != directory.tenant_id:
            raise TenancyError(
                "client ranch hint is not authorized for this directory",
                TenancyErrorCode.TENANT_NOT_AUTHORIZED,
            )
    return directory.sign_in(email, principal, store)
