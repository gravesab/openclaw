---
title: "Atomic Authoritative Write and Audit Transaction Design v1"
summary: "Normative transaction design for atomic authoritative mutations, confirmation consumption, idempotency, concurrency, audit, and post-commit delivery"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-04"
category: "Architecture"
source_document: "ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md"
read_when:
  - Implementing or reviewing an authoritative mutation transaction
  - Designing audit, idempotency, confirmation consumption, concurrency, or outbox behavior
  - Evaluating failure recovery, ambiguous outcomes, bulk writes, or post-commit effects
---

# Atomic Authoritative Write and Audit Transaction Design v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-04

This design extends the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1) and the [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1). Those documents remain authoritative for proposals, capability and confirmation classification, challenge issuance, and confirmation records. This document defines the atomic application boundary.

Normative requirements use stable **ATX** identifiers. Examples are explanatory and do not grant authority.

## 1. Governing atomicity invariant

> An authoritative state mutation, its required audit evidence, durable idempotency outcome, and any required confirmation consumption MUST commit in one authoritative transaction or MUST all remain uncommitted.

- **ATX-001:** PostgreSQL MUST be the authoritative commit boundary for governed OpenClaw state.
- **ATX-002:** The authoritative API MUST be the sole coordinator allowed to enter this transaction boundary.
- **ATX-003:** A success response MUST correspond to one durable committed outcome.
- **ATX-004:** Audit persistence failure MUST prevent mutation, idempotency completion, and confirmation consumption.
- **ATX-005:** Transaction ambiguity MUST fail closed until authoritative status is proven.
- **ATX-006:** Process memory, client state, model memory, files, logs, queues, or caches MUST NOT substitute for the authoritative transaction.

## 2. Trust and transaction boundaries

The architecture has four distinct boundaries:

1. **Proposal preparation:** clients, models, retrieval, tools, and offline queues MAY prepare inert proposals.
2. **Pre-transaction admission:** deterministic server code performs bounded parsing, authentication, authorization, policy classification, canonicalization, and preliminary validation.
3. **Authoritative transaction:** one database transaction rechecks mutable facts, reserves idempotency, applies the allowlisted mutation, consumes confirmation when required, records audit, and commits.
4. **Post-commit delivery:** outbox consumers and response delivery observe only committed results and MUST NOT change the authoritative outcome.

- **ATX-007:** Every input crossing into the authoritative transaction MUST be treated as untrusted until revalidated against authoritative state.
- **ATX-008:** Models, retrieval, clients, integrations, App Intents, administrators, and service identities MUST NOT open or control the authoritative database transaction.
- **ATX-009:** Transaction duration MUST be bounded and MUST exclude model inference, retrieval, human interaction, network calls, artifact upload, and other unbounded external work.
- **ATX-010:** Database roles, network policy, and schema constraints SHOULD provide defense in depth without replacing server authorization.

## 3. Transaction input contract

The coordinator MUST construct an immutable transaction input before beginning the transaction.

| Field                     | Required authoritative semantics                                                           |
| ------------------------- | ------------------------------------------------------------------------------------------ |
| transaction_input_version | Supported exact schema version; unknown versions fail closed.                              |
| proposal_id               | Server-issued immutable proposal identifier.                                               |
| canonical_proposal_digest | Server-recalculated digest of the exact proposed operation.                                |
| operation_id              | Stable operation identifier resolved in the confirmation matrix.                           |
| module_id and handler_id  | Allowlisted module and deterministic mutation handler.                                     |
| target_set                | Bounded immutable resource identifiers and expected versions.                              |
| actor_context             | Server-derived actor, service identity, roles, delegations, and revocation context.        |
| authorization_decision    | Stable policy decision and version, subject to transaction-time recheck.                   |
| validator_version         | Exact deterministic validator version.                                                     |
| confirmation_class        | Server-derived CF-0, CF-1, CF-2, or CF-3 classification.                                   |
| confirmation_record_id    | Exact record identifier when confirmation is required; otherwise absent.                   |
| idempotency_scope and key | Non-secret durable key bound to actor, operation, module boundary, and canonical content.  |
| provenance_refs           | Bounded server-authorized evidence references.                                             |
| request_context           | Correlation ID, verified client/channel context, and bounded model participation metadata. |
| proposed_values           | Typed canonical values accepted by the allowlisted handler.                                |

- **ATX-011:** Unknown input fields, unsupported versions, absent required fields, or ambiguous encodings MUST be rejected before the transaction.
- **ATX-012:** The server MUST derive or independently verify every authority-bearing field.
- **ATX-013:** Credentials, raw tokens, signing secrets, SQL, internal paths, unrestricted payloads, and reusable confirmation material MUST NOT enter audit or idempotency records.
- **ATX-014:** The transaction input MUST be immutable for one application attempt; any material change requires new canonical identity and revalidation.

## 4. Pre-transaction admission

Before opening a database transaction, the server MUST:

1. enforce request size, decompression, nesting, collection, string, and reference limits;
2. validate the exact proposal-envelope and transaction-input schemas;
3. authenticate the actor and service identity;
4. authorize the operation and target scope;
5. resolve the operation and confirmation class in current versioned policy;
6. reject CF-0 and unresolved CF-3 operations;
7. recalculate canonical identity and compare any supplied digest;
8. run deterministic semantic and provenance validation that does not require locks;
9. verify that the handler is allowlisted and transaction-safe;
10. prepare sanitized public reason codes and protected correlation context.

- **ATX-015:** Pre-transaction success MUST NOT guarantee commit; mutable facts MUST be rechecked inside the transaction.
- **ATX-016:** Admission MUST fail closed when identity, policy, validator, canonicalization, trusted time, provenance, handler registration, or authoritative storage is missing or indeterminate.
- **ATX-017:** Admission MUST NOT consume confirmation, reserve a durable success outcome, mutate target state, or emit a success audit record.

## 5. Normative in-transaction sequence

The coordinator MUST execute the following steps in order within one database transaction:

1. **Begin and identify.** Begin with the approved isolation mode and assign one server-generated transaction identifier.
2. **Establish trusted time.** Read authoritative database time for expiry, ordering, and audit timestamps.
3. **Lock or condition targets.** Load every bounded target and related invariant row using deterministic lock order or atomic version predicates.
4. **Recheck authority.** Revalidate actor, service identity, delegation, revocation, operation policy, capability, handler, validator, and confirmation class against transaction-time state.
5. **Recheck proposal identity.** Recalculate or verify the canonical digest and exact target set against the immutable input.
6. **Enforce concurrency.** Compare every expected record version and invariant precondition; stale or missing state conflicts.
7. **Reserve or resolve idempotency.** Atomically create the scoped reservation or load the existing authoritative outcome.
8. **Verify confirmation.** For CF-2 or approved CF-3, lock and verify the exact unused record, binding, trusted-time validity, actor, operation, target, versions, policy, validator, digest, and idempotency identity.
9. **Run final deterministic validation.** Validate current values, relationships, constraints, provenance references, and operation-specific invariants under the acquired locks.
10. **Apply the allowlisted mutation.** Invoke only the selected deterministic handler and capture exact before/after versions and bounded result data.
11. **Consume confirmation.** When required, mark the exact record consumed and bind it to the transaction and result; zero or multiple affected rows fail.
12. **Persist audit and idempotency outcome.** Write the immutable audit record, final idempotency outcome, and any required transactional outbox rows.
13. **Commit once.** Commit the transaction, then return or recover the committed authoritative outcome.

- **ATX-018:** No step MAY be skipped because a client, model, prior request, cache, or UI claims it passed.
- **ATX-019:** A failure before commit MUST roll back all writes from steps 7 through 12.
- **ATX-020:** The coordinator MUST NOT report success before commit acknowledgement.
- **ATX-021:** A handler MUST NOT perform external side effects inside the transaction.
- **ATX-022:** Database constraint or serialization failures MUST be treated as authoritative rejection or retryable conflict, never partial success.

## 6. Atomic audit record

Every committed mutation MUST produce one immutable audit event or a bounded set linked by one transaction identifier.

| Audit field                             | Required semantics                                                                     |
| --------------------------------------- | -------------------------------------------------------------------------------------- |
| audit_format_version                    | Exact schema version.                                                                  |
| transaction_id                          | Server-generated identifier shared with confirmation, idempotency, and outbox records. |
| occurred_at                             | Authoritative database commit-time context.                                            |
| proposal_id and digest                  | Exact canonical proposal identity.                                                     |
| operation, module, resource, target set | Stable identifiers, never labels alone.                                                |
| actor and service identity              | Server-derived effective authority and delegation reference.                           |
| policy and validator versions           | Exact versions evaluated at commit.                                                    |
| confirmation                            | Class, record reference, and consumption result without reusable secrets.              |
| idempotency                             | Scope, non-secret key reference or digest, reservation, and final outcome.             |
| concurrency                             | Expected and resulting record versions.                                                |
| provenance                              | Bounded authorized evidence references and model participation.                        |
| mutation result                         | Stable outcome code and bounded before/after facts or protected references.            |
| request context                         | Correlation, verified client/channel, and retry relationship.                          |
| failure context                         | Stable sanitized reason code when policy requires failed-attempt audit.                |

- **ATX-023:** Ordinary clients MUST NOT update or delete authoritative audit records.
- **ATX-024:** Audit retention, access, integrity, and redaction MUST be least-privilege and policy governed.
- **ATX-025:** Required failed-attempt audit MAY use a separate protected transaction only after the failed mutation transaction rolls back; it MUST NOT claim a mutation committed.
- **ATX-026:** Failure to write optional telemetry MUST NOT be confused with failure to write required authoritative audit.

## 7. Confirmation consumption

- **ATX-027:** CF-1 operations MUST record the server-derived classification and MUST NOT fabricate a confirmation record.
- **ATX-028:** CF-2 and approved CF-3 operations MUST consume exactly one eligible record in the same transaction as mutation and audit.
- **ATX-029:** Confirmation consumption MUST use an atomic state predicate or locked row so concurrent requests cannot both consume it.
- **ATX-030:** Transaction rollback MUST restore the record to its prior eligible state unless authoritative evidence proves a different terminal state.
- **ATX-031:** An ambiguous commit MUST NOT make a confirmation reusable; recovery MUST first resolve the transaction or idempotency outcome.
- **ATX-032:** A changed proposal, target version, actor, operation, policy, validator, authorization, device/session binding, or idempotency identity MUST invalidate the confirmation.

## 8. Idempotency and ambiguous outcomes

- **ATX-033:** Idempotency scope MUST bind actor or service identity, operation, module or tenant boundary, canonical digest, target set, and confirmation record when applicable.
- **ATX-034:** The reservation and final outcome MUST be durable, shared across instances, and transactionally coupled to the mutation.
- **ATX-035:** An identical replay after commit MUST return the original outcome and MUST NOT re-run the handler, consume again, or create a second success audit.
- **ATX-036:** The same key with different bound content MUST fail with a stable idempotency conflict.
- **ATX-037:** An in-progress reservation MAY be waited on or returned as retryable pending under bounded policy; it MUST NOT authorize parallel execution.
- **ATX-038:** On lost response or connection, the client SHOULD query or retry with the identical scoped key.
- **ATX-039:** The server MUST resolve ambiguity from authoritative idempotency and transaction state, not from client belief or process-local memory.
- **ATX-040:** If status cannot be proven, mutation retry and confirmation reuse MUST remain blocked.

## 9. Concurrency and isolation

- **ATX-041:** Every mutable target MUST use an expected version, compare-and-set predicate, row lock, or stronger approved invariant.
- **ATX-042:** Multi-row invariants MUST use a documented isolation and locking strategy that prevents write skew.
- **ATX-043:** Locks MUST be acquired in a stable global order and held only for the bounded transaction.
- **ATX-044:** Serialization failures and deadlocks MAY be retried only with the identical immutable input and idempotency identity under a bounded server policy.
- **ATX-045:** A retry MUST re-run all transaction-time checks and MUST NOT reuse stale in-memory state.
- **ATX-046:** Conflict responses MUST be stable and sanitized and MUST NOT silently merge, overwrite, or reinterpret the proposal.

## 10. Multi-resource and bulk operations

- **ATX-047:** A request MUST declare a complete bounded target manifest before transaction admission.
- **ATX-048:** The safest default is all-or-nothing application in one transaction with deterministic lock order.
- **ATX-049:** Partial success MUST be prohibited unless a separately approved operation contract defines partitions, confirmation scope, idempotency, audit, compensation, and client semantics.
- **ATX-050:** A saga or compensation design MUST NOT be described as atomic and MUST fail closed until separately approved.
- **ATX-051:** Bulk operations MUST use the strongest applicable confirmation class and MUST NOT inherit a single item's weaker class.
- **ATX-052:** Resource, row, statement, lock, and transaction-time limits MUST be enforced before and during execution.

## 11. Post-commit effects and outbox delivery

- **ATX-053:** Required downstream delivery MUST be represented by an outbox row written in the authoritative transaction.
- **ATX-054:** Outbox consumers MUST process only committed rows and MUST be idempotent by stable event identifier.
- **ATX-055:** Notification, indexing, cache invalidation, model invocation, webhook, file movement, and message delivery MUST occur after commit.
- **ATX-056:** Post-commit delivery failure MUST NOT roll back or misreport the committed authoritative mutation.
- **ATX-057:** Delivery retries MUST preserve ordering where the operation contract requires it and MUST expose bounded dead-letter or operator-review state.
- **ATX-058:** If a downstream effect is necessary for correctness and cannot be expressed transactionally or compensated safely, the mutation MUST remain unsupported.

## 12. Failure and recovery matrix

| Failure case                                                    | Commit state                 | Confirmation state              | Idempotency state               | Audit state                                            | Client result and retry                           | Fail-closed rule                             |
| --------------------------------------------------------------- | ---------------------------- | ------------------------------- | ------------------------------- | ------------------------------------------------------ | ------------------------------------------------- | -------------------------------------------- |
| Malformed or oversized input                                    | None                         | Unchanged                       | None                            | Optional rejected-attempt                              | Stable rejection; correct input with new identity | No transaction opens.                        |
| Authentication failure                                          | None                         | Unchanged                       | None                            | Protected attempt if required                          | Unauthorized; reauthenticate                      | Confirmation cannot cure authn.              |
| Authorization or CF-0 failure                                   | None                         | Unchanged                       | None                            | Protected attempt if required                          | Forbidden                                         | No handler runs.                             |
| Missing or unresolved CF-3 policy                               | None                         | Unchanged                       | None                            | Protected attempt                                      | Blocked                                           | Strong policy cannot be guessed.             |
| Canonical digest mismatch                                       | None                         | Unchanged                       | None                            | Optional rejected-attempt                              | Conflict; rebuild proposal                        | Never normalize ambiguously.                 |
| Expired proposal or trusted-time failure                        | None                         | Unchanged or expired by policy  | None                            | Protected attempt if required                          | Expired/unavailable                               | Client time cannot extend validity.          |
| Target missing                                                  | None                         | Unchanged                       | Rolled back or stable rejection | Required rejection if policy says                      | Not found or conflict                             | Do not retarget by label.                    |
| Stale target version                                            | None                         | Unchanged or superseded         | Rolled back or stable conflict  | Required conflict audit if policy says                 | Conflict; create new proposal                     | Never silently rebase.                       |
| Idempotency key with different content                          | Prior outcome unchanged      | Unchanged                       | Existing record unchanged       | Conflict attempt if required                           | Idempotency conflict; no retry with same key      | Never replace reservation.                   |
| Identical replay after commit                                   | Already committed            | Already consumed if required    | Original outcome                | Original success audit                                 | Return original outcome                           | No second handler run.                       |
| Concurrent duplicate before commit                              | At most one                  | At most one consumption         | One reservation                 | At most one success audit                              | Other request waits or returns pending/original   | Process-local locks insufficient.            |
| Missing confirmation                                            | None                         | Absent                          | Rolled back                     | Rejection if required                                  | Confirmation required                             | No mutation.                                 |
| Wrong, expired, or superseded confirmation                      | None                         | Unchanged or terminal by policy | Rolled back                     | Rejection if required                                  | Stable confirmation error                         | Never consume another record.                |
| Concurrent confirmation reuse                                   | At most one                  | Exactly one or zero consumption | One winning outcome             | At most one success audit                              | Loser returns replay/conflict                     | Atomic predicate required.                   |
| Final semantic validation failure                               | None                         | Unchanged                       | Rolled back or stable rejection | Rejection if required                                  | Correct and repropose                             | No partial writes.                           |
| Database constraint failure                                     | None                         | Unchanged                       | Rolled back                     | Protected failure audit after rollback if required     | Stable validation/conflict                        | Constraint failure is not success.           |
| Serialization failure or deadlock                               | None                         | Unchanged                       | Rolled back or pending cleared  | No success audit                                       | Bounded identical retry allowed                   | Recheck every fact.                          |
| Handler exception                                               | None                         | Unchanged                       | Rolled back                     | Protected sanitized failure after rollback if required | Internal error; retry only by policy              | No raw exception disclosure.                 |
| Audit insert failure                                            | None                         | Unchanged                       | Rolled back                     | None committed                                         | Audit unavailable                                 | Mutation MUST roll back.                     |
| Outbox insert failure when required                             | None                         | Unchanged                       | Rolled back                     | None committed                                         | Delivery unavailable                              | Required effect blocks commit.               |
| Commit rejected before acknowledgement                          | None                         | Unchanged                       | Rolled back                     | None committed                                         | Retry identical request if non-ambiguous          | Never report success.                        |
| Commit acknowledgement lost                                     | Unknown until resolved       | MUST be treated non-reusable    | Authoritative lookup decides    | Authoritative lookup decides                           | Query/retry identical key                         | Block new execution until proven.            |
| Process crash before commit                                     | None after database recovery | Unchanged                       | Rolled back                     | None committed                                         | Identical retry                                   | Database recovery is authoritative.          |
| Process crash after commit                                      | Committed                    | Consumed if required            | Completed                       | Committed                                              | Return original result on retry                   | Do not repeat mutation.                      |
| Response serialization or delivery failure                      | Committed                    | Consumed if required            | Completed                       | Committed                                              | Identical retry/status lookup                     | Transport failure cannot undo commit.        |
| Post-commit consumer failure                                    | Committed                    | Consumed if required            | Completed                       | Committed plus pending delivery                        | Retry outbox event                                | Never claim mutation failed.                 |
| Audit store, idempotency store, or authoritative DB unavailable | None                         | Unchanged                       | None                            | None                                                   | Service unavailable                               | No fallback store.                           |
| Multi-resource limit exceeded                                   | None                         | Unchanged                       | None or rolled back             | Rejection if required                                  | Reduce scope and create new proposal              | No implicit partitioning.                    |
| Cancellation during transaction                                 | Determined by commit         | Determined by commit            | Authoritative outcome           | Authoritative outcome                                  | Status lookup                                     | Client disconnect is not rollback authority. |
| Indeterminate recovery metadata                                 | Unknown                      | Failed-safe/non-reusable        | Blocked                         | Protected recovery event                               | Operator/security recovery                        | Never guess commit state.                    |

## 13. Security and privacy requirements

- **ATX-059:** Transaction logs, errors, audit, and telemetry MUST redact credentials, tokens, key material, nonces capable of replay, SQL, internal paths, raw exceptions, and unnecessary sensitive values.
- **ATX-060:** Audit and idempotency access MUST use least-privilege roles separated from ordinary client mutation permissions.
- **ATX-061:** Dynamic SQL, client-selected handlers, and model-selected capabilities MUST be prohibited.
- **ATX-062:** Provenance and artifact references MUST be reauthorized at transaction time and MUST NOT become executable instructions.
- **ATX-063:** Recovery and break-glass procedures MUST be separately governed, strongly authenticated, and auditable; they MUST NOT rewrite history silently.
- **ATX-064:** Retention and deletion policy MUST preserve required replay and audit evidence while minimizing sensitive data.

## 14. Observability and operational evidence

- **ATX-065:** Every attempt MUST have a correlation identifier; every committed mutation MUST have a transaction identifier.
- **ATX-066:** Metrics SHOULD distinguish admission rejection, concurrency conflict, idempotent replay, transaction rollback, ambiguous commit, audit failure, and outbox backlog.
- **ATX-067:** Health checks MUST NOT report mutation readiness when authoritative database, required audit, idempotency, policy, validator, trusted-time, or confirmation dependencies are unverifiable.
- **ATX-068:** Public health and errors MUST remain sanitized; protected diagnostics MAY include bounded technical evidence.
- **ATX-069:** Alerts SHOULD detect repeated ambiguity, replay conflicts, confirmation reuse, audit failure, dead-letter growth, and transaction latency limit breaches.

## 15. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                    |
| ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| ATM-001 | Mutation, required audit, idempotency completion, and confirmation consumption commit together.                                   |
| ATM-002 | Required audit failure rolls back every mutation write.                                                                           |
| ATM-003 | Required outbox failure rolls back every mutation write.                                                                          |
| ATM-004 | A client, model, tool, or administrator cannot bypass the authoritative coordinator.                                              |
| ATM-005 | Unknown input fields and unsupported versions fail before transaction entry.                                                      |
| ATM-006 | Mutable authority and policy facts are rechecked inside the transaction.                                                          |
| ATM-007 | Stale expected versions conflict without overwrite or silent rebase.                                                              |
| ATM-008 | Multi-row invariant tests prevent write skew under the selected isolation strategy.                                               |
| ATM-009 | Lock ordering and bounded deadlock retry produce no partial outcome.                                                              |
| ATM-010 | Identical concurrent requests produce at most one mutation and one success audit.                                                 |
| ATM-011 | An identical replay after success returns the original outcome only.                                                              |
| ATM-012 | Idempotency-key reuse with changed content fails closed.                                                                          |
| ATM-013 | An in-progress reservation cannot authorize parallel execution.                                                                   |
| ATM-014 | A lost success response is recovered through authoritative idempotency state.                                                     |
| ATM-015 | Indeterminate commit state blocks new execution and confirmation reuse.                                                           |
| ATM-016 | CF-1 records classification without a fabricated confirmation.                                                                    |
| ATM-017 | CF-2 consumes exactly one eligible record atomically.                                                                             |
| ATM-018 | Wrong, expired, superseded, or changed-binding confirmation cannot mutate.                                                        |
| ATM-019 | Concurrent confirmation replay across instances has at most one committed outcome.                                                |
| ATM-020 | Transaction rollback leaves an eligible confirmation reusable only for the identical still-valid request.                         |
| ATM-021 | Handler, constraint, serialization, deadlock, and process-crash failures leave no partial state.                                  |
| ATM-022 | Response loss or serialization failure after commit cannot cause a second mutation.                                               |
| ATM-023 | Bulk all-or-nothing failure leaves every target unchanged.                                                                        |
| ATM-024 | Unapproved partial-success or saga behavior fails closed.                                                                         |
| ATM-025 | Resource and transaction-duration limits reject oversized bulk work safely.                                                       |
| ATM-026 | Post-commit consumer failure leaves the mutation committed and retries one stable outbox event.                                   |
| ATM-027 | Model inference, retrieval, network calls, and human interaction never occur inside the transaction.                              |
| ATM-028 | Audit, logs, health, and public errors contain no forbidden secrets or raw internals.                                             |
| ATM-029 | Missing database, audit, idempotency, policy, validator, trusted-time, or confirmation dependencies block readiness and mutation. |
| ATM-030 | Recovery cannot infer success from client state, process memory, or an unverified external store.                                 |

This documentation task adds no executable tests.

## 16. Requirement-to-test traceability

| Requirement area                      | Requirements            | Tests                                              |
| ------------------------------------- | ----------------------- | -------------------------------------------------- |
| Atomic invariant and trust boundaries | ATX-001 through ATX-010 | ATM-001 through ATM-004, ATM-027, ATM-030          |
| Input and admission                   | ATX-011 through ATX-017 | ATM-005, ATM-006, ATM-029                          |
| Transaction sequence                  | ATX-018 through ATX-022 | ATM-001 through ATM-003, ATM-006, ATM-021, ATM-027 |
| Audit                                 | ATX-023 through ATX-026 | ATM-001, ATM-002, ATM-010, ATM-028                 |
| Confirmation                          | ATX-027 through ATX-032 | ATM-016 through ATM-020                            |
| Idempotency and ambiguity             | ATX-033 through ATX-040 | ATM-010 through ATM-015, ATM-022, ATM-030          |
| Concurrency and isolation             | ATX-041 through ATX-046 | ATM-007 through ATM-010, ATM-021                   |
| Multi-resource and bulk               | ATX-047 through ATX-052 | ATM-023 through ATM-025                            |
| Post-commit delivery                  | ATX-053 through ATX-058 | ATM-003, ATM-022, ATM-026                          |
| Security and privacy                  | ATX-059 through ATX-064 | ATM-004, ATM-018, ATM-027 through ATM-030          |
| Observability                         | ATX-065 through ATX-069 | ATM-014, ATM-015, ATM-026, ATM-028, ATM-029        |

## 17. Unresolved decisions

Owner and security review remain required for:

1. exact transaction isolation modes by operation family;
2. lock-order registry and bounded deadlock or serialization retry limits;
3. idempotency scope namespaces, key format, retention, and status-query authorization;
4. canonical serialization and digest algorithms inherited from the mutation contract;
5. database-time trust, clock-failure detection, and maximum skew;
6. audit schema, immutable-storage controls, retention, redaction, and failed-attempt policy;
7. confirmation and idempotency table schemas and recovery states;
8. outbox schema, delivery ordering, retention, retry, dead-letter, and operator recovery;
9. bulk target, statement, row, lock, duration, and payload limits;
10. operations eligible for one-transaction bulk handling;
11. any partial-success, saga, or compensation contract;
12. public reason-code registry and role-sensitive error detail;
13. disaster-recovery reconciliation of audit, idempotency, confirmation, and outbox state;
14. strong CF-3 transaction requirements and any multi-party confirmation;
15. transaction-safe artifact finalization when authoritative records reference external storage.

Unresolved decisions MUST fail closed. They MUST NOT be filled by client behavior, model reasoning, implementation convenience, or inferred precedent.

## 18. Non-goals and future deliverables

This document does not:

- implement mutation, confirmation, audit, idempotency, recovery, or outbox code;
- select database schemas, SQL, libraries, algorithms, isolation modes, or deployment topology;
- authorize direct database access by clients, models, tools, or integrations;
- authorize partial success, sagas, compensation, or CF-3 operations;
- create or modify migrations, including Migration 009;
- create or modify an external authority anchor;
- access or change Development or Production data, services, containers, or runtimes;
- modify PropertyManager application behavior, clients, App Intents, or deployment;
- authorize Production deployment or branch integration.

Future deliverables MAY define:

1. a full threat model for clients, models, tools, offline replay, retrieval, administrators, developers, and service identities;
2. exact audit, idempotency, confirmation-consumption, and outbox schemas;
3. executable concurrency, fault-injection, crash-recovery, and adversarial tests;
4. operation-specific transaction profiles and bulk limits;
5. disaster-recovery and ambiguity-resolution runbooks.

Implementation MUST NOT begin until applicable unresolved decisions receive owner and security approval.
