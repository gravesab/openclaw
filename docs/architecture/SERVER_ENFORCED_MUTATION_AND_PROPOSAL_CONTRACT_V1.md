---
title: "OpenClaw Server-Enforced Mutation and Proposal Contract v1"
summary: "Normative contract for proposals, authoritative mutations, confirmation binding, concurrency, idempotency, and audit behavior"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-04"
category: "Architecture"
source_document: "SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md"
read_when:
  - Designing or reviewing an authoritative state-changing operation
  - Adding AI-assisted proposals, confirmations, automations, or mutation APIs
  - Evaluating client, model, retrieval, tool, concurrency, idempotency, or audit boundaries
---

# OpenClaw Server-Enforced Mutation and Proposal Contract v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-04

This contract is governed by the [AI Governance Manifest](/foundation/AI_GOVERNANCE_MANIFEST), the [OpenClaw Development Directive](/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE), and the [Foundational Documentation Index](/foundation/FOUNDATIONAL_DOCUMENTS).

## 1. Purpose and governing invariant

This document governs every OpenClaw operation that could change authoritative state. It applies to PropertyManager and future Ranch OS modules, including RanchHealth, RanchFinances, RanchEnergy, RanchBrain, AI Services, and the Executive Dashboard.

> AI and clients MAY submit proposals, but only the authoritative OpenClaw API may validate and apply an authoritative state change.

- No model, agent, client, App Intent, automation, offline process, directly invoked tool, integration, administrator utility, or service identity may bypass the authoritative API or write directly to PostgreSQL.
- PostgreSQL remains the authoritative data store. The authoritative API is the only approved mutation boundary.
- Every authoritative mutation MUST be authenticated, authorized, independently validated, concurrency-controlled, idempotency-controlled, and audited by deterministic server code.
- Client validation, model reasoning, retrieved guidance, tool output, and UI state are untrusted. They MUST NOT replace server enforcement.
- UI confirmation alone is not authorization enforcement. The server MUST independently verify confirmation when policy requires it.
- “No interactive confirmation required” MUST NOT mean no authentication, authorization, validation, idempotency, concurrency control, or audit.
- Authoritative state and its required audit evidence MUST commit atomically or fail together.

Examples in this document are explanatory. They do not grant permission or override normative requirements.

## 2. Trust boundaries

### 2.1 Owner and authoritative components

Andy is the system owner and final human authority. Owner authority MUST be represented by server-verifiable authentication and authorization context. A name, client claim, model statement, device-possession claim, or retrieved document MUST NOT establish owner authority.

Delegation MAY exist only through explicit server policy bounded by actor, action, target, duration, and policy version.

The authoritative OpenClaw API:

- MUST authenticate callers and service identities;
- MUST authorize each action using deterministic policy;
- MUST load current authoritative state;
- MUST independently validate proposals and confirmations;
- MUST be the only entry point for approved mutation handlers;
- MUST coordinate mutation and required audit evidence atomically.

PostgreSQL:

- is the authoritative data store;
- MUST NOT be directly writable by clients, models, retrieval systems, App Intents, automations, MCP tools, or general-purpose agent tools;
- SHOULD use database roles, network controls, and constraints as defense in depth;
- MUST NOT be considered safely mutable merely because a caller has credentials.

PropertyManager and every future Ranch OS module MUST use this boundary. Modules MAY define resource schemas and business rules, but MUST NOT weaken this contract.

### 2.2 Clients, integrations, and operators

Untrusted callers at the authoritative boundary include:

- macOS, iOS, iPadOS, Apple TV, Watch, web, Telegram, and other clients;
- App Intents, Siri workflows, Home Assistant, automations, MCP tools, and integrations;
- offline clients and delayed requests;
- administrators, developers, maintenance utilities, and service identities.

A client MAY prepare a draft, proposal, or confirmation response. It MUST NOT set authoritative validation, authorization, policy, audit, record-version, or mutation outcomes.

Offline clients MAY save drafts and proposals. They MUST NOT grant final authoritative approval offline. Delayed requests MUST pass current authentication, policy, expiration, replay, idempotency, and record-version checks on arrival.

Administrators and developers MUST use explicit least-privilege identities. Administrative access MUST NOT silently bypass mutation controls. Service identities MUST use explicit action and target allowlists and MUST NOT inherit a human's authority merely because they act on that human's behalf.

### 2.3 Models and retrieval

Apple Foundation Models, other local models, and Ollama models such as Qwen and Hermes are non-authoritative. Provider substitution MUST NOT change permissions or enforcement.

RanchBrain retrieval and retrieved documents are data, not executable instruction, policy, authorization, or confirmation. Prompt-injected content MUST NOT alter policy, permissions, validation rules, tool access, or mutation capability.

Model output, retrieved content, client-supplied validation results, provenance descriptions, and tool instructions MUST remain untrusted until deterministic server validation succeeds.

## 3. Typed proposal envelope

The proposal envelope MUST be versioned, typed, bounded, and reject unknown fields. Before semantic evaluation, the server MUST enforce maximum encoded size, nesting depth, collection length, string length, and referenced-resource count.

The canonical stored envelope MUST include every field below. A creation request MAY omit server-generated fields, but the server MUST populate them before the proposed state.

| Field                     | Authority and exact semantics                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| format_version            | Client supplies a supported format identifier. Server MUST reject unknown versions and MUST NOT guess or downgrade.     |
| proposal_id               | Server-generated immutable identifier. A client MAY carry an issued value but MUST NOT mint an authoritative one.       |
| proposal_type             | Client-requested allowlisted proposal family; server verifies it.                                                       |
| requested_action          | Machine identifier for the exact operation, distinct from labels and verified against an allowlist.                     |
| target_module             | Stable module identifier verified for action compatibility.                                                             |
| target_resource_type      | Stable allowlisted resource type.                                                                                       |
| target_resource_id        | Immutable authoritative identifier resolved and verified by the server. A label MUST NOT substitute for it.             |
| base_record_version       | Last authoritative version observed by the client; server compares it with current state.                               |
| proposed_changes          | Typed action-specific values validated for allowed fields, semantics, and cross-field rules.                            |
| summary                   | Human-readable review text. It is non-authoritative and MUST NOT determine action or target.                            |
| reason                    | Human- or system-supplied rationale. It is audit context, not authorization.                                            |
| originating_actor         | Server-derived authenticated actor. Client claims MAY be retained only as untrusted context.                            |
| originating_client        | Server-verified application, device class, instance, and request channel where available; unverified labels are marked. |
| model_participation       | Server-normalized provider, model, and participation role when AI participated. It grants no authority.                 |
| provenance                | Bounded references to evidence, retrieved records, source versions, or observations.                                    |
| policy_version            | Server-selected immutable identifier for the deterministic policy evaluated.                                            |
| created_at                | Server-generated timestamp from the authoritative clock.                                                                |
| expires_at                | Server-issued or verified expiration within policy bounds and later than created_at.                                    |
| idempotency_key           | Caller-supplied opaque key within a server-defined scope. It MUST NOT contain credentials or authority.                 |
| canonical_proposal_digest | Server-calculated digest of the canonical authorization-bound representation.                                           |

The envelope MUST distinguish immutable identifiers from human-readable labels. It MUST NOT contain passwords, connection strings, credentials, raw tokens, private keys, unrestricted logs, raw exceptions, or unnecessary personal data. Protected evidence MUST use bounded, separately authorized server-resolvable references.

The server MUST independently derive or verify the actor and service identity, roles and delegations, trusted client context, target identity, current record version, allowlist membership, policy version, timestamps, expiration bounds, observable model participation, canonical digest, and all validation, authorization, confirmation, idempotency, and audit outcomes. A client MUST NOT mark these as already verified.

## 4. Canonical proposal identity

The server MUST produce a deterministic canonical representation before confirmation or application. It MUST bind authorization to the exact:

- envelope format, proposal type, and requested action;
- target module, resource type, and immutable identifier;
- base record version and normalized proposed values;
- policy version and expiration;
- authenticated actor and authorization context where policy requires;
- idempotency scope where policy requires;
- evidence references whose change could alter the decision.

Any material change MUST produce a different digest, invalidate prior validation and confirmation, and require new review when confirmation is required.

Presentation-only labels, whitespace, or field ordering SHOULD NOT change identity after approved normalization. The profile MUST reject ambiguous encodings, duplicate keys, unsupported numeric forms, and inconsistently representable values.

OpenClaw MUST use an established canonical serialization standard and established cryptographic digest algorithm. It MUST NOT invent a cryptographic algorithm or concatenate strings informally. The exact canonical JSON or equivalent profile, Unicode and numeric rules, and digest algorithm require owner and security review before implementation.

The server-calculated digest is authoritative. A client MAY provide a comparison digest, but a match MUST NOT skip server recalculation.

## 5. Server-side validation pipeline

The authoritative API MUST perform these stages in order. Failure stops processing unless sanitized failure audit is explicitly required.

1. **Bounded parsing.** Enforce body, decompression, collection, string, nesting, and reference limits.
2. **Envelope schema.** Validate format_version, required fields, exact types, and reject unknown fields.
3. **Authentication.** Establish caller, service identity, session, and credential state using server-trusted evidence.
4. **Authorization.** Decide whether that identity may request the action for the target scope.
5. **Allowlists.** Verify module, resource type, action, proposal type, and mutation handler.
6. **Semantic validation.** Enforce types, ranges, relationships, invariants, and business rules.
7. **Authoritative load.** Load current target and required related state from PostgreSQL.
8. **Optimistic concurrency.** Compare base_record_version. A mismatch conflicts and MUST NOT be silently rebased.
9. **Deterministic policy.** Evaluate the applicable policy version and record a stable reason code.
10. **Canonical identity.** Normalize bound data, calculate the digest, and reject a disagreeing supplied digest.
11. **Confirmation decision.** Determine whether explicit human confirmation is required.
12. **Confirmation verification.** Verify an unexpired, unused confirmation bound to digest, actor, action, and target.
13. **Expiration and replay protection.** Reject expired proposals, stale offline submissions, reused confirmations, and replay.
14. **Idempotency.** Reserve or resolve the scoped key. Different content under the same key MUST fail closed.
15. **Approved mutation handler.** Invoke only the allowlisted action-specific server handler.
16. **Atomic audit and commit.** Commit state and required audit evidence together or fail both.
17. **Sanitized response.** Return authoritative identifiers, outcome, versions, and stable reason codes without secrets.

Client or model assertions that validation, authorization, confirmation, audit, or mutation succeeded MUST NOT skip any stage.

## 6. Proposal and mutation separation

The architecture MUST expose distinct conceptual operations for:

1. creating or evaluating a non-authoritative proposal;
2. requesting confirmation;
3. submitting an authorized proposal for application;
4. retrieving proposal status;
5. cancelling an eligible proposal;
6. expiring proposals through deterministic policy.

Concrete endpoint names are outside this contract. These operations MUST remain distinguishable in routing, authorization, logging, and tests.

A proposal endpoint MUST NOT silently become a mutation endpoint. Read-only evaluation MUST have no target-state side effects. It MUST NOT consume confirmation, advance a target version, or invoke a mutation handler.

Application MUST accept only an eligible proposal and MUST recheck every fact that may have changed since evaluation.

## 7. Proposal lifecycle

| State                 | Meaning                                                                            | Terminal |
| --------------------- | ---------------------------------------------------------------------------------- | -------- |
| draft                 | Non-authoritative work not accepted for validation.                                | No       |
| proposed              | Server accepted a bounded envelope for evaluation.                                 | No       |
| validation_failed     | Deterministic schema or semantic validation failed.                                | Yes      |
| awaiting_confirmation | Validation passed and policy requires human confirmation.                          | No       |
| authorized            | Authorization and any required confirmation passed; application has not committed. | No       |
| applied               | Mutation and audit evidence committed atomically.                                  | Yes      |
| rejected              | Human authority or deterministic policy rejected it.                               | Yes      |
| conflicted            | Current state no longer matches bound assumptions.                                 | Yes      |
| expired               | Server validity window elapsed.                                                    | Yes      |
| cancelled             | An eligible actor cancelled before application.                                    | Yes      |

| From                  | To                                       | Server component allowed to transition                      |
| --------------------- | ---------------------------------------- | ----------------------------------------------------------- |
| draft                 | proposed                                 | Proposal service after bounded acceptance                   |
| proposed              | validation_failed                        | Validation engine                                           |
| proposed              | awaiting_confirmation                    | Policy engine                                               |
| proposed              | authorized                               | Policy engine when interactive confirmation is not required |
| proposed              | rejected, conflicted, expired, cancelled | Policy or proposal service under the corresponding rule     |
| awaiting_confirmation | authorized                               | Confirmation verifier                                       |
| awaiting_confirmation | rejected, conflicted, expired, cancelled | Confirmation, policy, or proposal service                   |
| authorized            | applied                                  | Transactional mutation coordinator only                     |
| authorized            | conflicted, expired, cancelled           | Mutation coordinator or proposal service before commit      |

Terminal states MUST NOT transition. Changed content, base version, authority, or confirmation MUST create a new proposal identity or formally versioned successor with a new digest. Clients and models MAY request transitions but MUST NOT set state directly.

## 8. Confirmation-policy interface

The separate Canonical Confirmation Policy MUST require every confirmation to be:

- server issued or independently server verified;
- single use and time limited;
- bound to the exact proposal digest, actor, action, and immutable target;
- invalidated by material proposal changes or conflicting state changes;
- non-transferable between users, service identities, devices, proposals, targets, or actions unless reviewed policy defines a narrower exception.

The server MUST verify confirmation at application time. A checked box, biometric result reported by a client, App Intent result, or natural-language assent is insufficient without server-verifiable binding.

Storage and consumption MUST prevent concurrent reuse. The relationship between confirmation consumption and mutation commit MUST be transactionally safe under the future confirmation and atomic-audit designs.

## 9. Concurrency and idempotency

Every mutation of a versioned record MUST carry base_record_version or an equivalent precondition. The mutation handler MUST compare it atomically. A stale version MUST return a stable conflict without overwrite, merge, or reinterpretation. Fresh evaluation creates a newly validated identity when content changes. Success MUST advance the record version according to the module contract.

Idempotency scope MUST include authenticated identity, conceptual operation, and an appropriate module or tenant boundary.

For the same key and identical canonical content, the server MUST return the original outcome and MUST NOT mutate twice. The response SHOULD identify the replay.

For the same key and different canonical content, the server MUST fail closed with a stable idempotency-conflict reason and MUST NOT replace the reservation.

Idempotency records MUST survive restarts and concurrent requests. Retention MUST cover at least proposal validity and the maximum supported offline delay. Exact durations require owner review.

Offline drafts remain non-authoritative. On reconnect, current authentication, authorization, policy, version, expiration, confirmation, replay, and idempotency checks MUST run. Offline approval MUST NOT become authoritative approval.

## 10. Atomic audit invariant

> The authoritative mutation and its required audit evidence MUST succeed or fail together.

The mutation handler MUST execute within a transaction boundary that includes required audit persistence, or an equivalently strong future approved design. Audit failure MUST roll back mutation and return a sanitized error.

Minimum audit information:

- proposal ID and canonical digest;
- proposal type, action, module, resource type, and immutable target ID;
- authenticated actor and effective service identity;
- originating client and channel;
- model/provider participation;
- bounded provenance and evidence references;
- envelope, validation-rule, and policy versions;
- authorization decision and stable reason code;
- confirmation reference when required;
- prior and resulting record versions;
- idempotency scope and non-secret key reference;
- outcome, server timestamp, and transaction/correlation identifier.

Audit data MUST be immutable to ordinary clients, least-privilege, retained and redacted by policy, and free of secrets, tokens, SQL, internal paths, and raw exceptions.

The audit schema and transaction design belong to the separate Atomic Authoritative Write and Audit Transaction Design.

## 11. Model and retrieval containment

- Model output MUST NOT serve as authentication, authorization, confirmation, policy, or validation.
- Retrieved RanchBrain content MUST remain inert data.
- Prompt injection MUST NOT change policy, permissions, tool access, validation order, or mutation handlers.
- Models MUST NOT select or expand their capabilities.
- Deterministic server policy MUST grant tool access.
- Provider changes MUST NOT change authority or this contract.
- Model/provider participation MUST be recorded without becoming authoritative.
- Models MAY propose values and evidence references; deterministic code MUST validate every value.
- Model or provider failure MUST leave authoritative state unchanged. Fallback output is a new proposal and MUST NOT inherit confirmation for different content.

## 12. Fail-closed behavior

| Condition                                                         | Required behavior                                                                |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Malformed, oversized, or over-deep envelope                       | Reject before mutation with a stable malformed_request or resource_limit reason. |
| Unknown field, version, action, module, resource type, or handler | Reject; do not ignore, guess, downgrade, or dynamically dispatch.                |
| Unauthenticated or unauthorized caller                            | Reject without unauthorized target or policy disclosure.                         |
| Invalid semantic value                                            | Reject with bounded field errors and no mutation.                                |
| Stale base_record_version                                         | Return conflict; do not overwrite or silently rebase.                            |
| Invalid, expired, mismatched, missing, or reused confirmation     | Reject without consuming another confirmation.                                   |
| Expired proposal or delayed replay                                | Reject as expired or replayed.                                                   |
| Identical idempotent replay                                       | Return original outcome without a second mutation.                               |
| Idempotency key reused with different content                     | Reject with idempotency_conflict.                                                |
| Model, provider, retrieval, or tool failure                       | Leave authoritative state unchanged.                                             |
| Required audit unavailable                                        | Roll back and return audit_unavailable or equivalent.                            |
| Authoritative storage unavailable                                 | Do not fall back to client state, files, model memory, or another store.         |
| Unexpected internal error                                         | Roll back, retain protected diagnostics, and return sanitized internal_error.    |

Public errors MUST use stable reason codes and sanitized messages. They MUST NOT expose secrets, tokens, SQL, unapproved schema details, stack traces, raw exceptions, internal paths, private hostnames, or policy internals. Retryability MUST be explicit.

## 13. Capability classification

| Classification                            | Contract                                                                                           |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Read-only                                 | May read authorized state and MUST NOT mutate records or create hidden authoritative side effects. |
| Non-authoritative proposal                | May create or evaluate a proposal and MUST NOT apply the target mutation.                          |
| Mutation without interactive confirmation | Requires authentication, authorization, validation, concurrency, idempotency, and audit.           |
| Mutation requiring explicit confirmation  | Requires all mutation controls plus exact single-use confirmation.                                 |
| Prohibited                                | MUST be rejected unless a separately approved policy revision changes classification.              |

Examples subject to future policy:

- Reading an authorized maintenance schedule may be read-only.
- AI drafting a task may be a non-authoritative proposal.
- A low-risk pre-authorized meter observation may be a mutation without interactive confirmation.
- Task deletion, financial-account changes, or high-impact equipment actions may require confirmation.
- Direct model access to PostgreSQL is prohibited.
- RanchHealth, RanchEnergy, RanchFinances, RanchBrain, AI Services, and Executive Dashboard operations MUST be classified before implementation.

Examples do not set final module policy.

## 14. Implementation-independent acceptance tests

| ID      | Required proof                                                                                            |
| ------- | --------------------------------------------------------------------------------------------------------- |
| MUT-001 | A model cannot write directly to PostgreSQL or invoke an unapproved mutation path.                        |
| MUT-002 | A client claim that server validation passed is ignored and full validation runs.                         |
| MUT-003 | Unknown envelope fields fail closed.                                                                      |
| MUT-004 | Unauthenticated, unauthorized, or non-allowlisted actions fail closed.                                    |
| MUT-005 | Changing a reviewed proposal changes its digest and invalidates confirmation.                             |
| MUT-006 | Confirmation cannot be reused, including concurrently.                                                    |
| MUT-007 | Confirmation cannot authorize another actor, device, target, action, or proposal.                         |
| MUT-008 | Stale base_record_version conflicts without mutation.                                                     |
| MUT-009 | Identical idempotent replay returns the original outcome without a second mutation.                       |
| MUT-010 | The same idempotency key with different content fails closed.                                             |
| MUT-011 | Delayed offline replay fails safely when identity, policy, version, confirmation, or expiration is stale. |
| MUT-012 | Prompt-injected retrieved content remains inert.                                                          |
| MUT-013 | Model/provider substitution cannot expand capabilities or reuse identity for changed content.             |
| MUT-014 | Required audit failure prevents mutation commit.                                                          |
| MUT-015 | Public errors do not leak secrets, exceptions, SQL, internal paths, or private policy.                    |
| MUT-016 | Existing deterministic non-AI writes remain governed by all server controls.                              |
| MUT-017 | Proposal/evaluation cannot invoke mutation or advance the target version.                                 |
| MUT-018 | Unknown versions, actions, types, and handlers cannot trigger fallback.                                   |
| MUT-019 | Concurrent application produces at most one mutation and committed outcome.                               |
| MUT-020 | Storage failure cannot fall back to client state, model memory, files, or another store.                  |

This documentation task adds no executable tests.

## 15. Requirement-to-test traceability

| Requirement                               | Tests                                       |
| ----------------------------------------- | ------------------------------------------- |
| Sole API mutation boundary                | MUT-001, MUT-016, MUT-020                   |
| Typed bounded envelope                    | MUT-002, MUT-003, MUT-018                   |
| Authentication, authorization, allowlists | MUT-004, MUT-007, MUT-016                   |
| Canonical identity                        | MUT-005, MUT-007, MUT-010, MUT-013          |
| Proposal/mutation separation              | MUT-017                                     |
| Lifecycle                                 | MUT-005, MUT-008, MUT-011, MUT-017          |
| Confirmation interface                    | MUT-005, MUT-006, MUT-007, MUT-019          |
| Concurrency                               | MUT-008, MUT-011, MUT-019                   |
| Idempotency and replay                    | MUT-006, MUT-009, MUT-010, MUT-011, MUT-019 |
| Atomic audit                              | MUT-014, MUT-019                            |
| Model/retrieval containment               | MUT-001, MUT-012, MUT-013                   |
| Fail-closed behavior                      | MUT-014, MUT-015, MUT-018, MUT-020          |
| Capability classification                 | MUT-001, MUT-004, MUT-016, MUT-017          |
| Sanitized errors                          | MUT-015                                     |

## 16. Unresolved decisions

These decisions MUST be resolved before implementation:

1. Canonical serialization, including key order, Unicode, numbers, timestamps, and duplicate keys.
2. Cryptographic digest algorithm and versioning profile.
3. Envelope size, depth, collection, evidence, and field limits.
4. Proposal, confirmation, audit, replay, and idempotency retention.
5. Maximum offline delay and module-specific shorter windows.
6. Server-verifiable confirmation mechanism and actor/device/session binding.
7. Delegated authority, service identities, and any separately governed break-glass process.
8. Policy-version lifecycle and treatment of proposals under older policy.
9. Proposal persistence, status-query access, cancellation, and successor relationships.
10. Module-specific interactive-confirmation classifications.
11. Conflict presentation and any separately reviewed re-proposal workflow.
12. Atomic audit schema, transaction boundary, retention, and protected diagnostics.
13. Evidence-reference authorization, immutability, retention, and redaction.
14. Public reason-code registry and role-specific validation disclosure.

Owner review is required for authority, classification, retention, and product behavior. Security review is required for canonicalization, digesting, confirmation, replay, identities, error disclosure, and atomic audit.

## 17. Non-goals and future deliverables

Separate future deliverables:

1. Canonical Confirmation Policy and single-use confirmation record.
2. Atomic Authoritative Write and Audit Transaction Design.
3. Full threat model for clients, models, tools, offline replay, retrieval, administrators, developers, and service identities.
4. Executable contract, concurrency, failure-injection, and adversarial tests.
5. Proposal, status, confirmation, cancellation, and mutation endpoints.

This phase does not authorize or implement:

- verifier integration or verifier-branch changes;
- an external authority anchor;
- deployment or Production changes;
- PostgreSQL readiness correction;
- migration 009 or any schema change;
- PropertyManager features, photos, last_done, or Spa/Pool behavior;
- client, Watch, Siri, Apple TV, App Intent, Home Assistant, Telegram, MCP, or integration implementation;
- database, SQL, service, container, runtime, authentication, API, WSGI, application, test, or deployment changes.

Future work MUST preserve strict Development and Production separation and require owner approval before Production action.

## 18. Review checklist

Conforming implementation MUST demonstrate:

- one authoritative API mutation boundary;
- no direct model, client, tool, integration, or offline database writes;
- typed bounded envelopes with unknown-field rejection;
- server-derived identity, policy, digest, and outcomes;
- separate proposal and mutation operations;
- deterministic lifecycle transitions;
- single-use digest-bound confirmation when required;
- optimistic concurrency and durable idempotency;
- atomic mutation and audit;
- inert retrieval and non-authoritative models;
- fail-closed sanitized errors;
- explicit capability classification;
- passing evidence for each applicable MUT test;
- reviewed resolution of each relevant open decision.
