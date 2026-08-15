---
title: "External Authority Anchor and Trust-Root Specification v1"
summary: "Normative design for an external authority anchor, trust-root manifests, signed authority statements, verification, lifecycle, rotation, revocation, anti-rollback, audit, and recovery"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-05"
category: "Architecture"
source_document: "EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1.md"
read_when:
  - Designing or reviewing the external root of trust for authoritative OpenClaw decisions
  - Defining authority statements, trust-root lifecycle, rotation, revocation, anti-rollback, or recovery
  - Evaluating verifier bootstrap, environment separation, compromise, or fail-closed authority behavior
---

# External Authority Anchor and Trust-Root Specification v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-05

This specification extends the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1), [Authoritative Mutation Threat Model v1](/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1), [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1), and [Authoritative Mutation Protocol v1](/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1). Those documents remain normative.

Requirements use stable **EAA** identifiers and implementation-independent acceptance tests use **EAT** identifiers. Examples do not create authority.

## 1. Governing invariant and purpose

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

The external authority anchor provides independently verifiable evidence that an authority root, governing policy set, verifier profile, or other explicitly approved authority statement was authorized under a defined ceremony. It does not decide an individual mutation, authenticate an arbitrary request, replace confirmation, or make inadmissible content admissible.

- **EAA-001:** The anchor MUST preserve owner authority by recording verifiable evidence of an approved authority statement; it MUST NOT replace owner authorization.
- **EAA-002:** The authoritative server MUST still independently perform identity, authorization, delegation, validation, confirmation, concurrency, idempotency, transaction, audit, and result processing.
- **EAA-003:** A valid anchor statement MUST NOT by itself authorize an individual mutation.
- **EAA-004:** A model, provider, retriever, tool, client, automation, administrator, developer, service identity, or internal network participant MUST NOT mint or alter anchor authority.
- **EAA-005:** Missing, stale, inconsistent, unavailable, compromised, revoked, rolled-back, or unverifiable anchor state MUST fail closed for every operation that requires it.
- **EAA-006:** This document specifies evidence and verification semantics only and MUST NOT be treated as authorization to create an anchor, credential, key, signature, trust store, or operational ceremony.

## 2. Security objectives

The anchor architecture MUST protect:

- authenticity of the approved authority source;
- integrity of trust-root manifests and signed statements;
- explicit scope and environment separation;
- freshness and anti-rollback;
- cryptographic agility without silent downgrade;
- revocation, suspension, rotation, and compromise response;
- separation of signing, verification, administration, and mutation authority;
- confidentiality of private and recovery material;
- durable accountable evidence;
- availability that never induces fail-open behavior;
- recovery without split brain, fabricated continuity, or restored obsolete authority;
- clear distinction between trust evidence and the current server decision.

The principal objective is to prevent forged, substituted, stale, cross-environment, overbroad, ambiguously recovered, or falsely represented authority from enabling authoritative mutation.

## 3. Trust model and boundaries

“External” means logically and operationally independent of the mutable OpenClaw application datastore and ordinary administrative path. It does not require a third-party cloud provider. The approved deployment form remains unresolved.

| Boundary                                              | Required treatment                                                                |
| ----------------------------------------------------- | --------------------------------------------------------------------------------- |
| Owner ceremony to anchor issuance                     | Verify owner identity, intent, statement, environment, and ceremony policy.       |
| Anchor signer to public trust-root manifest           | Protect private material; publish only approved verifiable public metadata.       |
| Trust-root distribution to verifier bootstrap         | Use independently authenticated pinned root evidence.                             |
| Verifier to authoritative admission                   | Return bounded deterministic verification evidence, never a mutation decision.    |
| Authority statement to policy and identity evaluation | Apply only exact approved scope and current server policy.                        |
| Rotation or revocation to all verifier instances      | Preserve monotonic ordering and block uncertain instances.                        |
| Development to Production                             | Use distinct roots, statements, credentials, channels, and activation ceremonies. |
| Backup or recovery to restored verifier               | Prove continuity, freshness, revocation, and single-writer authority before use.  |

- **EAA-007:** The mutable application database MUST NOT be the sole source from which the trust root is established.
- **EAA-008:** Ordinary database, application, deployment, or administrator access MUST NOT be sufficient to replace the trust root.
- **EAA-009:** The verifier MUST begin from independently provisioned bootstrap evidence approved for one environment and purpose.
- **EAA-010:** Trust in a transport, host, internal network, file path, database row, DNS response, package, or provider MUST NOT substitute for cryptographic and policy verification.

## 4. Protected assets and roles

| Asset or role                      | Security property                                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Root public verification material  | Authentic, environment-bound, versioned, and independently distributed.                                 |
| Root private or recovery material  | Non-exported or strongly protected under approved custody; never exposed to OpenClaw application roles. |
| Trust-root manifest                | Canonical, signed, monotonic, scoped, and rollback-resistant.                                           |
| Authority statement                | Canonical, signed, bounded, time-limited where required, and linked to policy.                          |
| Revocation and suspension evidence | Authentic, current, monotonic, and rapidly distributable.                                               |
| Ceremony evidence                  | Links owner authorization, participants, reviewed content, time, and result.                            |
| Verifier profile                   | Defines accepted algorithms, encodings, quorum, time, and chain rules.                                  |
| Bootstrap evidence                 | Pins the first trusted root for one environment and purpose.                                            |
| Verification result                | Bounded evidence with statement, root, profile, freshness, and reason identifiers.                      |
| Anchor administrator               | May maintain approved infrastructure but cannot unilaterally authorize statements.                      |
| Ceremony participant               | Performs one defined independent role; does not gain general mutation authority.                        |
| Verifier                           | Read-only evaluator of trust evidence; has no signing or mutation credential.                           |
| Recovery custodian                 | Participates only under separately governed recovery rules.                                             |
| Auditor                            | Reads protected evidence and cannot sign, activate, or mutate.                                          |

- **EAA-011:** Signing, verification, anchor administration, ordinary mutation, deployment, audit review, and recovery SHOULD use separated identities and duties.
- **EAA-012:** A role MUST NOT inherit another role’s authority from co-location, employment, device possession, or infrastructure access.
- **EAA-013:** Private, recovery, and quorum material MUST NOT enter application memory, proposals, model context, tools, logs, audit payloads, source control, or ordinary backups.
- **EAA-014:** Public verification material MAY be widely distributed but MUST retain authenticated provenance, environment, purpose, version, and status.

## 5. Trust-root manifest

A canonical trust-root manifest MUST contain or securely reference:

| Field                                   | Required semantics                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------------------ |
| manifest_format_version                 | Exact supported schema; unknown fields and versions reject.                                |
| trust_root_id                           | Immutable server-independent identifier.                                                   |
| trust_domain                            | Stable purpose domain, such as authority-policy verification.                              |
| environment                             | Exact Development, Production, recovery, or other approved environment.                    |
| root_epoch                              | Monotonic root generation that cannot decrease.                                            |
| root_sequence                           | Monotonic manifest sequence within the epoch.                                              |
| prior_manifest_digest                   | Digest of the directly preceding manifest, except approved genesis.                        |
| issued_at and effective_at              | Trusted ceremony times.                                                                    |
| expires_at or explicit no-expiry policy | Approved validity treatment; ambiguity rejects.                                            |
| public_verification_entries             | Versioned key or verifier references, purposes, states, and allowed profiles.              |
| threshold_policy                        | Required signer or quorum policy, including explicit single-signer policy when approved.   |
| accepted_statement_profiles             | Exact statement types and versions this root may verify.                                   |
| algorithm_profile                       | Approved signature, digest, canonicalization, and parameter identifiers.                   |
| revocation_sources                      | Authenticated current revocation and suspension evidence locations or embedded references. |
| recovery_policy_id                      | Exact separately approved recovery policy, or absent when recovery is prohibited.          |
| ceremony_id and audit_reference         | Protected accountable issuance evidence.                                                   |
| manifest_digest and signature_set       | Canonical digest and qualifying signatures.                                                |
| status                                  | proposed, active, suspended, revoked, expired, superseded, or compromised.                 |

- **EAA-015:** The manifest MUST be canonicalized and verified under an approved established cryptographic profile.
- **EAA-016:** Unknown fields, duplicate keys, ambiguous encodings, unsupported algorithms, invalid parameters, or unrecognized purposes MUST reject.
- **EAA-017:** Root epoch and sequence MUST be monotonic and bound to prior-manifest continuity.
- **EAA-018:** One root or manifest MUST NOT cross environment or trust-domain boundaries.
- **EAA-019:** A client-supplied manifest or key MUST NOT replace verifier bootstrap evidence.
- **EAA-020:** Manifest status and revocation state MUST be checked whenever a dependent authority statement is evaluated.

## 6. Signed authority statement

An authority statement records approved authority evidence. It MUST contain:

| Field                                       | Required semantics                                                                                 |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| statement_format_version                    | Exact supported statement schema.                                                                  |
| statement_id                                | Immutable globally unique identifier within the trust domain.                                      |
| statement_type                              | Stable allowlisted authority-statement purpose.                                                    |
| trust_root_id, epoch, and manifest_sequence | Exact root and manifest used for issuance.                                                         |
| environment and trust_domain                | Exact non-transferable scope.                                                                      |
| subject_type and subject_id                 | Policy set, identity authority, verifier profile, or other approved subject.                       |
| authority_claims                            | Typed bounded claims; unknown claims reject.                                                       |
| constraints                                 | Operation, module, resource, target, time, assurance, confirmation, or other deterministic bounds. |
| policy and validator references             | Exact approved identities and versions where applicable.                                           |
| not_before and expires_at                   | Trusted validity window or explicit approved non-expiring treatment.                               |
| statement_sequence                          | Monotonic sequence for the subject and purpose.                                                    |
| prior_statement_digest                      | Direct predecessor digest except approved genesis.                                                 |
| supersedes_statement_id                     | Exact predecessor when replacement applies.                                                        |
| owner_authorization_reference               | Protected reference to the reviewed owner decision.                                                |
| ceremony_id and evidence_digest             | Accountable ceremony and reviewed-content evidence.                                                |
| canonical_digest and signature_set          | Server-independent canonical identity and qualifying signatures.                                   |
| status                                      | proposed, active, suspended, revoked, expired, superseded, or compromised.                         |

- **EAA-021:** Authority claims MUST be typed, bounded, explicit, and incapable of granting unspecified authority.
- **EAA-022:** A statement MUST NOT grant authority beyond the statement type, trust domain, environment, subject, constraints, validity, policy, and verifier profile.
- **EAA-023:** A statement MUST NOT embed raw credentials, private keys, signing secrets, recovery material, unrestricted personal data, or executable instructions.
- **EAA-024:** A material statement change MUST create a new canonical digest, sequence, and signature set.
- **EAA-025:** A statement MUST NOT be transferred between subjects, environments, trust domains, policy versions, or purposes.
- **EAA-026:** Statement validity MUST remain separate from current identity, authorization, delegation, confirmation, mutation, and transaction admissibility.

## 7. Canonicalization and cryptographic profiles

- **EAA-027:** Canonicalization, digest, signature, threshold, and key-identifier algorithms MUST use established reviewed standards.
- **EAA-028:** Every cryptographic profile MUST have an immutable identifier and exact parameter set.
- **EAA-029:** Algorithm agility MUST use explicit new profiles and MUST NOT silently reinterpret old signatures.
- **EAA-030:** Downgrade, algorithm confusion, cross-protocol signature reuse, ambiguous key identifiers, duplicate signers, or unsupported parameters MUST reject.
- **EAA-031:** Signature verification MUST bind exact canonical bytes, statement purpose, environment, trust domain, root epoch, sequence, and profile.
- **EAA-032:** Private-key custody, hardware protection, signer quorum, and recovery shares remain unresolved and MUST NOT be inferred from this specification.
- **EAA-033:** Custom cryptographic constructions or informal string concatenation MUST be prohibited.
- **EAA-034:** Verification libraries and dependencies MUST be versioned, reviewed, and treated as untrusted when integrity or behavior cannot be proven.

## 8. Bootstrap and genesis

Bootstrap establishes the first independently trusted public root for one environment and trust domain.

- **EAA-035:** Genesis MUST require an explicit owner-approved ceremony with exact root ID, environment, trust domain, profile, participants, and reviewed manifest digest.
- **EAA-036:** Bootstrap evidence MUST be distributed through an independently authenticated channel that does not rely solely on the system being anchored.
- **EAA-037:** A verifier MUST pin exact genesis evidence and MUST NOT use trust-on-first-use unless separately approved.
- **EAA-038:** Reinstallation, new instance enrollment, or disaster recovery MUST NOT silently create a new genesis.
- **EAA-039:** Multiple conflicting genesis roots for one environment and trust domain MUST produce failed-safe split-brain status.
- **EAA-040:** Genesis ceremony, distribution, and acceptance remain prohibited until separately authorized.

## 9. Anchor and statement lifecycle

| State       | Meaning                                           | Permitted treatment                 |
| ----------- | ------------------------------------------------- | ----------------------------------- |
| proposed    | Draft evidence not yet authorized or active.      | Cannot verify operational authority |
| active      | Authorized and current under approved policy.     | Eligible for complete verification  |
| suspended   | Temporarily unusable pending review.              | Reject dependent use                |
| revoked     | Permanently invalidated.                          | Reject and terminal                 |
| expired     | Trusted validity ended.                           | Reject and terminal                 |
| superseded  | Replaced by an approved successor.                | Reject new use; retain history      |
| compromised | Integrity or custody is suspected or proven lost. | Reject and enter incident recovery  |

- **EAA-041:** Only an approved ceremony and qualifying signatures MAY transition proposed evidence to active.
- **EAA-042:** State transitions MUST be monotonic, versioned, authorized, and auditable.
- **EAA-043:** Revoked, expired, superseded, or compromised evidence MUST NOT return to active.
- **EAA-044:** Suspension, revocation, expiry, supersession, or compromise MUST invalidate dependent use under current verification policy.
- **EAA-045:** Historical evidence MUST remain available for attribution and prior-result verification without authorizing new mutation.
- **EAA-046:** Lifecycle state stored only in a mutable application cache MUST NOT establish current status.

## 10. Issuance and activation ceremony

A future ceremony MUST separate preparation, review, owner authorization, signing, verification, publication, activation, and audit.

- **EAA-047:** The exact canonical manifest or statement digest MUST be displayed and reviewed before authorization.
- **EAA-048:** Human-readable material effects MUST be bound to the reviewed canonical digest.
- **EAA-049:** Participants MUST use individual ceremony identities and approved assurance profiles.
- **EAA-050:** Signers MUST verify environment, trust domain, purpose, sequence, predecessor, validity, policy, constraints, and owner authorization before signing.
- **EAA-051:** Activation MUST require independent verification that the published object exactly matches the authorized and signed object.
- **EAA-052:** A signer MUST NOT sign unknown, incomplete, ambiguous, conflicting, or policy-ineligible content.
- **EAA-053:** Ceremony failure or disagreement MUST leave the object non-active.
- **EAA-054:** This specification does not authorize or perform a ceremony.

## 11. Rotation and continuity

- **EAA-055:** Planned rotation MUST create a new epoch or verification entry under an approved continuity rule.
- **EAA-056:** Rotation MUST bind predecessor and successor identities, profiles, activation time, overlap, retirement, and rollback treatment.
- **EAA-057:** A successor MUST be authorized before the predecessor loses the ability to establish approved continuity, unless compromise recovery policy applies.
- **EAA-058:** Overlap MUST be bounded and MUST NOT allow contradictory active authority.
- **EAA-059:** Retired verification material MAY verify historical evidence only under an explicit historical-verification policy.
- **EAA-060:** Unknown, missed, partial, or conflicting rotation MUST fail closed.
- **EAA-061:** Rotation MUST NOT reactivate revoked statements or extend their validity.
- **EAA-062:** Clients and verifiers MUST NOT select an older root merely because it still verifies cryptographically.

## 12. Suspension, revocation, and compromise

- **EAA-063:** Suspension and revocation evidence MUST be authenticated, monotonic, scoped, and distributed through approved channels.
- **EAA-064:** Suspected signer, key, verifier, bootstrap, ceremony, or distribution compromise MUST suspend affected authority immediately under policy.
- **EAA-065:** Compromise handling MUST identify affected roots, statements, environments, time windows, mutations, and audit evidence.
- **EAA-066:** Revocation MUST NOT erase history or falsely relabel previously valid results.
- **EAA-067:** Compromised evidence MUST NOT authorize recovery of itself.
- **EAA-068:** Recovery MUST use separately protected recovery authority and independent owner authorization.
- **EAA-069:** If compromise scope cannot be determined, every potentially affected operation MUST remain blocked.
- **EAA-070:** Emergency bypass or acceptance of unverifiable signatures MUST be prohibited.

## 13. Verification pipeline

For every anchor-dependent decision, the verifier MUST perform in order:

1. parse bounded exact object bytes;
2. validate object schema, version, purpose, and unknown-field rejection;
3. load independently pinned bootstrap evidence for the exact environment and trust domain;
4. verify trust-root ID, epoch, sequence, predecessor continuity, and manifest status;
5. verify the approved cryptographic and threshold profile;
6. verify every qualifying signer is distinct, eligible, current, and purpose-authorized;
7. verify object digest and signature set over exact canonical bytes;
8. verify environment, trust domain, subject, statement type, policy, validator, and constraint binding;
9. verify trusted not-before, expiry, suspension, revocation, compromise, and supersession state;
10. enforce monotonic anti-rollback state;
11. produce a bounded versioned verification result and stable reason;
12. pass evidence to current deterministic server policy without deciding mutation admissibility.

- **EAA-071:** No verification stage MAY be skipped because the object came from an owner, administrator, internal host, database, backup, client, or previously trusted cache.
- **EAA-072:** The verifier MUST reject unknown signer, root, statement, algorithm, profile, environment, purpose, or sequence.
- **EAA-073:** Verification success MUST identify exact manifest, statement, profile, signers, freshness, and revocation evidence.
- **EAA-074:** Verification failure MUST be stable, sanitized, and free of private material or exploitable oracle detail.
- **EAA-075:** A successful verification result is evidence for server policy; it MUST NOT itself invoke mutation, consume confirmation, or claim commit.

## 14. Mutation-protocol integration

The Authoritative Mutation Protocol remains the only lifecycle for authoritative application.

- **EAA-076:** Admission MUST require current anchor verification only for operation classes and authority facts explicitly governed by an approved anchor policy.
- **EAA-077:** The server MUST bind required verification-result identity into proposal, command, confirmation, policy, validator, idempotency, transaction, and audit evidence as applicable.
- **EAA-078:** Statement change, root rotation, revocation, compromise, or freshness loss MUST invalidate dependent pending eligibility when material.
- **EAA-079:** The authoritative transaction MUST recheck material anchor status or an approved transaction-safe freshness proof.
- **EAA-080:** Confirmation MUST NOT override failed anchor verification.
- **EAA-081:** Idempotent retrieval MAY return an outcome committed while authority was valid, but MUST NOT authorize a new mutation after revocation.
- **EAA-082:** Required anchor-verification evidence missing from audit MUST prevent commit.
- **EAA-083:** A model, client, tool, or service claim that anchor verification succeeded MUST be ignored.

## 15. Freshness, trusted time, and anti-rollback

- **EAA-084:** Trusted server time, not client or signer device time, MUST govern validity checks.
- **EAA-085:** Verifiers MUST retain monotonic highest-seen epoch, manifest sequence, and subject statement sequence under an approved durable anti-rollback design.
- **EAA-086:** Older evidence MUST NOT replace newer accepted evidence even when its signature remains mathematically valid.
- **EAA-087:** Clock rollback, excessive skew, unavailable time, lost monotonic state, or inconsistent replicas MUST fail closed.
- **EAA-088:** Offline verification MAY use cached evidence only within an approved bounded freshness window and with current revocation guarantees.
- **EAA-089:** Offline storage MUST NOT extend statement validity, bypass revocation, or reset highest-seen state.
- **EAA-090:** Exact freshness windows, time sources, and rollback-resistant storage remain unresolved.

## 16. Availability and fail-closed behavior

Anchor dependency increases availability risk. The architecture MUST prefer denial over unverified authority.

- **EAA-091:** Verifier, trust manifest, revocation, time, policy, or anti-rollback unavailability MUST block affected mutations.
- **EAA-092:** Availability failure MUST NOT fall back to an embedded default root, older manifest, client-provided key, disabled verification, or direct administrator approval.
- **EAA-093:** Cached success MUST NOT outlive its approved freshness, environment, policy, or revocation conditions.
- **EAA-094:** Health and readiness MUST report anchor-dependent mutation unavailable when current verification cannot be proven.
- **EAA-095:** Denial-of-service mitigation MUST use bounded parsing, caching, rate limits, and resilient distribution without weakening verification.
- **EAA-096:** Operations not governed by an anchor MAY continue only when deterministic policy proves complete isolation from the failed trust domain.

## 17. Audit and accountable evidence

Required audit MUST record or securely reference:

- trust root, domain, environment, epoch, and manifest sequence;
- statement ID, type, subject, sequence, canonical digest, status, and validity;
- verifier and algorithm profiles;
- qualifying signer identifiers without private material;
- bootstrap, continuity, freshness, time, and revocation evidence;
- ceremony and owner-authorization references;
- verification result and stable reason;
- dependent proposal, command, principal, delegation, confirmation, transaction, and result;
- rotation, suspension, revocation, compromise, or recovery context.

- **EAA-097:** Required verification audit MUST commit atomically with an anchor-dependent mutation.
- **EAA-098:** Ordinary application, client, signer, verifier, and administrator roles MUST NOT alter or delete canonical audit evidence.
- **EAA-099:** Logs, metrics, dashboards, and transparency views MUST remain derived and MUST NOT become alternate trust roots.
- **EAA-100:** Audit and public diagnostics MUST minimize sensitive data and MUST NOT expose private, recovery, nonce, or signing material.

## 18. Backup, restoration, and disaster recovery

- **EAA-101:** Ordinary application backup MUST NOT include unprotected root private or recovery material.
- **EAA-102:** Backup of public manifests, statements, revocation evidence, anti-rollback state, and audit MUST preserve integrity, ordering, environment, and provenance.
- **EAA-103:** Restore MUST verify archive integrity, checksum, identity, environment, continuity, highest-seen state, revocation, trusted time, and single-writer fencing.
- **EAA-104:** Restored stale trust state MUST NOT reauthorize revoked or superseded evidence.
- **EAA-105:** A recovered verifier MUST remain disabled until bootstrap and current continuity are independently proven.
- **EAA-106:** Split-brain trust roots or conflicting highest-seen state MUST block anchor-dependent mutation.
- **EAA-107:** Recovery evidence MUST be auditable and MUST NOT fabricate uninterrupted continuity.
- **EAA-108:** Recovery custody, quorum, ceremony, and continuity remain unresolved and prohibited from operational use.

## 19. Development and Production separation

- **EAA-109:** Development and Production MUST use different trust-root IDs, keys, manifests, statements, signers, bootstrap channels, verifier state, revocation evidence, and ceremonies.
- **EAA-110:** Development evidence MUST NOT verify or activate Production authority, and Production evidence MUST NOT authorize Development mutation.
- **EAA-111:** Production root creation, activation, rotation, revocation, recovery, or use requires separate explicit owner authorization.
- **EAA-112:** Development approval, commit, branch, worktree, network, administrator, or signer access MUST NOT imply Production authority.
- **EAA-113:** Test fixtures and example signatures MUST be unmistakably non-production and MUST fail under Production bootstrap evidence.
- **EAA-114:** This specification does not authorize Production access, deployment, configuration, key creation, or ceremony.

## 20. Threat and failure matrix

| Threat or failure                                                 | Required disposition                      | Evidence                            |
| ----------------------------------------------------------------- | ----------------------------------------- | ----------------------------------- |
| Forged manifest or statement                                      | Reject                                    | Digest, signer, profile, and reason |
| Client-provided root or key substitution                          | Reject                                    | Bootstrap mismatch                  |
| Wrong environment or trust domain                                 | Reject and alert                          | Expected and observed scope         |
| Unknown field, profile, algorithm, or purpose                     | Reject                                    | Stable unsupported reason           |
| Signature, threshold, or canonicalization failure                 | Reject                                    | Sanitized verification reason       |
| Duplicate signer counted toward quorum                            | Reject                                    | Distinct signer-set evidence        |
| Root epoch or sequence rollback                                   | Reject and failed-safe                    | Highest-seen and presented state    |
| Statement sequence rollback                                       | Reject                                    | Subject sequence evidence           |
| Broken predecessor chain                                          | Reject                                    | Expected and observed digest        |
| Expired, suspended, revoked, superseded, or compromised root      | Reject                                    | Current lifecycle evidence          |
| Expired, suspended, revoked, superseded, or compromised statement | Reject                                    | Current lifecycle evidence          |
| Trusted-time failure or rollback                                  | Reject                                    | Protected time-health evidence      |
| Revocation source unavailable                                     | Unavailable, never fail open              | Dependency state                    |
| Split-brain roots or manifests                                    | Failed-safe                               | Conflicting root evidence           |
| Rotation partially distributed                                    | Reject uncertain instances                | Rotation and distribution state     |
| Recovery from stale backup                                        | Keep verifier disabled                    | Restore consistency report          |
| Compromised signer or verifier                                    | Suspend affected authority                | Incident and scope evidence         |
| Administrator edits mutable trust cache                           | Ignore cache as authority and detect      | Pinned-root comparison              |
| Valid statement exceeds current server policy                     | Reject mutation                           | Statement and policy decision       |
| Valid confirmation with invalid anchor                            | Reject mutation                           | Confirmation and anchor reasons     |
| Idempotent replay of prior committed result                       | Return original result only               | Original transaction evidence       |
| New mutation after anchor revocation                              | Reject                                    | Current revocation evidence         |
| Required anchor audit write fails                                 | Roll back mutation                        | audit_unavailable                   |
| Anchor service denial                                             | Anchor-dependent operations unavailable   | Health and dependency evidence      |
| Model or tool claims anchor success                               | Ignore and verify independently           | Participation and verifier result   |
| Production request with Development root                          | Reject and security audit                 | Environment mismatch                |
| Unapproved ceremony or genesis                                    | Remain proposed or absent                 | Missing authorization evidence      |
| Ambiguous compromise scope                                        | Block all potentially affected operations | Incident scope record               |

## 21. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                            |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| EAT-001 | A client, model, tool, automation, or administrator cannot mint an accepted trust root or statement.                                      |
| EAT-002 | A valid anchor statement cannot directly invoke or authorize an individual mutation.                                                      |
| EAT-003 | Unknown fields, versions, algorithms, profiles, purposes, or claims fail closed.                                                          |
| EAT-004 | Ambiguous canonical encoding, duplicate key, or unsupported numeric form fails.                                                           |
| EAT-005 | Signature verification binds exact canonical bytes, purpose, environment, root, epoch, sequence, and profile.                             |
| EAT-006 | Duplicate or ineligible signers cannot satisfy threshold policy.                                                                          |
| EAT-007 | Client-provided root, key, manifest, or trust-on-first-use cannot replace pinned bootstrap evidence.                                      |
| EAT-008 | Development root or statement cannot verify in Production and vice versa.                                                                 |
| EAT-009 | Manifest epoch or sequence rollback is rejected even when the old signature is valid.                                                     |
| EAT-010 | Statement sequence rollback or broken predecessor continuity is rejected.                                                                 |
| EAT-011 | Cross-subject, environment, domain, purpose, policy, or constraint reuse fails.                                                           |
| EAT-012 | Expired, suspended, revoked, superseded, or compromised root cannot verify new authority.                                                 |
| EAT-013 | Expired, suspended, revoked, superseded, or compromised statement cannot support mutation.                                                |
| EAT-014 | Trusted-clock failure, rollback, excessive skew, or unavailable time fails closed.                                                        |
| EAT-015 | Revocation-source unavailability blocks affected use without fallback.                                                                    |
| EAT-016 | Partially distributed or conflicting rotation causes uncertain verifiers to reject.                                                       |
| EAT-017 | Retired verification material cannot authorize new statements outside historical policy.                                                  |
| EAT-018 | Compromised root or signer cannot authorize its own recovery.                                                                             |
| EAT-019 | Ambiguous compromise scope blocks every potentially affected operation.                                                                   |
| EAT-020 | Anchor verification does not replace identity, authorization, delegation, validation, confirmation, concurrency, or idempotency.          |
| EAT-021 | Valid confirmation cannot override failed anchor verification.                                                                            |
| EAT-022 | Material root or statement change invalidates dependent pending proposal or confirmation.                                                 |
| EAT-023 | Authoritative transaction rechecks required anchor freshness or approved proof.                                                           |
| EAT-024 | Required anchor audit failure rolls back mutation and confirmation consumption.                                                           |
| EAT-025 | Idempotent retrieval returns a result committed under then-valid authority without authorizing a new mutation.                            |
| EAT-026 | Offline cache cannot extend validity, bypass revocation, or reset anti-rollback state.                                                    |
| EAT-027 | Verifier outage cannot select an older root, embedded default, client key, or disabled-verification fallback.                             |
| EAT-028 | Non-anchor operations continue only when policy proves isolation from failed trust domain.                                                |
| EAT-029 | Private or recovery material cannot appear in application memory, model context, tools, logs, audit, source control, or ordinary backups. |
| EAT-030 | Mutable database or application-cache edit cannot replace independently pinned trust state.                                               |
| EAT-031 | New verifier enrollment requires independently authenticated bootstrap evidence.                                                          |
| EAT-032 | Reinstallation or recovery cannot silently create a new genesis.                                                                          |
| EAT-033 | Restore of stale or inconsistent root, statement, revocation, or highest-seen state leaves verifier disabled.                             |
| EAT-034 | Split-brain roots or anti-rollback state block anchor-dependent mutation.                                                                 |
| EAT-035 | Ceremony content mismatch or participant disagreement leaves object non-active.                                                           |
| EAT-036 | Unapproved genesis, activation, rotation, recovery, or Production ceremony cannot create active authority.                                |
| EAT-037 | Audit links exact anchor evidence to proposal, identity, confirmation, transaction, and result.                                           |
| EAT-038 | Logs, metrics, dashboards, and transparency views cannot become alternate trust roots.                                                    |
| EAT-039 | Provider, dependency, verifier, transport, or host substitution cannot change accepted authority.                                         |
| EAT-040 | A successful anchor-dependent mutation always includes current verified anchor evidence and every governing protocol control.             |

No executable tests, keys, signatures, or anchors are created by this documentation task.

## 22. Traceability

### 22.1 Requirement-to-test traceability

| Requirements            | Tests                                                     |
| ----------------------- | --------------------------------------------------------- |
| EAA-001 through EAA-010 | EAT-001, EAT-002, EAT-007, EAT-020, EAT-030, EAT-039      |
| EAA-011 through EAA-020 | EAT-003, EAT-007, EAT-008, EAT-029, EAT-030               |
| EAA-021 through EAA-026 | EAT-002 through EAT-005, EAT-011, EAT-020                 |
| EAA-027 through EAA-034 | EAT-003 through EAT-006, EAT-017, EAT-029, EAT-039        |
| EAA-035 through EAA-040 | EAT-007, EAT-031, EAT-032, EAT-035, EAT-036               |
| EAA-041 through EAA-046 | EAT-012, EAT-013, EAT-017, EAT-035                        |
| EAA-047 through EAA-054 | EAT-001, EAT-005, EAT-006, EAT-035, EAT-036               |
| EAA-055 through EAA-062 | EAT-009, EAT-010, EAT-016, EAT-017, EAT-022               |
| EAA-063 through EAA-070 | EAT-012, EAT-013, EAT-015, EAT-018, EAT-019               |
| EAA-071 through EAA-075 | EAT-003 through EAT-007, EAT-011 through EAT-015, EAT-039 |
| EAA-076 through EAA-083 | EAT-002, EAT-020 through EAT-025, EAT-037, EAT-040        |
| EAA-084 through EAA-090 | EAT-009, EAT-010, EAT-014, EAT-026, EAT-033, EAT-034      |
| EAA-091 through EAA-096 | EAT-015, EAT-027, EAT-028, EAT-039                        |
| EAA-097 through EAA-100 | EAT-024, EAT-029, EAT-037, EAT-038, EAT-040               |
| EAA-101 through EAA-108 | EAT-018, EAT-029, EAT-032 through EAT-034                 |
| EAA-109 through EAA-114 | EAT-008, EAT-036                                          |

### 22.2 Governing-document traceability

| Governing document                                                                                      | Anchor requirements                                                                                | Tests                                                                |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Mutation and Proposal Contract MUT-001 through MUT-020                                                  | EAA-001 through EAA-010, EAA-021 through EAA-026, EAA-076 through EAA-083                          | EAT-001, EAT-002, EAT-020 through EAT-025, EAT-040                   |
| Confirmation Policy CONF-001 through CONF-074 and CFM-001 through CFM-028                               | EAA-003, EAA-021 through EAA-026, EAA-076 through EAA-083                                          | EAT-002, EAT-020 through EAT-025                                     |
| Atomic Transaction Design ATX-001 through ATX-069 and ATM-001 through ATM-030                           | EAA-075 through EAA-083, EAA-097 through EAA-108                                                   | EAT-023 through EAT-025, EAT-033, EAT-034, EAT-037, EAT-040          |
| Mutation Threat Model AMT-001 through AMT-040, AMR-001 through AMR-068, and AMTST-001 through AMTST-038 | EAA-001 through EAA-114                                                                            | EAT-001 through EAT-040                                              |
| Identity and Delegation Policy IDP-001 through IDP-082 and IDT-001 through IDT-038                      | EAA-001 through EAA-014, EAA-021 through EAA-026, EAA-047 through EAA-054, EAA-076 through EAA-083 | EAT-001, EAT-002, EAT-020 through EAT-025, EAT-029, EAT-037, EAT-040 |
| Authoritative Mutation Protocol AMP-001 through AMP-090 and APT-001 through APT-040                     | EAA-001 through EAA-006, EAA-071 through EAA-100                                                   | EAT-001 through EAT-040                                              |

## 23. Unresolved decisions and interim treatment

| Decision                                                        | Affected boundary               | Interim fail-closed treatment                                   | Owner                     |
| --------------------------------------------------------------- | ------------------------------- | --------------------------------------------------------------- | ------------------------- |
| Physical or logical anchor deployment form                      | Trust-root infrastructure       | No anchor-dependent operation may be enabled                    | Owner and Security        |
| Genesis and bootstrap ceremony                                  | Bootstrap                       | No trust root may become active                                 | Owner and Security        |
| Owner identity assurance during ceremony                        | Issuance and recovery           | Ceremony prohibited without approved profile                    | Owner and Security        |
| Canonical serialization and digest algorithms                   | All signed objects              | No object may be accepted                                       | Security                  |
| Signature algorithms and parameters                             | Signing and verification        | No signature profile may be activated                           | Security                  |
| Key generation, storage, hardware protection, and export policy | Signer custody                  | No key may be created under this specification                  | Owner and Security        |
| Signer count, threshold, independence, and quorum               | Ceremony and statements         | No statement may become active                                  | Owner and Security        |
| Recovery shares, custodians, and quorum                         | Recovery                        | Recovery prohibited                                             | Owner and Security        |
| Manifest and statement schemas and extension registry           | Parsing                         | Unknown or incomplete object rejects                            | Architecture and Security |
| Root and statement validity periods                             | Freshness                       | Missing validity policy rejects                                 | Owner and Security        |
| Trusted-time sources and skew limits                            | Verification                    | Clock uncertainty blocks                                        | Security                  |
| Revocation publication and maximum staleness                    | Revocation                      | Unverifiable revocation blocks                                  | Security                  |
| Anti-rollback durable storage                                   | Verifier                        | Missing or lost state blocks                                    | Security                  |
| Rotation overlap and historical verification                    | Rotation                        | Uncertain predecessor or successor rejects                      | Owner and Security        |
| Transparency, witness, or external timestamping                 | Audit and detection             | Absence cannot be treated as assurance                          | Owner and Security        |
| Verifier implementation and dependency assurance                | Verification                    | Unverified verifier blocks                                      | Security                  |
| Audit integrity and retention                                   | Accountability                  | Required audit failure blocks commit                            | Owner and Security        |
| Backup and recovery continuity                                  | Recovery                        | Restored verifier remains disabled                              | Owner and Security        |
| Incident response and compromise scope analysis                 | Compromise                      | Potentially affected operations remain blocked                  | Owner and Security        |
| Production root and ceremony authorization                      | Production                      | Production trust root remains absent and unauthorized           | Owner                     |
| Residual-risk acceptance                                        | All anchor-dependent operations | Only explicit owner acceptance with security review may unblock | Owner                     |

## 24. Explicit non-goals

This specification does not:

- create an authority anchor, trust root, manifest, statement, signature, credential, cryptographic key, recovery share, trust store, or ceremony;
- select final algorithms, libraries, hardware, custodians, providers, deployment topology, or key custody;
- implement verification, identity, authorization, delegation, confirmation, mutation, audit, outbox, recovery, or transparency code;
- create executable tests, schemas, DDL, configuration, services, accounts, capabilities, or deployment artifacts;
- inspect or modify SQL or any migration, including Migration 009;
- modify PropertyManager or another application;
- access Development or Production runtimes, databases, services, containers, devices, or external providers;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- authorize Production genesis, activation, rotation, revocation, or recovery;
- begin implementation or the next architecture deliverable.

Implementation and operational ceremonies MUST NOT begin until applicable unresolved decisions receive owner and security approval.
