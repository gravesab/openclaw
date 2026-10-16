"""DEV-only RanchOS Hub Livestock read API contract.

This module is the versioned, read-only contract a future DEV service must
implement. It does not listen, deploy, migrate, store credentials, or change
authentication. Authorization is the existing fail-closed ``TenantContextResolver``
with ``Capability.LIVESTOCK_READ``.

The current Apple boundary is ``RanchOSLivestockAuthorizedReadProvider.readDashboard()``.
Only the herd summary maps to that method. This module does not modify the
Apple project, and it does not construct a provider, URL, or credential.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Literal, Mapping, Protocol, assert_never

from ranchbrain.tenancy import (
    Capability,
    TenantContext,
    TenantContextResolver,
    TenancyError,
    TenancyErrorCode,
    VerifiedPrincipal,
)

API_VERSION = "v1"
API_PREFIX = "/api/ranchos/livestock/v1"
HUB_AUTHORIZED_READ_PROVIDER = "RanchOSLivestockAuthorizedReadProvider"
HUB_READ_DASHBOARD_OPERATION = "readDashboard"
HUB_LIVE_SESSION = "live"
LIVE_AS_FIXTURE_MESSAGE = "live data cannot be represented as fixture data"
CONTRACT_STATUS = "dev_contract_only"

ALLOWED_METHODS = ("GET",)
WRITE_VERBS = ("POST", "PUT", "PATCH", "DELETE")
PROHIBITIONS = (
    "direct_database_access_by_apple_clients",
    "unauthenticated_reads",
    "cross_tenant_results",
    "mutation_routes",
    "write_verbs",
)
FORBIDDEN_QUERY_KEYS = frozenset(
    {"tenant_id", "tenant", "origin", "fixture", "fact_freshness", "classification"}
)
SYNTHETIC_SOURCE_TYPES = frozenset(
    {"synthetic_dev_fixture", "fixture", "development_fixture", "sample_catalog"}
)
IDENTIFIER_KINDS = frozenset({"ear_tag", "rfid", "brand", "registry_number"})
SPECIES_CODES = frozenset(
    {"chicken", "goat", "bison", "cattle", "sheep", "pig", "horse", "pet"}
)
PRODUCTION_TYPES_BY_SPECIES: dict[str, frozenset[str]] = {
    "cattle": frozenset({"beef", "dairy", "breeding"}),
    "bison": frozenset({"beef", "breeding"}),
    "goat": frozenset({"beef", "dairy", "breeding"}),
    "sheep": frozenset({"breeding", "companion"}),
    "chicken": frozenset({"layer", "broiler", "breeding"}),
    "pig": frozenset({"breeding", "companion"}),
    "horse": frozenset({"breeding", "companion"}),
    "pet": frozenset({"companion"}),
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


class LivestockReadContractErrorCode(str, Enum):
    WRITE_PROHIBITED = "livestock_read_write_prohibited"
    CROSS_TENANT = "livestock_read_cross_tenant"
    FIXTURE_PROHIBITED = "livestock_read_fixture_prohibited"
    NOT_FOUND = "livestock_read_not_found"
    INVALID = "livestock_read_invalid"


class LivestockReadContractError(Exception):
    def __init__(self, message: str, code: LivestockReadContractErrorCode):
        super().__init__(message)
        self.code = code


class FactFreshness(str, Enum):
    CURRENT = "current"
    STALE = "stale"
    INCOMPLETE = "incomplete"
    CONFLICTING = "conflicting"


class DataOrigin(str, Enum):
    LIVE = "live"
    FIXTURE = "fixture"


class HubSummaryStatus(str, Enum):
    """Raw values of ``RanchOSLivestockSummary.Status``. The Apple enum is unchanged."""

    CARE_DUE = "Care due"
    CURRENT = "Current"
    REVIEW = "Review"


class LiveLifecycleStatus(str, Enum):
    ACTIVE = "active"


@dataclass(frozen=True)
class FutureGate:
    order: int
    name: str
    status: str


FUTURE_GATES = (
    FutureGate(1, "service_implementation", "not_started"),
    FutureGate(2, "disposable_tenant_isolation_proof", "not_started"),
    FutureGate(3, "dev_deployment", "not_started"),
    FutureGate(4, "authenticated_ranchos_integration", "not_started"),
    FutureGate(5, "physical_device_acceptance", "not_started"),
)


@dataclass(frozen=True)
class LivestockReadRoute:
    method: str
    path: str
    operation: str
    hub_provider_operation: str | None

    def __post_init__(self) -> None:
        if self.method not in ALLOWED_METHODS:
            raise LivestockReadContractError(
                "livestock read routes accept GET only",
                LivestockReadContractErrorCode.WRITE_PROHIBITED,
            )
        if self.method in WRITE_VERBS or not self.path.startswith(f"{API_PREFIX}/"):
            raise LivestockReadContractError(
                "livestock read routes must be versioned GET paths",
                LivestockReadContractErrorCode.INVALID,
            )


LIVESTOCK_READ_ROUTES = (
    LivestockReadRoute("GET", f"{API_PREFIX}/herd", "herd_summary", HUB_READ_DASHBOARD_OPERATION),
    LivestockReadRoute("GET", f"{API_PREFIX}/animals", "animal_list", None),
    LivestockReadRoute(
        "GET",
        f"{API_PREFIX}/animals/{{animal_id}}",
        "animal_detail",
        None,
    ),
    LivestockReadRoute(
        "GET",
        f"{API_PREFIX}/animals/{{animal_id}}/provenance",
        "provenance",
        None,
    ),
)
MUTATION_ROUTES: tuple[LivestockReadRoute, ...] = ()
HUB_PROVIDER_OPERATIONS = {
    route.operation: route.hub_provider_operation for route in LIVESTOCK_READ_ROUTES
}
_ReadOperation = Literal["herd_summary", "animal_list", "animal_detail", "provenance"]


@dataclass(frozen=True)
class LivestockProvenanceV1:
    """Same fact fields as ``LivestockFactProvenance``, plus an origin label.

    ``source_type``, ``source_id``, ``source_version``, and ``observed_at`` match
    the read-model provenance stored on livestock facts. Origin is a contract
    label only. It is not a new database column.
    """

    source_type: str
    source_id: str
    source_version: str
    observed_at: datetime
    origin: DataOrigin

    def __post_init__(self) -> None:
        if not all(
            isinstance(value, str) and value.strip()
            for value in (self.source_type, self.source_id, self.source_version)
        ):
            raise LivestockReadContractError(
                "livestock provenance requires source type, id, and version",
                LivestockReadContractErrorCode.INVALID,
            )
        _require_aware(self.observed_at, "provenance observed_at")
        synthetic = _is_synthetic_source(self.source_type, self.source_version)
        if self.origin is DataOrigin.LIVE and synthetic:
            raise LivestockReadContractError(
                LIVE_AS_FIXTURE_MESSAGE,
                LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
            )
        if self.origin is DataOrigin.FIXTURE and not synthetic:
            raise LivestockReadContractError(
                LIVE_AS_FIXTURE_MESSAGE,
                LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
            )
        if self.origin is not DataOrigin.LIVE and self.origin is not DataOrigin.FIXTURE:
            assert_never(self.origin)


@dataclass(frozen=True)
class LivestockAnimalReadFactV1:
    animal_id: str
    tenant_id: str
    display_name: str
    species_code: str
    production_type_code: str
    breed_code: str | None
    lifecycle_status: LiveLifecycleStatus
    fact_freshness: FactFreshness
    identifier_kind: str | None
    identifier_value: str | None
    provenance: LivestockProvenanceV1

    def __post_init__(self) -> None:
        if not all(
            isinstance(value, str) and value.strip()
            for value in (self.animal_id, self.tenant_id, self.display_name)
        ):
            raise LivestockReadContractError(
                "livestock read fact requires animal, tenant, and display name",
                LivestockReadContractErrorCode.INVALID,
            )
        if self.species_code not in SPECIES_CODES:
            raise LivestockReadContractError(
                "livestock species is outside the read catalog",
                LivestockReadContractErrorCode.INVALID,
            )
        if self.production_type_code not in PRODUCTION_TYPES_BY_SPECIES[self.species_code]:
            raise LivestockReadContractError(
                "livestock production type is outside the read catalog",
                LivestockReadContractErrorCode.INVALID,
            )
        if self.breed_code is not None and BREED_SPECIES.get(self.breed_code) != self.species_code:
            raise LivestockReadContractError(
                "livestock breed is outside the read catalog",
                LivestockReadContractErrorCode.INVALID,
            )
        if self.species_code == "pet" and self.breed_code is not None:
            raise LivestockReadContractError(
                "pet livestock facts have no breed",
                LivestockReadContractErrorCode.INVALID,
            )
        if not isinstance(self.lifecycle_status, LiveLifecycleStatus):
            raise LivestockReadContractError(
                "live livestock lifecycle status must be active",
                LivestockReadContractErrorCode.INVALID,
            )
        if not isinstance(self.fact_freshness, FactFreshness):
            raise LivestockReadContractError(
                "livestock fact freshness is outside the read catalog",
                LivestockReadContractErrorCode.INVALID,
            )
        if not isinstance(self.provenance, LivestockProvenanceV1):
            raise LivestockReadContractError(
                "livestock read fact requires provenance",
                LivestockReadContractErrorCode.INVALID,
            )
        has_kind = self.identifier_kind is not None
        has_value = isinstance(self.identifier_value, str) and bool(self.identifier_value.strip())
        if has_kind != has_value or (self.identifier_kind is not None and self.identifier_kind not in IDENTIFIER_KINDS):
            raise LivestockReadContractError(
                "livestock identifier must be an active catalog kind and value, or absent",
                LivestockReadContractErrorCode.INVALID,
            )


class LivestockReadFactSource(Protocol):
    def tenant_display_name(self, tenant_id: str) -> str | None: ...

    def animals_for_tenant(self, tenant_id: str) -> tuple[LivestockAnimalReadFactV1, ...]: ...


@dataclass(frozen=True)
class HubLivestockSummaryCardV1:
    id: str
    title: str
    detail: str
    status: HubSummaryStatus


@dataclass(frozen=True)
class HubLivestockDashboardV1:
    """Field-compatible projection for ``RanchOSLivestockDashboard``."""

    ranch_name: str
    herd_count: int
    summaries: tuple[HubLivestockSummaryCardV1, ...]
    origin: DataOrigin

    def __post_init__(self) -> None:
        if self.origin is not DataOrigin.LIVE:
            raise LivestockReadContractError(
                LIVE_AS_FIXTURE_MESSAGE,
                LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
            )
        if not isinstance(self.ranch_name, str) or not self.ranch_name.strip() or self.herd_count < 0:
            raise LivestockReadContractError(
                "herd summary requires a ranch name and a non-negative count",
                LivestockReadContractErrorCode.INVALID,
            )


@dataclass(frozen=True)
class LivestockReadResponseV1:
    api_version: str
    operation: str
    origin: DataOrigin
    body: Mapping[str, object]

    def __post_init__(self) -> None:
        if self.api_version != API_VERSION or self.origin is not DataOrigin.LIVE:
            raise LivestockReadContractError(
                LIVE_AS_FIXTURE_MESSAGE,
                LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
            )


def require_origin_label(origin: DataOrigin, labeled_as: DataOrigin) -> DataOrigin:
    """Reject any relabeling between live facts and fixture facts."""

    if origin is DataOrigin.LIVE and labeled_as is DataOrigin.FIXTURE:
        raise LivestockReadContractError(
            LIVE_AS_FIXTURE_MESSAGE,
            LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
        )
    if origin is DataOrigin.FIXTURE and labeled_as is DataOrigin.LIVE:
        raise LivestockReadContractError(
            "fixture data cannot be represented as live data",
            LivestockReadContractErrorCode.FIXTURE_PROHIBITED,
        )
    if origin is labeled_as:
        return origin
    assert_never(origin)


def authorize_livestock_read(
    resolver: TenantContextResolver,
    principal: VerifiedPrincipal | None,
    requested_tenant_id: str | None,
    now: datetime | None,
) -> TenantContext:
    """Fail closed unless a verified principal has an active livestock.read membership."""

    if principal is None:
        raise TenancyError(
            "verified principal is required",
            TenancyErrorCode.TENANT_CONTEXT_INVALID,
        )
    if requested_tenant_id is None or not requested_tenant_id.strip():
        raise TenancyError(
            "an explicit tenant selection is required",
            TenancyErrorCode.TENANT_CONTEXT_INVALID,
        )
    return resolver.resolve(
        principal=principal,
        requested_tenant_id=requested_tenant_id.strip(),
        capability=Capability.LIVESTOCK_READ,
        now=_require_now(now),
    )


class LivestockAuthorizedReadContract:
    """In-process read contract. It has no transport, database, or write method."""

    def __init__(self, resolver: TenantContextResolver, source: LivestockReadFactSource):
        self._resolver = resolver
        self._source = source

    def execute(
        self,
        *,
        principal: VerifiedPrincipal | None,
        requested_tenant_id: str | None,
        method: str,
        path: str,
        now: datetime | None,
        query: Mapping[str, str] | None = None,
    ) -> LivestockReadResponseV1:
        _reject_write_verb(method)
        context = authorize_livestock_read(self._resolver, principal, requested_tenant_id, now)
        _reject_forbidden_query(query)
        operation, animal_id = _match_route(method, path)
        animals = self._load_authorized_animals(context.tenant_id)
        ranch_name = self._load_authorized_ranch_name(context.tenant_id)
        match operation:
            case "herd_summary":
                dashboard = build_herd_dashboard(ranch_name, animals)
                body: Mapping[str, object] = {
                    "ranch_name": dashboard.ranch_name,
                    "herd_count": dashboard.herd_count,
                    "summaries": [_summary_body(card) for card in dashboard.summaries],
                    "hub": _hub_envelope(dashboard),
                }
            case "animal_list":
                body = {
                    "herd_count": len(animals),
                    "animals": [_animal_body(animal) for animal in animals],
                    "hub": _unmapped_hub_operation("animal_list"),
                }
            case "animal_detail":
                body = {
                    "animal": _animal_body(_find_animal(animals, animal_id)),
                    "hub": _unmapped_hub_operation("animal_detail"),
                }
            case "provenance":
                animal = _find_animal(animals, animal_id)
                body = {
                    "animal_id": animal.animal_id,
                    "fact_freshness": animal.fact_freshness.value,
                    "provenance": _provenance_body(animal.provenance),
                    "hub": _unmapped_hub_operation("provenance"),
                }
            case _ as unreachable:
                assert_never(unreachable)
        return LivestockReadResponseV1(API_VERSION, operation, DataOrigin.LIVE, body)

    def _load_authorized_animals(self, tenant_id: str) -> tuple[LivestockAnimalReadFactV1, ...]:
        animals = tuple(self._source.animals_for_tenant(tenant_id))
        for animal in animals:
            if animal.tenant_id != tenant_id:
                raise LivestockReadContractError(
                    "cross-tenant livestock result",
                    LivestockReadContractErrorCode.CROSS_TENANT,
                )
            require_origin_label(animal.provenance.origin, DataOrigin.LIVE)
        return animals

    def _load_authorized_ranch_name(self, tenant_id: str) -> str:
        name = self._source.tenant_display_name(tenant_id)
        if not isinstance(name, str) or not name.strip():
            raise TenancyError(
                "authorized tenant display name is missing",
                TenancyErrorCode.TENANT_CONTEXT_INVALID,
            )
        return name.strip()


def build_herd_dashboard(
    ranch_name: str,
    animals: tuple[LivestockAnimalReadFactV1, ...],
) -> HubLivestockDashboardV1:
    attention = sum(1 for animal in animals if animal.fact_freshness is not FactFreshness.CURRENT)
    missing_identifier = sum(1 for animal in animals if animal.identifier_kind is None)
    freshness_detail = (
        "Animal facts are current" if attention == 0 else f"{attention} animals need fact review"
    )
    if missing_identifier == 0:
        records_detail = "Every animal has an active identifier"
    else:
        records_detail = f"{missing_identifier} animals have no active identifier"
    records_status = (
        HubSummaryStatus.REVIEW if _records_need_review(animals) else HubSummaryStatus.CURRENT
    )
    summaries = (
        HubLivestockSummaryCardV1(
            "herd-count",
            "Herd",
            f"{len(animals)} animals in this ranch",
            HubSummaryStatus.CURRENT,
        ),
        HubLivestockSummaryCardV1(
            "fact-freshness",
            "Fact freshness",
            freshness_detail,
            _freshness_card_status(animals),
        ),
        HubLivestockSummaryCardV1(
            "records-review",
            "Records review",
            records_detail,
            records_status,
        ),
    )
    return HubLivestockDashboardV1(ranch_name, len(animals), summaries, DataOrigin.LIVE)


def hub_read_dashboard_projection(dashboard: HubLivestockDashboardV1) -> dict[str, object]:
    """CamelCase payload a future ``readDashboard()`` decoder can use without changing Swift."""

    require_origin_label(dashboard.origin, DataOrigin.LIVE)
    return {
        "ranchName": dashboard.ranch_name,
        "herdCount": dashboard.herd_count,
        "summaries": [_summary_body(card) for card in dashboard.summaries],
    }


def _summary_body(card: HubLivestockSummaryCardV1) -> dict[str, str]:
    return {
        "id": card.id,
        "title": card.title,
        "detail": card.detail,
        "status": card.status.value,
    }


def _hub_envelope(dashboard: HubLivestockDashboardV1) -> dict[str, object]:
    return {
        "provider": HUB_AUTHORIZED_READ_PROVIDER,
        "operation": HUB_READ_DASHBOARD_OPERATION,
        "session": HUB_LIVE_SESSION,
        "dashboard": hub_read_dashboard_projection(dashboard),
    }


def _unmapped_hub_operation(operation: str) -> dict[str, object]:
    if HUB_PROVIDER_OPERATIONS[operation] is not None:
        raise LivestockReadContractError(
            "animal reads are not the current provider operation",
            LivestockReadContractErrorCode.INVALID,
        )
    return {
        "provider": HUB_AUTHORIZED_READ_PROVIDER,
        "operation": None,
        "reason": "not_on_current_provider",
    }


def _animal_body(animal: LivestockAnimalReadFactV1) -> dict[str, object]:
    identifier = None
    if animal.identifier_kind is not None:
        identifier = {"kind": animal.identifier_kind, "value": animal.identifier_value}
    return {
        "animal_id": animal.animal_id,
        "display_name": animal.display_name,
        "species_code": animal.species_code,
        "production_type_code": animal.production_type_code,
        "breed_code": animal.breed_code,
        "lifecycle_status": animal.lifecycle_status.value,
        "fact_freshness": animal.fact_freshness.value,
        "identifier": identifier,
        "provenance": _provenance_body(animal.provenance),
    }


def _provenance_body(provenance: LivestockProvenanceV1) -> dict[str, str]:
    require_origin_label(provenance.origin, DataOrigin.LIVE)
    return {
        "source_type": provenance.source_type,
        "source_id": provenance.source_id,
        "source_version": provenance.source_version,
        "observed_at": provenance.observed_at.isoformat(),
        "origin": provenance.origin.value,
    }


def _find_animal(
    animals: tuple[LivestockAnimalReadFactV1, ...],
    animal_id: str | None,
) -> LivestockAnimalReadFactV1:
    if animal_id is None:
        raise LivestockReadContractError(
            "animal is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    matches = [animal for animal in animals if animal.animal_id == animal_id]
    if len(matches) != 1:
        raise LivestockReadContractError(
            "animal is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    return matches[0]


def _freshness_card_status(animals: tuple[LivestockAnimalReadFactV1, ...]) -> HubSummaryStatus:
    status = HubSummaryStatus.CURRENT
    for animal in animals:
        match animal.fact_freshness:
            case FactFreshness.CURRENT:
                candidate = HubSummaryStatus.CURRENT
            case FactFreshness.STALE:
                candidate = HubSummaryStatus.CARE_DUE
            case FactFreshness.INCOMPLETE:
                candidate = HubSummaryStatus.REVIEW
            case FactFreshness.CONFLICTING:
                candidate = HubSummaryStatus.REVIEW
            case _ as unreachable:
                assert_never(unreachable)
        status = _more_severe_status(status, candidate)
    return status


def _more_severe_status(left: HubSummaryStatus, right: HubSummaryStatus) -> HubSummaryStatus:
    if HubSummaryStatus.REVIEW in (left, right):
        return HubSummaryStatus.REVIEW
    if HubSummaryStatus.CARE_DUE in (left, right):
        return HubSummaryStatus.CARE_DUE
    return HubSummaryStatus.CURRENT


def _records_need_review(animals: tuple[LivestockAnimalReadFactV1, ...]) -> bool:
    return any(
        animal.fact_freshness in (FactFreshness.INCOMPLETE, FactFreshness.CONFLICTING)
        or animal.identifier_kind is None
        for animal in animals
    )


def _match_route(method: str, path: str) -> tuple[_ReadOperation, str | None]:
    if method != "GET" or "?" in path or not path.startswith(f"{API_PREFIX}/"):
        raise LivestockReadContractError(
            "livestock read route is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    if path == f"{API_PREFIX}/herd":
        return "herd_summary", None
    if path == f"{API_PREFIX}/animals":
        return "animal_list", None
    prefix = f"{API_PREFIX}/animals/"
    if not path.startswith(prefix):
        raise LivestockReadContractError(
            "livestock read route is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    remainder = path[len(prefix) :]
    if remainder.endswith("/provenance"):
        animal_id = remainder[: -len("/provenance")]
        operation = "provenance"
    elif "/" in remainder:
        raise LivestockReadContractError(
            "livestock read route is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    else:
        animal_id = remainder
        operation = "animal_detail"
    if not _is_animal_id(animal_id):
        raise LivestockReadContractError(
            "animal is not available",
            LivestockReadContractErrorCode.NOT_FOUND,
        )
    return operation, animal_id


def _is_animal_id(value: str) -> bool:
    if not value or len(value) > 128:
        return False
    return value[0].isalnum() and all(character.isalnum() or character in "-_" for character in value)


def _reject_write_verb(method: str) -> None:
    if method in WRITE_VERBS or method.upper() in WRITE_VERBS:
        raise LivestockReadContractError(
            "livestock read contract defines no mutation route",
            LivestockReadContractErrorCode.WRITE_PROHIBITED,
        )
    if method != "GET":
        raise LivestockReadContractError(
            "livestock read contract defines no mutation route",
            LivestockReadContractErrorCode.WRITE_PROHIBITED,
        )


def _reject_forbidden_query(query: Mapping[str, str] | None) -> None:
    if query is None:
        return
    forbidden = {key.lower() for key in query} & FORBIDDEN_QUERY_KEYS
    if forbidden:
        raise TenancyError(
            "livestock read query cannot supply tenant, origin, or freshness",
            TenancyErrorCode.TENANT_CONTEXT_INVALID,
        )


def _require_now(now: datetime | None) -> datetime:
    if not isinstance(now, datetime):
        raise TenancyError(
            "livestock read requires an explicit timezone-aware server time",
            TenancyErrorCode.TENANT_CONTEXT_INVALID,
        )
    try:
        aware = now.tzinfo is not None and now.utcoffset() is not None
    except (TypeError, ValueError):
        aware = False
    if not aware:
        raise TenancyError(
            "livestock read requires an explicit timezone-aware server time",
            TenancyErrorCode.TENANT_CONTEXT_INVALID,
        )
    return now


def _require_aware(value: object, field_name: str) -> None:
    if not isinstance(value, datetime):
        raise LivestockReadContractError(
            f"{field_name} must be timezone-aware",
            LivestockReadContractErrorCode.INVALID,
        )
    try:
        aware = value.tzinfo is not None and value.utcoffset() is not None
    except (TypeError, ValueError):
        aware = False
    if not aware:
        raise LivestockReadContractError(
            f"{field_name} must be timezone-aware",
            LivestockReadContractErrorCode.INVALID,
        )


def _is_synthetic_source(source_type: str, source_version: str) -> bool:
    return source_type.strip().lower() in SYNTHETIC_SOURCE_TYPES or source_version.startswith(
        "sample-catalog"
    )
