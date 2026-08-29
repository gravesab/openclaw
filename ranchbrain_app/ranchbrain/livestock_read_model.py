"""Canonical, tenant-scoped Ranch OS Livestock read/query contract.

This module is transport- and storage-agnostic. A deployed OpenClaw-authoritative
ingress is the only future path that may construct a ``VerifiedPrincipal``;
this boundary resolves its ``TenantContext`` before a repository sees a query.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Protocol

from ranchbrain.tenancy import Capability, TenantContext, TenantContextResolver, VerifiedPrincipal


LIVESTOCK_READ_MEDIA_TYPE = "application/vnd.ranchos.livestock-read+json;version=1"
MAX_LIVESTOCK_READ_PAGE_SIZE = 100
PRODUCTION_TYPES_BY_SPECIES = {
    "cattle": frozenset({"beef", "dairy", "breeding"}),
    "bison": frozenset({"beef", "breeding"}),
    "goat": frozenset({"beef", "dairy", "breeding"}),
    "sheep": frozenset({"breeding", "companion"}),
    "chicken": frozenset({"layer", "broiler", "breeding"}),
    "pig": frozenset({"breeding", "companion"}),
    "horse": frozenset({"breeding", "companion"}),
}
BREED_SPECIES = {
    "angus": "cattle",
    "hereford": "cattle",
    "american_bison": "bison",
    "boer": "goat",
    "dorper": "sheep",
    "rhode_island_red": "chicken",
    "yorkshire": "pig",
    "quarter_horse": "horse",
}


class LivestockFactFamily(str, Enum):
    """The complete V1 query vocabulary; callers cannot invent a family."""

    HERD_OVERVIEW = "herd_overview"
    ANIMAL_LIST = "animal_list"
    ANIMAL_DETAIL = "animal_detail"
    IDENTIFIERS = "identifiers"
    ROUTINE_LIFECYCLE_EVENTS = "routine_lifecycle_events"
    CARE_HISTORY = "care_history"
    FEEDING_CONSUMPTION_HISTORY = "feeding_consumption_history"
    OPERATIONAL_COST_ATTRIBUTIONS = "operational_cost_attributions"


ENABLED_LIVESTOCK_FACT_FAMILIES_V1 = frozenset(
    {
        LivestockFactFamily.HERD_OVERVIEW,
        LivestockFactFamily.ANIMAL_LIST,
        LivestockFactFamily.ANIMAL_DETAIL,
    }
)


class LivestockFactStatus(str, Enum):
    """Explicit result confidence; unavailable facts are never fabricated."""

    CURRENT = "current"
    STALE = "stale"
    INCOMPLETE = "incomplete"
    CONFLICTING = "conflicting"


class LivestockFactFamilyAvailability(str, Enum):
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"


class LivestockReadErrorCode(str, Enum):
    QUERY_INVALID = "livestock_query_invalid"
    PROJECTION_TENANT_MISMATCH = "livestock_projection_tenant_mismatch"


class LivestockReadQueryError(ValueError):
    """A stable, non-sensitive rejected-query error."""

    code = LivestockReadErrorCode.QUERY_INVALID


class LivestockReadUnavailableError(RuntimeError):
    """An authorized query could not safely return its tenant-bound page."""

    code = LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH


@dataclass(frozen=True)
class LivestockReadQueryV1:
    """A bounded, cursor-only request; there is intentionally no offset."""

    fact_family: LivestockFactFamily
    page_size: int
    cursor: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.fact_family, LivestockFactFamily):
            raise LivestockReadQueryError("Livestock fact family is not supported")
        if not isinstance(self.page_size, int) or isinstance(self.page_size, bool):
            raise LivestockReadQueryError("Livestock page size must be an integer")
        if not 1 <= self.page_size <= MAX_LIVESTOCK_READ_PAGE_SIZE:
            raise LivestockReadQueryError("Livestock page size is outside the allowed bound")
        if self.cursor is not None and (not isinstance(self.cursor, str) or not self.cursor.strip()):
            raise LivestockReadQueryError("Livestock cursor must be an opaque non-empty value")


@dataclass(frozen=True)
class LivestockFactProvenance:
    source_type: str
    source_id: str
    source_version: str
    observed_at: datetime

    def __post_init__(self) -> None:
        if not all(isinstance(value, str) and value.strip() for value in (self.source_type, self.source_id, self.source_version)):
            raise ValueError("Livestock fact provenance requires stable source references")
        if self.observed_at.tzinfo is None or self.observed_at.utcoffset() is None:
            raise ValueError("Livestock fact provenance timestamps must be timezone-aware")


@dataclass(frozen=True)
class LivestockAnimalFact:
    id: str
    display_name: str
    species_code: str
    production_type_code: str
    breed_code: str | None
    status: str
    identifier_summary: str | None
    observed_at: datetime

    def __post_init__(self) -> None:
        if not self.id or not self.display_name:
            raise ValueError("animal facts require an id and display name")
        if self.species_code not in PRODUCTION_TYPES_BY_SPECIES:
            raise ValueError("animal facts require an approved species code")
        if self.production_type_code not in PRODUCTION_TYPES_BY_SPECIES[self.species_code]:
            raise ValueError("animal facts require a compatible production type code")
        if self.breed_code is not None and BREED_SPECIES.get(self.breed_code) != self.species_code:
            raise ValueError("animal facts require a compatible breed code")
        if self.status not in {"active", "archived"}:
            raise ValueError("animal facts require an approved status")
        if self.observed_at.tzinfo is None or self.observed_at.utcoffset() is None:
            raise ValueError("animal fact timestamps must be timezone-aware")


@dataclass(frozen=True)
class LivestockDashboardSummary:
    active_animal_count: int
    routine_lifecycle_count: int
    generated_at: datetime

    def __post_init__(self) -> None:
        if self.active_animal_count < 0 or self.routine_lifecycle_count < 0:
            raise ValueError("dashboard counts cannot be negative")
        if self.generated_at.tzinfo is None or self.generated_at.utcoffset() is None:
            raise ValueError("dashboard timestamps must be timezone-aware")


@dataclass(frozen=True)
class LivestockReadItemV1:
    """A fact envelope with mandatory provenance and explicit status."""

    id: str
    fact_family: LivestockFactFamily
    status: LivestockFactStatus
    provenance: LivestockFactProvenance
    animal: LivestockAnimalFact | None = None
    herd_overview: LivestockDashboardSummary | None = None

    def __post_init__(self) -> None:
        if not self.id:
            raise ValueError("Livestock read items require an id")
        if not isinstance(self.fact_family, LivestockFactFamily) or not isinstance(self.status, LivestockFactStatus):
            raise ValueError("Livestock read items require closed family and status values")
        if not isinstance(self.provenance, LivestockFactProvenance):
            raise ValueError("Livestock read items require tenant-safe provenance")
        if self.fact_family is LivestockFactFamily.HERD_OVERVIEW:
            if self.herd_overview is None or self.animal is not None:
                raise ValueError("herd overview items require only a herd overview payload")
        elif self.fact_family in {LivestockFactFamily.ANIMAL_LIST, LivestockFactFamily.ANIMAL_DETAIL}:
            if self.animal is None or self.herd_overview is not None:
                raise ValueError("animal items require only an animal payload")
        else:
            raise ValueError("unavailable fact families cannot return item payloads")


@dataclass(frozen=True)
class LivestockReadPage:
    tenant_id: str
    fact_family: LivestockFactFamily
    availability: LivestockFactFamilyAvailability
    items: tuple[LivestockReadItemV1, ...]
    next_cursor: str | None
    source_as_of: datetime
    projection_revision: str

    def __post_init__(self) -> None:
        if not self.tenant_id or not self.projection_revision:
            raise ValueError("Livestock pages require tenant binding and revision")
        if not isinstance(self.fact_family, LivestockFactFamily) or not isinstance(self.availability, LivestockFactFamilyAvailability):
            raise ValueError("Livestock pages require closed family and availability values")
        if self.source_as_of.tzinfo is None or self.source_as_of.utcoffset() is None:
            raise ValueError("Livestock page timestamps must be timezone-aware")
        if self.next_cursor is not None and (not isinstance(self.next_cursor, str) or not self.next_cursor.strip()):
            raise ValueError("Livestock next cursor must be opaque and non-empty")
        if self.availability is LivestockFactFamilyAvailability.UNAVAILABLE and (self.items or self.next_cursor is not None):
            raise ValueError("unavailable fact families cannot return facts or a cursor")
        if any(item.fact_family is not self.fact_family for item in self.items):
            raise ValueError("Livestock page items must match the requested fact family")


class LivestockReadModelV1(Protocol):
    """Canonical repository contract; implementations receive only resolved context."""

    def load(self, context: TenantContext, query: LivestockReadQueryV1) -> LivestockReadPage: ...


@dataclass(frozen=True)
class LivestockReadResponse:
    schema_version: str
    read_model_version: str
    tenant_id: str
    environment: str
    correlation_id: str
    fact_family: LivestockFactFamily
    availability: LivestockFactFamilyAvailability
    items: tuple[LivestockReadItemV1, ...]
    next_cursor: str | None
    source_as_of: datetime
    projection_revision: str


class LivestockReadService:
    """Authorizes a canonical V1 query before repository access."""

    def __init__(self, resolver: TenantContextResolver, repository: LivestockReadModelV1):
        self._resolver = resolver
        self._repository = repository

    def load(
        self,
        *,
        principal: VerifiedPrincipal,
        requested_tenant_id: str | None,
        query: LivestockReadQueryV1,
        accept: str,
        now: datetime | None = None,
    ) -> LivestockReadResponse:
        if accept != LIVESTOCK_READ_MEDIA_TYPE:
            raise LivestockReadQueryError("unsupported Livestock read media type")
        current_time = now or datetime.now(timezone.utc)
        context = self._resolver.resolve(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=Capability.LIVESTOCK_READ,
            now=current_time,
        )
        if query.fact_family not in ENABLED_LIVESTOCK_FACT_FAMILIES_V1:
            return LivestockReadResponse(
                schema_version="v1",
                read_model_version="LivestockReadModelV1",
                tenant_id=context.tenant_id,
                environment=context.environment,
                correlation_id=context.correlation_id,
                fact_family=query.fact_family,
                availability=LivestockFactFamilyAvailability.UNAVAILABLE,
                items=(),
                next_cursor=None,
                source_as_of=current_time,
                projection_revision="unavailable",
            )
        page = self._repository.load(context, query)
        if page.tenant_id != context.tenant_id:
            raise LivestockReadUnavailableError("Livestock projection tenant binding failed")
        if page.fact_family is not query.fact_family:
            raise LivestockReadUnavailableError("Livestock projection fact family binding failed")
        if len(page.items) > query.page_size:
            raise LivestockReadUnavailableError("Livestock projection page bound failed")
        return LivestockReadResponse(
            schema_version="v1",
            read_model_version="LivestockReadModelV1",
            tenant_id=context.tenant_id,
            environment=context.environment,
            correlation_id=context.correlation_id,
            fact_family=page.fact_family,
            availability=page.availability,
            items=page.items,
            next_cursor=page.next_cursor,
            source_as_of=page.source_as_of,
            projection_revision=page.projection_revision,
        )
