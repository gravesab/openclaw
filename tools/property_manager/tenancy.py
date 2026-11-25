"""PropertyManager tenancy: re-exports of the canonical Ranch OS types.

The canonical session types live in ``ranchbrain_app/ranchbrain/tenancy.py``
and are shared by property, livestock, and finance. This module defines no
role map and no principal type of its own; it only re-exports the canonical
names so PropertyManager call sites keep one import.

Glossary: a ranch is a ``ranchos.tenants`` row, a person is a
``ranchos.users`` row, access is a ``ranchos.tenant_memberships`` row.
"""

from ranchbrain_app.ranchbrain.tenancy import (
    ROLE_CAPABILITIES,
    Capability,
    Role,
    TenancyError,
    TenancyErrorCode,
    Tenant,
    TenantContext,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
    VerifiedPrincipalVerifier,
    open_session,
    require_capability,
    require_tenant_id,
)

__all__ = [
    "ROLE_CAPABILITIES",
    "Capability",
    "Role",
    "TenancyError",
    "TenancyErrorCode",
    "Tenant",
    "TenantContext",
    "TenantContextResolver",
    "TenantMembership",
    "User",
    "VerifiedPrincipal",
    "VerifiedPrincipalVerifier",
    "open_session",
    "require_capability",
    "require_tenant_id",
]
