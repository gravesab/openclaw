from datetime import datetime, timedelta, timezone
import unittest
from unittest.mock import patch

from ranchbrain.livestock_read_model import (
    LIVESTOCK_READ_MEDIA_TYPE,
    MAX_LIVESTOCK_READ_PAGE_SIZE,
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
    LivestockReadService,
    LivestockReadUnavailableError,
)
from ranchbrain.tenancy import ROLE_CAPABILITIES, Role, Tenant, TenantContextResolver, TenantMembership, TenancyError, User, VerifiedPrincipal


NOW = datetime(2026, 8, 29, 17, tzinfo=timezone.utc)


def principal() -> VerifiedPrincipal:
    return VerifiedPrincipal("principal-a", "human", "development", "active", "mfa-fresh", "session-a", NOW - timedelta(minutes=5), NOW + timedelta(minutes=5), "request-a")


def animal_item() -> LivestockReadItemV1:
    animal = LivestockAnimalFact("animal-1", "Juniper", "cattle", "beef", "angus", "active", "Tag RB-104", NOW)
    provenance = LivestockFactProvenance("fixture", "animal-1", "fixture-1", NOW)
    return LivestockReadItemV1("animal-1", LivestockFactFamily.ANIMAL_LIST, LivestockFactStatus.CURRENT, provenance, animal=animal)


def page(tenant_id: str, *, family=LivestockFactFamily.ANIMAL_LIST, availability=LivestockFactFamilyAvailability.AVAILABLE, items=None, next_cursor=None) -> LivestockReadPage:
    if items is None:
        items = (animal_item(),) if family is LivestockFactFamily.ANIMAL_LIST and availability is LivestockFactFamilyAvailability.AVAILABLE else ()
    return LivestockReadPage(tenant_id, family, availability, items, next_cursor, NOW, "fixture-1")


class RecordingRepository:
    def __init__(self, pages: dict[str, LivestockReadPage]):
        self.pages = pages
        self.calls = []

    def load(self, context, query):
        self.calls.append((context, query))
        return self.pages[context.tenant_id]


def service(repository: RecordingRepository) -> LivestockReadService:
    resolver = TenantContextResolver(
        environment="development",
        users=[User("user-a", "principal-a"), User("user-b", "principal-b")],
        tenants=[Tenant("tenant-a", "a", "A"), Tenant("tenant-b", "b", "B")],
        memberships=[TenantMembership("tenant-a", "user-a", Role.VIEWER), TenantMembership("tenant-b", "user-b", Role.VIEWER)],
    )
    return LivestockReadService(resolver, repository)


class LivestockReadModelTests(unittest.TestCase):
    def test_authorized_read_returns_tenant_bound_provenance_bearing_facts(self):
        repository = RecordingRepository({"tenant-a": page("tenant-a"), "tenant-b": page("tenant-b")})
        query = LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, page_size=25)

        response = service(repository).load(principal=principal(), requested_tenant_id="tenant-a", query=query, accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW)

        self.assertEqual(response.read_model_version, "LivestockReadModelV1")
        self.assertEqual(response.tenant_id, "tenant-a")
        self.assertEqual(response.items[0].animal.species_code, "cattle")
        self.assertEqual(response.items[0].provenance.source_id, "animal-1")
        self.assertEqual(response.items[0].status, LivestockFactStatus.CURRENT)
        self.assertEqual([context.tenant_id for context, _ in repository.calls], ["tenant-a"])

    def test_cross_tenant_selection_stops_before_repository_lookup(self):
        repository = RecordingRepository({"tenant-a": page("tenant-a"), "tenant-b": page("tenant-b")})
        with self.assertRaises(TenancyError):
            service(repository).load(principal=principal(), requested_tenant_id="tenant-b", query=LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10), accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW)
        self.assertEqual(repository.calls, [])

    def test_livestock_capability_denial_stops_before_repository_lookup(self):
        repository = RecordingRepository({"tenant-a": page("tenant-a"), "tenant-b": page("tenant-b")})
        resolver = TenantContextResolver(
            environment="development",
            users=[User("user-a", "principal-a")],
            tenants=[Tenant("tenant-a", "a", "A")],
            memberships=[TenantMembership("tenant-a", "user-a", Role.VIEWER)],
        )
        with patch.dict(ROLE_CAPABILITIES, {Role.VIEWER: frozenset()}):
            with self.assertRaisesRegex(TenancyError, "lacks"):
                LivestockReadService(resolver, repository).load(
                    principal=principal(), requested_tenant_id="tenant-a", query=LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10), accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW
                )
        self.assertEqual(repository.calls, [])

    def test_mismatched_projection_tenant_is_a_fail_closed_error(self):
        repository = RecordingRepository({"tenant-a": page("tenant-b"), "tenant-b": page("tenant-b")})
        with self.assertRaises(LivestockReadUnavailableError) as raised:
            service(repository).load(principal=principal(), requested_tenant_id="tenant-a", query=LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10), accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW)
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.PROJECTION_TENANT_MISMATCH)

    def test_unavailable_family_is_non_sensitive_empty_result(self):
        repository = RecordingRepository({
            "tenant-a": page("tenant-a", family=LivestockFactFamily.CARE_HISTORY, availability=LivestockFactFamilyAvailability.UNAVAILABLE),
            "tenant-b": page("tenant-b", family=LivestockFactFamily.CARE_HISTORY, availability=LivestockFactFamilyAvailability.UNAVAILABLE),
        })
        response = service(repository).load(
            principal=principal(), requested_tenant_id="tenant-a", query=LivestockReadQueryV1(LivestockFactFamily.CARE_HISTORY, 10), accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW
        )
        self.assertEqual(response.availability, LivestockFactFamilyAvailability.UNAVAILABLE)
        self.assertEqual(response.items, ())
        self.assertIsNone(response.next_cursor)
        self.assertEqual(repository.calls, [])

    def test_empty_page_is_successful_end_of_results(self):
        repository = RecordingRepository({
            "tenant-a": page("tenant-a", items=()),
            "tenant-b": page("tenant-b", items=()),
        })
        response = service(repository).load(
            principal=principal(), requested_tenant_id="tenant-a", query=LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10), accept=LIVESTOCK_READ_MEDIA_TYPE, now=NOW
        )
        self.assertEqual(response.items, ())
        self.assertIsNone(response.next_cursor)

    def test_closed_query_vocabulary_and_bounds_reject_before_lookup(self):
        with self.assertRaises(LivestockReadQueryError) as raised:
            LivestockReadQueryV1("other", 10)
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.QUERY_INVALID)
        with self.assertRaises(LivestockReadQueryError):
            LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, MAX_LIVESTOCK_READ_PAGE_SIZE + 1)
        with self.assertRaises(LivestockReadQueryError):
            LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10, cursor="")

        repository = RecordingRepository({"tenant-a": page("tenant-a"), "tenant-b": page("tenant-b")})
        with self.assertRaises(LivestockReadQueryError) as raised:
            service(repository).load(principal=principal(), requested_tenant_id="tenant-a", query=LivestockReadQueryV1(LivestockFactFamily.ANIMAL_LIST, 10), accept="application/json", now=NOW)
        self.assertEqual(raised.exception.code, LivestockReadErrorCode.QUERY_INVALID)
        self.assertEqual(repository.calls, [])

    def test_unknown_catalog_values_are_rejected(self):
        with self.assertRaises(ValueError):
            LivestockAnimalFact("animal-2", "Unknown", "other", "beef", None, "active", None, NOW)
        with self.assertRaises(ValueError):
            LivestockAnimalFact("animal-2", "Unknown", "chicken", "beef", None, "active", None, NOW)
        with self.assertRaises(ValueError):
            LivestockAnimalFact("animal-2", "Unknown", "cattle", "beef", "boer", "active", None, NOW)
        with self.assertRaises(ValueError):
            LivestockAnimalFact("animal-3", "Milo", "pet", "beef", None, "active", None, NOW)
        with self.assertRaises(ValueError):
            LivestockAnimalFact("animal-3", "Milo", "pet", "companion", "angus", "active", None, NOW)
        pet = LivestockAnimalFact("animal-3", "Milo", "pet", "companion", None, "active", None, NOW)
        self.assertEqual(pet.species_code, "pet")
        self.assertEqual(pet.production_type_code, "companion")
        self.assertIsNone(pet.breed_code)
