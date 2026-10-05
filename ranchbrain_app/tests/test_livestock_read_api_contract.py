"""Contract tests for the DEV Livestock read API. No service or database is started."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import inspect
import unittest
from pathlib import Path

from ranchbrain.livestock_read_api import (
    API_PREFIX,
    API_VERSION,
    FUTURE_GATES,
    HUB_AUTHORIZED_READ_PROVIDER,
    HUB_PROVIDER_OPERATIONS,
    HUB_READ_DASHBOARD_OPERATION,
    LIVE_AS_FIXTURE_MESSAGE,
    LIVESTOCK_READ_ROUTES,
    MUTATION_ROUTES,
    PROHIBITIONS,
    WRITE_VERBS,
    DataOrigin,
    FactFreshness,
    HubLivestockDashboardV1,
    LivestockAnimalReadFactV1,
    LivestockAuthorizedReadContract,
    LivestockProvenanceV1,
    LivestockReadContractError,
    LivestockReadContractErrorCode,
    LivestockReadResponseV1,
    LiveLifecycleStatus,
    authorize_livestock_read,
    require_origin_label,
)
from ranchbrain.tenancy import (
    Capability,
    Role,
    Tenant,
    TenantContextResolver,
    TenantMembership,
    TenancyError,
    TenancyErrorCode,
    User,
    VerifiedPrincipal,
)


NOW = datetime(2026, 9, 22, 14, tzinfo=timezone.utc)
OBSERVED = datetime(2026, 9, 21, 12, tzinfo=timezone.utc)
HERD_PATH = f"{API_PREFIX}/herd"
MODULE_PATH = Path(__file__).parents[1] / "ranchbrain" / "livestock_read_api.py"


def principal(**overrides) -> VerifiedPrincipal:
    values = {
        "id": "principal-a",
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


def resolver(memberships=None) -> TenantContextResolver:
    return TenantContextResolver(
        environment="development",
        users=(User(id="user-a", principal_id="principal-a"),),
        tenants=(
            Tenant(id="tenant-a", slug="a", display_name="North Ranch"),
            Tenant(id="tenant-b", slug="b", display_name="South Ranch"),
        ),
        memberships=memberships
        or (TenantMembership(tenant_id="tenant-a", user_id="user-a", role=Role.VIEWER),),
    )


def live_provenance(animal_id: str) -> LivestockProvenanceV1:
    return LivestockProvenanceV1(
        "ranch_record",
        animal_id,
        "read-model-v1",
        OBSERVED,
        DataOrigin.LIVE,
    )


def animal(
    tenant_id: str,
    animal_id: str,
    name: str,
    freshness: FactFreshness = FactFreshness.CURRENT,
) -> LivestockAnimalReadFactV1:
    return LivestockAnimalReadFactV1(
        animal_id,
        tenant_id,
        name,
        "cattle",
        "beef",
        "angus",
        LiveLifecycleStatus.ACTIVE,
        freshness,
        "ear_tag",
        f"tag-{animal_id}",
        live_provenance(animal_id),
    )


class MemorySource:
    def __init__(self, animals, names=None, leak: bool = False):
        self.animals = tuple(animals)
        self.names = names or {"tenant-a": "North Ranch", "tenant-b": "South Ranch"}
        self.leak = leak
        self.calls: list[tuple[str, str]] = []

    def tenant_display_name(self, tenant_id: str) -> str | None:
        self.calls.append(("name", tenant_id))
        return self.names.get(tenant_id)

    def animals_for_tenant(self, tenant_id: str) -> tuple[LivestockAnimalReadFactV1, ...]:
        self.calls.append(("animals", tenant_id))
        if self.leak:
            return self.animals
        return tuple(row for row in self.animals if row.tenant_id == tenant_id)


class LivestockReadApiContractTests(unittest.TestCase):
    def contract(self, source: MemorySource, memberships=None) -> LivestockAuthorizedReadContract:
        return LivestockAuthorizedReadContract(resolver(memberships), source)

    def read(
        self,
        source: MemorySource,
        tenant_id: str | None = "tenant-a",
        path: str = HERD_PATH,
        method: str = "GET",
        query=None,
        principal_value: VerifiedPrincipal | None = None,
        omit_principal: bool = False,
    ):
        return self.contract(source).execute(
            principal=None if omit_principal else principal() if principal_value is None else principal_value,
            requested_tenant_id=tenant_id,
            method=method,
            path=path,
            now=NOW,
            query=query,
        )

    def test_missing_tenant_context_fails_closed_without_reading(self):
        source = MemorySource((animal("tenant-a", "animal-a", "North Cow"),))
        for missing in (None, "", "   "):
            with self.subTest(missing=missing):
                with self.assertRaises(TenancyError) as denied:
                    self.read(source, tenant_id=missing)
                self.assertEqual(denied.exception.code, TenancyErrorCode.TENANT_CONTEXT_INVALID)
                self.assertIn("explicit tenant", str(denied.exception))
        self.assertEqual(source.calls, [])

    def test_missing_principal_and_inactive_membership_fail_closed(self):
        source = MemorySource((animal("tenant-a", "animal-a", "North Cow"),))
        with self.assertRaises(TenancyError) as unauthenticated:
            self.read(source, omit_principal=True)
        self.assertEqual(unauthenticated.exception.code, TenancyErrorCode.TENANT_CONTEXT_INVALID)
        self.assertIn("verified principal", str(unauthenticated.exception))

        inactive = (
            TenantMembership(
                tenant_id="tenant-a",
                user_id="user-a",
                role=Role.VIEWER,
                status="inactive",
            ),
        )
        with self.assertRaises(TenancyError) as denied:
            self.contract(source, inactive).execute(
                principal=principal(),
                requested_tenant_id="tenant-a",
                method="GET",
                path=HERD_PATH,
                now=NOW,
            )
        self.assertEqual(denied.exception.code, TenancyErrorCode.TENANT_NOT_AUTHORIZED)
        self.assertEqual(source.calls, [])

    def test_tenant_a_cannot_read_tenant_b(self):
        source = MemorySource(
            (
                animal("tenant-a", "animal-a", "North Cow"),
                animal("tenant-b", "animal-b", "South Cow"),
            )
        )
        with self.assertRaises(TenancyError) as denied:
            self.read(source, tenant_id="tenant-b")
        self.assertEqual(denied.exception.code, TenancyErrorCode.TENANT_NOT_AUTHORIZED)
        self.assertNotIn("South Cow", str(denied.exception))
        self.assertEqual(source.calls, [])

        herd = self.read(source)
        self.assertEqual(herd.body["herd_count"], 1)
        self.assertNotIn("South Cow", repr(herd.body))
        listed = self.read(source, path=f"{API_PREFIX}/animals")
        self.assertEqual([row["animal_id"] for row in listed.body["animals"]], ["animal-a"])
        for suffix in ("/animals/animal-b", "/animals/animal-b/provenance"):
            with self.assertRaises(LivestockReadContractError) as missing:
                self.read(source, path=f"{API_PREFIX}{suffix}")
            self.assertEqual(missing.exception.code, LivestockReadContractErrorCode.NOT_FOUND)
            self.assertNotIn("South Cow", str(missing.exception))
        self.assertNotIn(("animals", "tenant-b"), source.calls)

    def test_foreign_rows_from_the_authorized_tenant_fail_closed(self):
        source = MemorySource((animal("tenant-b", "animal-b", "South Cow"),), leak=True)
        with self.assertRaises(LivestockReadContractError) as denied:
            self.read(source)
        self.assertEqual(denied.exception.code, LivestockReadContractErrorCode.CROSS_TENANT)
        self.assertNotIn("South Cow", str(denied.exception))
        self.assertEqual(source.calls, [("animals", "tenant-a")])

    def test_no_write_endpoints_are_defined(self):
        self.assertEqual(MUTATION_ROUTES, ())
        self.assertEqual(tuple(route.method for route in LIVESTOCK_READ_ROUTES), ("GET", "GET", "GET", "GET"))
        self.assertTrue(set(WRITE_VERBS).isdisjoint(route.method for route in LIVESTOCK_READ_ROUTES))
        self.assertEqual(
            [route.path for route in LIVESTOCK_READ_ROUTES],
            [
                f"{API_PREFIX}/herd",
                f"{API_PREFIX}/animals",
                f"{API_PREFIX}/animals/{{animal_id}}",
                f"{API_PREFIX}/animals/{{animal_id}}/provenance",
            ],
        )
        for prohibition in (
            "direct_database_access_by_apple_clients",
            "unauthenticated_reads",
            "cross_tenant_results",
            "mutation_routes",
            "write_verbs",
        ):
            self.assertIn(prohibition, PROHIBITIONS)
        operations = [route.operation for route in LIVESTOCK_READ_ROUTES]
        for token in ("post", "patch", "put", "delete", "create", "update", "remove", "mutate", "write"):
            self.assertFalse(any(token in operation for operation in operations))
        source = MemorySource(())
        for verb in (*WRITE_VERBS, "post"):
            with self.assertRaises(LivestockReadContractError) as denied:
                self.read(source, method=verb)
            self.assertEqual(denied.exception.code, LivestockReadContractErrorCode.WRITE_PROHIBITED)
        self.assertEqual(source.calls, [])
        text = MODULE_PATH.read_text(encoding="utf-8")
        for banned in (
            "psycopg",
            "sqlite3",
            "http.server",
            "Flask",
            "FastAPI",
            "uvicorn",
            "socket.bind",
            "DATABASE_URL",
            "create_engine",
        ):
            self.assertNotIn(banned, text)

    def test_live_data_cannot_be_represented_as_fixture_data(self):
        with self.assertRaises(LivestockReadContractError) as relabeled:
            require_origin_label(DataOrigin.LIVE, DataOrigin.FIXTURE)
        self.assertEqual(str(relabeled.exception), LIVE_AS_FIXTURE_MESSAGE)
        self.assertEqual(relabeled.exception.code, LivestockReadContractErrorCode.FIXTURE_PROHIBITED)

        with self.assertRaises(LivestockReadContractError) as synthetic:
            LivestockProvenanceV1(
                "synthetic_dev_fixture",
                "sample-animal-cattle-angus-001",
                "sample-catalog-v1",
                OBSERVED,
                DataOrigin.LIVE,
            )
        self.assertEqual(str(synthetic.exception), LIVE_AS_FIXTURE_MESSAGE)

        with self.assertRaises(LivestockReadContractError) as dashboard:
            HubLivestockDashboardV1("North Ranch", 1, (), DataOrigin.FIXTURE)
        self.assertEqual(str(dashboard.exception), LIVE_AS_FIXTURE_MESSAGE)

        with self.assertRaises(LivestockReadContractError) as response:
            LivestockReadResponseV1(API_VERSION, "herd_summary", DataOrigin.FIXTURE, {})
        self.assertEqual(str(response.exception), LIVE_AS_FIXTURE_MESSAGE)

        fixture = LivestockProvenanceV1(
            "synthetic_dev_fixture",
            "sample-animal",
            "sample-catalog-v1",
            OBSERVED,
            DataOrigin.FIXTURE,
        )
        fact = LivestockAnimalReadFactV1(
            "sample-animal",
            "tenant-a",
            "Fixture Cow",
            "cattle",
            "beef",
            "angus",
            LiveLifecycleStatus.ACTIVE,
            FactFreshness.CURRENT,
            None,
            None,
            fixture,
        )
        source = MemorySource((fact,))
        with self.assertRaises(LivestockReadContractError) as served:
            self.read(source)
        self.assertEqual(served.exception.code, LivestockReadContractErrorCode.FIXTURE_PROHIBITED)
        self.assertNotIn("Fixture Cow", str(served.exception))

    def test_authorized_herd_maps_to_the_provider_dashboard_and_keeps_provenance(self):
        source = MemorySource(
            (
                animal("tenant-a", "animal-a", "North Cow", FactFreshness.STALE),
                animal("tenant-a", "animal-c", "Creek Cow", FactFreshness.CURRENT),
            )
        )
        herd = self.read(source)
        self.assertEqual(herd.api_version, API_VERSION)
        self.assertEqual(herd.origin, DataOrigin.LIVE)
        hub = herd.body["hub"]
        self.assertEqual(hub["provider"], HUB_AUTHORIZED_READ_PROVIDER)
        self.assertEqual(hub["operation"], HUB_READ_DASHBOARD_OPERATION)
        self.assertEqual(hub["session"], "live")
        dashboard = hub["dashboard"]
        self.assertEqual(set(dashboard), {"ranchName", "herdCount", "summaries"})
        self.assertEqual(dashboard["ranchName"], "North Ranch")
        self.assertEqual(dashboard["herdCount"], 2)
        freshness = next(card for card in dashboard["summaries"] if card["id"] == "fact-freshness")
        self.assertEqual(freshness["status"], "Care due")
        self.assertNotIn("DEV fixture", repr(herd.body))
        self.assertNotIn("developmentFixture", repr(herd.body))

        listed = self.read(source, path=f"{API_PREFIX}/animals")
        self.assertIsNone(listed.body["hub"]["operation"])
        self.assertEqual(listed.body["hub"]["reason"], "not_on_current_provider")
        detail = self.read(source, path=f"{API_PREFIX}/animals/animal-a")
        provenance = self.read(source, path=f"{API_PREFIX}/animals/animal-a/provenance")
        self.assertEqual(detail.body["animal"]["fact_freshness"], "stale")
        self.assertEqual(detail.body["animal"]["provenance"]["origin"], "live")
        self.assertEqual(provenance.body["fact_freshness"], "stale")
        self.assertEqual(
            set(provenance.body["provenance"]),
            {"source_type", "source_id", "source_version", "observed_at", "origin"},
        )
        self.assertEqual(provenance.body["provenance"]["source_type"], "ranch_record")

    def test_livestock_read_capability_is_required_and_query_cannot_override_tenant(self):
        seen: list[Capability] = []

        class RecordingResolver:
            def resolve(self, *, principal, requested_tenant_id, capability, now=None):
                seen.append(capability)
                return resolver().resolve(
                    principal=principal,
                    requested_tenant_id=requested_tenant_id,
                    capability=capability,
                    now=now,
                )

        source = MemorySource((animal("tenant-a", "animal-a", "North Cow"),))
        LivestockAuthorizedReadContract(RecordingResolver(), source).execute(
            principal=principal(),
            requested_tenant_id="tenant-a",
            method="GET",
            path=HERD_PATH,
            now=NOW,
        )
        self.assertEqual(seen, [Capability.LIVESTOCK_READ])

        denied_source = MemorySource((animal("tenant-a", "animal-a", "North Cow"),))

        class DeniedResolver:
            def resolve(self, *, principal, requested_tenant_id, capability, now=None):
                raise TenancyError(
                    "membership lacks the requested capability",
                    TenancyErrorCode.LIVESTOCK_READ_FORBIDDEN,
                )

        with self.assertRaises(TenancyError) as forbidden:
            LivestockAuthorizedReadContract(DeniedResolver(), denied_source).execute(
                principal=principal(),
                requested_tenant_id="tenant-a",
                method="GET",
                path=HERD_PATH,
                now=NOW,
            )
        self.assertEqual(forbidden.exception.code, TenancyErrorCode.LIVESTOCK_READ_FORBIDDEN)
        self.assertEqual(denied_source.calls, [])
        parameters = set(inspect.signature(authorize_livestock_read).parameters)
        self.assertEqual(parameters, {"resolver", "principal", "requested_tenant_id", "now"})

        with self.assertRaises(TenancyError) as override:
            self.read(MemorySource((animal("tenant-a", "animal-a", "North Cow"),)), query={"tenant_id": "tenant-b"})
        self.assertEqual(override.exception.code, TenancyErrorCode.TENANT_CONTEXT_INVALID)

    def test_future_gates_are_not_started_and_only_herd_maps_to_read_dashboard(self):
        self.assertEqual(
            [gate.name for gate in FUTURE_GATES],
            [
                "service_implementation",
                "disposable_tenant_isolation_proof",
                "dev_deployment",
                "authenticated_ranchos_integration",
                "physical_device_acceptance",
            ],
        )
        self.assertEqual([gate.order for gate in FUTURE_GATES], [1, 2, 3, 4, 5])
        self.assertTrue(all(gate.status == "not_started" for gate in FUTURE_GATES))
        self.assertEqual(HUB_PROVIDER_OPERATIONS["herd_summary"], HUB_READ_DASHBOARD_OPERATION)
        self.assertEqual(
            [operation for operation, mapped in HUB_PROVIDER_OPERATIONS.items() if mapped is None],
            ["animal_list", "animal_detail", "provenance"],
        )


if __name__ == "__main__":
    unittest.main()
