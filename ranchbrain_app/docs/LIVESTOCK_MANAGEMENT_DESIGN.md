# Ranch OS livestock management design

Status: Proposed for DEV foundation review  
Scope: Dedicated Ranch OS Livestock Management application  
Last updated: 2026-08-26

Livestock Management is a dedicated Ranch OS application. It gives a ranch a
durable, tenant-scoped operational record of its animals and owns livestock
identity, classification, lifecycle history, veterinary care, livestock-input
operations, and operational-cost attribution. It does not create financial
ledger entries, automate physical actions, or authorize sharing an animal
across ranches.

This document is a design contract. It does not authorize a database, data migration, vendor import, application implementation, or Production release.

## Application boundary

Livestock Management is not a RanchBrain resource type. It is an independent
Ranch OS module with its own domain API, dedicated user interface, records,
workflows, dashboards, and tests. The application owns livestock-specific
validation, lifecycle and care projections, catalog validation, livestock-input
planning, operational-cost attribution, and operational views.

The application must consume shared Ranch OS `VerifiedPrincipal`,
`TenantContext`, authorization, RLS, audit, notification, and AI-query
boundaries. It must not introduce its own identity source, tenant resolver,
database bypass, or cross-tenant administrator path. Its domain API is the
only approved mutation boundary for livestock records and follows the Ranch OS
authoritative mutation contract.

The future UI must use the domain API and preserve the selected authorized
tenant context. Livestock dashboards are tenant-scoped views built from the
same authorized read model; they must not query global tables, files, caches,
or indexes.

## Ownership and boundaries

Every livestock record belongs to exactly one Ranch OS tenant. `tenant_id`
expresses Ranch OS record ownership only; it does not assert legal ownership or
physical custody of an animal. Legal ownership, third-party custody, and every
cross-tenant transfer workflow are deferred. A transfer is never an ordinary
record edit.

Livestock Management owns animal identity, classification, identifiers, routine
lifecycle events, veterinary observations and conditions, treatments, surgeries,
vaccinations, medication administration, care schedules, livestock-input plans
and consumption, and operational-cost attribution. Herd assignment is deferred.
It only references these adjacent domains:

- Ranch Health is human health only. It does not own animal, veterinary, care, treatment, or animal-medication records.
- Ranch Finance is the canonical accounting system for bills, payments, budgets, tax treatment, and reporting. Livestock Management may link an operational-cost attribution to an authorized Finance record, but never creates, duplicates, or independently posts a ledger entry.
- Property Management owns facilities, assets, and maintenance state.

## Core model

`LivestockAnimal` is the stable Ranch OS identity for one animal. A tag, brand, registry number, or vendor label is an `AnimalIdentifier`, not the primary identity; corrected or recycled external labels must not overwrite history.

```
Tenant --< LivestockAnimal --< AnimalIdentifier
                         --< LivestockLifecycleEvent
                         --< LivestockCareCondition
                         --< LivestockCareEvent
                         --< LivestockCareSchedule
                         --< LivestockInputAllocation
                         --< LivestockCostAttribution

Future after separate approval:
Tenant --< LivestockAnimal --< AnimalHerdAssignment >-- Herd
```

| Entity                        | Required fields                                                                                                                                                   | Rules                                                                                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `livestock_animals`           | `id`, `tenant_id`, `display_name`, `species_code`, `production_type_code`, optional `breed_id`, `status`, audit fields                                            | Ranch OS record ownership is immutable outside a future transfer workflow. Classification codes must resolve through the approved catalog. |
| `animal_identifiers`          | `id`, `tenant_id`, `animal_id`, `identifier_type`, `value`, `normalized_value`, `status`, `effective_at`, `retired_at`, audit fields                              | Active identifiers use a tenant-scoped partial unique constraint on `(tenant_id, identifier_type, normalized_value)`.                      |
| `livestock_lifecycle_events`  | `id`, `tenant_id`, `animal_id`, `event_type`, `occurred_at`, `recorded_at`, actor and audit fields                                                                | Only routine append-only operational events are in the first slice.                                                                        |
| `livestock_care_conditions`   | `id`, `tenant_id`, `animal_id`, condition reference or recorded description, status, onset time, provenance, audit fields                                         | Represents veterinary conditions in the livestock domain. Condition history remains auditable.                                             |
| `livestock_care_events`       | `id`, `tenant_id`, `animal_id`, optional `condition_id`, `event_type`, `occurred_at`, `recorded_at`, actor, provenance, optional `supersedes_event_id`            | Event types include observation, treatment, surgery, vaccination, and medication administration. Events are immutable.                     |
| `livestock_care_schedules`    | `id`, `tenant_id`, animal or future herd target, planned care type, due window, status, provenance, audit fields                                                  | A schedule is an operational plan, not proof that care occurred; completion creates a distinct care event.                                 |
| `livestock_input_plans`       | `id`, `tenant_id`, animal or future herd target, input type, planned quantity and unit, schedule, provenance, audit fields                                        | Input types include feed, hay, mineral, supplement, and approved future catalog entries.                                                   |
| `livestock_input_allocations` | `id`, `tenant_id`, input-plan reference, animal or future herd target, quantity and unit, allocated time, supplier or batch reference when applicable, provenance | Allocation is an authorized operational record, not a Finance posting.                                                                     |
| `livestock_input_consumption` | `id`, `tenant_id`, allocation or input-plan reference, animal or future herd target, quantity and unit, observed time, provenance, optional `supersedes_event_id` | Consumption is immutable operational history; corrections supersede rather than overwrite.                                                 |
| `livestock_cost_attributions` | `id`, `tenant_id`, animal, future herd, input, or care-event target; amount, currency, cost basis, source/provenance, optional Finance reference, audit fields    | An operational attribution only. It never creates a bill, payment, budget, tax treatment, or accounting entry.                             |
| `herds`                       | Deferred                                                                                                                                                          | Herd semantics require separate approval.                                                                                                  |
| `animal_herd_assignments`     | Deferred                                                                                                                                                          | Effective-time, overlap, and one-active-assignment rules require separate approval.                                                        |

The initial status vocabulary is `active` and `archived`. `sold`, `deceased`,
and `transferred` are not first-slice statuses. Sale and death events require
separate approval of their payload, confirmation, Ranch Finance, and audit
policies. Cross-tenant transfer requires a separate workflow. No deferred event
may delete an animal record.

## Controlled classification

The Livestock Management UI and domain API must use controlled catalog values.
Neither may accept arbitrary free-text animal type, species, production type,
or breed values that bypass the approved catalog.

| Classification  | Initial dropdown values                                       | Rules                                                                                                                                                            |
| --------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Species         | `chicken`, `goat`, `bison`, `cattle`, `sheep`, `pig`, `horse` | `species_code` is required and stored as a stable catalog code. Future entries require an approved catalog change.                                               |
| Production type | `beef`, `dairy`, `layer`, `broiler`, `breeding`, `companion`  | `production_type_code` is required and must be an allowed catalog value for the selected species. Future entries require an approved catalog change.             |
| Breed           | Optional catalog selection                                    | A breed belongs to one species and can be selected only after its species is selected. A missing catalog entry remains unset; it is not replaced with free text. |

Catalog records use stable codes and display labels. A future catalog addition,
retirement, or label correction must preserve historical animal classifications
and use an approved, audited Ranch OS administrative workflow. The first slice
does not grant tenant users authority to create catalog entries.

## Multi-user security

The [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) is authoritative for `VerifiedPrincipal`, `TenantContext`, membership, capabilities, RLS, and subsystem isolation. Livestock Management adds no alternate identity or access path. A CLI option, tag number, barcode, file path, model output, or job payload is never proof of tenant access.

The active-member capability matrix is below. Only the animal, identifier, and
routine-lifecycle rows are enabled in the foundational first slice; care, input,
and cost actions remain unavailable until their vertical-slice requirements in
**DEV rollout and proof** are met.

| Capability                                                | Owner                                                                | Manager                                                              | Viewer |
| --------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------- | ------ |
| List, search, and view livestock records                  | Yes                                                                  | Yes                                                                  | Yes    |
| Create or update animals and identifiers                  | Yes                                                                  | Yes                                                                  | No     |
| Record routine lifecycle events                           | Yes                                                                  | Yes                                                                  | No     |
| Record veterinary observations or routine care            | Yes                                                                  | Yes, when explicitly granted                                         | No     |
| Record medication administration, vaccination, or surgery | Yes, with explicit capability and required confirmation              | Only with explicit capability and required confirmation              | No     |
| Create or revise care schedules and input plans           | Yes                                                                  | Yes, when explicitly granted                                         | No     |
| Record input allocation or consumption                    | Yes                                                                  | Yes, when explicitly granted                                         | No     |
| Create a cost attribution or Finance-record reference     | Yes, with explicit capability and confirmation where policy requires | Only with explicit capability and confirmation where policy requires | No     |
| Archive records                                           | Yes                                                                  | No                                                                   | No     |
| Export tenant livestock data                              | Deferred; owner-only when separately enabled                         | Deferred; owner-only when separately enabled                         | No     |
| Record sale, death, or transfer                           | Deferred                                                             | Deferred                                                             | No     |

Medication, surgery, and cost-sensitive actions must have operation-specific
capability checks, confirmation classification, provenance, and audit evidence.
The UI may request a confirmation but cannot consume or bypass it. Tenant-safe
attachments may be used only after the attachment isolation contract is enabled;
their object key, metadata, access check, content policy, and audit record must
all remain tenant scoped.

Every repository, service, worker, search query, attachment operation, export, cache entry, and notification requires a server-derived `TenantContext`. PostgreSQL RLS must independently block cross-tenant records when an application query omits a tenant predicate. The runtime role must not own livestock tables or have `BYPASSRLS`.

## Lifecycle and data integrity

Current operational state is a projection of authorized lifecycle history, not a
free-form overwrite. The first slice accepts only `intake`, `tagged`, and
`weight_recorded` routine operational event types. Each event records `occurred_at` as a timezone-aware
instant and `recorded_at` as the authoritative server timestamp. Event ordering
uses `occurred_at`, then `recorded_at`, then immutable event ID as a stable
tiebreaker.

A correction must append a new event that identifies exactly one superseded
event and records its reason, actor, and correlation ID. It must not mutate or
delete the original event. High-impact lifecycle events cannot be enabled until
their event payload, confirmation class, audit requirements, and projection
invariants are separately approved.

Care events, input-consumption events, and cost attributions are likewise
immutable, auditable history. Their corrections create a new record with an
explicit supersession link, correction reason, actor, timestamp, correlation
ID, and provenance; the superseded record remains retrievable to authorized
auditors. Care schedules and input plans may change only through an auditable
revision or cancellation record. A medication administration, surgery, or
cost-sensitive attribution must not be represented as a generic note.

An identifier is active from `effective_at` until `retired_at` and may not be
silently reassigned while active. Reuse is allowed only after the prior
identifier is retired and only when the tenant-scoped partial unique constraint
permits it.

Herds and animal-herd assignments are deferred until their effective-time,
overlap, and one-active-assignment rules are separately approved. Herd-targeted
care, input, and cost records may be designed now but must not be enabled until
that contract supplies an authorized herd target. Attachments, photographs,
certificates, and notes are also deferred. Before any attachment, export,
notification, cache, or job subsystem is enabled, it must implement the tenant
isolation requirements in the Ranch OS multi-tenancy design.

## Care, livestock inputs, and operational costs

Veterinary observations, conditions, treatments, surgeries, vaccinations,
medication administration, and care schedules are Livestock Management data.
Each record identifies its source or recorder, relevant observation time,
source-system or document reference when present, and uncertainty where the
assertion is incomplete or conflicting. This is operational veterinary history;
it does not make Ranch Health responsible for animal care.

Feed, hay, mineral, supplement, and other approved livestock inputs use a
controlled input-type catalog. Plans, allocations, and consumption preserve
quantity, unit, time, target, supplier and batch reference where applicable,
and source/provenance. An inventory reference may identify an approved external
or future inventory source, but Livestock Management neither assumes that
source's authority nor changes its stock without a separate integration contract.

An operational-cost attribution can target an animal, an approved herd, an
input allocation or consumption record, or a care event. It records its amount,
currency, allocation basis, source/provenance, and optional canonical Finance
record reference. The Finance reference is a link, not a copy: Finance remains
the only system that owns bills, payments, budgets, tax treatment, accounting
entries, and financial reports. Cost trends are operational views over
authorized attribution records and must label incomplete, missing, or unlinked
Finance evidence as uncertainty.

The herd overview, when the herd contract is enabled, must expose only
tenant-authorized indicators for active care, upcoming treatments, feed needs,
recent surgeries, and cost trends. Before then, the dashboard may expose only
the equivalent tenant- and animal-scoped indicators supported by enabled data.

## Integration boundaries

Ranch Health is human health only and has no ownership of animal veterinary
data. Livestock Management must keep veterinary observations, conditions,
treatments, surgeries, vaccinations, medication administration, and care
schedules in dedicated auditable records rather than generic notes.

Ranch Finance may consume or be linked from an authorized livestock operational
cost reference through a separate approved contract. Livestock Management does
not create financial entries, bills, payments, budgets, tax treatment, or
financial reports, and does not infer revenue, valuation, or tax treatment.

Feed, sensor, registry, and vendor integrations are future opt-in adapters. Each requires tenant-context reauthorization, provenance, bounded import scope, idempotency, and separate approval.

## AI query boundary

RanchBrain and OpenClaw may access livestock facts only through an authorized
Livestock Management read/query API or a versioned Livestock Management read
model. Both paths must require the caller's `TenantContext` and enforce the
same tenant, role, and RLS boundary as the application UI.

RanchBrain, OpenClaw, models, and AI tools must not directly query livestock
databases, filesystems, caches, indexes, or unrestricted search surfaces. They
must not use a livestock fact as authority to mutate livestock, Health,
Finance, Property, or tenant policy.

Every AI-readable response must carry tenant-scoped provenance sufficient to
identify the source record or versioned read-model entry, its observation or
update time, and any applicable uncertainty. The authorized facts may include
care conditions and events, care schedules, input plans, allocations,
consumption, operational-cost attributions, and enabled dashboard indicators
for active care, upcoming treatments, feed needs, recent surgeries, and cost
trends. Missing, stale, incomplete, or conflicting livestock facts must be
represented as uncertainty rather than silently inferred as authoritative state.

## DEV rollout and proof

After the Ranch OS identity and PostgreSQL foundations are approved, start with a two-tenant vertical slice:

1. Add tenant-scoped animals, identifiers, and routine lifecycle events with
   tenant-aware constraints and RLS.
2. Add a Livestock Management domain API and repository that require
   `TenantContext`.
3. Prove authorized UI/API create, list, classification selection, search, and
   routine-event paths.
4. Do not enable care, feeding, input consumption, cost attribution, Finance
   references, or attachments until their immutable-history, supersession,
   capability, confirmation, provenance, tenant-safe attachment, and RLS test
   requirements are implemented as a complete vertical addition.
5. Do not add herds, assignments, exports, notifications, caches, jobs, sale,
   death, or transfer behavior in this slice.

First-slice acceptance must prove Tenant A cannot read, write, search, or link
Tenant B's animals, identifiers, or routine events. It must also prove missing
context fails closed, a dual-member user makes an explicit authorized choice,
and an intentionally unfiltered repository query remains blocked by RLS.

Before care is enabled, acceptance must prove tenant isolation for every care
condition, event, schedule, confirmation, provenance record, and attachment;
event corrections must retain immutable superseded history. Before feeding or
input tracking is enabled, it must prove tenant isolation and authorized
attribution for plans, allocations, consumption, supplier or batch references,
and inventory references. Before cost tracking is enabled, it must prove an
operational cost cannot post or duplicate a Finance ledger entry, that a Finance
reference is tenant-authorized, and that cost corrections supersede rather than
overwrite. Herd-level functionality remains unavailable until the herd and
assignment contract is approved.

Attachment isolation is mandatory before attachments are enabled. Export,
notification, cache, and job isolation are each mandatory before their
respective subsystem is enabled.

## Non-goals

This design does not approve legal ownership, third-party custody, herd
assignment, human-health records, accounting, sale, death, cross-tenant
transfer, regulatory reporting, breeding analytics, registry synchronization,
IoT automation, public APIs, cross-ranch sharing, Production migration, or
cloud hosting. Finance and Property integration each require a separate
approved contract.

## Related architecture

- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
- [Livestock Management application blueprint](LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md)
- [RanchBrain architecture](ARCHITECTURE.md)
- [RanchBrain data model](DATA_MODEL.md)
- `docs/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md`
- `docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md`
