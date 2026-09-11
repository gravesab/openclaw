# Ranch OS Apple TV Phase 1 design and test plan

Status: Proposed for DEV design review
Scope: Read-only Apple TV Today endpoint and fixture-backed backend vertical slice
Last updated: 2026-08-27

This plan defines Phase 1 of Ranch OS Apple TV: an authenticated viewer loads a compact, tenant-scoped Today screen through `GET /v1/tv/today`. It is a DEV-only design and test plan. It authorizes no application code, database schema, credentials, configuration, deployment, or Production change.

The [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) remains authoritative for tenant ownership, `VerifiedPrincipal`, `TenantContext`, membership, capability checks, PostgreSQL RLS, cache isolation, and auditing. This plan narrows that design to one read-only vertical slice; it does not introduce an Apple TV authorization model.

The canonical Phase 1 capability is `tv.today.read`. The existing provisional
`TV_MORNING_BRIEF_READ` / `tv.morning_brief.read` primitive must be renamed to
the corresponding canonical enum/value in the same future approved tenancy
implementation change. No compatibility alias, dual check, or runtime fallback
is permitted.

## Phase 1 scope

The Apple TV app renders only server-authorized tenant display name, tenant-local date, read-only summary cards, and a server freshness declaration. The DEV fixture catalog has only non-sensitive operational summaries: `weather`, `livestock`, and `property`. A card has a title, concise value, optional detail, and source timestamp.

Health, Finance, attachments, full-text search, records, histories, notifications, exports, write controls, and cross-tenant aggregation are out of scope. A missing card is omitted; the server never fabricates a value or substitutes another tenant's data.

The slice is fixture-backed. Fixtures are deterministic DEV test data selected only after the server has derived and authorized `TenantContext`. The fixture verifier is test-only and implements the same versioned `VerifiedPrincipal` contract as the deployed OpenClaw identity adapter. It must not be loadable or configurable in deployed DEV runtime.

## Principal-to-context flow

`GET /v1/tv/today` accepts an authenticated request and explicit `X-Ranch-OS-Tenant-Id` tenant-selection hint. The header is not authorization and is never copied into a repository, cache, fixture lookup, audit record, or database transaction until this flow completes.

1. Trusted DEV ingress validates its assertion and passes the request to the OpenClaw-authoritative identity adapter. Direct Gateway traffic and forged, missing, or conflicting proxy assertions are denied.
2. The adapter validates the current session and returns versioned `VerifiedPrincipal`: immutable `principal_id`, principal type, lifecycle state, environment, assurance profile, session reference, validity window, and correlation ID. It does not assert tenant, role, or capability. Tests alone use the fixture verifier.
3. Ranch OS rejects invalid lifecycle, environment, validity, or assurance; missing/malformed selection; and omitted selection for a principal with multiple memberships. It never picks a recent, default, or global tenant.
4. Ranch OS loads active membership for the requested active tenant from the authoritative membership store and derives `tv.today.read`. Phase 1 grants this capability to owner, manager, and viewer; client role text is ignored.
5. Ranch OS creates immutable `TenantContext` containing authorized `tenant_id`, principal/user reference, membership reference, resolved role, `tv.today.read`, environment `dev`, correlation ID, and applicable service/delegation references.
6. Before a tenant repository runs, the transaction uses `SET LOCAL` for `ranchos.principal_id`, `ranchos.environment`, and `ranchos.tenant_id`. The runtime role does not own tenant tables or have `BYPASSRLS`; tenant tables have `ENABLE` and `FORCE ROW LEVEL SECURITY` plus `USING` and `WITH CHECK` policies.
7. The Today repository reads an authorized fixture projection tagged with that same `tenant_id`. An intentionally unfiltered query must still be limited by RLS.
8. The endpoint serializes V1, records a redacted audit event, and returns it. The client renders it without adding authority.

Any failure stops before fixture retrieval or cache lookup. An authorization failure is never an empty `200`.

## GET /v1/tv/today contract

### Request

| Element                | Required | Contract                                                                                               |
| ---------------------- | -------- | ------------------------------------------------------------------------------------------------------ |
| Method and path        | Yes      | `GET /v1/tv/today`                                                                                     |
| Trusted identity       | Yes      | OpenClaw-authoritative `VerifiedPrincipal`; fixture verifier only in tests.                            |
| `X-Ranch-OS-Tenant-Id` | Yes      | UUID selection hint for one explicit tenant; validated against current membership and never authority. |
| `Accept`               | Yes      | `application/vnd.ranchos.tv-today+json;version=1`                                                      |
| `If-None-Match`        | No       | ETag from the same authorized tenant, authorization revision, response version, and fixture revision.  |

The endpoint accepts no caller-supplied role, capability, user ID, date, environment, card family, cache mode, or fixture ID. Unknown query parameters and unsupported media/version requests are rejected.

### Successful response

`200 OK` returns `Content-Type: application/vnd.ranchos.tv-today+json;version=1`, `Cache-Control: private, max-age=60, must-revalidate`, `Vary: Accept, X-Ranch-OS-Tenant-Id, Authorization`, and an ETag. A `304 Not Modified` is allowed only after reauthentication, reauthorization, and confirmation of the same tenant-scoped cache key.

```json
{
  "version": "v1",
  "tenant": {
    "id": "8d8d6b8a-4e9b-46e4-92ff-0fc3e371c4ca",
    "display_name": "North Creek Ranch"
  },
  "today": {
    "date": "2026-08-27",
    "time_zone": "America/Chicago",
    "label": "Thursday, August 27"
  },
  "cards": [
    {
      "id": "livestock-summary",
      "kind": "livestock",
      "title": "Livestock",
      "value": "18 active animals",
      "detail": "2 routine items due today",
      "as_of": "2026-08-27T12:00:00Z"
    }
  ],
  "freshness": {
    "generated_at": "2026-08-27T12:00:05Z",
    "source_as_of": "2026-08-27T12:00:00Z",
    "fresh_until": "2026-08-27T12:01:05Z",
    "state": "fresh"
  },
  "request": {
    "correlation_id": "9cf61a04-47e4-4c3d-a8c4-c21681ecda2b"
  }
}
```

`tenant.id` is only an opaque response identity for client-side binding, not next-request authority. `cards` is an array so unavailable data can be omitted; cards expose no detail URL, record ID, attachment, or mutation affordance.

The V1 success schema is closed: fields not listed below are invalid until a
later version declares them. All timestamps are RFC 3339 UTC instants and all
IDs are UUID strings.

| Field                                                                       | Type   | Required | Constraint                                                                   |
| --------------------------------------------------------------------------- | ------ | -------- | ---------------------------------------------------------------------------- |
| `version`                                                                   | string | Yes      | Exactly `v1`.                                                                |
| `tenant.id`                                                                 | string | Yes      | Authorized tenant UUID; opaque client binding only.                          |
| `tenant.display_name`                                                       | string | Yes      | Server-authorized tenant display value.                                      |
| `today.date`                                                                | string | Yes      | ISO 8601 calendar date in `today.time_zone`.                                 |
| `today.time_zone`                                                           | string | Yes      | IANA time-zone identifier resolved by the server.                            |
| `today.label`                                                               | string | Yes      | Server-produced display label; not client authority.                         |
| `cards`                                                                     | array  | Yes      | Zero or more `TodayCard`; stable order is fixture projection order.          |
| `cards[].id`                                                                | string | Yes      | Stable V1 card ID unique within the response.                                |
| `cards[].kind`                                                              | string | Yes      | One of `weather`, `livestock`, or `property`.                                |
| `cards[].title`, `cards[].value`                                            | string | Yes      | Plain read-only display text.                                                |
| `cards[].detail`                                                            | string | No       | Plain read-only display text.                                                |
| `cards[].as_of`                                                             | string | Yes      | Source freshness timestamp for that card.                                    |
| `freshness.generated_at`, `freshness.source_as_of`, `freshness.fresh_until` | string | Yes      | `fresh_until` is no earlier than `generated_at`; server freshness authority. |
| `freshness.state`                                                           | string | Yes      | Exactly `fresh` in Phase 1.                                                  |
| `request.correlation_id`                                                    | string | Yes      | Request correlation UUID; no principal or tenant authority.                  |

### Error response

Every error has this sanitized V1 shape and must not reveal an unauthorized tenant's existence, fixture state, or memberships.

```json
{
  "error": {
    "code": "tenant_not_authorized",
    "message": "The requested Today view is not available.",
    "correlation_id": "9cf61a04-47e4-4c3d-a8c4-c21681ecda2b"
  }
}
```

| HTTP status | Stable code              | Condition                                                                                           |
| ----------- | ------------------------ | --------------------------------------------------------------------------------------------------- |
| `401`       | `principal_invalid`      | Missing, expired, inactive, malformed, or wrong-environment principal; untrusted ingress assertion. |
| `400`       | `tenant_context_invalid` | Missing, malformed, ambiguous tenant selection or unsupported request shape/version.                |
| `403`       | `tenant_not_authorized`  | No active membership, inactive tenant, or denied capability.                                        |
| `503`       | `today_unavailable`      | Authorized request cannot safely obtain its tenant-scoped projection; no fallback is allowed.       |

## Cache and freshness semantics

The server is freshness authority. A DEV cache key must contain response version, environment, authorized `tenant_id`, projection revision, and authorization revision; it must validate all three tenant/version/authorization bindings on read. Global, device-only, user-only, and tenant-header-only keys are prohibited.

The server may return a cached response for at most 60 seconds from `generated_at`, bounded by `fresh_until`. On expiry it reauthorizes, rebuilds from the tenant-scoped fixture projection, and replaces the entry. Membership, tenant-status, or capability change invalidates affected authorization revisions immediately. Cache failure is availability failure, never permission to widen a lookup.

The Apple TV app may hold the last successful response in memory only through `fresh_until`, bound to its authorized tenant. It discards it on sign-out, tenant change, `401`, `403`, context failure, or expiry. It never renders stale data as current, switches tenant silently, emits cached content after a denial, or uses shared-device persistence. Offline display is deferred.

## Audit events

The endpoint writes a redacted, tenant-scoped audit event for every authorization decision and completed authorized read. Audit data must not retain card values, tokens, raw headers, session secrets, device IDs, or presentation attributes.

| Event                       | Required fields                                                                                                                                            | Outcome       |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| `tv.today.read.authorized`  | timestamp, environment, tenant ID, principal and membership references, operation, correlation ID, response version, projection revision, freshness state  | `allowed`     |
| `tv.today.read.denied`      | timestamp, environment, redacted principal reference when available, requested tenant reference hashed or omitted when unsafe, denial code, correlation ID | `denied`      |
| `tv.today.read.unavailable` | timestamp, environment, authorized tenant ID, principal reference, correlation ID, safe dependency class                                                   | `unavailable` |

Audit queries and dashboards remain tenant-scoped. A platform-administration view needs separate approval.

## Negative authorization cases

The implementation and tests must deny with no fixture body or cached disclosure:

1. direct Gateway access; forged/missing proxy assertions; missing, expired, revoked, malformed, or wrong-environment principal;
2. caller-supplied role, capability, principal ID, environment, fixture ID, or tenant selection treated as authority;
3. missing, malformed, duplicate, or ambiguous tenant selection, including a multi-tenant principal with no selection;
4. no membership; suspended/revoked membership; inactive tenant; or missing `tv.today.read`;
5. Tenant A probing Tenant B, its ETag, cached entry, or correlation ID;
6. fixture data with missing, malformed, or mismatched `tenant_id`;
7. intentionally unfiltered repository query; missing/malformed `SET LOCAL`; or runtime RLS-bypass attempt;
8. unknown card kind, unsupported media/version, caller date, or extra filters; and
9. a server or device cache used before current authorization or after revocation.

## Fixture-backed backend vertical slice

The fixture set has distinct active Tenant A and Tenant B, distinct principals, fixtures, projection revisions, visible card strings, ETags, and audit records. A third principal belongs to both tenants and proves explicit selection. A fourth active principal lacks `tv.today.read`.

The fixture repository accepts only `TenantContext` and a fixed V1 projection request. It returns matching `tenant_id`, projection revision, cards, source timestamp, and fixture provenance. It accepts no raw tenant ID, principal ID, client filter, or fixture path. The endpoint validates returned tenant binding before serialization.

No Production adapter, database, deployment artifact, credential, or environment configuration belongs to this phase. A database-backed projection needs separate DEV review and must retain this contract, context flow, RLS proof, cache rules, and audit events.

## Two-tenant acceptance tests

Phase 1 is acceptable only after focused automated tests prove these DEV fixture and isolated DEV RLS cases:

| Test                   | Setup                                                                   | Expected proof                                                                                               |
| ---------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Tenant A happy path    | A viewer requests A explicitly.                                         | `200`; only A name, cards, timestamps, ETag, and allowed audit event.                                        |
| Tenant B happy path    | B viewer requests B explicitly.                                         | `200`; no A marker in body, headers, cache observation, or audit query.                                      |
| Cross-tenant selection | A viewer requests B.                                                    | `403 tenant_not_authorized`; no fixture lookup/body, ETag reuse, or cache disclosure; denied audit only.     |
| Dual membership        | Principal belongs to A and B.                                           | No selection denies; explicit A then B returns only its selected tenant and does not change the other cache. |
| Capability denial      | Active membership lacks `tv.today.read`.                                | `403`; no fixture or prior cached response.                                                                  |
| Fixture binding        | Repository returns B-tagged fixture under A context.                    | `503 today_unavailable`; no cards and unavailable audit event.                                               |
| Cache partition        | Warm A cache, then request B with same device/principal class and ETag. | B receives B only; A ETag cannot produce B `304`; B observes no A cache data.                                |
| Revocation freshness   | Cache A, revoke A membership/capability, repeat before TTL.             | Reauthorization denies; no `200`/`304`; app cache clears.                                                    |
| RLS adversarial read   | A context makes an intentionally unfiltered query over A and B rows.    | Only A rows return; missing/malformed `SET LOCAL` denies; runtime role cannot bypass RLS.                    |
| Audit isolation        | Authorized and denied A/B calls, queried under each tenant context.     | Each tenant sees only its own audit data; denied events leak neither other identity nor fixture state.       |

The Apple TV UI fixture must also prove the app displays only server-delivered cards; contains no write controls or navigation to records, attachments, exports, Health, or Finance; and clears in-memory content on tenant change, sign-out, and authorization failure.

## DEV gates and follow-up

Before implementation, apply the approved `tv.today.read` rename as one tenancy
change, then approve the trusted-ingress-to-`VerifiedPrincipal` boundary, exact
fixture catalog, and isolated DEV RLS test identities. Before Phase 1
readiness, review endpoint contract, adversarial two-tenant evidence, audit
redaction, and Apple TV cache behavior together.

This plan does not authorize a Production endpoint, Apple Developer signing, TestFlight distribution, database migration, Apple TV writes, or deployment. Each remains behind its own approval gate.

## Related design

- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
- [Livestock Management application blueprint](LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md)
- [RanchBrain architecture](ARCHITECTURE.md)
