# Ranch OS Livestock Management application blueprint

Status: Proposed for DEV application design review  
Scope: Tenant-safe Livestock Management UI, domain API, and AI read boundary  
Last updated: 2026-08-26

Livestock Management is a dedicated Ranch OS application. This blueprint
defines its user-facing surfaces and its authorized read/query boundary. It
does not authorize UI, API, database, migration, or infrastructure
implementation.

The [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md) and the
[Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) are authoritative for
domain ownership, `TenantContext`, authorization, RLS, audit, and isolation.

## Application surfaces

Every screen receives a server-derived `TenantContext`; a tenant picker may
request a tenant but cannot establish access. A user with multiple memberships
must select an authorized tenant. Missing, invalid, stale, or unauthorized
context fails closed.

| Screen | Purpose | First-slice availability |
| --- | --- | --- |
| Herd overview | Shows authorized herd counts and herd indicators for active care, upcoming treatments, feed needs, recent surgeries, and cost trends. | Deferred until the herd and assignment contract is approved. |
| Animal list | Lists authorized animals with status, controlled classification, identifier summary, filtering, and pagination. | Required. |
| Animal detail | Shows one authorized animal, identifiers, current projected status, routine lifecycle history, care history, enabled input activity, cost-attribution references, and provenance. | Animal and lifecycle facts required; care, input, and cost panels require their vertical-slice gates. |
| Add/edit animal | Creates or updates authorized animal identity and controlled classifications. | Required for owners and managers. |
| Lifecycle history | Shows immutable routine events and their corrections or supersession links. | Required. |
| Care history and schedule | Shows veterinary observations, conditions, treatments, surgeries, vaccinations, medication administration, due care, immutable corrections, and permitted attachments. | Deferred until the care vertical slice meets its security and audit gates. |
| Feed and input operations | Shows feed, hay, mineral, supplement, and approved input plans, allocations, consumption, supplier or batch references, and authorized animal or herd attribution. | Deferred until the input vertical slice meets its security and audit gates. |
| Operational costs | Shows livestock operational-cost attributions, source/provenance, allocation target, trend context, and an optional canonical Finance reference. | Deferred until the cost vertical slice meets its security, confirmation, and Finance-link gates. |
| Herd assignment | Assigns an animal to a herd and shows placement history. | Deferred until effective-time and overlap rules are approved. |
| Dashboard | Shows tenant-scoped operational counts, unresolved routine work, and permitted recent activity. | Required only for data available in the first slice. |

The UI must hide or disable unauthorized actions and must not treat that as the
authorization decision. The domain API independently rejects every disallowed
operation. Deferred actions, including herd assignment, sale, death, transfer,
care, feeding, cost tracking, attachments, exports, and notifications, must be
unavailable rather than rendered as unimplemented writable controls. An enabled
attachment is tenant-safe only when the attachment contract is active; it is
never a general file picker or a cross-tenant document lookup.

## Controlled classification behavior

The add/edit flow uses catalog-backed dropdowns. It must not expose a free-text
type, species, production type, or breed field.

1. Species is required. The initial choices are `chicken`, `goat`, `bison`,
   `cattle`, `sheep`, and `horse`.
2. Production type is required after species selection. The initial choices are
   `beef`, `dairy`, `layer`, `broiler`, `breeding`, and `companion`; the UI
   shows only choices allowed by the selected species.
3. Breed is optional. The UI loads only catalog breeds for the selected species
   and leaves the field unset when no approved breed applies.
4. When species changes, the UI clears an incompatible production type or breed
   and requires the user to select a new valid value before saving.
5. The domain API validates every catalog code again. A retired, unknown, or
   incompatible code is rejected with a stable validation error; a display
   label is never an accepted substitute.

Catalog additions and retirements are separate audited administrative work. A
tenant user cannot create a personal catalog value as a workaround.

## User flows

### Create an animal

1. The user selects an authorized tenant and opens **Add animal**.
2. The UI loads the approved classification catalog through the domain API.
3. The user enters the display name, selects species, production type, and an
   optional compatible breed, then adds zero or more valid identifiers.
4. The UI submits the requested values without asserting tenant ownership,
   role, or authorization.
5. The domain API resolves `TenantContext`, validates capability and catalog
   values, creates tenant-owned records, records audit evidence, and returns
   the created animal with provenance.
6. The UI opens the authorized animal detail view. A validation or
   authorization failure leaves no partially accepted animal record.

### Record a routine status change

1. An owner or manager opens an authorized animal detail view and selects an
   allowlisted routine lifecycle event.
2. The UI records the event time as a timezone-aware value and sends it as a
   proposed routine event; it does not patch animal status directly.
3. The domain API validates the event type, `TenantContext`, ordering, and
   lifecycle projection, then appends the event and audit evidence atomically.
4. The UI refreshes the projected status and lifecycle history with the event
   provenance. Sale, death, and transfer are not choices in this flow.

### Retire an identifier

1. An owner or manager opens an authorized animal and selects an active
   identifier.
2. The UI collects the retirement effective time and reason; it does not offer
   free-text replacement of the active identifier value.
3. The domain API authorizes the operation, retires the identifier, preserves
   its history, and enforces the active tenant-scoped identifier uniqueness
   rule.
4. A replacement identifier can be created only through the normal validated
   identifier flow. The former value is reusable only when the domain rule
   permits it.

### Record care or a high-impact procedure

1. An authorized user opens an animal's care history and chooses a controlled
   care action: observation, condition, treatment, surgery, vaccination,
   medication administration, or a care schedule.
2. The UI collects the occurred or due time, source/provenance, and permitted
   tenant-safe attachment reference. It never writes a medical fact to Ranch
   Health or a generic note.
3. For medication administration, surgery, and any policy-classified
   high-impact action, the domain API requires the exact capability and a
   server-enforced confirmation before atomically appending the immutable care
   event, audit evidence, and any attachment reference.
4. A correction creates a new care record that explicitly supersedes the prior
   record with a reason and provenance. It does not edit or delete the original.

### Plan feed and attribute an operational cost

1. An authorized user creates an input plan or records a controlled allocation
   or consumption of feed, hay, mineral, supplement, or another approved input
   for an animal or, once enabled, a herd.
2. The UI sends quantity, unit, target, time, supplier or batch reference when
   applicable, and source/provenance. The domain API validates tenant context,
   capabilities, and the controlled input catalog.
3. A permitted user may add an operational-cost attribution to the animal,
   herd, care event, or input activity. A cost-sensitive action requires the
   exact capability and any required server-enforced confirmation.
4. An optional Finance reference links to the canonical Finance record. The UI
   must not create, copy, or post a bill, payment, budget, tax treatment, or
   ledger entry. Corrections supersede immutable input-consumption or cost
   records rather than overwriting them.

### View herd history

Herd overview, assignment, and history are intentionally unavailable until the
separate herd-assignment contract defines effective-time, overlap, and
one-active-assignment rules. The future flow must read only an authorized,
tenant-scoped assignment history; it must not infer history from animal notes,
files, or lifecycle events.

## Versioned livestock read/query contract

RanchBrain and OpenClaw consume Livestock Management through either the
versioned Livestock read/query API or an equivalently versioned read model.
They must not receive direct access to Livestock Management databases,
filesystems, caches, indexes, or unrestricted search.

The first contract is `LivestockReadModelV1`. Its foundational first slice
supports only authorized tenant-scoped animals, identifiers, routine lifecycle
facts, and dashboard summaries. Once the stated vertical gates are complete,
the same versioned contract may add authorized care conditions and events, care
schedules, input plans, allocations, consumption, operational-cost
attributions, and indicators for active care, upcoming treatments, feed needs,
recent surgeries, and cost trends. Herd assignments, herd-targeted facts,
attachments, exports, notifications, sale, death, and transfer facts remain
absent until their separate contracts are enabled.

### Query request

The caller supplies an API version, an authorized tenant selection request,
requested fact family, bounded filters, opaque cursor, and page size. The
server derives `TenantContext` from the verified principal and current Ranch OS
membership; it ignores a caller's attempt to assert a role or tenant authority.

Valid foundational fact families are `animal`, `identifier`,
`routine_lifecycle_event`, and `dashboard_summary`. Care-enabled fact families
are `care_condition`, `care_event`, and `care_schedule`; input-enabled families
are `input_plan`, `input_allocation`, and `input_consumption`; cost-enabled
families are `operational_cost_attribution` and `cost_trend`. The API exposes a
family only after its vertical-slice gate is complete. Filters and sort fields
are allowlisted. Cursors are opaque, tenant-bound, query-bound, and expire
under server policy.

### Query response

Every successful response contains:

- `schema_version` and `read_model_version`;
- a bounded tenant context reference containing the resolved tenant identifier,
  environment, and correlation identifier, but no credential or session secret;
- `results` containing only facts authorized for that context;
- `page` with an opaque next cursor or an explicit end-of-results indicator;
- `provenance` for each fact: source type, immutable source identifier, source
  or read-model version, and observation or update time;
- `uncertainty` when the fact is missing, stale, incomplete, conflicting, or
  unavailable under the selected contract.

Care and input facts retain source, actor, occurrence or due time, and explicit
supersession information where applicable. Cost facts retain allocation basis,
source/provenance, and an optional Finance reference only; they do not return
or fabricate a Finance bill, payment, tax, budget, or ledger entry.

No result is a successful empty result set with `results: []` and an explicit
end-of-results indicator. It is not a fabricated animal, inferred lifecycle
state, or cross-tenant fallback.

Authorization and validation failures use stable, sanitized errors:

| Condition | Result |
| --- | --- |
| Missing, malformed, expired, or ambiguous tenant context | Deny with `tenant_context_invalid`. |
| Selected tenant is not an active membership | Deny with `tenant_not_authorized`. |
| Active membership lacks the requested read capability | Deny with `livestock_read_forbidden`. |
| Unknown fact family, filter, sort, cursor, or API version | Reject with `livestock_query_invalid`. |

An AI consumer must preserve returned provenance and uncertainty when answering.
It must state uncertainty when the response supplies it and must not use
livestock facts to authorize a mutation or infer Health, Finance, Property, or
cross-tenant transfer state.

## Integration boundaries

- **Ranch Health:** is human health only and does not own veterinary, animal
  treatment, animal medication, or livestock-care data.
- **Ranch Finance:** is the canonical ledger and accounting boundary. Livestock
  Management can link an authorized operational-cost attribution to a Finance
  record, but does not create or duplicate bills, payments, budgets, tax
  treatment, financial reporting, valuations, revenue, or accounting entries.
- **Property:** may later associate an authorized facility or maintenance
  reference through a separate Property contract. It does not own facilities,
  equipment, or maintenance state.
- **Cross-tenant transfer:** remains unavailable until a separate transfer
  contract defines legal/custody semantics, authorization, confirmation,
  audit, and atomic ownership boundaries.

## Focused DEV acceptance tests

UI and API tests must prove:

1. A viewer can list, search, and view only authorized tenant livestock facts;
   create, edit, retire-identifier, archive, and deferred controls are absent
   or rejected.
2. A manager can create/edit animals, manage identifiers, and record routine
   events only in the selected authorized tenant.
3. An owner can perform owner-only first-slice actions; a user with two
   memberships must explicitly select one authorized tenant.
4. Tenant A cannot discover, load, update, or search Tenant B animal,
   identifier, routine-event, or dashboard data; the database RLS suite still
   blocks an intentionally unfiltered repository query.
5. Species, production type, and breed controls reject unknown, retired, or
   incompatible catalog codes in both UI behavior and the domain API.
6. Before care is enabled, care views and mutations remain unavailable. When
   enabled, Tenant A cannot view, attach to, create, confirm, correct, search,
   or schedule Tenant B care data; medication, surgery, and high-impact care
   actions require the appropriate capability, confirmation, provenance, and
   immutable supersession proof.
7. Before input tracking is enabled, input views and mutations remain
   unavailable. When enabled, plans, allocations, consumption, supplier or
   batch references, and animal or herd attribution stay tenant scoped and
   correct only through immutable supersession.
8. Before cost tracking is enabled, cost views and mutations remain
   unavailable. When enabled, cost attributions and Finance references require
   tenant context, the appropriate capability and confirmation policy, preserve
   provenance and immutable correction history, and cannot create, duplicate,
   or post a Finance ledger entry.
9. Herd overview remains unavailable until the herd contract is approved. When
   enabled, its active-care, upcoming-treatment, feed-need, recent-surgery, and
   cost-trend indicators are limited to the selected authorized tenant.

AI-query isolation tests must prove:

1. RanchBrain and OpenClaw can retrieve livestock facts only through
   `LivestockReadModelV1` or its approved API equivalent.
2. Direct database, filesystem, cache, index, and unrestricted-search access is
   not exposed to AI consumers.
3. Every result is tenant-bound, paginated, provenance-bearing, and preserves
   uncertainty; a cursor from Tenant A cannot retrieve Tenant B facts.
4. Missing context, insufficient capability, and no-result behavior are
   distinguishable and fail closed without leaking tenant existence.
5. Care, input, cost, and dashboard facts are returned only after their
   respective vertical-slice gate is enabled; every enabled fact retains tenant
   context, provenance, uncertainty, and appropriate supersession history.

## Related architecture

- [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md)
- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
- [RanchBrain architecture](ARCHITECTURE.md)
