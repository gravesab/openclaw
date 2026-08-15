---
title: "Canonical Confirmation Policy v1 and Single-Use Confirmation Record"
summary: "Normative confirmation classifications, operation matrix, challenge contract, and single-use confirmation record for authoritative mutations"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-04"
category: "Architecture"
source_document: "CANONICAL_CONFIRMATION_POLICY_V1.md"
read_when:
  - Classifying an authoritative mutation or deciding whether confirmation is required
  - Designing confirmation challenges, records, retries, replay protection, or audit behavior
  - Adding clients, automations, App Intents, models, or integrations that can propose mutations
---

# Canonical Confirmation Policy v1 and Single-Use Confirmation Record

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-04

This policy extends the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1). The governing mutation contract remains authoritative for proposal envelopes, validation, concurrency, idempotency, mutation handling, and atomic audit. This policy defines only confirmation classification, challenge issuance, and the single-use confirmation record.

Normative requirements use stable **CONF** identifiers. Examples and explanatory notes do not grant authority.

## 1. Governing principles

- **CONF-001:** The authoritative OpenClaw API MUST be the sole authority that determines whether a requested mutation is admissible.
- **CONF-002:** Admissibility and confirmation MUST be separate server decisions. A valid confirmation proves an authorized actor confirmed exact content; it does not prove that content is admissible.
- **CONF-003:** Confirmation MUST NOT substitute for authentication, authorization, proposal validation, provenance validation, policy evaluation, concurrency control, idempotency, or audit.
- **CONF-004:** A confirmation MUST NOT make an otherwise inadmissible mutation admissible.
- **CONF-005:** Clients, models, App Intents, automations, offline queues, replay systems, synchronization layers, retrieval systems, administrators, and service identities MUST NOT select, downgrade, bypass, or claim satisfaction of confirmation policy.
- **CONF-006:** Providers and models MAY return inert typed proposals. They MUST NOT receive authoritative database credentials, mutation credentials, reusable confirmation material, or direct authoritative mutation capability.
- **CONF-007:** The server MUST evaluate the current canonical operation matrix after proposal validation and before it accepts a confirmation record.
- **CONF-008:** Missing, ambiguous, conflicting, unavailable, or unversioned confirmation policy MUST fail closed.
- **CONF-009:** Human-readable confirmation UI MAY explain a decision, but only a server-verifiable record bound to the exact proposal can satisfy a confirmation requirement.
- **CONF-010:** Confirmation and its consumption MUST preserve the atomic audit invariant defined by the governing mutation contract.

## 2. Confirmation and capability are different

Authorization capability answers: **May this authenticated actor request this operation on this target?**

Confirmation classification answers: **After the request is independently admissible, what additional human confirmation evidence is required for this exact proposal?**

An actor MAY possess an authorization capability and still be required to confirm. An actor MAY present a valid confirmation and still lack authorization. Implementations MUST evaluate both independently and MUST require both when applicable.

## 3. Stable confirmation classifications

| ID   | Classification                                   | Normative treatment                                                                                                                                                                                                          |
| ---- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CF-0 | Forbidden                                        | The operation MUST be rejected. No confirmation can authorize it.                                                                                                                                                            |
| CF-1 | Server-governed without interactive confirmation | The mutation MAY proceed without an interactive challenge only after every non-confirmation control passes.                                                                                                                  |
| CF-2 | Explicit single-use confirmation                 | The server MUST issue a challenge and verify one fresh single-use confirmation record for the exact proposal.                                                                                                                |
| CF-3 | Separately governed strong confirmation          | The operation MUST NOT proceed under CF-1 or ordinary CF-2 alone. A separately approved policy MUST define stronger reauthentication, ceremony, evidence, or multi-party requirements. Until then, the operation is blocked. |

- **CONF-011:** Confirmation classification MUST be independent of authorization roles or capability names.
- **CONF-012:** An operation missing from the canonical matrix MUST be treated as CF-0.
- **CONF-013:** An unresolved ordinary mutation MUST receive the safest interim CF-2 treatment.
- **CONF-014:** An unresolved destructive, security-sensitive, financial, privacy-sensitive, bulk, irreversible, infrastructure, or Production operation MUST receive interim CF-3 treatment and remain blocked until its stronger policy is approved.
- **CONF-015:** A policy update MAY raise a classification immediately. Lowering a classification requires owner and security review, a new policy version, and evidence that the lower class preserves the governing contract.

## 4. Canonical operation matrix

This matrix is the single canonical source for confirmation requirements. Implementations MUST identify operations by the stable identifier below and MUST NOT infer confirmation class from endpoint names, UI labels, model text, HTTP methods, or client type.

**Legend**

- **Authn:** authenticated identity requirement.
- **Capability:** deterministic authorization requirement, separate from confirmation.
- **Freshness:** maximum age is policy-configured and unresolved; “fresh” means unexpired under trusted server time.
- **Version:** authoritative target-version or equivalent concurrency precondition.
- **Idem:** durable scoped idempotency.
- **Audit:** atomic authoritative audit.
- **Automation/offline:** permission to initiate, never permission to bypass current server checks.

| Operation ID                            | Target/resource class                                                         | Initiator/channel and required provenance                                                                  | Authn and capability                                      | Class and freshness                                           | Version, idem, audit                                              | Automation/offline                                                               | Fail-closed behavior                                                                              |
| --------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| mutation.direct-database-write          | Any authoritative record                                                      | Any client, model, tool, administrator utility, or integration; proposal provenance absent                 | Not applicable                                            | CF-0                                                          | No mutation permitted                                             | Never                                                                            | Reject direct path and record protected security telemetry.                                       |
| mutation.unknown-or-unregistered        | Any unregistered operation or resource                                        | Any                                                                                                        | Authn cannot cure missing policy                          | CF-0                                                          | No mutation permitted                                             | Never                                                                            | Reject unknown operation; do not guess or fall back.                                              |
| property.meter-reading.record-normal    | Asset meter reading not requiring correction                                  | Authenticated operator or registered API integration; typed proposal with observed source and entry method | Required; meter-write capability                          | CF-1 only where current policy recognizes an ordinary reading | Version, idem, and audit required                                 | Registered automation MAY initiate; offline MAY replay only under current checks | Reject or elevate to CF-2 if classification, provenance, unit, version, or identity is uncertain. |
| property.meter-reading.lower-correction | Lower reading, correction, rollover, or replacement                           | Authenticated operator; server preview from proposal and current reading chain                             | Required; correction capability                           | CF-2, fresh                                                   | Version and idem required; audit and epoch effects atomic         | Automation MUST NOT confirm; offline proposal only                               | Reject stale preview, changed chain, wrong reason, or missing confirmation.                       |
| property.meter.activate                 | Proposed meter defaults and activation                                        | Authenticated operator; import proposal plus source/category provenance                                    | Required; activation capability                           | CF-2, fresh                                                   | Asset version, idem, and audit required                           | Automation MAY propose only; offline confirmation prohibited                     | Reject changed defaults, policy, proposal, or asset version.                                      |
| property.maintenance.complete-metered   | Completion and confirmed/new live meter                                       | Authenticated operator; task, live meter, and completion provenance                                        | Required; completion capability                           | CF-2                                                          | Task/meter versions, idem, and audit required                     | Automation MAY propose only; offline confirmation prohibited                     | Reject stale cache, missing acknowledgement, or mismatched reading.                               |
| property.mapping.approve-one            | One RanchBrain task-to-asset mapping                                          | Authenticated operator; mapping proposal with source, confidence, rationale                                | Required; mapping-review capability                       | CF-2, fresh                                                   | Proposal/target versions, idem, and audit required                | Automation MAY propose only; offline prohibited                                  | Reject changed proposal, target, source, or version.                                              |
| property.mapping.approve-bulk           | Multiple mappings                                                             | Authenticated operator; complete bounded manifest                                                          | Required; bulk-mapping capability                         | Interim CF-3                                                  | Every version, batch idem, atomic or explicitly partitioned audit | Automation/offline prohibited                                                    | Block until bulk scope, failure, and stronger policy are approved.                                |
| property.asset-metadata.update          | Asset metadata                                                                | Authenticated operator; typed before/after proposal and provenance                                         | Required; asset-edit capability                           | Interim CF-2; final field classes unresolved                  | Asset version, idem, and audit required                           | Automation MAY propose only; offline prohibited                                  | Reject unknown fields, changed target, or missing classification.                                 |
| property.task.create-or-edit            | Maintenance task                                                              | Authenticated operator; typed proposal with evidence provenance when derived                               | Required; task-edit capability                            | Interim CF-2                                                  | Applicable versions, idem, and audit required                     | Automation/models MAY propose only                                               | Reject unverified evidence, unknown fields, or stale target.                                      |
| property.task-or-category.delete        | Task, category, and reassignment effects                                      | Authenticated operator; exact dependency/reassignment preview                                              | Required; delete capability                               | CF-2; bulk/irreversible elevates to CF-3                      | Dependency versions, idem, atomic audit                           | Automation/offline prohibited                                                    | Reject without confirmation or when dependencies changed.                                         |
| property.photo-or-artifact.mutate       | Artifact content or metadata                                                  | Operator or registered ingestion service; checksum/source provenance                                       | Required; artifact-write capability                       | Interim CF-2; retention/delete classes unresolved             | Version/checksum, idem, audit                                     | Ingestion MAY propose; destructive automation prohibited                         | Reject unknown storage, checksum mismatch, or unresolved class.                                   |
| governance.scorecard.decision           | Local scorecard approval/rejection                                            | Authenticated operator; displayed evaluation digest/evidence                                               | Required; review capability                               | CF-2; bound explicit decision may satisfy challenge           | Evaluation version/digest, idem, immutable audit                  | Automation/offline prohibited                                                    | Reject missing evidence, changed evaluation, or synthetic item.                                   |
| governance.scorecard.promote            | Promotion or routing activation                                               | Authenticated operator; accepted decision plus exact promotion proposal                                    | Required; promotion capability                            | CF-3 pending stronger policy                                  | Versions, idem, audit                                             | Automation/offline prohibited                                                    | Block without stronger approved policy.                                                           |
| security-or-identity.change             | Authn, authz, credentials, roles, firewall, security policy, service identity | Authenticated owner; exact before/after proposal                                                           | Required; owner security capability plus reauthentication | CF-3                                                          | Current versions, idem, atomic audit                              | Automation/offline prohibited                                                    | Block without separately governed strong policy.                                                  |
| data.destructive-or-restore             | Delete, restore, bulk overwrite, irreversible repair                          | Authenticated owner; verified manifest or exact destructive proposal                                       | Required; owner destructive/recovery capability           | CF-3                                                          | Snapshot/target versions, idem, atomic audit/rollback evidence    | Automation/offline prohibited                                                    | Block without approved destructive/restore policy and prerequisites.                              |
| finances.authoritative-mutation         | Financial state                                                               | Authorized actor; typed proposal and financial provenance                                                  | Required; financial capability                            | Interim CF-3                                                  | Version, idem, atomic audit                                       | Automation/offline prohibited                                                    | Block until financial policy and strong confirmation are approved.                                |
| privacy.bulk-or-sensitive-mutation      | Bulk personal, health, location, or sensitive state                           | Authorized actor; bounded manifest and lawful provenance                                                   | Required; privacy capability                              | Interim CF-3                                                  | Per-target versions, batch idem, protected audit                  | Automation/offline prohibited                                                    | Block until privacy and strong confirmation policy are approved.                                  |
| production.deploy-or-reconfigure        | Production deploy, migration, restart, infrastructure                         | Andy through controlled workflow; accepted Development evidence                                            | Required; owner Production capability                     | CF-3 plus separate Production authorization                   | Artifact/config version, idem, deployment audit                   | Automation/offline prohibited                                                    | Block without separate authorization and accepted evidence.                                       |

- **CONF-016:** A matrix row describes confirmation policy, not implementation permission.
- **CONF-017:** Operation-specific policy MAY be stricter but MUST NOT weaken this matrix.
- **CONF-018:** An operation spanning rows MUST use the strongest applicable class.
- **CONF-019:** A bulk request MUST NOT inherit one item's class without a bulk row.
- **CONF-020:** Automation and offline permission MUST be affirmative. Silence means prohibited.

## 5. Server-generated confirmation challenge

A challenge is short-lived and server-generated only after all pre-confirmation validation succeeds. It MUST include or reference:

- **CONF-021:** server-generated challenge ID and format version;
- **CONF-022:** proposal ID and canonical proposal digest;
- **CONF-023:** operation ID and immutable target ID;
- **CONF-024:** expected target version, validator version, and confirmation-policy version;
- **CONF-025:** actor and authorization context allowed to answer;
- **CONF-026:** trusted issuance and expiration times;
- **CONF-027:** plain-language material effects and safe before/after values;
- **CONF-028:** destructive, security, financial, privacy, bulk, or irreversible consequences;
- **CONF-029:** device/session binding requirements without secrets;
- **CONF-030:** cryptographic nonce or reference preventing substitution and replay.

A challenge MUST NOT reveal credentials, signing secrets, reusable verification material, unnecessary sensitive data, raw tokens, SQL, internal paths, or protected policy internals.

Any material proposal, policy, validator, actor, authorization, session, device, target, target-version, or digest change MUST invalidate the challenge. Client presentation MUST NOT alter authoritative effects, target, or binding.

## 6. Single-use confirmation record

| Field                       | Required semantics                                                      |
| --------------------------- | ----------------------------------------------------------------------- |
| confirmation_record_id      | Server-generated immutable record ID.                                   |
| record_format_version       | Exact record schema version.                                            |
| actor_id                    | Server-derived authenticated actor.                                     |
| authorization_context       | Bound roles, capabilities, delegation, and reauthentication context.    |
| device_session_context      | Required device/session binding or explicit server policy stating none. |
| proposal_id                 | Authoritative proposal ID.                                              |
| canonical_proposal_digest   | Exact confirmed digest.                                                 |
| operation_id                | Stable matrix operation ID.                                             |
| target_resource_id          | Immutable target ID.                                                    |
| expected_target_version     | Confirmed target version.                                               |
| validator_version           | Validator version used before challenge.                                |
| confirmation_policy_version | Exact policy version.                                                   |
| challenge_issued_at         | Trusted server issuance time.                                           |
| confirmed_at                | Trusted server confirmation time.                                       |
| expires_at                  | Trusted expiration time.                                                |
| cryptographic_nonce         | Unique unpredictable nonce or server-side nonce reference.              |
| verification_binding        | Cryptographic binding or verification reference.                        |
| key_or_verifier_version     | Key ID or verifier-version reference when applicable.                   |
| decision                    | Confirmed or rejected; rejection cannot become confirmation.            |
| consumption_state           | Unused, consumed, expired, cancelled, superseded, or failed-safe.       |
| consumption_reference       | Mutation/audit transaction reference when consumed.                     |

- **CONF-031:** Records MUST reject unknown fields and ambiguous encodings.
- **CONF-032:** The server MUST generate or independently verify every authoritative field.
- **CONF-033:** Any material payload, operation, actor, authorization, target, version, policy, validator, device/session, or digest change MUST invalidate the record.
- **CONF-034:** Records MUST be single-use and non-transferable.
- **CONF-035:** Verification MUST use an established cryptographic construction; this policy does not select algorithm, key store, or custody.
- **CONF-036:** Clients MUST NOT receive signing keys, reusable verification secrets, or material sufficient to mint records.
- **CONF-037:** Rejection MUST be terminal and audited.

## 7. Lifecycle and state transitions

| State             | Created by                                       | Permitted next state                                  |
| ----------------- | ------------------------------------------------ | ----------------------------------------------------- |
| challenge_created | Confirmation service after eligible validation   | presented, cancelled, expired, superseded             |
| presented         | Server after exact rendering                     | confirmed, rejected, cancelled, expired, superseded   |
| confirmed_unused  | Server after verified actor response             | consumed, cancelled, expired, superseded, failed_safe |
| rejected          | Server after actor rejection                     | Terminal                                              |
| consumed          | Atomic mutation coordinator                      | Terminal                                              |
| cancelled         | Authorized server operation                      | Terminal                                              |
| expired           | Trusted-time policy                              | Terminal                                              |
| superseded        | Material successor or version/policy change      | Terminal                                              |
| failed_safe       | Indeterminate or unverifiable confirmation state | Terminal pending separate recovery                    |

- **CONF-038:** Creation MUST follow complete pre-confirmation validation.
- **CONF-039:** Presentation MUST show exact material effects and target.
- **CONF-040:** Confirmation or rejection MUST be authenticated and challenge-bound.
- **CONF-041:** Issuance MUST follow server verification of the response.
- **CONF-042:** Application MUST revalidate record and current proposal facts.
- **CONF-043:** Consumption MUST be atomic with mutation and audit.
- **CONF-044:** Expiration, cancellation, supersession, malformed state, or failed verification MUST prevent consumption.
- **CONF-045:** Replay of consumed or terminal records MUST be rejected.
- **CONF-046:** Ambiguous failures MUST NOT make records reusable.

If the mutation transaction rolls back, consumption MUST roll back. Retry MAY reuse an unexpired record only for the identical proposal, digest, operation, target, version, actor, idempotency identity, validator, policy, and authorization.

If mutation committed but response was lost, identical idempotent retry MUST return the original outcome without another mutation or consumption. If commit state is indeterminate, the server MUST fail closed and prove authoritative status before retry; recovery MUST NOT create reusable confirmation.

## 8. Normative server validation order

The server MUST:

1. validate envelope/schema and reject unknown fields;
2. recalculate canonical identity/digest;
3. validate proposal provenance;
4. authenticate actor/service identity;
5. authorize capabilities/delegation;
6. resolve operation in the versioned matrix;
7. independently determine confirmation class;
8. reject CF-0 and unresolved CF-3 without stronger policy;
9. verify record schema and authoritative existence;
10. verify cryptographic binding and key/verifier version;
11. verify trusted issuance, confirmation, and expiration times;
12. verify actor, authorization, device, and session binding;
13. verify proposal, digest, operation, target, and expected version;
14. verify validator and policy versions;
15. load current state and enforce concurrency;
16. reserve or resolve idempotency;
17. atomically mutate, consume confirmation when applicable, and persist audit;
18. return committed or prior idempotent outcome with sanitized reason codes.

- **CONF-047:** Confirmation MUST NOT skip any governing-contract stage.
- **CONF-048:** Missing or indeterminate provenance, policy, keys, clock, versions, verifier, storage, idempotency, or audit MUST fail closed.
- **CONF-049:** Policy/validator changes require revalidation and invalidate confirmation when material.
- **CONF-050:** Errors MUST be stable, sanitized, and free of verification secrets.

## 9. Concurrency, idempotency, and replay resistance

- **CONF-051:** Target-version changes MUST invalidate confirmation.
- **CONF-052:** Payload changes MUST create a new digest, challenge, and confirmation.
- **CONF-053:** Expired, consumed, cancelled, rejected, superseded, malformed, failed-safe, or unverifiable records MUST be rejected.
- **CONF-054:** Concurrent requests MUST NOT double-consume or double-mutate.
- **CONF-055:** Idempotent retry MUST remain bound to original proposal, digest, operation, target, actor, and record.
- **CONF-056:** Idempotency-key reuse for another proposal, target, or content MUST fail closed.
- **CONF-057:** Offline replay/sync MUST NOT extend expiration, reuse terminal records, or bypass current policy.
- **CONF-058:** Material policy/validator change requires new confirmation.
- **CONF-059:** Multi-instance servers MUST use shared authoritative atomic replay protection; process-local locks/caches are insufficient.
- **CONF-060:** Trusted-time rollback, excessive skew, or unavailability MUST fail closed.

## 10. Audit and provenance

The protected audit trail MUST link proposal/digest, challenge/effects, decision, record, actor/authorization, policy/validator versions, target/version, client/session, provenance, idempotency, mutation result, consumption, and rejection/failure reason.

- **CONF-061:** Mutation, consumption, and audit MUST satisfy the governing atomic audit invariant.
- **CONF-062:** Audit MUST use server time and stable reason codes.
- **CONF-063:** Failed attempts MUST be auditable without secrets or reusable verification material.
- **CONF-064:** Audit access, retention, integrity, and redaction MUST follow least privilege.
- **CONF-065:** Audit persistence failure MUST prevent mutation and consumption.

## 11. Privacy and security boundaries

- **CONF-066:** Retain only data necessary for exact-decision proof, replay resistance, and approved audit.
- **CONF-067:** Displays/logs MUST redact secrets, tokens, risky nonce disclosure, key material, and unnecessary sensitive data.
- **CONF-068:** Records/verifier material MUST be protected in transit and at rest.
- **CONF-069:** Logs MUST NOT contain signing secrets, reusable verification material, credentials, keys, or unrestricted payloads.
- **CONF-070:** Trusted server time MUST govern issuance, expiration, and consumption; client clocks are advisory.
- **CONF-071:** Key/verifier rotation MUST be versioned; uncertain retired-version behavior fails closed.
- **CONF-072:** Session/device revocation MUST invalidate bound records.
- **CONF-073:** Compromised, missing, corrupted, or unverifiable record, key, clock, policy, validator, or replay state MUST fail closed.
- **CONF-074:** Reauthentication/recovery MUST NOT silently replace or extend confirmation.

## 12. Implementation-independent acceptance tests

| ID      | Required proof                                                                                     |
| ------- | -------------------------------------------------------------------------------------------------- |
| CFM-001 | Valid fresh confirmation for an admissible proposal produces one mutation, consumption, and audit. |
| CFM-002 | Confirmation cannot override failed authentication or authorization.                               |
| CFM-003 | Confirmation cannot override inadmissible policy.                                                  |
| CFM-004 | Payload change after confirmation invalidates digest and record.                                   |
| CFM-005 | Target-version change invalidates confirmation.                                                    |
| CFM-006 | Wrong actor fails closed.                                                                          |
| CFM-007 | Wrong or revoked device/session fails where binding applies.                                       |
| CFM-008 | Wrong operation fails closed.                                                                      |
| CFM-009 | Wrong target fails closed.                                                                         |
| CFM-010 | Expired confirmation fails under trusted time.                                                     |
| CFM-011 | Consumed-record replay cannot mutate or consume twice.                                             |
| CFM-012 | Concurrent double-use across instances has at most one committed outcome.                          |
| CFM-013 | Cancelled, rejected, failed-safe, or superseded records fail closed.                               |
| CFM-014 | Material validator change requires revalidation/new confirmation.                                  |
| CFM-015 | Material policy change requires revalidation/new confirmation.                                     |
| CFM-016 | Missing/corrupted/unverifiable cryptographic binding fails closed.                                 |
| CFM-017 | Trusted-clock failure, rollback, or skew prevents issuance/consumption.                            |
| CFM-018 | Identical idempotent retry after success returns original outcome only.                            |
| CFM-019 | Mutation failure rolls back consumption; ambiguity blocks retry until proven.                      |
| CFM-020 | Offline replay cannot extend expiration or bypass current checks.                                  |
| CFM-021 | Automation cannot weaken or satisfy CF-2/CF-3 confirmation.                                        |
| CFM-022 | Direct authoritative payload without proposal provenance is rejected.                              |
| CFM-023 | Audit persistence failure prevents mutation and consumption.                                       |
| CFM-024 | Multi-instance replay protection prevents cross-instance reuse.                                    |
| CFM-025 | Valid confirmation cannot authorize CF-0.                                                          |
| CFM-026 | Operation absent from matrix is forbidden.                                                         |
| CFM-027 | Bulk request cannot inherit one item's weaker class.                                               |
| CFM-028 | Provider/model substitution cannot gain mutation credentials or confirmation authority.            |

No executable tests are added.

## 13. Requirement-to-test traceability

| Area                           | Requirements              | Tests                                                                       |
| ------------------------------ | ------------------------- | --------------------------------------------------------------------------- |
| Server authority/admissibility | CONF-001 through CONF-010 | CFM-002, CFM-003, CFM-021, CFM-022, CFM-025, CFM-028                        |
| Classification/matrix          | CONF-011 through CONF-020 | CFM-003, CFM-021, CFM-025 through CFM-027                                   |
| Challenge binding              | CONF-021 through CONF-030 | CFM-004 through CFM-010, CFM-014, CFM-015                                   |
| Record/cryptography            | CONF-031 through CONF-037 | CFM-004 through CFM-010, CFM-013, CFM-016                                   |
| Lifecycle/atomicity            | CONF-038 through CONF-046 | CFM-001, CFM-011 through CFM-013, CFM-018, CFM-019                          |
| Validation/fail-closed         | CONF-047 through CONF-050 | CFM-002, CFM-003, CFM-014 through CFM-017, CFM-022                          |
| Concurrency/replay             | CONF-051 through CONF-060 | CFM-004, CFM-005, CFM-010 through CFM-012, CFM-018 through CFM-020, CFM-024 |
| Audit/provenance               | CONF-061 through CONF-065 | CFM-001, CFM-019, CFM-022, CFM-023                                          |
| Privacy/security               | CONF-066 through CONF-074 | CFM-007, CFM-010, CFM-016, CFM-017, CFM-020                                 |

## 14. Unresolved decisions

Owner and security review remain required for:

1. expiration periods by class;
2. canonical serialization and cryptographic algorithm;
3. key custody, verification architecture, hardware protection, and rotation;
4. device-binding strength and provable channels;
5. session binding, reauthentication, recovery, and lost-device behavior;
6. final classes for asset metadata, tasks, artifacts, normal readings, and other fields;
7. bulk limits, partial failure, and any CF-2 bulk class;
8. challenge, record, idempotency, replay, and audit retention;
9. possible multi-party approval and independence;
10. multi-instance replay-store/transaction architecture;
11. unexpired-record behavior during key, validator, and policy rotation;
12. reason-code registry and role-sensitive disclosure;
13. strong confirmation for Production, security, financial, privacy, restore, and destructive operations.

Interim CF-2/CF-3 classifications MUST apply. Uncertainty MUST NOT lower class, extend expiration, or permit fallback.

## 15. Non-goals

This document does not:

- implement confirmation/mutation APIs, UI, clients, or App Intents;
- grant models, providers, tools, automation, or integrations mutation authority;
- implement token storage, signing, cryptographic keys, or key management;
- create/modify migrations, including Migration 009;
- create the external authority anchor;
- deploy or activate runtime behavior;
- modify PropertyManager or another Ranch OS module;
- access Development or Production runtimes;
- change databases, SQL, services, containers, configuration, tests, applications, or deployment.

The next deliverable MAY define the Atomic Authoritative Write and Audit Transaction Design. It MUST NOT be inferred as implemented.
