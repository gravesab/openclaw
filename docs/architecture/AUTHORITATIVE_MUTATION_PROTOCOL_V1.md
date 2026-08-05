---
title: "Authoritative Mutation Protocol v1"
summary: "Canonical server-enforced protocol for proposal admission, identity and delegation, validation, confirmation, concurrency, idempotency, atomic commit, audit, outbox, rejection, retry, and recovery"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-05"
category: "Architecture"
source_document: "AUTHORITATIVE_MUTATION_PROTOCOL_V1.md"
read_when:
  - Designing or reviewing an end-to-end authoritative mutation path
  - Defining proposal, command, confirmation, idempotency, concurrency, rejection, retry, or result behavior
  - Connecting identity, policy, validation, transaction, audit, outbox, and recovery requirements
---

# Authoritative Mutation Protocol v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-05

This protocol composes the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1), [Authoritative Mutation Threat Model v1](/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1), and [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1). Those documents remain normative. When this protocol is more restrictive, the more restrictive treatment applies; it MUST NOT weaken a governing contract.

Protocol requirements use stable **AMP** identifiers and acceptance tests use **APT** identifiers. Examples do not grant authority.

## 1. Governing invariant and protocol objective

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

The protocol defines the complete server-enforced lifecycle by which untrusted input may become eligible for authoritative consideration and, only after every current control succeeds, one authoritative committed result.

- **AMP-001:** Models, providers, retrievers, clients, tools, App Intents, automations, offline queues, synchronization systems, administrators, developers, and integrations MAY submit typed proposals but MUST NOT determine authoritative admissibility or success.
- **AMP-002:** The authoritative server MUST independently authenticate, authorize, evaluate delegation, validate provenance and semantics, select current policy and validator versions, determine confirmation, enforce concurrency and idempotency, and coordinate the authoritative transaction.
- **AMP-003:** Confirmation MUST remain separate from authentication, authorization, delegation, policy admissibility, provenance validation, concurrency, idempotency, and commit.
- **AMP-004:** A successful authoritative mutation, required audit evidence, durable idempotency outcome, required confirmation consumption, and required transactional outbox event MUST commit atomically.
- **AMP-005:** Missing, stale, inconsistent, unavailable, compromised, or unverifiable authority or evidence MUST fail closed.
- **AMP-006:** Only a committed authoritative result or an idempotent retrieval of that result MAY be represented as success.

## 2. Protocol roles and trust posture

| Role                                | Permitted protocol behavior                                                                                      |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Proposer                            | Submits bounded typed proposal data and provenance; cannot authorize or commit.                                  |
| Client                              | Transports requests and displays server results; cannot select policy, confirmation, or outcome.                 |
| Model, provider, retriever, or tool | Produces inert suggestions or evidence candidates; possesses no authoritative credential or mutation capability. |
| Human principal                     | Requests, reviews, confirms, or rejects within current identity and capability policy.                           |
| Service identity                    | Initiates only explicitly allowed operations and cannot satisfy human confirmation.                              |
| Authoritative admission service     | Performs deterministic pre-transaction evaluation and issues server evidence.                                    |
| Confirmation service                | Issues and verifies exact single-use confirmation under canonical policy.                                        |
| Mutation coordinator                | Rechecks mutable facts and executes the atomic authoritative transaction.                                        |
| Authoritative datastore             | Stores governed state and required transactional evidence.                                                       |
| Outbox consumer                     | Processes committed events idempotently after commit; cannot redefine transaction outcome.                       |
| Audit reader or operator            | Reviews protected evidence; cannot rewrite the authoritative result.                                             |

- **AMP-007:** Every role MUST use least privilege and MUST remain outside roles it is not explicitly assigned.
- **AMP-008:** Internal network, process location, host access, database access, client type, model choice, or administrator status MUST NOT imply protocol authority.
- **AMP-009:** The same component MAY implement multiple roles only if their logical authority boundaries, credentials, policy decisions, and audit evidence remain distinct and reviewable.
- **AMP-010:** Derived projections, caches, logs, dashboards, model memory, client state, and offline copies MUST remain non-authoritative.

## 3. Protocol objects and immutable identifiers

The protocol uses these distinct objects:

| Object                     | Purpose and authority                                                                    |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| Proposal envelope          | Non-authoritative typed requested change and provenance.                                 |
| Proposal record            | Server-accepted immutable proposal identity and lifecycle evidence.                      |
| Confirmation challenge     | Server-generated exact material-effect request when required.                            |
| Confirmation record        | Single-use server-verifiable human decision bound to exact proposal identity.            |
| Mutation command envelope  | Request to apply one eligible proposal under current authority and transaction controls. |
| Idempotency record         | Durable reservation and outcome for one scoped command identity.                         |
| Mutation result            | Authoritative committed outcome or stable non-success result.                            |
| Audit record               | Required immutable accountability evidence.                                              |
| Transactional outbox event | Required committed notice for post-commit effects.                                       |
| Recovery record            | Protected evidence for resolving ambiguity without inventing outcome.                    |

- **AMP-011:** Each authoritative protocol object MUST have a server-generated immutable identifier and explicit format version.
- **AMP-012:** Human-readable labels MUST NOT substitute for immutable principal, proposal, operation, target, confirmation, transaction, or result identifiers.
- **AMP-013:** Unknown object types, fields, enum values, encodings, or versions MUST be rejected rather than ignored, guessed, or downgraded.
- **AMP-014:** Protocol objects MUST NOT contain credentials, raw tokens, signing secrets, private keys, unrestricted logs, SQL, internal paths, raw exceptions, or unnecessary sensitive data.

## 4. Typed proposal envelope

The canonical proposal-envelope requirements from the mutation contract remain authoritative. A proposal creation request MUST contain or allow the server to derive:

| Field                                 | Protocol semantics                                                                |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| format_version                        | Exact supported proposal-envelope version.                                        |
| proposal_type                         | Stable allowlisted proposal family.                                               |
| requested_action                      | Stable canonical operation identifier.                                            |
| target_module and resource_type       | Allowlisted module and resource type.                                             |
| target_resource_id or target_manifest | Immutable target identity or bounded complete manifest.                           |
| base_record_version or preconditions  | Last observed authoritative version and invariant assumptions.                    |
| proposed_changes                      | Typed operation-specific values with unknown-field rejection.                     |
| summary and material_effects          | Non-authoritative human-readable review content derived or verified by server.    |
| reason                                | Bounded rationale; never authority.                                               |
| provenance                            | Bounded source identity, version, checksum, evidence references, and uncertainty. |
| originating_context                   | Untrusted client/model/tool metadata normalized by server.                        |
| requested_expiration                  | Advisory bound; server selects trusted validity.                                  |
| idempotency_key                       | Opaque caller key within server-defined proposal-creation scope.                  |

After bounded acceptance, the server MUST add proposal ID, canonical digest, originating principal, verified client context, policy and validator versions, trusted creation and expiration times, and lifecycle state.

- **AMP-015:** Proposal creation MUST be distinct from mutation application and MUST NOT mutate the target, consume confirmation, advance target version, or emit a committed-success audit.
- **AMP-016:** The server MUST enforce encoded size, decompression, nesting, collection, string, evidence, and target-manifest limits before semantic evaluation.
- **AMP-017:** Proposal provenance MUST distinguish verified source facts, model inference, user assertion, uncertainty, and missing evidence.
- **AMP-018:** A proposal without required provenance MUST be rejected or remain explicitly ineligible; the server MUST NOT fabricate provenance.
- **AMP-019:** Server normalization MUST be deterministic and MUST reject ambiguous encodings, duplicate keys, unsupported numbers, or unrepresentable values.
- **AMP-020:** Material proposal change MUST produce a new canonical identity and invalidate dependent validation and confirmation.

## 5. Canonical proposal and command identity

Canonical proposal identity MUST bind exact format, proposal type, operation, module, resource type, target set, expected versions, normalized values, material provenance, policy and validator versions, originating principal where policy requires, trusted validity, and other governing constraints.

The mutation command has a separate canonical identity. It MUST bind:

- command format and command ID;
- proposal ID and canonical proposal digest;
- operation, handler, module, target set, and expected versions;
- authenticated principal, effective service identity, delegation identity and versions when applicable;
- current policy, validator, capability, assurance, session, and environment context;
- confirmation class and exact confirmation record when required;
- idempotency scope and key;
- requested result representation version.

- **AMP-021:** The server MUST calculate canonical identities using an approved serialization and cryptographic digest profile.
- **AMP-022:** Client-supplied digests MAY be comparison values but MUST NOT skip server calculation.
- **AMP-023:** Any material identity difference MUST fail as mismatch and MUST NOT be normalized into another authorized command.
- **AMP-024:** Presentation-only normalization MAY be excluded only under the approved canonicalization profile.
- **AMP-025:** Proposal and command digests MUST be versioned so algorithm or canonicalization changes cannot be silently reinterpreted.

## 6. Typed mutation command envelope

A mutation command MUST reference an eligible proposal rather than restating an independently authoritative payload.

| Field                                | Required semantics                                                         |
| ------------------------------------ | -------------------------------------------------------------------------- |
| command_format_version               | Exact supported version.                                                   |
| command_id                           | Server-generated immutable identifier or server-verified issued reference. |
| proposal_id                          | Exact eligible proposal.                                                   |
| canonical_proposal_digest            | Exact server-calculated proposal identity.                                 |
| operation_id                         | Stable operation resolved against policy and proposal.                     |
| target_manifest                      | Exact bounded immutable targets and expected versions.                     |
| principal_context                    | Server-derived human and effective service identities.                     |
| delegation_id and version            | Exact delegation when used; otherwise absent.                              |
| policy_version and validator_version | Server-selected current versions; client copies are comparison only.       |
| confirmation_record_id               | Exact record for CF-2 or approved CF-3; absent for CF-1.                   |
| idempotency_scope and key            | Durable command application identity.                                      |
| client_request_id and correlation_id | Non-authoritative transport and tracing identifiers.                       |
| requested_result_version             | Supported sanitized result representation.                                 |

- **AMP-026:** A direct mutation payload without eligible proposal identity and provenance MUST be rejected.
- **AMP-027:** Command fields derived by the server MUST NOT be overridden by a client, model, tool, automation, or integration.
- **AMP-028:** A command MUST address one canonical operation; compound or bulk operations require an explicit bounded operation contract.
- **AMP-029:** A command MUST NOT carry reusable credentials or confirmation material beyond opaque server-issued references.
- **AMP-030:** Command acceptance MUST NOT imply commit.

## 7. Proposal lifecycle

| State                 | Meaning                                                                     | Allowed next states                                             |
| --------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------- |
| draft                 | Non-authoritative client or server draft.                                   | submitted, cancelled                                            |
| submitted             | Bounded envelope received but not yet fully evaluated.                      | rejected, validated, conflicted, expired, cancelled             |
| validated             | Deterministic validation passed for recorded versions.                      | awaiting_confirmation, eligible, conflicted, expired, cancelled |
| awaiting_confirmation | Current policy requires human confirmation.                                 | eligible, rejected, conflicted, expired, cancelled, superseded  |
| eligible              | Current evaluation permits command submission; commit has not occurred.     | applying, conflicted, expired, cancelled, superseded            |
| applying              | One command is resolving idempotency and authoritative transaction outcome. | applied, rejected, conflicted, failed_safe                      |
| applied               | Mutation and required evidence committed.                                   | Terminal                                                        |
| rejected              | Deterministic policy, validation, or human decision rejected.               | Terminal                                                        |
| conflicted            | Target or governing state no longer matches.                                | Terminal                                                        |
| expired               | Trusted validity ended.                                                     | Terminal                                                        |
| cancelled             | Eligible actor cancelled before application.                                | Terminal                                                        |
| superseded            | Material successor replaced this identity.                                  | Terminal                                                        |
| failed_safe           | Outcome or authority cannot be safely resolved automatically.               | Terminal pending governed recovery                              |

- **AMP-031:** Only the authoritative server MAY transition proposal state.
- **AMP-032:** Terminal proposal states MUST NOT transition.
- **AMP-033:** Re-proposal after rejection, conflict, expiry, cancellation, supersession, or material change MUST create a new identity.
- **AMP-034:** The applying state MUST NOT be treated as successful or authorize another parallel application.
- **AMP-035:** State transitions MUST be concurrency-controlled and auditable with trusted time and stable reason.

## 8. Pre-transaction admission sequence

Before opening the authoritative transaction, the server MUST perform in order:

1. bounded transport decoding and parsing;
2. exact proposal and command schema validation;
3. principal, credential, session, assurance, environment, and revocation verification;
4. capability and delegation evaluation;
5. operation, module, resource, target, and handler allowlist resolution;
6. provenance identity, integrity, authorization, sufficiency, and uncertainty validation;
7. current policy and validator selection;
8. proposal canonicalization and digest verification;
9. preliminary target and related-state load;
10. expected-version and invariant comparison;
11. confirmation-class determination;
12. challenge or confirmation-record validation when applicable;
13. proposal and command expiration and replay checks;
14. idempotency scope derivation;
15. transaction-safe handler and resource-bound verification.

- **AMP-036:** Each admission stage MUST stop on failure and MUST NOT be bypassed by cached success, client assertion, model reasoning, prior confirmation, administrator status, or internal origin.
- **AMP-037:** Admission success MUST remain provisional because mutable facts are rechecked inside the transaction.
- **AMP-038:** Pre-transaction evaluation MUST NOT hold database locks during model inference, retrieval, human review, external calls, or offline delay.
- **AMP-039:** Admission MUST return stable sanitized non-success outcomes without revealing secrets, raw policy, SQL, internal paths, or exceptions.
- **AMP-040:** Admission failure MUST NOT reserve a committed-success result or consume confirmation.

## 9. Identity, authorization, and delegation evaluation

The server MUST apply the Authoritative Identity, Service Identity, and Delegation Policy at admission and again for mutable facts inside the transaction.

Effective authority is the intersection of principal status, assurance, session, capabilities, delegation, delegator authority, operation, module, target, environment, policy, validity, revocation, and deterministic deny rules.

- **AMP-041:** Authentication success alone MUST NOT satisfy authorization.
- **AMP-042:** Delegation MUST NOT expand current delegator authority, transfer confirmation, cross environment, or survive underlying authority loss.
- **AMP-043:** Service identities MUST remain bounded and MUST NOT satisfy human CF-2 or CF-3 confirmation.
- **AMP-044:** Unknown or conflicting capability, delegation, identity, assurance, session, environment, or revocation state MUST deny.
- **AMP-045:** Identity or delegation version change after evaluation MUST conflict or require full re-evaluation.

## 10. Deterministic validation and freshness

Validation MUST include schema, type, range, relationship, invariant, target existence, authorization of evidence references, provenance sufficiency, operation-specific rules, resource limits, and current authoritative state.

- **AMP-046:** Validator behavior MUST be identified by an immutable version included in proposal, confirmation, command, and audit evidence.
- **AMP-047:** Current policy MUST determine whether an older proposal or confirmation remains eligible; uncertainty invalidates eligibility.
- **AMP-048:** Policy or validator downgrade, unknown version, integrity failure, or unavailable version state MUST fail closed.
- **AMP-049:** Deterministic validation MUST re-run for every fact that may have changed before commit.
- **AMP-050:** Client, model, retrieved, or tool-provided validation results are evidence candidates only and MUST NOT replace server validation.

## 11. Confirmation binding and consumption

The server MUST independently derive the confirmation class from the canonical operation matrix after admissibility checks.

- **AMP-051:** CF-0 MUST reject, CF-1 MAY proceed without interactive confirmation only after all other controls, CF-2 requires one exact single-use confirmation, and CF-3 remains blocked until its stronger policy exists.
- **AMP-052:** A challenge MUST bind exact material effects, proposal digest, operation, target, expected versions, principal, policy, validator, trusted validity, and required device or session context.
- **AMP-053:** A confirmation record MUST NOT authorize changed content, actor, delegation, operation, target, version, environment, policy, validator, or idempotency identity.
- **AMP-054:** Confirmation MUST be verified at command admission and rechecked and consumed atomically inside the transaction.
- **AMP-055:** Missing, expired, rejected, cancelled, superseded, consumed, malformed, cryptographically invalid, or unverifiable confirmation MUST fail closed.
- **AMP-056:** Transaction rollback MUST roll back confirmation consumption; ambiguous commit MUST keep the record non-reusable until outcome is proven.

## 12. Concurrency and target versions

- **AMP-057:** Every mutable target MUST use expected record version or an equivalent approved atomic precondition.
- **AMP-058:** Multi-resource invariants MUST use a documented isolation and deterministic locking strategy that prevents write skew.
- **AMP-059:** A stale or missing target MUST conflict without overwrite, silent merge, retargeting, or reinterpretation.
- **AMP-060:** Locks MUST be acquired in approved global order within a bounded transaction.
- **AMP-061:** Serialization or deadlock retry MAY occur only under bounded server policy with identical immutable command and idempotency identity.
- **AMP-062:** Every retry MUST recheck all current authority, policy, confirmation, target, and invariant state.

## 13. Idempotency, replay, retry, and ambiguity

Idempotency scope MUST bind effective principal, operation, environment, module or tenant boundary, proposal digest, target manifest, command identity, and confirmation when applicable.

- **AMP-063:** The reservation and final result MUST be durable, shared across instances, and atomic with mutation and required evidence.
- **AMP-064:** Identical replay after commit MUST return the original result without revalidating into a new mutation, consuming again, or creating another success audit.
- **AMP-065:** Reuse of an idempotency key with different bound content MUST fail as idempotency conflict.
- **AMP-066:** In-progress duplication MUST wait or return a bounded pending result and MUST NOT execute in parallel.
- **AMP-067:** Offline replay MUST NOT extend expiration or preserve revoked identity, delegation, capability, confirmation, policy, validator, or target state.
- **AMP-068:** Client timeout, connection loss, or response loss SHOULD be resolved through status lookup or identical idempotent retry.
- **AMP-069:** When commit state is ambiguous, the server MUST resolve authoritative transaction and idempotency evidence before any new execution or confirmation reuse.
- **AMP-070:** Unresolvable ambiguity MUST enter failed_safe and require separately governed recovery.

## 14. Authoritative transaction and commit

Inside one authoritative transaction, the coordinator MUST:

1. begin with approved isolation and transaction identity;
2. establish trusted database time;
3. lock or condition targets and invariant rows;
4. recheck principal, service identity, delegation, revocation, capability, policy, validator, environment, and handler;
5. recheck proposal and command identity;
6. enforce target versions and invariants;
7. reserve or resolve idempotency;
8. lock and verify confirmation when required;
9. run final deterministic validation;
10. apply only the allowlisted mutation handler;
11. consume confirmation when required;
12. persist required audit, final idempotency result, and required outbox event;
13. commit once and expose only the committed outcome.

- **AMP-071:** Handler code MUST NOT perform external side effects inside the transaction.
- **AMP-072:** Any required mutation, audit, idempotency, confirmation, or outbox write failure MUST roll back all protocol writes.
- **AMP-073:** Commit acknowledgement MUST precede a new success response.
- **AMP-074:** Database constraint, serialization, process, or infrastructure failure MUST NOT produce partial success.
- **AMP-075:** Required audit MUST link proposal, command, identities, delegation, policy, validator, provenance, confirmation, versions, idempotency, transaction, outbox, and result.

## 15. Result envelope and standard outcomes

Every response MUST use a versioned bounded result envelope:

| Field                      | Semantics                                                                       |
| -------------------------- | ------------------------------------------------------------------------------- |
| result_format_version      | Exact supported representation.                                                 |
| command_id and proposal_id | Stable protocol identities.                                                     |
| status                     | One canonical outcome status.                                                   |
| reason_code                | Stable machine-readable reason.                                                 |
| retry_class                | never, after_change, identical_retry, status_lookup, or governed_recovery.      |
| transaction_id             | Present only for committed outcome or protected reference where policy permits. |
| idempotent_replay          | True only when returning a prior outcome.                                       |
| target_versions            | Sanitized resulting or conflict versions as policy permits.                     |
| confirmation_state         | Sanitized required, consumed, terminal, or not_applicable state.                |
| correlation_id             | Server-verified tracing reference.                                              |
| details                    | Bounded role-appropriate data without secrets or internals.                     |

Canonical statuses:

| Status                | Meaning                                                                                  | Success |
| --------------------- | ---------------------------------------------------------------------------------------- | ------- |
| applied               | Mutation and all required evidence committed.                                            | Yes     |
| replayed              | Original committed result returned idempotently.                                         | Yes     |
| awaiting_confirmation | Eligible proposal requires confirmation.                                                 | No      |
| rejected              | Authentication, authorization, policy, validation, provenance, or confirmation rejected. | No      |
| conflicted            | Target or governing version changed.                                                     | No      |
| expired               | Proposal, command, session, delegation, or confirmation validity ended.                  | No      |
| cancelled             | Eligible actor cancelled before commit.                                                  | No      |
| pending               | One identical command is still resolving.                                                | No      |
| unavailable           | Required authoritative dependency cannot be verified.                                    | No      |
| failed_safe           | Outcome or authority cannot be safely resolved automatically.                            | No      |

- **AMP-076:** Only applied and replayed MAY be represented as success.
- **AMP-077:** Replayed MUST reference the original committed result and MUST NOT imply a new transaction.
- **AMP-078:** Public reasons MUST be stable, sanitized, and role-appropriate.
- **AMP-079:** Transport status, UI wording, logs, metrics, outbox delivery, or client cache MUST NOT redefine canonical outcome.
- **AMP-080:** Retry guidance MUST follow the authoritative retry_class and MUST NOT invite unsafe blind retry.

## 16. Standard reason-code families

Implementations MUST use a reviewed versioned registry. This protocol reserves semantic families without selecting transport codes:

- malformed_request and resource_limit;
- unauthenticated and identity_unverifiable;
- unauthorized and capability_denied;
- delegation_invalid and delegation_stale;
- operation_forbidden and policy_unavailable;
- provenance_missing and provenance_invalid;
- validation_failed and validator_unavailable;
- confirmation_required, confirmation_invalid, and confirmation_terminal;
- target_not_found, version_conflict, and invariant_conflict;
- expired and replay_rejected;
- idempotency_conflict and command_pending;
- audit_unavailable, datastore_unavailable, and outbox_unavailable;
- commit_ambiguous and recovery_required;
- internal_error.

- **AMP-081:** Unknown reason or outcome MUST NOT fall back to success or retryable mutation.
- **AMP-082:** A rejection audit MUST NOT imply mutation commit.
- **AMP-083:** Error details MUST NOT expose credential presence, verification secrets, private policy internals, raw provenance, SQL, internal paths, stack traces, or raw exceptions.
- **AMP-084:** Reason-code registry changes MUST be versioned and reviewed for disclosure and retry safety.

## 17. Outbox and post-commit delivery

Required post-commit work MUST be represented by an outbox event written in the authoritative transaction. Consumers MUST process committed events only, deduplicate by stable event ID, preserve required ordering, and expose bounded retry or dead-letter state.

Notification, indexing, cache invalidation, model invocation, file movement, webhook, messaging, and projection updates occur after commit. Their failure MUST NOT roll back or misrepresent the committed mutation. If an external effect is necessary for correctness and cannot be transactionally represented or safely compensated under a separately approved design, the operation remains unsupported.

## 18. Offline and synchronization protocol

Offline clients MAY create drafts and queue proposal or command attempts. On reconnect, each item MUST pass the complete current protocol. Queue order, client time, cached policy, prior authentication, prior validation, or prior confirmation MUST NOT preserve authority.

Synchronization MUST treat server outcome and target versions as authoritative. It MUST NOT silently choose a conflict winner, rewrite proposal identity, reactivate expired objects, or present local mutation as committed. Cross-actor, cross-device, cross-operation, cross-target, or cross-environment replay MUST fail.

## 19. Rejection and recovery matrix

| Condition                                            | Canonical outcome                           | State and confirmation                                     | Retry or recovery                            |
| ---------------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------- |
| Malformed, oversized, unknown, or ambiguous envelope | rejected                                    | No mutation; confirmation unchanged                        | New corrected proposal                       |
| Unknown or unverifiable identity                     | rejected                                    | No mutation                                                | Reauthenticate or governed identity recovery |
| Unauthorized capability or delegation                | rejected                                    | No mutation                                                | Policy-authorized change only                |
| CF-0 or unresolved CF-3                              | rejected                                    | No mutation                                                | Separate policy approval required            |
| Missing or invalid provenance                        | rejected                                    | No mutation                                                | New evidence and proposal                    |
| Policy or validator unavailable or downgraded        | unavailable                                 | No mutation; confirmation non-reusable if ambiguity exists | Restore verified current dependency          |
| Proposal or command digest mismatch                  | rejected                                    | No mutation                                                | New canonical identity                       |
| Confirmation required                                | awaiting_confirmation                       | No mutation; eligible challenge may be issued              | Confirm exact challenge                      |
| Confirmation invalid or terminal                     | rejected                                    | No mutation; do not consume another record                 | New proposal or challenge as policy permits  |
| Stale target or governing version                    | conflicted                                  | No mutation; confirmation superseded when material         | Re-read and create new proposal              |
| Idempotency key with changed content                 | rejected                                    | Existing result unchanged                                  | New key and proposal identity                |
| Identical command already committed                  | replayed                                    | Original confirmation remains consumed                     | Return original result                       |
| Identical command in progress                        | pending                                     | At most one transaction                                    | Wait or status lookup                        |
| Validation or invariant failure                      | rejected                                    | Transaction rolls back                                     | Correct and repropose                        |
| Serialization or deadlock                            | pending or unavailable                      | Transaction rolls back; confirmation unchanged             | Bounded identical server retry               |
| Required audit or outbox unavailable                 | unavailable                                 | Transaction rolls back, including consumption              | Retry only after dependency recovery         |
| Process crash before commit                          | unavailable or pending                      | Database recovery rolls back                               | Identical retry or status lookup             |
| Process crash after commit before response           | replayed after lookup                       | Complete committed outcome                                 | Return original result                       |
| Commit acknowledgement lost                          | failed_safe until resolved                  | Confirmation non-reusable                                  | Authoritative status resolution              |
| Post-commit delivery failure                         | applied                                     | Mutation remains committed                                 | Retry outbox event only                      |
| Client displays unproven success                     | failed_safe or authoritative current status | Display has no authority                                   | Query server                                 |
| Restored or split-brain state inconsistent           | unavailable                                 | Mutation disabled                                          | Governed recovery and writer fencing         |
| Break-glass or direct-database bypass attempted      | rejected                                    | No canonical mutation                                      | Security review                              |
| Required dependency cannot prove current state       | unavailable                                 | No mutation                                                | Restore verification; never fail open        |

## 20. Security, privacy, and observability

- **AMP-085:** Protocol data MUST be minimized and retained only for approved authority, replay, audit, and recovery needs.
- **AMP-086:** Credentials, key material, reusable confirmation evidence, protected provenance, and sensitive fields MUST remain least-privilege and redacted.
- **AMP-087:** Correlation IDs MUST be server-generated or verified and MUST NOT grant authority.
- **AMP-088:** Health and readiness MUST report mutation unavailable when required identity, policy, validator, confirmation, idempotency, audit, outbox, trusted-time, or datastore state is unverifiable.
- **AMP-089:** Metrics SHOULD distinguish rejection, conflict, expiration, replay, pending duplicate, rollback, audit failure, outbox backlog, and ambiguous commit without becoming authority.
- **AMP-090:** Administrative, recovery, and incident investigation MUST preserve accountability and MUST NOT rewrite canonical history.

## 21. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                                                  |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| APT-001 | Model, client, tool, or automation can create only a non-authoritative proposal.                                                                                |
| APT-002 | Direct mutation payload without eligible proposal identity and provenance is rejected.                                                                          |
| APT-003 | Unknown envelope field, object type, operation, handler, or version fails closed.                                                                               |
| APT-004 | Oversized, over-deep, or ambiguous input fails before semantic or transaction work.                                                                             |
| APT-005 | Client-supplied identity, capability, delegation, policy, validator, confirmation class, or outcome is ignored.                                                 |
| APT-006 | Failed authentication, authorization, delegation, or assurance cannot be cured by confirmation.                                                                 |
| APT-007 | Service identity cannot exceed exact scope or satisfy human confirmation.                                                                                       |
| APT-008 | Prompt-injected retrieval or tool output cannot alter authority, validation, or mutation routing.                                                               |
| APT-009 | Missing, fabricated, corrupted, or unauthorized provenance blocks eligibility.                                                                                  |
| APT-010 | Material proposal change produces new digest and invalidates dependent confirmation.                                                                            |
| APT-011 | Command cannot restate changed authoritative payload under an eligible proposal reference.                                                                      |
| APT-012 | Policy or validator change, rollback, unknown version, or unavailability fails safely.                                                                          |
| APT-013 | CF-0 remains forbidden and unresolved CF-3 remains blocked.                                                                                                     |
| APT-014 | Exact CF-2 confirmation authorizes only its bound actor, proposal, operation, target, versions, policy, validator, and context.                                 |
| APT-015 | Expired, rejected, cancelled, superseded, consumed, or invalid confirmation cannot mutate.                                                                      |
| APT-016 | Concurrent confirmation use across instances produces at most one consumption and mutation.                                                                     |
| APT-017 | Stale target version conflicts without overwrite, merge, or retargeting.                                                                                        |
| APT-018 | Concurrent multi-row requests cannot violate protected invariants or write skew controls.                                                                       |
| APT-019 | Identical concurrent commands produce one reservation, mutation, audit, outbox event, and result.                                                               |
| APT-020 | Idempotency-key reuse with different content fails without replacing the prior result.                                                                          |
| APT-021 | Identical replay after success returns the original result without another mutation or consumption.                                                             |
| APT-022 | Offline replay after identity, delegation, policy, validator, confirmation, expiry, or target change fails.                                                     |
| APT-023 | Retry after serialization or deadlock rechecks all mutable facts.                                                                                               |
| APT-024 | Required audit failure rolls back mutation, idempotency completion, confirmation consumption, and outbox.                                                       |
| APT-025 | Required outbox failure rolls back the entire authoritative transaction.                                                                                        |
| APT-026 | Process crash before commit leaves no partial protocol state.                                                                                                   |
| APT-027 | Process crash after commit before response is recovered as one original result.                                                                                 |
| APT-028 | Client timeout followed by identical retry cannot double mutate.                                                                                                |
| APT-029 | Ambiguous commit blocks new execution and confirmation reuse until authoritative resolution.                                                                    |
| APT-030 | Post-commit consumer failure cannot change applied outcome and retries one event idempotently.                                                                  |
| APT-031 | Rejection, logs, metrics, dashboard, projection, or cache cannot claim authoritative success.                                                                   |
| APT-032 | Result envelopes expose stable sanitized outcome and safe retry classification.                                                                                 |
| APT-033 | Unknown reason or outcome cannot fall back to success or blind retry.                                                                                           |
| APT-034 | Development identity, client, test, command, or delegation cannot target Production.                                                                            |
| APT-035 | Direct database, administrator, migration, deployment, or break-glass bypass cannot create a canonical protocol result.                                         |
| APT-036 | Restored inconsistent audit, confirmation, idempotency, policy, identity, target, or outbox state cannot accept mutations.                                      |
| APT-037 | Unavailable identity, policy, validator, provenance, key, trusted-time, confirmation, audit, idempotency, outbox, or datastore dependency blocks mutation.      |
| APT-038 | A successful authoritative result always has required linked proposal, identity, authority, transaction, audit, idempotency, confirmation, and outbox evidence. |
| APT-039 | Bulk or compound request without an approved bounded operation contract fails closed.                                                                           |
| APT-040 | Provider, model, client, or transport substitution cannot change protocol authority or result semantics.                                                        |

No executable tests are created by this documentation task.

## 22. Traceability

### 22.1 Protocol requirement-to-test traceability

| Requirements            | Tests                                                |
| ----------------------- | ---------------------------------------------------- |
| AMP-001 through AMP-010 | APT-001, APT-005 through APT-008, APT-031, APT-040   |
| AMP-011 through AMP-020 | APT-002 through APT-004, APT-009, APT-010            |
| AMP-021 through AMP-030 | APT-002, APT-003, APT-010, APT-011, APT-020          |
| AMP-031 through AMP-035 | APT-010, APT-013, APT-015, APT-017, APT-019, APT-029 |
| AMP-036 through AMP-040 | APT-003 through APT-009, APT-012, APT-037            |
| AMP-041 through AMP-045 | APT-005 through APT-007, APT-022, APT-034            |
| AMP-046 through AMP-050 | APT-008, APT-009, APT-012, APT-017, APT-023          |
| AMP-051 through AMP-056 | APT-006, APT-013 through APT-016, APT-024, APT-029   |
| AMP-057 through AMP-062 | APT-017 through APT-019, APT-023, APT-039            |
| AMP-063 through AMP-070 | APT-019 through APT-023, APT-027 through APT-029     |
| AMP-071 through AMP-075 | APT-024 through APT-030, APT-038                     |
| AMP-076 through AMP-084 | APT-021, APT-027 through APT-033                     |
| AMP-085 through AMP-090 | APT-031, APT-032, APT-034 through APT-038            |

### 22.2 Governing-document traceability

| Governing contract                                                                                      | Protocol requirements                                                                                                                                    | Tests                                                                                                |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Mutation and Proposal Contract MUT-001 through MUT-020                                                  | AMP-001 through AMP-050, AMP-057 through AMP-070, AMP-076 through AMP-084                                                                                | APT-001 through APT-013, APT-017, APT-020 through APT-023, APT-031 through APT-033, APT-039, APT-040 |
| Confirmation Policy CONF-001 through CONF-074 and CFM-001 through CFM-028                               | AMP-003, AMP-020, AMP-041 through AMP-056, AMP-063 through AMP-070                                                                                       | APT-006, APT-007, APT-010, APT-013 through APT-016, APT-021, APT-022, APT-029                        |
| Atomic Transaction Design ATX-001 through ATX-069 and ATM-001 through ATM-030                           | AMP-004 through AMP-006, AMP-034, AMP-057 through AMP-075, AMP-079, AMP-080                                                                              | APT-016 through APT-030, APT-038, APT-039                                                            |
| Mutation Threat Model AMT-001 through AMT-040, AMR-001 through AMR-068, and AMTST-001 through AMTST-038 | AMP-001 through AMP-010, AMP-036 through AMP-090                                                                                                         | APT-001 through APT-040                                                                              |
| Identity and Delegation Policy IDP-001 through IDP-082 and IDT-001 through IDT-038                      | AMP-002, AMP-005, AMP-007 through AMP-009, AMP-026 through AMP-029, AMP-036, AMP-041 through AMP-045, AMP-063, AMP-067, AMP-075, AMP-085 through AMP-090 | APT-005 through APT-007, APT-022, APT-034 through APT-038                                            |

## 23. Unresolved decisions and interim treatment

| Decision                                                        | Affected protocol stage       | Interim fail-closed treatment                                   | Owner                     |
| --------------------------------------------------------------- | ----------------------------- | --------------------------------------------------------------- | ------------------------- |
| Exact wire formats and media types                              | Proposal, command, result     | Unsupported formats reject                                      | Architecture              |
| Canonical serialization and digest algorithms                   | Proposal and command identity | No custom or unverifiable identity; application blocked         | Owner and Security        |
| Envelope size, depth, collection, evidence, and target limits   | Parsing and admission         | Missing limit blocks operation enablement                       | Owner and Security        |
| Proposal persistence and retention                              | Proposal lifecycle            | No unbounded or unaudited retention                             | Owner                     |
| Proposal cancellation and successor semantics                   | Lifecycle                     | Ambiguous transition rejects                                    | Owner                     |
| Policy and validator compatibility across versions              | Admission and confirmation    | Unknown compatibility invalidates eligibility                   | Owner and Security        |
| Identity assurance, service identity, and delegation enablement | Identity evaluation           | Applicable unresolved authority remains blocked                 | Owner and Security        |
| Confirmation expiry, binding, cryptography, and CF-3 policy     | Confirmation                  | Unverifiable CF-2 and all unresolved CF-3 block                 | Owner and Security        |
| Isolation, lock order, and retry bounds                         | Transaction                   | Operation remains unsupported without approved profile          | Architecture and Security |
| Idempotency scope, retention, and status authorization          | Replay and recovery           | Missing durable profile blocks mutation                         | Owner and Security        |
| Reason-code registry and role-sensitive disclosure              | Results                       | Unknown reasons fail closed with minimal disclosure             | Security                  |
| Audit schema, integrity, retention, and failed-attempt policy   | Transaction and recovery      | Required audit failure blocks commit                            | Owner and Security        |
| Outbox schema, ordering, retry, and dead-letter policy          | Transaction and delivery      | Required delivery without approved outbox remains unsupported   | Architecture              |
| Bulk and compound operation contracts                           | Command and transaction       | Prohibited by default                                           | Owner and Security        |
| Ambiguous-commit recovery procedure                             | Recovery                      | failed_safe; no new execution or confirmation reuse             | Owner and Security        |
| Backup and restore consistency verification                     | Recovery                      | Restored authority cannot accept mutation                       | Owner and Security        |
| Development and Production protocol endpoints                   | Environment                   | Production remains inaccessible and unauthorized                | Owner                     |
| Break-glass and direct administrative mutation                  | Administration                | Prohibited                                                      | Owner and Security        |
| Protocol version negotiation and deprecation                    | All stages                    | Unknown version rejects; no downgrade                           | Architecture and Security |
| Residual-risk acceptance                                        | All stages                    | Only explicit owner acceptance with security review may unblock | Owner                     |

## 24. Explicit non-goals

This protocol does not:

- implement proposals, commands, identity, authorization, delegation, validation, confirmation, mutation, audit, idempotency, outbox, result, or recovery code;
- create executable tests, APIs, schemas, DDL, configuration, credentials, keys, service identities, or capabilities;
- inspect or modify SQL or any migration, including Migration 009;
- create the external authority anchor;
- grant authoritative authority to any user, service, model, tool, client, automation, administrator, developer, or integration;
- modify PropertyManager or another application;
- access Development or Production runtimes, databases, services, containers, or external providers;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- begin implementation or the next architecture deliverable.

Implementation MUST NOT begin until applicable unresolved decisions receive owner and security approval.
