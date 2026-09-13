# Ranch OS Livestock authoritative mutation persistence design

Status: Proposed for approval; DEV persistence decisions recorded
Scope: Future durable mutation boundary for animal, identifier, and lifecycle contracts
Last updated: 2026-09-13 by A.Graves

This document defines the approval gate for making the local
`ranchbrain.livestock_write_model` contracts durable. The recorded DEV
decisions below authorize only a later, separately landed unapplied DEV SQL
contract. They do not authorize applying that SQL, a repository, trusted
ingress, credential, service, UI, device work, or Production.

The repository-wide [atomic transaction design](../../docs/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md), [confirmation policy](../../docs/architecture/CANONICAL_CONFIRMATION_POLICY_V1.md), and [identity policy](../../docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md) remain authoritative.

## Authority boundary

Only a future Ranch OS authoritative mutation coordinator may persist a
Livestock command. It must receive an OpenClaw-authoritative
`VerifiedPrincipal`, derive a current `TenantContext`, authorize the exact
operation, and call an allowlisted local write contract. Clients, models, AI,
fixtures, direct database users, and background tools cannot open the
transaction or claim authority.

The first durable slice is limited to `animal_create`, `identifier_assign`,
`identifier_retire`, routine `lifecycle_record`, and `lifecycle_correct`.
Each of those five operations requires a current CF-2 confirmation. Sale,
death, transfer, archive, care, feed, cost,
attachments, exports, notifications, jobs, legal ownership, and Finance posting
remain unavailable. Ranch Health is human-only and Ranch Finance owns its
ledger.

## Admission requirements

Before starting a transaction, the coordinator must have a versioned immutable
principal from the sole deployed ingress; an explicit active tenant selection;
current membership and exact capability; a bounded typed command; canonical
digest; tenant-bound idempotency key; target manifest; provenance references;
policy and validator versions; and a correlation ID.

Every first-slice operation additionally requires a current CF-2 confirmation
bound to actor, tenant, operation, target, digest, policy, validator, and
idempotency identity. The confirmation is fresh and single-use. Freshness
expires 2 minutes after issuance and is enforced with trusted
transaction-time state, not client, confirmation, or wall-clock claims.
Missing, expired, forged, ambiguous, malformed, reused, or unsupported facts
fail closed. Admission does not consume confirmation, write a success audit, or
mutate livestock data.

## One authoritative transaction

Before repository access, the coordinator must set only transaction-local
PostgreSQL settings:

```sql
SET LOCAL ranchos.principal_id = '<server-derived principal UUID>';
SET LOCAL ranchos.environment = '<server-derived environment>';
SET LOCAL ranchos.tenant_id = '<server-authorized tenant UUID>';
```

The runtime role must not own tenant tables or have `BYPASSRLS`. Tenant tables
must enable and force RLS and use `USING` plus `WITH CHECK` policies tied to
`ranchos.require_uuid_setting('ranchos.tenant_id')`. Missing/malformed settings
deny access; connection-level state and pool residue are prohibited.

One transaction must obtain database time; lock targets in deterministic order;
recheck authority and mutable facts; reserve/resolve idempotency; validate
invariants; apply one immutable record; consume confirmation when required;
write audit evidence and final idempotency outcome; then commit once. Any
failure rolls back all of those effects. Network calls, inference, files,
notifications, caches, and Finance work stay outside the transaction.

## Operation invariants

| Operation                | Transaction-time invariant                                                     | Concurrency rule                                                      |
| ------------------------ | ------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| Animal create            | Controlled classification; tenant from context; unused ID.                     | Tenant-bound create-if-absent identity.                               |
| Identifier assign        | No active same-tenant `(type, normalized_value)`.                              | Lock/constrain the active identifier key.                             |
| Identifier retire        | Identifier is tenant-owned and active; retirement follows assignment.          | Lock state; exactly one retirement succeeds.                          |
| Routine lifecycle record | Closed event type; tenant-owned animal; ordered occurrence time.               | Lock ordering state or use versioned append predicate.                |
| Lifecycle correction     | Same tenant/animal/type, unsuperseded target, one eligible owner confirmation. | Lock target and confirmation; reject second supersession/consumption. |

Conflicts must not silently merge, reorder, overwrite, or reinterpret commands.
Retries repeat all checks with the identical immutable input and idempotency
identity only.

## Idempotency, confirmation, and audit

Idempotency binds tenant, actor/service identity, operation, command digest,
target manifest, policy/validator version, and confirmation when present. An
identical replay returns its original outcome without another append,
confirmation consumption, or success audit. The same key with different content
returns a stable conflict. Ambiguous outcomes remain blocked until durable
transaction/idempotency state proves the result.

Every committed mutation writes immutable tenant-scoped audit evidence in the
same transaction: transaction ID, tenant, operation, targets, actor/principal,
correlation ID, policy/validator versions, idempotency outcome, versions,
provenance, confirmation reference, and bounded result metadata. Audit records
must never contain raw tokens, credentials, SQL, reusable confirmations, or
unsupported client claims.

## Approved DEV persistence decisions

These decisions are recorded for a later unapplied DEV SQL contract. They do
not apply SQL, open ingress, create a repository, or touch Production.

### Identifier assignment and retirement

Immutable `animal_identifiers` assignment rows are never updated to retire.
Retirement is a separate `animal_identifier_retirements` row: `id`,
`tenant_id`, `identifier_id`, closed reason (`replaced`, `lost`, `invalid`,
`duplicate`), `retired_at`, and audit facts. Active uniqueness is tenant-scoped
on `(identifier_type, normalized_value)` for assignments that have no matching
retirement. Identifier types remain `ear_tag`, `rfid`, `brand`, and
`registry_number`. In-place `retired_at` on the assignment, `tag`, and
`vendor_label` are rejected.

### Lifecycle correction and supersession

Routine and correction events share `livestock_lifecycle_events`. A correction
inserts a new same-type row with `supersedes_event_id` and a closed correction
reason. Exactly one successor per target is enforced. The original row is never
updated. Event types remain `intake`, `tagged`, and `weight_recorded`.

### Provenance and audit

Domain livestock rows carry `LivestockFactProvenance` columns (source type, id,
version, observed_at). Mutation audit is a separate
`ranchos.livestock_mutation_audit` table written in the same transaction as the
domain change, idempotency outcome, and confirmation consumption. Audit stores
transaction ID, tenant, operation, targets, actor/principal, correlation ID,
policy/validator versions, idempotency outcome, provenance reference,
confirmation reference, and bounded result metadata. It must not store tokens,
credentials, SQL, reusable confirmations, or unsupported client claims.

### Idempotency retention and status query

A tenant-scoped idempotency row holds scope, key digest, operation, outcome,
and transaction ID. Rows are retained indefinitely. A status query is allowed
only with a current `TenantContext` and the exact key. The same key with a
different digest is a stable conflict.

### Confirmation class and expiry

All five first-slice operations are CF-2. Confirmations are fresh and
single-use. Freshness expires 2 minutes after issuance and is enforced with
trusted transaction-time state. Registering these operations on the
repository-wide confirmation matrix is a separate docs change. Sale, death,
transfer, archive, and Production stay out of slice and are not lowered to
CF-2.

### Audit retention and reader access

Livestock mutation audit is write-only in this slice. There is no livestock
audit reader, viewer path, or new read capability. Retention is indefinite.
Least-privilege RLS still applies. A later reader needs its own approval.

### RLS naming and ownership

Reuse the committed tenancy foundation: `ranchos.require_uuid_setting`,
`<table>_tenant_isolation` `USING`/`WITH CHECK` on `ranchos.tenant_id`, ENABLE
and FORCE RLS, `OWNER TO ranchos_dev_migrator`, and `ranchos_dev_runtime`
without `BYPASSRLS`. Migrator-only apply and a never-apply-to-Production header
are required on any later livestock SQL file.

### Adversarial two-tenant SQL proof

The SQL-land gate is a disposable-DEV, rollback-only proof after `001`:
unfiltered reads on every livestock table in that file (animals, assignments,
retirements, lifecycle events, provenance-bearing domain rows, mutation audit,
and idempotency); cross-tenant assign, retire, and correct denied; missing or
malformed `SET LOCAL` denied; runtime has no `BYPASSRLS`. Fixtures use
`ear_tag` and may use `pet` / `companion`. Stale `'tag'` fixtures are
rejected. Coordinator concurrency, confirmation-consumption races, and
idempotency replay races remain later live proof, not the SQL-land gate.

### Authorization to land unapplied livestock SQL

After this design amendment, a separately authorized change may land only:

- `ranchbrain_app/migrations/002_livestock_read_model_foundation.sql`
- `ranchbrain_app/tests/rls/two_tenant_livestock_isolation.sql`
- `ranchbrain_app/tests/test_livestock_migration_contract.py`

That change must match these decisions and the committed `pet` / companion
catalog. It must not apply SQL, create roles, open ingress, add a repository,
or touch Production. The current untracked `002` is stale and must not land
as-is.

## Required proof before implementation

Against a disposable isolated DEV database, adversarial tests must prove:

1. Tenant A cannot create, retire, reuse, correct, or discover Tenant B data,
   including through an intentionally unfiltered query.
2. Invalid principal/context facts never start a durable transaction.
3. `SET LOCAL` context and forced RLS block missing, malformed, and
   cross-tenant access.
4. Identifier reuse and concurrent assignment preserve immutable history.
5. Lifecycle ordering, supersession, confirmation consumption, idempotency, and
   audit rollback each have exactly one authoritative outcome.
6. No UI, AI, fixture, client, direct database role, or service identity bypasses
   the future trusted ingress and mutation coordinator.

Items 1 and 3 are the SQL-land gate. Items 2, 4, 5, and 6 stay closed until a
later coordinator implementation is approved.

## Remaining before apply

- Register the five livestock operations on the canonical confirmation matrix
  as CF-2, or keep them livestock-local until that matrix change is approved.
- Provision disposable-DEV migrator/runtime roles and apply only under a later
  explicit apply approval.
- The deployed OpenClaw-authoritative ingress remains a separate prerequisite.

## Related architecture

- [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md)
- [Livestock Management application blueprint](LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md)
- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
