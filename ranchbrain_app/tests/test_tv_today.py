from datetime import datetime, timedelta, timezone
import unittest
from unittest.mock import patch

from ranchbrain.tenancy import (
    ROLE_CAPABILITIES,
    Capability,
    Role,
    Tenant,
    TenantContext,
    TenantContextResolver,
    TenantMembership,
    TenancyError,
    User,
    VerifiedPrincipal,
)
from ranchbrain.tv_today import (
    COMPILE_TIME_TODAY_PROJECTIONS,
    TODAY_MEDIA_TYPE,
    CompileTimeTodayFixtureRepository,
    TodayCard,
    TodayProjection,
    TodayService,
    TodayUnavailableError,
)


NOW = datetime(2026, 8, 27, 14, tzinfo=timezone.utc)


def principal(id="principal-a", **overrides):
    values = {
        "id": id,
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": "session-a",
        "valid_from": NOW - timedelta(minutes=5),
        "valid_until": NOW + timedelta(minutes=5),
        "correlation_id": "request-a",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


def projection(tenant_id):
    return TodayProjection(
        tenant_id=tenant_id,
        tenant_display_name=f"{tenant_id} ranch",
        date="2026-08-27",
        time_zone="America/Chicago",
        label="Thursday, August 27",
        cards=(TodayCard("livestock-summary", "livestock", "Livestock", "18 active animals", NOW),),
        generated_at=NOW,
        source_as_of=NOW,
        fresh_until=NOW + timedelta(minutes=1),
        projection_revision="fixture-1",
    )


class RecordingRepository:
    def __init__(self, projections):
        self.projections = projections
        self.contexts = []

    def load(self, context):
        self.contexts.append(context)
        return self.projections[context.tenant_id]


class RecordingResolver:
    def __init__(self, inner):
        self.inner = inner
        self.capabilities = []

    def resolve(self, *, principal, requested_tenant_id, capability, now=None):
        self.capabilities.append(capability)
        return self.inner.resolve(
            principal=principal,
            requested_tenant_id=requested_tenant_id,
            capability=capability,
            now=now,
        )


class FixedContextResolver:
    def __init__(self, context):
        self.context = context

    def resolve(self, **kwargs):
        return self.context


def resolver(memberships=None):
    return TenantContextResolver(
        environment="development",
        users=[
            User("user-a", "principal-a"),
            User("user-b", "principal-b"),
            User("user-c", "principal-c"),
        ],
        tenants=[Tenant("tenant-a", "a", "A"), Tenant("tenant-b", "b", "B")],
        memberships=memberships
        or [
            TenantMembership("tenant-a", "user-a", Role.VIEWER),
            TenantMembership("tenant-b", "user-b", Role.VIEWER),
            TenantMembership("tenant-a", "user-c", Role.VIEWER),
            TenantMembership("tenant-b", "user-c", Role.VIEWER),
        ],
    )


def service(repository=None, memberships=None):
    return TodayService(resolver(memberships=memberships), repository)


def load(handler, *, id="principal-a", requested_tenant_id="tenant-a", accept=TODAY_MEDIA_TYPE):
    return handler.load(
        principal=principal(id),
        requested_tenant_id=requested_tenant_id,
        accept=accept,
        now=NOW,
    )


class TodayFoundationTests(unittest.TestCase):
    def test_authorized_viewer_receives_only_compile_time_tenant_a_projection(self):
        recorded = RecordingResolver(resolver())
        response = TodayService(recorded).load(
            principal=principal(), requested_tenant_id="tenant-a", accept=TODAY_MEDIA_TYPE, now=NOW
        )

        self.assertEqual(recorded.capabilities, [Capability.TV_TODAY_READ])
        self.assertEqual(response.version, "v1")
        self.assertEqual(response.tenant_id, "tenant-a")
        self.assertEqual(response.tenant_display_name, "North Creek Ranch")
        self.assertEqual(
            [card.value for card in response.cards],
            ["Clear at North Creek", "18 active animals", "North Creek gates closed"],
        )
        self.assertNotIn("South Ridge", response.tenant_display_name)
        self.assertTrue(all("South Ridge" not in card.value for card in response.cards))
        self.assertEqual(response.correlation_id, "request-a")
        self.assertEqual(COMPILE_TIME_TODAY_PROJECTIONS["tenant-a"].projection_revision, "compile-time-v1")

    def test_authorized_viewer_receives_only_compile_time_tenant_b_projection(self):
        response = load(service(), id="principal-b", requested_tenant_id="tenant-b")

        self.assertEqual(response.tenant_id, "tenant-b")
        self.assertEqual(response.tenant_display_name, "South Ridge Ranch")
        self.assertEqual(
            [card.value for card in response.cards],
            ["Wind advisory at South Ridge", "7 active animals", "South Ridge water check due"],
        )
        self.assertNotIn("North Creek", response.tenant_display_name)
        self.assertTrue(all("North Creek" not in card.value for card in response.cards))

    def test_dual_member_receives_only_the_explicitly_selected_compile_time_projection(self):
        for tenant_id, display_name in (("tenant-a", "North Creek Ranch"), ("tenant-b", "South Ridge Ranch")):
            response = load(service(), id="principal-c", requested_tenant_id=tenant_id)
            self.assertEqual(response.tenant_id, tenant_id)
            self.assertEqual(response.tenant_display_name, display_name)

    def test_cross_tenant_selection_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})

        with self.assertRaisesRegex(TenancyError, "not authorized"):
            load(service(repository), requested_tenant_id="tenant-b")

        self.assertEqual(repository.contexts, [])

    def test_missing_tenant_selection_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})

        with self.assertRaisesRegex(TenancyError, "explicit tenant"):
            service(repository).load(
                principal=principal(), requested_tenant_id=None, accept=TODAY_MEDIA_TYPE, now=NOW
            )

        self.assertEqual(repository.contexts, [])

    def test_invalid_principal_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})
        for change in ({"environment": "production"}, {"lifecycle_state": "revoked"}, {"valid_until": NOW}):
            with self.subTest(change=change):
                repository.contexts.clear()
                with self.assertRaisesRegex(TenancyError, "not active"):
                    service(repository).load(
                        principal=principal(**change),
                        requested_tenant_id="tenant-a",
                        accept=TODAY_MEDIA_TYPE,
                        now=NOW,
                    )
                self.assertEqual(repository.contexts, [])

    def test_missing_principal_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})

        with self.assertRaisesRegex(TenancyError, "verified principal"):
            service(repository).load(
                principal=None, requested_tenant_id="tenant-a", accept=TODAY_MEDIA_TYPE, now=NOW
            )

        self.assertEqual(repository.contexts, [])

    def test_missing_capability_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})

        with patch.dict(ROLE_CAPABILITIES, {Role.VIEWER: frozenset({Capability.MEMORY_READ})}):
            with self.assertRaisesRegex(TenancyError, "lacks"):
                load(service(repository))

        self.assertEqual(repository.contexts, [])

    def test_resolver_wrong_tenant_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})
        handler = TodayService(
            FixedContextResolver(
                TenantContext("tenant-b", "user-a", "principal-a", Role.VIEWER, "development", "request-a")
            ),
            repository,
        )

        with self.assertRaisesRegex(TenancyError, "not authorized"):
            load(handler)

        self.assertEqual(repository.contexts, [])

    def test_invalid_resolved_context_stops_before_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})
        handler = TodayService(FixedContextResolver(None), repository)

        with self.assertRaisesRegex(TenancyError, "invalid"):
            load(handler)

        self.assertEqual(repository.contexts, [])

    def test_compile_time_catalog_rejects_invalid_context(self):
        with self.assertRaisesRegex(TenancyError, "invalid"):
            CompileTimeTodayFixtureRepository().load(None)

    def test_mismatched_fixture_binding_is_unavailable(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-b"), "tenant-b": projection("tenant-b")})

        with self.assertRaises(TodayUnavailableError):
            load(service(repository))

    def test_unsupported_media_type_stops_before_tenant_or_fixture_lookup(self):
        repository = RecordingRepository({"tenant-a": projection("tenant-a"), "tenant-b": projection("tenant-b")})

        with self.assertRaisesRegex(ValueError, "media type"):
            load(service(repository), accept="application/json")

        self.assertEqual(repository.contexts, [])


if __name__ == "__main__":
    unittest.main()
