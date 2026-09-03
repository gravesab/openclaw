"""Fail-closed Ranch OS tenancy primitives.

These types are intentionally storage- and transport-agnostic. A deployed
adapter must create ``VerifiedPrincipal`` only after OpenClaw has verified the
identity; callers cannot create authority by supplying a tenant identifier.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Iterable, Protocol


class TenancyErrorCode(str, Enum):
    TENANT_CONTEXT_INVALID = "tenant_context_invalid"
    TENANT_NOT_AUTHORIZED = "tenant_not_authorized"
    CAPABILITY_FORBIDDEN = "tenant_capability_forbidden"
    LIVESTOCK_READ_FORBIDDEN = "livestock_read_forbidden"


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
    MEMORY_READ = "memory.read"
    LIVESTOCK_READ = "livestock.read"
    LIVESTOCK_ANIMAL_WRITE = "livestock.animal.write"
    LIVESTOCK_IDENTIFIER_WRITE = "livestock.identifier.write"
    LIVESTOCK_LIFECYCLE_WRITE = "livestock.lifecycle.write"
    LIVESTOCK_LIFECYCLE_CORRECT = "livestock.lifecycle.correct"
    TV_TODAY_READ = "tv.today.read"


ROLE_CAPABILITIES: dict[Role, frozenset[Capability]] = {
    Role.OWNER: frozenset(
        {
            Capability.MEMORY_READ,
            Capability.LIVESTOCK_READ,
            Capability.LIVESTOCK_ANIMAL_WRITE,
            Capability.LIVESTOCK_IDENTIFIER_WRITE,
            Capability.LIVESTOCK_LIFECYCLE_WRITE,
            Capability.LIVESTOCK_LIFECYCLE_CORRECT,
            Capability.TV_TODAY_READ,
        }
    ),
    Role.MANAGER: frozenset(
        {
            Capability.MEMORY_READ,
            Capability.LIVESTOCK_READ,
            Capability.LIVESTOCK_ANIMAL_WRITE,
            Capability.LIVESTOCK_IDENTIFIER_WRITE,
            Capability.LIVESTOCK_LIFECYCLE_WRITE,
            Capability.TV_TODAY_READ,
        }
    ),
    Role.VIEWER: frozenset({Capability.MEMORY_READ, Capability.LIVESTOCK_READ, Capability.TV_TODAY_READ}),
}


@dataclass(frozen=True)
class VerifiedPrincipal:
    """An identity assertion verified by the OpenClaw-authoritative adapter."""

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
        if not isinstance(self.id, str) or not self.id.strip():
            raise TenancyError("verified principal requires a non-empty immutable id")
        if not isinstance(self.environment, str) or not self.environment.strip():
            raise TenancyError("verified principal requires a non-empty environment")
        _require_aware_timestamp(self.valid_from, "valid_from")
        _require_aware_timestamp(self.valid_until, "valid_until")
        if not _precedes(self.valid_from, self.valid_until):
            raise TenancyError("verified principal validity window is invalid")

    def is_active_at(self, now: datetime) -> bool:
        _require_aware_timestamp(now, "now")
        try:
            return (
                self.lifecycle_state == "active"
                and self.valid_from <= now
                and now < self.valid_until
            )
        except (TypeError, ValueError, OverflowError) as error:
            raise TenancyError("verified principal validity window is invalid") from error


def _require_aware_timestamp(value: object, field_name: str) -> None:
    """Reject malformed time facts as tenancy failures before comparison."""

    if not isinstance(value, datetime):
        raise TenancyError(f"verified principal {field_name} must be a datetime")
    try:
        is_aware = value.tzinfo is not None and value.utcoffset() is not None
    except (TypeError, ValueError):
        is_aware = False
    if not is_aware:
        raise TenancyError(f"verified principal {field_name} must be timezone-aware")


def _precedes(left: datetime, right: datetime) -> bool:
    try:
        return left < right
    except (TypeError, ValueError, OverflowError) as error:
        raise TenancyError("verified principal validity window is invalid") from error


class VerifiedPrincipalVerifier(Protocol):
    """Boundary implemented by the deployed OpenClaw identity adapter only."""

    def verify(self, assertion: str) -> VerifiedPrincipal: ...


@dataclass(frozen=True)
class Tenant:
    id: str
    slug: str
    display_name: str
    status: str = "active"


@dataclass(frozen=True)
class User:
    id: str
    principal_id: str
    status: str = "active"


@dataclass(frozen=True)
class TenantMembership:
    tenant_id: str
    user_id: str
    role: Role
    status: str = "active"


@dataclass(frozen=True)
class TenantContext:
    """Server-derived authorization context required by tenant repositories."""

    tenant_id: str
    user_id: str
    principal_id: str
    role: Role
    environment: str
    correlation_id: str


class TenantContextResolver:
    """Resolves membership facts; it never accepts client authority as fact."""

    def __init__(self, *, environment: str, users: Iterable[User], tenants: Iterable[Tenant], memberships: Iterable[TenantMembership]):
        self._environment = environment
        self._users_by_principal = {user.principal_id: user for user in users}
        self._tenants_by_id = {tenant.id: tenant for tenant in tenants}
        self._memberships = tuple(memberships)

    def resolve(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        capability: Capability,
        now: datetime | None = None,
    ) -> TenantContext:
        current_time = now or datetime.now(timezone.utc)
        if principal.environment != self._environment or not principal.is_active_at(current_time):
            raise TenancyError("principal is not active in this environment")
        if not requested_tenant_id:
            raise TenancyError("an explicit tenant selection is required")

        user = self._users_by_principal.get(principal.id)
        tenant = self._tenants_by_id.get(requested_tenant_id)
        if user is None or user.status != "active" or tenant is None or tenant.status != "active":
            raise TenancyError("tenant context is not authorized", TenancyErrorCode.TENANT_NOT_AUTHORIZED)

        matches = [
            membership
            for membership in self._memberships
            if membership.tenant_id == tenant.id
            and membership.user_id == user.id
            and membership.status == "active"
        ]
        if not matches:
            raise TenancyError("tenant context is not authorized", TenancyErrorCode.TENANT_NOT_AUTHORIZED)
        if len(matches) != 1:
            raise TenancyError("tenant membership is ambiguous", TenancyErrorCode.TENANT_CONTEXT_INVALID)
        membership = matches[0]
        if capability not in ROLE_CAPABILITIES[membership.role]:
            code = (
                TenancyErrorCode.LIVESTOCK_READ_FORBIDDEN
                if capability is Capability.LIVESTOCK_READ
                else TenancyErrorCode.CAPABILITY_FORBIDDEN
            )
            raise TenancyError("membership lacks the requested capability", code)

        return TenantContext(
            tenant_id=tenant.id,
            user_id=user.id,
            principal_id=principal.id,
            role=membership.role,
            environment=principal.environment,
            correlation_id=principal.correlation_id,
        )
