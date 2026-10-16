"""Fail-closed PropertyManager tenancy primitives.

Server-side tenant context for PropertyManager repository calls, following
``ranchbrain_app/docs/MULTI_TENANCY_DESIGN.md``. Storage- and transport
agnostic: no database driver, no environment reads, no fixture principal.
Tests construct these values directly; the live API must resolve them from
verified identity and authoritative membership, never from configuration.

Glossary: a ranch is a ``ranchos.tenants`` row, a person is a
``ranchos.users`` row, access is a ``ranchos.tenant_memberships`` row.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from uuid import UUID


class TenancyErrorCode(str, Enum):
    TENANT_CONTEXT_INVALID = "tenant_context_invalid"
    TENANT_NOT_AUTHORIZED = "tenant_not_authorized"
    CAPABILITY_FORBIDDEN = "tenant_capability_forbidden"


class TenancyError(PermissionError):
    """A missing, malformed, stale, ambiguous, or unauthorized tenancy fact."""

    def __init__(self, message: str, code: TenancyErrorCode = TenancyErrorCode.TENANT_CONTEXT_INVALID):
        super().__init__(message)
        self.code = code


class Role(str, Enum):
    OWNER = "owner"
    MANAGER = "manager"
    VIEWER = "viewer"


class Capability(str, Enum):
    READ = "property.read"
    WRITE = "property.write"
    ADMIN = "property.admin"


ROLE_CAPABILITIES: dict[Role, frozenset[Capability]] = {
    Role.OWNER: frozenset({Capability.READ, Capability.WRITE, Capability.ADMIN}),
    Role.MANAGER: frozenset({Capability.READ, Capability.WRITE}),
    Role.VIEWER: frozenset({Capability.READ}),
}


def _require_uuid(value: str | None, field: str) -> str:
    if value is None or not str(value).strip():
        raise TenancyError(f"{field} is required", TenancyErrorCode.TENANT_CONTEXT_INVALID)
    try:
        return str(UUID(str(value).strip()))
    except ValueError:
        raise TenancyError(f"{field} is not a UUID", TenancyErrorCode.TENANT_CONTEXT_INVALID) from None


def _require_text(value: str | None, field: str) -> str:
    if value is None or not str(value).strip():
        raise TenancyError(f"{field} is required", TenancyErrorCode.TENANT_CONTEXT_INVALID)
    return str(value).strip()


@dataclass(frozen=True)
class VerifiedPrincipal:
    """Immutable identity established by the authoritative ingress.

    Carries no tenant, role, or capability: Ranch OS resolves those from its
    authoritative store. In a deployed runtime only the verified ingress may
    construct this type; tests construct it directly.
    """

    id: str
    principal_type: str
    environment: str
    lifecycle_state: str
    assurance_profile: str
    session_reference: str
    valid_from: datetime
    valid_until: datetime
    correlation_id: str

    def __post_init__(self) -> None:
        principal_id = _require_uuid(self.id, "principal id")
        environment = _require_text(self.environment, "environment")
        object.__setattr__(self, "id", principal_id)
        object.__setattr__(self, "environment", environment)
        _require_text(self.principal_type, "principal type")
        _require_text(self.lifecycle_state, "lifecycle state")
        _require_text(self.assurance_profile, "assurance profile")
        _require_text(self.session_reference, "session reference")
        _require_text(self.correlation_id, "correlation id")
        for label, moment in (("valid_from", self.valid_from), ("valid_until", self.valid_until)):
            if not isinstance(moment, datetime) or moment.tzinfo is None:
                raise TenancyError(f"{label} must be a timezone-aware datetime")
        if self.valid_until <= self.valid_from:
            raise TenancyError("validity window must be positive")
        if self.lifecycle_state.strip() != "active":
            raise TenancyError("principal is not active", TenancyErrorCode.TENANT_NOT_AUTHORIZED)

    def require_current(self, now: datetime) -> None:
        """Fail closed unless the principal is valid at ``now``."""
        if now.tzinfo is None:
            raise TenancyError("reference time must be timezone-aware")
        if not (self.valid_from <= now <= self.valid_until):
            raise TenancyError("principal validity window does not cover now", TenancyErrorCode.TENANT_NOT_AUTHORIZED)


@dataclass(frozen=True)
class TenantMembership:
    tenant_id: str
    user_id: str
    role: Role
    status: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "tenant_id", _require_uuid(self.tenant_id, "membership tenant_id"))
        object.__setattr__(self, "user_id", _require_uuid(self.user_id, "membership user_id"))
        if not isinstance(self.role, Role):
            raise TenancyError("membership role is invalid")
        _require_text(self.status, "membership status")

    @property
    def is_active(self) -> bool:
        return self.status.strip() == "active"


@dataclass(frozen=True)
class TenantContext:
    """Server-derived authorization scope for one request.

    Every tenant-owned repository method requires one. Callers never pass an
    arbitrary tenant filter: the context carries the single active tenant.
    """

    principal: VerifiedPrincipal
    environment: str
    tenant_id: str
    user_id: str
    membership_role: Role
    correlation_id: str

    def __post_init__(self) -> None:
        if not isinstance(self.principal, VerifiedPrincipal):
            raise TenancyError("tenant context requires a verified principal")
        if self.environment.strip() != self.principal.environment:
            raise TenancyError("tenant context environment must match the principal")
        _require_uuid(self.tenant_id, "tenant_id")
        _require_uuid(self.user_id, "user_id")
        if not isinstance(self.membership_role, Role):
            raise TenancyError("tenant context role is invalid")
        if self.correlation_id.strip() != self.principal.correlation_id.strip():
            raise TenancyError("tenant context correlation id must match the principal")

    @classmethod
    def resolve(
        cls,
        *,
        principal: VerifiedPrincipal,
        user_id: str,
        memberships: list[TenantMembership],
        requested_tenant_id: str | None,
        now: datetime | None = None,
    ) -> TenantContext:
        """Resolve the single active tenant for an authenticated principal.

        The requested tenant is only a routing hint: it must match an active
        membership or the call fails. One active membership may proceed
        without a hint. Several memberships require an explicit selection.
        There is no recent-tenant, default-tenant, or global-view fallback.
        """
        principal.require_current(now or datetime.now(timezone.utc))
        resolved_user = _require_uuid(user_id, "user_id")
        active = [m for m in memberships if m.user_id == resolved_user and m.is_active]
        if not active:
            raise TenancyError("no active membership for this principal", TenancyErrorCode.TENANT_NOT_AUTHORIZED)
        if requested_tenant_id is None or not str(requested_tenant_id).strip():
            if len(active) != 1:
                raise TenancyError(
                    "an explicit tenant selection is required",
                    TenancyErrorCode.TENANT_NOT_AUTHORIZED,
                )
            chosen = active[0]
        else:
            hint = _require_uuid(requested_tenant_id, "requested tenant_id")
            matches = [m for m in active if m.tenant_id == hint]
            if len(matches) != 1:
                raise TenancyError(
                    "requested tenant is not authorized for this principal",
                    TenancyErrorCode.TENANT_NOT_AUTHORIZED,
                )
            chosen = matches[0]
        return cls(
            principal=principal,
            environment=principal.environment,
            tenant_id=chosen.tenant_id,
            user_id=resolved_user,
            membership_role=chosen.role,
            correlation_id=principal.correlation_id,
        )


def require_capability(context: TenantContext, capability: Capability) -> None:
    """Fail closed unless the context role grants the capability."""
    if capability not in ROLE_CAPABILITIES[context.membership_role]:
        raise TenancyError(
            f"role {context.membership_role.value} is not granted {capability.value}",
            TenancyErrorCode.CAPABILITY_FORBIDDEN,
        )
