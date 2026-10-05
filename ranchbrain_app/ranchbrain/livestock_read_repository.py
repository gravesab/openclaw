"""In-memory LivestockReadModelV1 repository.

Transport-free. Callers must already have a server-derived TenantContext.
This module does not open HTTP, parse identity, connect to PostgreSQL, or
invent an endpoint.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from secrets import token_urlsafe
from typing import Mapping, assert_never

from ranchbrain.livestock_read_model import (
    ENABLED_LIVESTOCK_FACT_FAMILIES_V1,
    LivestockAnimalFact,
    LivestockDashboardSummary,
    LivestockFactFamily,
    LivestockFactFamilyAvailability,
    LivestockFactProvenance,
    LivestockFactStatus,
    LivestockReadErrorCode,
    LivestockReadItemV1,
    LivestockReadPage,
    LivestockReadQueryError,
    LivestockReadQueryV1,
    LivestockReadUnavailableError,
)
from ranchbrain.tenancy import TenantContext, TenancyError, TenancyErrorCode


_PROJECTION_REVISION = "in-memory-livestock-read-v1"
_SOURCE_AS_OF = datetime(2026, 9, 22, 12, tzinfo=timezone.utc)
_SYNTHETIC_SOURCE_TYPE = "synthetic_dev_fixture"


@dataclass(frozen=True)
class _CursorState:
    tenant_id: str
    fact_family: LivestockFactFamily
    offset: int


@dataclass(frozen=True)
class TenantLivestockCatalog:
    """Tenant-bound sample projection used only after TenantContext resolution."""

    tenant_id: str
    animals: tuple[LivestockAnimalFact, ...]
    herd_overview: LivestockDashboardSummary
    source_as_of: datetime = _SOURCE_AS_OF
    projection_revision: str = _PROJECTION_REVISION


def _animal(
    animal_id: str,
    display_name: str,
    species: str,
    production: str,
    breed: str | None,
    status: str,
    identifier: str | None,
    observed_at: datetime = _SOURCE_AS_OF,
) -> LivestockAnimalFact:
    return LivestockAnimalFact(
        animal_id,
        display_name,
        species,
        production,
        breed,
        status,
        identifier,
        observed_at,
    )


def _overview(active_animal_count: int, routine_lifecycle_count: int = 0) -> LivestockDashboardSummary:
    return LivestockDashboardSummary(active_animal_count, routine_lifecycle_count, _SOURCE_AS_OF)


def default_livestock_read_catalogs() -> dict[str, TenantLivestockCatalog]:
    tenant_a_animals = (
        _animal("sample-animal-cattle-angus-001", "Maple", "cattle", "beef", "angus", "active", "Tag SA-104"),
        _animal("sample-animal-cattle-dairy-002", "Clover", "cattle", "dairy", None, "active", "RFID 982"),
        _animal("sample-animal-cattle-breeding-003", "Ridge", "cattle", "breeding", None, "archived", None),
        _animal("sample-animal-goat-boer-005", "Willow", "goat", "dairy", "boer", "active", None),
        _animal("sample-animal-sheep-dorper-006", "Hill", "sheep", "breeding", "dorper", "active", None),
        _animal("sample-animal-chicken-layer-007", "Coop", "chicken", "layer", "rhode_island_red", "active", None),
        _animal("sample-animal-pig-breeding-008", "Pen", "pig", "breeding", None, "active", None),
        _animal("sample-animal-horse-quarter-009", "Pasture", "horse", "breeding", "quarter_horse", "active", None),
        _animal("sample-animal-pet-010", "Porch", "pet", "companion", None, "active", None),
    )
    tenant_b_animals = (
        _animal("sample-animal-bison-004", "Plains", "bison", "beef", "american_bison", "active", "Tag BZ-09"),
    )
    return {
        "tenant-a": TenantLivestockCatalog(
            tenant_id="tenant-a",
            animals=tenant_a_animals,
            herd_overview=_overview(active_animal_count=8),
        ),
        "tenant-b": TenantLivestockCatalog(
            tenant_id="tenant-b",
            animals=tenant_b_animals,
            herd_overview=_overview(active_animal_count=1),
        ),
    }


def _item_freshness(animal: LivestockAnimalFact) -> LivestockFactStatus:
    # Lifecycle status stays on the animal; freshness is independent sample confidence.
    if animal.id == "sample-animal-goat-boer-005":
        return LivestockFactStatus.STALE
    if animal.id == "sample-animal-pet-010":
        return LivestockFactStatus.INCOMPLETE
    return LivestockFactStatus.CURRENT


def _provenance(source_id: str) -> LivestockFactProvenance:
    return LivestockFactProvenance(
        _SYNTHETIC_SOURCE_TYPE,
        source_id,
        _PROJECTION_REVISION,
        _SOURCE_AS_OF,
    )


class InMemoryLivestockReadRepository:
    """Tenant-keyed in-memory projection. No driver, URL, or mutation surface."""

    def __init__(self, catalogs: Mapping[str, TenantLivestockCatalog] | None = None) -> None:
        self._catalogs = dict(catalogs or default_livestock_read_catalogs())
        self._cursors: dict[str, _CursorState] = {}

    def load(self, context: TenantContext, query: LivestockReadQueryV1) -> LivestockReadPage:
        if not isinstance(context, TenantContext) or not context.tenant_id:
            raise TenancyError("tenant context is invalid", TenancyErrorCode.TENANT_CONTEXT_INVALID)
        if not isinstance(query, LivestockReadQueryV1):
            raise LivestockReadQueryError("Livestock fact family is not supported")

        catalog = self._catalogs.get(context.tenant_id)
        if catalog is None or catalog.tenant_id != context.tenant_id:
            raise LivestockReadUnavailableError(
                "Livestock projection tenant binding failed",
                LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH,
            )

        if query.fact_family not in ENABLED_LIVESTOCK_FACT_FAMILIES_V1:
            return LivestockReadPage(
                catalog.tenant_id,
                query.fact_family,
                LivestockFactFamilyAvailability.UNAVAILABLE,
                (),
                None,
                catalog.source_as_of,
                "unavailable",
            )

        items = self._items_for_family(catalog, query.fact_family)
        start = self._offset_for_cursor(context.tenant_id, query)
        page_items = items[start : start + query.page_size]
        next_cursor = None
        remaining_start = start + len(page_items)
        if remaining_start < len(items):
            next_cursor = self._issue_cursor(context.tenant_id, query.fact_family, remaining_start)

        return LivestockReadPage(
            catalog.tenant_id,
            query.fact_family,
            LivestockFactFamilyAvailability.AVAILABLE,
            page_items,
            next_cursor,
            catalog.source_as_of,
            catalog.projection_revision,
        )

    def _items_for_family(
        self,
        catalog: TenantLivestockCatalog,
        fact_family: LivestockFactFamily,
    ) -> tuple[LivestockReadItemV1, ...]:
        match fact_family:
            case LivestockFactFamily.HERD_OVERVIEW:
                return (
                    LivestockReadItemV1(
                        f"{catalog.tenant_id}:herd-overview",
                        LivestockFactFamily.HERD_OVERVIEW,
                        LivestockFactStatus.CURRENT,
                        _provenance(f"{catalog.tenant_id}:herd-overview"),
                        herd_overview=catalog.herd_overview,
                    ),
                )
            case LivestockFactFamily.ANIMAL_LIST | LivestockFactFamily.ANIMAL_DETAIL:
                return tuple(
                    LivestockReadItemV1(
                        animal.id,
                        fact_family,
                        _item_freshness(animal),
                        _provenance(animal.id),
                        animal=animal,
                    )
                    for animal in catalog.animals
                )
            case LivestockFactFamily.CARE_TASK_LIST | LivestockFactFamily.FEED_STATUS | LivestockFactFamily.COST_SNAPSHOT:
                return ()
            case _ as unreachable:
                assert_never(unreachable)

    def _offset_for_cursor(self, tenant_id: str, query: LivestockReadQueryV1) -> int:
        if query.cursor is None:
            return 0
        state = self._cursors.get(query.cursor)
        if state is None:
            raise LivestockReadQueryError("Livestock cursor must be an opaque non-empty value")
        if state.tenant_id != tenant_id:
            raise LivestockReadUnavailableError(
                "Livestock projection tenant binding failed",
                LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH,
            )
        if state.fact_family is not query.fact_family:
            raise LivestockReadUnavailableError(
                "Livestock projection fact family binding failed",
                LivestockReadErrorCode.PROJECTION_FAMILY_MISMATCH,
            )
        return state.offset

    def _issue_cursor(self, tenant_id: str, fact_family: LivestockFactFamily, offset: int) -> str:
        token = token_urlsafe(16)
        self._cursors[token] = _CursorState(tenant_id, fact_family, offset)
        return token
