"""Behavioral tests for the in-memory LivestockReadModelV1 repository.

Transport-free: no HTTP, driver, URL, credentials, or mutation ingress.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone
from unittest.mock import patch

from ranchbrain.livestock_read_model import (
    ENABLED_LIVESTOCK_FACT_FAMILIES_V1,
    LivestockFactFamily,
    LivestockFactFamilyAvailability,
    LivestockFactStatus,
    LivestockReadErrorCode,
    LivestockReadMediaType,
    LivestockReadQueryError,
    LivestockReadQueryV1,
    LivestockReadService,
    LivestockReadUnavailableError,
)
from ranchbrain.livestock_read_repository import (
    InMemoryLivestockReadRepository,
    default_livestock_read_catalogs,
)
from ranchbrain.tenancy import (
    Capability,
    ROLE_CAPABILITIES,
    TenantContext,
    TenantContextResolver,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
)


NOW = datetime(2026, 3, 20, 12, tzinfo=timezone.utc)
PRINCIPAL = VerifiedPrincipal("user-1", "owner")
FORBIDDEN_FAMILIES = (
    LivestockFactFamily.CARE_TASK_LIST,
    LivestockFactFamily.FEED_STATUS,
    LivestockFactFamily.COST_SNAPSHOT,
)
EXPECTED_SPECIES = frozenset(
    {"cattle", "bison", "goat", "sheep", "chicken", "pig", "horse", "pet"}
)
EXPECTED_PRODUCTION = frozenset({"beef", "dairy", "breeding", "layer", "companion"})
EXPECTED_BREEDS = frozenset(
    {"angus", "american_bison", "boer", "dorper", "rhode_island_red", "quarter_horse"}
)


def _membership(tenant_id: str) -> TenantMembership:
    return TenantMembership("user-1", tenant_id, "owner", True, NOW)


def _service(
    repository: InMemoryLivestockReadRepository | None = None,
) -> LivestockReadService:
    return LivestockReadService(
        TenantContextResolver((_membership("tenant-a"), _membership("tenant-b"))),
        repository or InMemoryLivestockReadRepository(),
        now=NOW,
    )


def _query(
    family: LivestockFactFamily,
    *,
    page_size: int = 50,
    cursor: str | None = None,
) -> LivestockReadQueryV1:
    return LivestockReadQueryV1(family, page_size=page_size, cursor=cursor)


class LivestockReadRepositoryTests(unittest.TestCase):
    def test_tenant_a_animal_list_does_not_include_tenant_b_animals(self) -> None:
        page = _service().load(PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST))
        ids = {item.animal.id for item in page.items}
        self.assertEqual(page.tenant_id, "tenant-a")
        self.assertEqual(page.availability, LivestockFactFamilyAvailability.AVAILABLE)
        self.assertIn("sample-animal-cattle-angus-001", ids)
        self.assertNotIn("sample-animal-bison-004", ids)

    def test_tenant_b_animal_list_does_not_include_tenant_a_animals(self) -> None:
        page = _service().load(PRINCIPAL, "tenant-b", _query(LivestockFactFamily.ANIMAL_LIST))
        ids = {item.animal.id for item in page.items}
        self.assertEqual(page.tenant_id, "tenant-b")
        self.assertEqual(ids, {"sample-animal-bison-004"})

    def test_missing_capability_is_denied_before_repository_results(self) -> None:
        repository = InMemoryLivestockReadRepository()
        with patch.dict(ROLE_CAPABILITIES, {"owner": frozenset()}, clear=False):
            with self.assertRaises(TenancyError) as raised:
                _service(repository).load(
                    PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST)
                )
        self.assertEqual(raised.exception.code, TenancyErrorCode.LIVESTOCK_READ_FORBIDDEN)

    def test_care_feed_and_cost_families_are_unavailable_without_payloads(self) -> None:
        service = _service()
        for family in FORBIDDEN_FAMILIES:
            with self.subTest(family=family):
                page = service.load(PRINCIPAL, "tenant-a", _query(family))
                self.assertEqual(page.availability, LivestockFactFamilyAvailability.UNAVAILABLE)
                self.assertEqual(page.items, ())
                self.assertIsNone(page.next_cursor)
                self.assertEqual(page.projection_revision, "unavailable")

    def test_page_size_bounds_returned_items(self) -> None:
        page = _service().load(
            PRINCIPAL,
            "tenant-a",
            _query(LivestockFactFamily.ANIMAL_LIST, page_size=2),
        )
        self.assertEqual(len(page.items), 2)
        self.assertIsNotNone(page.next_cursor)

    def test_cursor_walks_same_tenant_and_family_without_overlap(self) -> None:
        service = _service()
        first = service.load(
            PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST, page_size=3)
        )
        second = service.load(
            PRINCIPAL,
            "tenant-a",
            _query(LivestockFactFamily.ANIMAL_LIST, page_size=3, cursor=first.next_cursor),
        )
        first_ids = [item.id for item in first.items]
        second_ids = [item.id for item in second.items]
        self.assertTrue(first.next_cursor)
        self.assertNotIn("tenant-a", first.next_cursor)
        self.assertNotIn("tenant-b", first.next_cursor)
        self.assertEqual(len(set(first_ids) & set(second_ids)), 0)
        self.assertGreaterEqual(len(first_ids) + len(second_ids), 4)

    def test_cursor_from_another_tenant_fails_closed(self) -> None:
        service = _service()
        tenant_a = service.load(
            PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST, page_size=2)
        )
        with self.assertRaises(LivestockReadUnavailableError) as raised:
            service.load(
                PRINCIPAL,
                "tenant-b",
                _query(LivestockFactFamily.ANIMAL_LIST, page_size=2, cursor=tenant_a.next_cursor),
            )
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH)

    def test_cursor_from_another_family_fails_closed(self) -> None:
        repository = InMemoryLivestockReadRepository()
        context = TenantContext(
            "user-1", "tenant-a", "owner", frozenset({Capability.LIVESTOCK_READ})
        )
        list_page = repository.load(context, _query(LivestockFactFamily.ANIMAL_LIST, page_size=2))
        with self.assertRaises(LivestockReadUnavailableError) as raised:
            repository.load(
                context,
                _query(
                    LivestockFactFamily.ANIMAL_DETAIL,
                    page_size=2,
                    cursor=list_page.next_cursor,
                ),
            )
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.PROJECTION_FAMILY_MISMATCH)

    def test_unknown_cursor_is_a_query_error(self) -> None:
        with self.assertRaises(LivestockReadQueryError):
            _service().load(
                PRINCIPAL,
                "tenant-a",
                _query(LivestockFactFamily.ANIMAL_LIST, cursor="not-a-server-cursor"),
            )

    def test_catalog_covers_hub_sample_species_production_and_breeds(self) -> None:
        service = _service()
        page_a = service.load(PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST))
        page_b = service.load(PRINCIPAL, "tenant-b", _query(LivestockFactFamily.ANIMAL_LIST))
        animals = tuple(item.animal for item in (*page_a.items, *page_b.items))
        species = {animal.species for animal in animals}
        production = {animal.production for animal in animals}
        breeds = {animal.breed for animal in animals if animal.breed is not None}
        self.assertTrue(EXPECTED_SPECIES.issubset(species))
        self.assertTrue(EXPECTED_PRODUCTION.issubset(production))
        self.assertTrue(EXPECTED_BREEDS.issubset(breeds))

    def test_identifier_is_optional_and_not_required_for_inclusion(self) -> None:
        page = _service().load(PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST))
        by_id = {item.animal.id: item.animal for item in page.items}
        self.assertEqual(by_id["sample-animal-cattle-angus-001"].identifier, "Tag SA-104")
        self.assertIsNone(by_id["sample-animal-cattle-breeding-003"].identifier)
        self.assertIsNone(by_id["sample-animal-goat-boer-005"].identifier)

    def test_lifecycle_status_is_independent_of_fact_freshness(self) -> None:
        page = _service().load(PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST))
        by_id = {item.animal.id: item for item in page.items}
        archived = by_id["sample-animal-cattle-breeding-003"]
        stale = by_id["sample-animal-goat-boer-005"]
        incomplete = by_id["sample-animal-pet-010"]
        self.assertEqual(archived.animal.status, "archived")
        self.assertEqual(archived.status, LivestockFactStatus.CURRENT)
        self.assertEqual(stale.animal.status, "active")
        self.assertEqual(stale.status, LivestockFactStatus.STALE)
        self.assertEqual(incomplete.animal.status, "active")
        self.assertEqual(incomplete.status, LivestockFactStatus.INCOMPLETE)

    def test_provenance_is_synthetic_timezone_aware_and_not_labeled_live(self) -> None:
        page = _service().load(PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_LIST))
        item = page.items[0]
        self.assertEqual(item.provenance.source_type, "synthetic_dev_fixture")
        self.assertTrue(item.provenance.source_id)
        self.assertTrue(item.provenance.source_version)
        self.assertIsNotNone(item.provenance.observed_at.tzinfo)
        self.assertNotIn("live", item.provenance.source_type.lower())
        self.assertNotEqual(page.projection_revision, "live")

    def test_json_v1_media_type_is_the_service_accept(self) -> None:
        page = _service().load(
            PRINCIPAL,
            "tenant-a",
            _query(LivestockFactFamily.HERD_OVERVIEW),
            accept=LivestockReadMediaType.JSON_V1,
        )
        self.assertEqual(page.availability, LivestockFactFamilyAvailability.AVAILABLE)
        self.assertEqual(len(page.items), 1)
        self.assertIsNotNone(page.items[0].herd_overview)
        self.assertIsNone(page.items[0].animal)
        self.assertEqual(page.items[0].herd_overview.active_animal_count, 8)
        self.assertEqual(page.items[0].herd_overview.routine_lifecycle_count, 0)

    def test_animal_detail_uses_animal_payload_not_care_feed_or_cost(self) -> None:
        page = _service().load(
            PRINCIPAL, "tenant-a", _query(LivestockFactFamily.ANIMAL_DETAIL, page_size=1)
        )
        self.assertEqual(page.items[0].fact_family, LivestockFactFamily.ANIMAL_DETAIL)
        self.assertIsNotNone(page.items[0].animal)
        self.assertIsNone(page.items[0].herd_overview)

    def test_unknown_tenant_catalog_fails_closed(self) -> None:
        repository = InMemoryLivestockReadRepository()
        context = TenantContext(
            "user-1", "tenant-missing", "owner", frozenset({Capability.LIVESTOCK_READ})
        )
        with self.assertRaises(LivestockReadUnavailableError) as raised:
            repository.load(context, _query(LivestockFactFamily.ANIMAL_LIST))
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH)

    def test_default_catalogs_are_tenant_keyed_and_disjoint(self) -> None:
        catalogs = default_livestock_read_catalogs()
        a_ids = {animal.id for animal in catalogs["tenant-a"].animals}
        b_ids = {animal.id for animal in catalogs["tenant-b"].animals}
        self.assertTrue(a_ids.isdisjoint(b_ids))
        self.assertEqual(catalogs["tenant-a"].tenant_id, "tenant-a")
        self.assertEqual(catalogs["tenant-b"].tenant_id, "tenant-b")

    def test_enabled_families_remain_the_read_model_set(self) -> None:
        self.assertEqual(
            ENABLED_LIVESTOCK_FACT_FAMILIES_V1,
            frozenset(
                {
                    LivestockFactFamily.HERD_OVERVIEW,
                    LivestockFactFamily.ANIMAL_LIST,
                    LivestockFactFamily.ANIMAL_DETAIL,
                }
            ),
        )


if __name__ == "__main__":
    unittest.main()
