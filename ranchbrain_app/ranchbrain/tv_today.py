"""Transport-free Ranch OS Today foundation.

This module has no HTTP, configuration, persistence, cache, audit, or
identity-assertion parsing surface. A trusted ingress must verify identity
before supplying a ``VerifiedPrincipal``; tenant selection remains only a
request hint. After ``TenantContext`` resolution and exact ``tv.today.read``,
the boundary may return a compile-time fixture projection.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Protocol

from ranchbrain.tenancy import (
    ROLE_CAPABILITIES,
    Capability,
    TenantContext,
    TenantContextResolver,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
)


TODAY_MEDIA_TYPE = "application/vnd.ranchos.tv-today+json;version=1"
ALLOWED_CARD_KINDS = frozenset({"weather", "livestock", "property"})
_FIXTURE_AS_OF = datetime(2026, 8, 27, 12, tzinfo=timezone.utc)


class TodayUnavailableError(RuntimeError):
    """An authorized request could not safely obtain its projection."""


@dataclass(frozen=True)
class TodayCard:
    id: str
    kind: str
    title: str
    value: str
    as_of: datetime
    detail: str | None = None

    def __post_init__(self) -> None:
        if self.kind not in ALLOWED_CARD_KINDS:
            raise ValueError("unsupported Today card kind")
        if not self.id or not self.title or not self.value:
            raise ValueError("Today cards require an id, title, and value")
        if self.as_of.tzinfo is None:
            raise ValueError("Today card timestamps must be timezone-aware")


@dataclass(frozen=True)
class TodayProjection:
    tenant_id: str
    tenant_display_name: str
    date: str
    time_zone: str
    label: str
    cards: tuple[TodayCard, ...]
    generated_at: datetime
    source_as_of: datetime
    fresh_until: datetime
    projection_revision: str

    def __post_init__(self) -> None:
        if not self.tenant_id or not self.tenant_display_name or not self.projection_revision:
            raise ValueError("Today projections require tenant binding and revision")
        if not self.generated_at.tzinfo or not self.source_as_of.tzinfo or not self.fresh_until.tzinfo:
            raise ValueError("Today freshness timestamps must be timezone-aware")
        if self.fresh_until < self.generated_at:
            raise ValueError("fresh_until cannot precede generated_at")
        if len({card.id for card in self.cards}) != len(self.cards):
            raise ValueError("Today card ids must be unique")


class TodayProjectionRepository(Protocol):
    def load(self, context: TenantContext) -> TodayProjection: ...


@dataclass(frozen=True)
class TodayResponse:
    version: str
    tenant_id: str
    tenant_display_name: str
    date: str
    time_zone: str
    label: str
    cards: tuple[TodayCard, ...]
    generated_at: datetime
    source_as_of: datetime
    fresh_until: datetime
    correlation_id: str


def _compile_time_projection(
    *,
    tenant_id: str,
    display_name: str,
    weather_value: str,
    livestock_value: str,
    livestock_detail: str,
    property_value: str,
) -> TodayProjection:
    return TodayProjection(
        tenant_id=tenant_id,
        tenant_display_name=display_name,
        date="2026-08-27",
        time_zone="America/Chicago",
        label="Thursday, August 27",
        cards=(
            TodayCard("weather-summary", "weather", "Weather", weather_value, _FIXTURE_AS_OF),
            TodayCard(
                "livestock-summary",
                "livestock",
                "Livestock",
                livestock_value,
                _FIXTURE_AS_OF,
                livestock_detail,
            ),
            TodayCard("property-summary", "property", "Property", property_value, _FIXTURE_AS_OF),
        ),
        generated_at=_FIXTURE_AS_OF + timedelta(seconds=5),
        source_as_of=_FIXTURE_AS_OF,
        fresh_until=_FIXTURE_AS_OF + timedelta(minutes=1),
        projection_revision="compile-time-v1",
    )


COMPILE_TIME_TODAY_PROJECTIONS: dict[str, TodayProjection] = {
    "tenant-a": _compile_time_projection(
        tenant_id="tenant-a",
        display_name="North Creek Ranch",
        weather_value="Clear at North Creek",
        livestock_value="18 active animals",
        livestock_detail="2 routine items due today",
        property_value="North Creek gates closed",
    ),
    "tenant-b": _compile_time_projection(
        tenant_id="tenant-b",
        display_name="South Ridge Ranch",
        weather_value="Wind advisory at South Ridge",
        livestock_value="7 active animals",
        livestock_detail="No routine items due today",
        property_value="South Ridge water check due",
    ),
}


class CompileTimeTodayFixtureRepository:
    """In-memory catalog selected only after an authorized TenantContext."""

    def load(self, context: TenantContext) -> TodayProjection:
        if not isinstance(context, TenantContext) or not context.tenant_id:
            raise TenancyError("tenant context is invalid")
        projection = COMPILE_TIME_TODAY_PROJECTIONS.get(context.tenant_id)
        if projection is None:
            raise TodayUnavailableError("Today projection is unavailable")
        return projection


def _require_verified_principal(principal: object) -> VerifiedPrincipal:
    if not isinstance(principal, VerifiedPrincipal):
        raise TenancyError("verified principal is required")
    return principal


def _require_explicit_tenant_selection(requested_tenant_id: str | None) -> str:
    if not isinstance(requested_tenant_id, str) or not requested_tenant_id.strip():
        raise TenancyError("an explicit tenant selection is required")
    return requested_tenant_id


def _require_authorized_today_context(context: object, requested_tenant_id: str) -> TenantContext:
    if not isinstance(context, TenantContext) or not context.tenant_id:
        raise TenancyError("tenant context is invalid")
    if context.tenant_id != requested_tenant_id:
        raise TenancyError("tenant context is not authorized", TenancyErrorCode.TENANT_NOT_AUTHORIZED)
    if Capability.TV_TODAY_READ not in ROLE_CAPABILITIES.get(context.role, frozenset()):
        raise TenancyError("membership lacks the requested capability", TenancyErrorCode.CAPABILITY_FORBIDDEN)
    return context


class TodayService:
    """Authorizes a tenant-scoped compile-time Today projection."""

    def __init__(
        self,
        resolver: TenantContextResolver,
        repository: TodayProjectionRepository | None = None,
    ):
        self._resolver = resolver
        self._repository = repository or CompileTimeTodayFixtureRepository()

    def load(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        accept: str,
        now: datetime | None = None,
    ) -> TodayResponse:
        if accept != TODAY_MEDIA_TYPE:
            raise ValueError("unsupported Today media type")

        verified = _require_verified_principal(principal)
        selected_tenant_id = _require_explicit_tenant_selection(requested_tenant_id)
        context = _require_authorized_today_context(
            self._resolver.resolve(
                principal=verified,
                requested_tenant_id=selected_tenant_id,
                capability=Capability.TV_TODAY_READ,
                now=now or datetime.now(timezone.utc),
            ),
            selected_tenant_id,
        )
        projection = self._repository.load(context)
        if projection.tenant_id != context.tenant_id:
            raise TodayUnavailableError("Today projection tenant binding failed")

        return TodayResponse(
            version="v1",
            tenant_id=projection.tenant_id,
            tenant_display_name=projection.tenant_display_name,
            date=projection.date,
            time_zone=projection.time_zone,
            label=projection.label,
            cards=projection.cards,
            generated_at=projection.generated_at,
            source_as_of=projection.source_as_of,
            fresh_until=projection.fresh_until,
            correlation_id=context.correlation_id,
        )
