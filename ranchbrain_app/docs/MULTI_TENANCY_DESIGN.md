# Ranch OS multi-tenancy design

Status: Approved for DEV foundation work
Scope: Ranch OS modules, beginning with RanchBrain
Last updated: 2026-09-19

Ranch OS supports multiple ranches and multiple users in a shared data
platform. A ranch's information must never be visible, searchable, mutable, or
deliverable to another ranch unless a future, separately approved sharing
feature explicitly authorizes it.

This is the canonical tenancy contract for DEV implementation. It defines a
security boundary; it does not authorize Production deployment, a Production
migration, or cloud hosting.

## Core model

`Tenant` is the ownership boundary for a ranch, household, or organization.
`User` is a global human identity. `TenantMembership` grants a user a role in a
tenant.

```
User --< TenantMembership >-- Tenant --< tenant-owned records
```

Tenant roles are:

- `owner`: archives, deletes, and exports tenant data and manages memberships
  and tenant settings, subject to the authoritative mutation policy.
- `manager`: creates, updates, and links tenant resources within the
  server-authorized policy.
- `viewer`: reads, searches, and lists tenant resources only.

The initial capability matrix is explicit. Role names group these capabilities;
they do not independently grant authority.

| Capability                              | Owner                                        | Manager                                      | Viewer                                       |
| --------------------------------------- | -------------------------------------------- | -------------------------------------------- | -------------------------------------------- |
| Read, search, or list tenant memories   | Yes                                          | Yes                                          | Yes                                          |
| Create, update, or link tenant memories | Yes                                          | Yes                                          | No                                           |
| Archive, delete, or export tenant data  | Yes                                          | No                                           | No                                           |
| Manage memberships or tenant settings   | Yes                                          | No                                           | No                                           |
| Run a service workload                  | Explicit tenant and operation grant required | Explicit tenant and operation grant required | Explicit tenant and operation grant required |

The following livestock write capabilities are DEV-only in-memory contracts.
They are authorized only through the same server-derived `TenantContext`
boundary as other capabilities. Owner has all four; manager has the first
three only; viewer has none. This does not authorize persistence, migrations,
database/RLS work, runtime integration, device work, or Production.

| Capability                    | Owner | Manager | Viewer |
| ----------------------------- | ----- | ------- | ------ |
| `livestock.animal.write`      | Yes   | Yes     | No     |
| `livestock.identifier.write`  | Yes   | Yes     | No     |
| `livestock.lifecycle.write`   | Yes   | Yes     | No     |
| `livestock.lifecycle.correct` | Yes   | No      | No     |

The following Finance capabilities are DEV-only contracts authorized only
through the same server-derived `TenantContext` boundary. A second equal
Finance administrator is a second tenant owner. Tenant owner means full Ranch
OS owner authority, not Finance-only authority. Owner has all five; manager
has the first four only; viewer has `finance.read` only. This does not
authorize Production, connectors, credentials, HTTP ingress, or money movement.

| Capability                       | Owner | Manager | Viewer |
| -------------------------------- | ----- | ------- | ------ |
| `finance.read`                   | Yes   | Yes     | Yes    |
| `finance.chart.write`            | Yes   | Yes     | No     |
| `finance.source.write`           | Yes   | Yes     | No     |
| `finance.interpretation.write`   | Yes   | Yes     | No     |
| `finance.interpretation.correct` | Yes   | No      | No     |

An asset belongs to a tenant, not to the user who created it. Tenant-owned
records retain `created_by_user_id` and `updated_by_user_id` for attribution,
but those fields must not be used to select or authorize data.

## Boundary invariant

Every tenant-owned record must have a non-null `tenant_id`. A request operates
inside a server-derived `TenantContext` containing, at minimum, the active
tenant, authenticated user, membership, role, environment, and request
correlation identifier.

### Identity and context source

OpenClaw-authoritative `VerifiedPrincipal` is the only deployed identity source
for Ranch OS. It must provide an immutable principal identifier and type,
lifecycle state, environment, assurance profile, session reference, validity
window, correlation identifier, and any applicable service or delegation
reference. It must not provide an authoritative tenant, role, or capability.

The shared value type rejects an empty principal identifier or environment,
naive or malformed validity timestamps, and a non-positive validity window as
an explicit tenancy/context failure. Immutability is not proof of provenance:
in a deployed runtime, only the OpenClaw-authoritative ingress may construct
this type after it has verified the assertion. No constructor, fixture, local
identity, configuration value, or client-provided principal is an alternative
deployed authority path. Fixtures may construct the identical value only in
isolated tests.

Ranch OS, not OpenClaw, must resolve active membership, requested tenant,
role, and operation-specific capability from its authoritative store. A
fixture verifier may implement the identical `VerifiedPrincipal` contract only
in tests. It must not be loadable or configurable in a deployed DEV runtime.

### Approved DEV bootstrap identity provider

DEV bootstrap enrollment uses Google OIDC with Google Security Bundle through
the OpenClaw-authoritative identity adapter. Google OIDC `sub` is the immutable
upstream identity key. Email, display name, and other presentation attributes
must not establish Ranch OS authority.

The adapter must accept bootstrap enrollment only when the signed Google ID
token contains a valid per-login `amr` claim with `mfa` and a fresh `auth_time`.
Missing, malformed, stale, conflicting, or unverifiable assurance claims deny
enrollment. The adapter emits the versioned `VerifiedPrincipal` contract; it
does not pass Google tokens or mutable profile attributes to Ranch OS as proof
of identity.

### Google Cross-Account Protection events

Google Cross-Account Protection (CAP) is an additional account-security-event
input for the DEV enrollment adapter. A validated event associated with an
enrolled principal may revoke or shorten an existing DEV enrollment or Ranch OS
session, require the principal to complete fresh verification before another
privileged operation, and create a redacted audit event. The audit event must
record the environment, principal reference, event class, receipt time,
validation outcome, and resulting action; it must not retain tokens, raw event
payloads, or presentation attributes unnecessarily.

CAP does not establish identity and does not replace any request-time control.
Every request must still independently validate the trusted-proxy assertion,
OpenClaw `VerifiedPrincipal`, issuer, audience, nonce, expiry, token signature,
MFA assurance, freshness, principal lifecycle, and environment. Missing,
malformed, stale, replayed, or untrusted CAP delivery must fail closed: it must
not alter enrollment/session state and must produce only a redacted denied-event
audit record.

Sign in with Apple is deferred for a future ordinary sign-in design. It is not
approved for bootstrap ownership under this provable-MFA and freshness policy.

A client may request a tenant selection, but that value is only a routing hint.
The authoritative API must authenticate the caller, load the current
membership, and reject a missing, suspended, revoked, or unauthorized tenant
selection. A client, model, retrieval result, cache entry, or job payload must
never establish access merely by carrying a tenant identifier.

Each tenant-owned repository and service method must require `TenantContext`.
It must apply the active `tenant_id` to every read and write; callers do not
pass arbitrary tenant filters into those methods.

## Data model

The future DEV relational foundation uses these authoritative entities:

| Entity                | Required fields                                                   | Rules                                                                                                        |
| --------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `tenants`             | `id`, `slug`, `display_name`, `status`, timestamps                | `slug` is globally unique; status changes are server-authorized and audited.                                 |
| `users`               | `id`, immutable external identity reference, `status`, timestamps | One global human identity per authenticated person; no shared human accounts.                                |
| `tenant_memberships`  | `tenant_id`, `user_id`, `role`, `status`, timestamps              | Unique active membership per tenant/user; role and lifecycle changes are server-authorized and audited.      |
| tenant-owned resource | `id`, `tenant_id`, audit fields, resource fields                  | `tenant_id` is non-null and immutable after creation except through a separately approved transfer workflow. |

Tenant-owned resources include assets, maintenance tasks, documents, memories,
financial records, livestock records, health records, search/vector records, file metadata,
exports, notifications, async jobs, and audit records.

Use tenant-scoped uniqueness for human-facing identifiers, for example
`UNIQUE (tenant_id, external_id)`. Relationships between tenant-owned tables
must include tenant-aware constraints so an asset from one tenant cannot be
referenced by a task in another. The preferred relational pattern is a unique
`(tenant_id, id)` key on the parent and a composite foreign key from the child.

`created_by_user_id`, `updated_by_user_id`, and optional actor/service identity
fields preserve audit attribution. They are not substitutes for `tenant_id`.

## Authorization and authoritative mutation

Tenancy narrows authorization; it does not replace it. Ranch OS mutations must
continue to follow the repository's server-enforced mutation and identity
contracts:

- The authoritative API authenticates the caller and derives `TenantContext`.
- The authoritative API validates role, operation, resource, current record
  state, confirmation requirements, idempotency, concurrency, and audit rules.
- Models, clients, direct database users, background tools, and retrieval
  systems cannot bypass the authoritative API to modify tenant data.
- Service identities have an explicit tenant and operation scope. They do not
  inherit the authority of a human operator or an entire database.

Tenant selection must be explicit when an authenticated user belongs to more
than one active tenant. A missing selection is rejected rather than choosing a
recent or arbitrary tenant. A single-tenant local bootstrap may supply one
configured tenant only after the server has established the local actor and
environment.

Service identities must use explicit, least-privilege tenant and operation
grants. They must not inherit a human's authority, receive authority from a
database credential, or select a tenant without current server authorization.

## Multi-user security requirements

Multi-user support is a security boundary, not a convenience feature. The
following rules apply before a Ranch OS module can claim multi-tenant support:

- **Authenticate before selecting a tenant.** OpenClaw establishes the user
  or service identity first and Ranch OS resolves current membership and
  capability. A tenant ID supplied by a CLI argument, request, model, file
  path, job payload, or configuration value is never proof of access.
- **Authorize through active membership and capability.** Every request checks
  the selected tenant's active membership, role, and operation-specific
  capability. Role names are not sufficient authority on their own; the
  authoritative API owns the capability matrix for `owner`, `manager`, and
  `viewer`.
- **Fail closed on ambiguous context.** A user with several memberships must
  choose one authorized tenant. Missing, suspended, revoked, stale, malformed,
  or ambiguous context denies the operation rather than falling back to a
  recent tenant, a local default, or a global view.
- **Defend in depth in PostgreSQL.** Repository methods scope every query to
  `TenantContext`, and RLS independently rejects rows outside the transaction's
  validated tenant setting. The application database role must neither own
  tenant tables nor bypass RLS.
- **Keep every data plane tenant-scoped.** File paths, search and vector
  retrieval, caches, jobs, exports, notifications, logs, and dashboards must
  carry and validate the same tenant boundary. No global cache, index, worker,
  or operator view may expose tenant data without separately authorized
  platform-administration policy.
- **Limit privileged identities.** Migration, emergency administration, and
  service identities are separate from user-facing application traffic. Each
  has only the tenant and operation scope it needs, and all membership,
  ownership, and privileged actions are auditable.

The acceptance tests in this document must include deliberate cross-tenant
read, write, search, relationship, cache, job, export, and notification
attempts. A passing application-level filter alone is not sufficient proof of
isolation.

## Database enforcement

PostgreSQL is the target authoritative store for cloud-capable Ranch OS
modules. Application filtering alone is insufficient. DEV implementation must
use Row Level Security (RLS) as defense in depth.

For every request and worker transaction, the authoritative API must validate
and set transaction-local principal, environment, and tenant settings before a
tenant repository runs. The required settings are `ranchos.principal_id`,
`ranchos.environment`, and, after membership authorization,
`ranchos.tenant_id`. Each must use `SET LOCAL`; connection-level state is
prohibited.

`ranchos.require_uuid_setting(name)` must read the setting, reject a missing or
malformed value, and never substitute a default. A missing, malformed, stale,
or unauthorized principal, environment, or tenant setting must deny access.

Every tenant-owned table must use both `ENABLE ROW LEVEL SECURITY` and `FORCE
ROW LEVEL SECURITY`. Its policies must use `USING` and `WITH CHECK` clauses
tied to `ranchos.require_uuid_setting('ranchos.tenant_id')`. This is required
for reads, inserts, updates, and deletes; a policy that protects only a
repository's usual query shape is insufficient.

The application database role must not own tenant tables or have `BYPASSRLS`.
Migrator, runtime, emergency-administration, and service identities are
separate, least-privilege, environment-bound identities and must not be used
interchangeably. Database policies complement, rather than replace,
application authorization: role permissions and action-level policy still
apply.

## Tenant-scoped subsystems

Every data-bearing subsystem carries the same boundary:

| Subsystem                 | Required isolation                                                                                                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Files and documents       | Store beneath a tenant-specific namespace such as `tenants/<tenant-id>/...`; authorize before issuing paths or downloads; reject traversal and cross-tenant moves.                          |
| Search and vectors        | Persist `tenant_id` with each record and require it as a mandatory retrieval predicate before ranking, previewing, or generating context.                                                   |
| Background jobs           | Store `tenant_id`, initiating actor or service identity, and correlation ID in each job; workers re-establish and authorize context before reading or writing.                              |
| Caches                    | Prefix and validate keys with `tenant_id`; never cache a tenant result under a global or user-only key.                                                                                     |
| Exports and notifications | Bind recipient, source records, generated files, and delivery attempts to the active tenant; reauthorize at delivery when access can have changed.                                          |
| Audit and observability   | Record tenant, actor, service identity, operation, and correlation ID; queries and dashboards are tenant-scoped unless an explicitly authorized platform-administration view is introduced. |

The current RanchBrain alpha stores memories and indexes in local files. It is
single-tenant until the tenant-specific data-root and repository boundary are
implemented. It must not claim cloud-grade tenant isolation before that work is
complete.

## Local bootstrap

DEV initializes the existing local ranch as one explicit bootstrap tenant. The
bootstrap tenant ID and initial owner identity are DEV configuration, never
hard-coded in application logic or embedded in files. Existing local data must
move into the bootstrap tenant namespace through an explicit, idempotent DEV
migration; the runtime must not silently fall back to unscoped legacy paths.

Local single-ranch operation uses the same `TenantContext`, repository, and
data layout as cloud-capable operation. It is a convenience configuration, not
a separate authorization model.

Health and personal-finance records require a separately approved per-user
privacy policy. Tenant membership alone is not sufficient authorization for
those future records, even when their tenant boundary is correct.

## DEV rollout sequence

1. Add the foundational `VerifiedPrincipal` adapter contract, tenant, user,
   membership, and `TenantContext` types with focused unit tests.
2. Add the first vertical slice: DEV schema migrations for tenants, users,
   memberships, and tenant-owned RanchBrain memories, with tenant-scoped
   indexes, foreign keys, and RLS policies using an isolated DEV database.
3. Add adversarial two-tenant RLS integration tests before converting another
   resource or subsystem.
4. Add the bootstrap tenant and explicit, idempotent migration of existing
   local data into its namespace.
5. Convert each Ranch OS module and subsystem to tenant-scoped repository,
   storage, search, job, cache, export, notification, and audit interfaces.

No step changes Production schemas, credentials, configuration, deployment, or
data. Production rollout requires a separate reviewed migration and rollback
plan after DEV evidence is accepted.

## Isolation acceptance tests

DEV implementation is acceptable only when tests prove all of the following:

1. A Tenant A user cannot list, retrieve, create, modify, delete, search,
   export, or receive a notification for Tenant B data.
2. A multi-tenant user can act only in an explicit authorized `TenantContext`.
3. An intentionally unfiltered repository query does not bypass database RLS.
4. Unauthorized, missing, stale, or ambiguous tenant context fails closed.
5. Files, indexes, jobs, cache entries, exports, notifications, and audit
   records do not cross tenant boundaries.
6. The bootstrap tenant preserves local single-ranch behavior through the same
   scoped code path.
7. The adversarial two-tenant RLS suite proves Tenant A cannot read or write
   Tenant B data even when an application repository omits its tenant
   predicate.
8. A validated CAP security event received after DEV enrollment shortens or
   revokes the applicable enrollment/session, requires fresh verification, and
   writes a redacted audit event without replacing request-time OIDC or
   principal validation.
9. A malformed, replayed, unsigned, wrong-audience, or otherwise untrusted CAP
   event is denied, makes no enrollment/session change, and records only a
   redacted denied-event audit result.

## Threats and non-goals

The design specifically defends against client-supplied tenant IDs, missing
query filters, cross-tenant foreign keys, stale membership, unscoped search,
shared cache keys, misrouted workers, unsafe file paths, and privileged
application database roles.

This design does not define billing, public cloud hosting, invitation UX,
cross-tenant sharing, data residency, retention policy, Production activation,
or a separate Production OpenClaw gateway trust boundary. Per-user Health and
personal-finance privacy is also deferred. Each needs its own approved design
before implementation.

## Related architecture

- `docs/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md`
- `docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md`
- `docs/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md`
- `ARCHITECTURE.md`
- `DATA_MODEL.md`
- `LIVESTOCK_MANAGEMENT_DESIGN.md`
