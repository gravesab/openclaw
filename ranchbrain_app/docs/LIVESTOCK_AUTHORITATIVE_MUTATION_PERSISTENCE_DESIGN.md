# Ranch OS Livestock authoritative mutation persistence design

Status: Proposed for approval
Scope: Future durable mutation boundary for animal, identifier, and lifecycle contracts
Last updated: 2026-08-30 by A.Graves

This document defines the approval gate for making the local
`ranchbrain.livestock_write_model` contracts durable. It does not authorize a
database schema, migration, repository, ingress, credential, service, UI, or
Production implementation.

The repository-wide [atomic transaction design](../../docs/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md), [confirmation policy](../../docs/architecture/CANONICAL_CONFIRMATION_POLICY_V1.md), and [identity policy](../../docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md) remain authoritative.

## Authority boundary

Only a future Ranch OS authoritative mutation coordinator may persist a
Livestock command. It must receive an OpenClaw-authoritative
`VerifiedPrincipal`, derive a current `TenantContext`, authorize the exact
operation, and call an allowlisted local write contract. Clients, models, AI,
fixtures, direct database users, and background tools cannot open the
transaction or claim authority.

The first durable slice is limited to `animal_create`, `identifier_assign`,
`identifier_retire`, routine `lifecycle_record`, and owner-confirmed
`lifecycle_correct`. Sale, death, transfer, archive, care, feed, cost,
attachments, exports, notifications, jobs, legal ownership, and Finance posting
remain unavailable. Ranch Health is human-only and Ranch Finance owns its
ledger.

## Admission requirements

Before starting a transaction, the coordinator must have a versioned immutable
principal from the sole deployed ingress; an explicit active tenant selection;
current membership and exact capability; a bounded typed command; canonical
digest; tenant-bound idempotency key; target manifest; provenance references;
policy and validator versions; and a correlation ID.

Lifecycle correction additionally requires a current owner confirmation bound
to actor, tenant, operation, target, digest, policy, validator, and idempotency
identity. Missing, expired, forged, ambiguous, malformed, or unsupported facts
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

## Required proof before implementation

Against a disposable isolated DEV database, adversarial tests must prove:

1. Tenant A cannot create, retire, reuse, correct, or discover Tenant B data,
   including through an intentionally unfiltered repository query.
2. Invalid principal/context facts never start a durable transaction.
3. `SET LOCAL` context and forced RLS block missing, malformed, and
   cross-tenant access.
4. Identifier reuse and concurrent assignment preserve immutable history.
5. Lifecycle ordering, supersession, confirmation consumption, idempotency, and
   audit rollback each have exactly one authoritative outcome.
6. No UI, AI, fixture, client, direct database role, or service identity bypasses
   the future trusted ingress and mutation coordinator.

## Decisions still required

Andrew must approve table/version schema, idempotency retention and status-query
policy, RLS function/policy naming, confirmation class and expiry, audit
retention/reader access, and the adversarial DEV proof plan. The deployed
OpenClaw-authoritative ingress remains a separate prerequisite.

## Related architecture

- [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md)
- [Livestock Management application blueprint](LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md)
- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
