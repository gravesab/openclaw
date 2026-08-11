---
title: "Candidate-Library Evidence and Comparative-Assessment Specification v1"
summary: "Normative evidence, provenance, comparison, uncertainty, decision-separation, and fail-closed requirements for future cryptographic-library candidate assessments"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-11"
category: "Architecture"
source_document: "CANDIDATE_LIBRARY_EVIDENCE_AND_COMPARATIVE_ASSESSMENT_SPECIFICATION_V1.md"
read_when:
  - Designing or reviewing a future cryptographic-library candidate assessment
  - Collecting, normalizing, comparing, or preserving candidate evidence
  - Distinguishing assessment findings from library eligibility or approval
---

# Candidate-Library Evidence and Comparative-Assessment Specification v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-11

This specification is governed by the [Authority Anchor Implementation Assurance and Approved Cryptographic Library Profile v1](/architecture/AUTHORITY_ANCHOR_IMPLEMENTATION_ASSURANCE_AND_APPROVED_CRYPTOGRAPHIC_LIBRARY_PROFILE_V1), [Authority Anchor Cryptographic and Canonicalization Parameter Profile v1](/architecture/AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1), and [Authority Anchor Immutable Non-Secret Compatibility Vector Specification v1](/architecture/AUTHORITY_ANCHOR_IMMUTABLE_NON_SECRET_COMPATIBILITY_VECTOR_SPECIFICATION_V1). It remains subordinate to the [External Authority Anchor and Trust-Root Specification v1](/architecture/EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1), [Authority Anchor Ceremony, Custody, Rotation, and Recovery Profile v1](/architecture/AUTHORITY_ANCHOR_CEREMONY_CUSTODY_ROTATION_AND_RECOVERY_PROFILE_V1), [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1), and [Authoritative Mutation Protocol v1](/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1).

Requirements use stable **CAE** identifiers. Implementation-independent acceptance tests use **CAT** identifiers.

## 1. Governing invariant and authorization boundary

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

- **CAE-001:** This specification MUST preserve owner authority and MUST NOT allow evidence volume, comparative rank, score, certification, popularity, model output, or assessor preference to substitute for owner authorization.
- **CAE-002:** This specification defines a future assessment method only and MUST NOT authorize identifying operational candidates, evaluating a real library, downloading a package, executing software, or selecting a provider.
- **CAE-003:** This specification MUST NOT authorize installation, integration, implementation code, executable tests, keys, signatures, credentials, an authority anchor, ceremonies, Migration 009, database changes, deployment, or Production access.
- **CAE-004:** An assessment result MUST remain non-authoritative and MUST NOT create eligibility, approval, activation, or permission to process authority-anchor material.
- **CAE-005:** Missing, stale, ambiguous, conflicting, incomplete, compromised, or unverifiable evidence MUST remain explicit and MUST fail closed.
- **CAE-006:** Development analysis MUST NOT imply Development approval, Production suitability, or Production approval.

## 2. Assessment and approval separation

| Artifact                | Purpose                                                         | Authority it cannot grant                   |
| ----------------------- | --------------------------------------------------------------- | ------------------------------------------- |
| Candidate evidence case | Preserves evidence about one exact candidate unit               | Eligibility or approval                     |
| Comparative assessment  | Compares consistently scoped candidate cases                    | Selection or operational preference         |
| Review finding          | Records a bounded issue, uncertainty, or strength               | Risk acceptance                             |
| Assessment conclusion   | States what verified evidence supports                          | Owner or security approval                  |
| Approval record         | Future separately authorized decision under the library profile | Mutation authority or Production activation |

- **CAE-007:** Every assessment MUST apply the complete approval-unit identity defined by the governing library-assurance profile.
- **CAE-008:** Assessment MUST precede and remain separate from approval.
- **CAE-009:** Comparative advantage MUST NOT waive a mandatory assurance requirement.
- **CAE-010:** The least deficient candidate MUST NOT be described as acceptable when every candidate fails a gate.
- **CAE-011:** A future approval decision MUST reference a frozen assessment revision and MUST add explicit owner and security decisions.
- **CAE-012:** This specification leaves the governing approved-library registry empty.

## 3. Current candidate and assessment registry

| Registry property                | Current value |
| -------------------------------- | ------------- |
| Named candidates                 | None          |
| Candidate evidence cases         | None          |
| Comparative assessments          | None          |
| Assessment conclusions           | None          |
| Preferred candidates             | None          |
| Approved candidates              | None          |
| Operational selection authorized | No            |

- **CAE-013:** This checkpoint MUST name, rank, score, prefer, reject, or assess no real library, provider, module, package, artifact, or platform.
- **CAE-014:** An empty candidate registry MUST mean that no candidate assessment has begun.
- **CAE-015:** A library mentioned in source, dependency metadata, prior analysis, vendor material, examples, or discussion MUST NOT become a candidate automatically.
- **CAE-016:** Creating a real candidate case requires separate authorization identifying permitted scope and evidence-access boundaries.
- **CAE-017:** A candidate case MUST NOT be inferred from an upstream package or operating-system API.
- **CAE-018:** Candidate status MUST NOT alter the approved-library registry.

## 4. Assessment and candidate identity

A future assessment identity MUST contain:

| Field                     | Required meaning                                            |
| ------------------------- | ----------------------------------------------------------- |
| assessment_id             | Globally unique immutable identifier                        |
| assessment_revision       | Monotonic immutable revision                                |
| specification_version     | Exact version of this specification                         |
| assurance_profile_version | Exact governing library-profile version                     |
| candidate_set_digest      | Digest of ordered exact candidate identities                |
| scope_digest              | Digest of platforms, backends, capabilities, and exclusions |
| evidence_manifest_digest  | Digest of the frozen evidence manifest                      |
| method_digest             | Digest of gates, comparison rules, and decision rubric      |
| created_at                | Canonical UTC creation time                                 |
| assessors                 | Verified accountable assessor identities                    |
| status                    | Closed assessment-lifecycle state                           |

- **CAE-019:** Every assessment revision MUST be immutable and content-addressed.
- **CAE-020:** A correction or added evidence MUST create a new revision and MUST NOT rewrite a prior revision.
- **CAE-021:** Candidate ordering, scope, evidence, methods, exclusions, and assessor identities MUST be bound by the assessment identity.
- **CAE-022:** Two assessments with different bound inputs MUST NOT share an identity.
- **CAE-023:** Human-readable titles and mutable issue numbers MUST NOT serve as canonical identity.
- **CAE-024:** Each candidate MUST bind exact library, provider, source, release, artifact, build, dependencies, platform, backend, configuration, module boundary, and evidence.
- **CAE-025:** A family-level candidate MUST remain provisional until expanded into exact approval units.
- **CAE-026:** Unknown or unverifiable identity fields MUST make the assessment unusable for approval.

## 5. Evidence object model

Each evidence object MUST contain:

| Field           | Required meaning                                          |
| --------------- | --------------------------------------------------------- |
| evidence_id     | Stable content-derived identifier                         |
| subject         | Exact candidate unit and assessment dimension             |
| evidence_class  | Primary, independent, derived, claim, or unresolved       |
| source          | Canonical source identity and location                    |
| publisher       | Verified publishing identity when applicable              |
| collected_at    | Canonical UTC collection time                             |
| valid_at        | Time for which the evidence claims validity               |
| collector       | Accountable collector identity and method                 |
| content_digest  | Digest of exact preserved content                         |
| extraction      | Exact fact or normalized observation                      |
| transformation  | Parsing, translation, summarization, or conversion        |
| freshness       | Applicable freshness rule and expiry                      |
| confidentiality | Public, restricted, prohibited, or unknown                |
| corroboration   | Linked confirming or conflicting evidence                 |
| disposition     | Accepted fact, bounded inference, unresolved, or rejected |

- **CAE-027:** Evidence MUST preserve the distinction between source content, extracted fact, assessor inference, and conclusion.
- **CAE-028:** Every transformation MUST be reproducible and MUST NOT conceal omitted or altered context.
- **CAE-029:** A digest MUST identify preserved bytes and MUST NOT imply source authenticity by itself.
- **CAE-030:** Provenance MUST remain traversable from a comparative statement to exact source content.
- **CAE-031:** Evidence lacking a verified subject or source MUST be unresolved or rejected.
- **CAE-032:** Secrets, credentials, operational keys, signatures, recovery material, or Production data MUST NOT enter an evidence case.
- **CAE-033:** Duplicate content MUST NOT be counted as independent corroboration.
- **CAE-034:** Evidence identifiers MUST remain stable across presentations of the same preserved bytes and provenance.

## 6. Evidence-source hierarchy

| Evidence class        | Examples                                                                                 | Default treatment             |
| --------------------- | ---------------------------------------------------------------------------------------- | ----------------------------- |
| Primary authoritative | Exact source, release artifact, signed advisory, official policy, validation certificate | Verify scope and authenticity |
| Independent technical | Reputable audit, reproducible analysis, independent validation                           | Corroborating evidence        |
| Derived               | SBOM, normalized manifest, assessor extraction                                           | Trace to inputs and method    |
| Publisher claim       | Marketing, feature matrix, support statement                                             | Unverified until corroborated |
| Community report      | Issue, discussion, anecdote                                                              | Lead only                     |
| Model or tool output  | Summary, classification, generated comparison                                            | Proposal only                 |
| Unknown               | Unattributed or irreproducible material                                                  | Reject                        |

- **CAE-035:** Primary evidence SHOULD be used where available.
- **CAE-036:** Publisher claims MUST NOT establish security, conformance, maintenance, or suitability without verification.
- **CAE-037:** Independent evidence MUST identify methods, versions, limitations, and conflicts of interest.
- **CAE-038:** Model-generated or tool-generated content MUST NOT be cited as the underlying fact source.
- **CAE-039:** Search snippets, package scores, download counts, stars, or reputation rankings MUST NOT establish assurance.
- **CAE-040:** Evidence from a different version, platform, backend, build, or configuration MUST be labeled non-equivalent.
- **CAE-041:** Certification evidence MUST preserve exact algorithm, module, operational environment, status, and certificate scope.
- **CAE-042:** Archived evidence MAY establish historical facts but MUST NOT establish current status without freshness proof.

## 7. Collection authorization and containment

- **CAE-043:** Future collection MUST operate only within separately authorized sources, methods, network access, and execution boundaries.
- **CAE-044:** Documentation review MUST NOT imply permission to download packages, clone candidate repositories, run installers, compile code, or execute tests.
- **CAE-045:** Collection MUST NOT access Development or Production services, databases, containers, credentials, or operational material.
- **CAE-046:** Collection tooling MUST NOT mutate candidate sources, evidence sources, or canonical repositories.
- **CAE-047:** Network-fetched evidence MUST preserve retrieval metadata and integrity evidence when separately authorized.
- **CAE-048:** Dynamic pages, mutable registries, and mirrors MUST receive explicit volatility and authenticity treatment.
- **CAE-049:** Access failures, rate limits, authentication barriers, or unavailable evidence MUST be recorded rather than bypassed.
- **CAE-050:** A collection failure MUST NOT be converted into favorable evidence.
- **CAE-051:** Prohibited material encountered during collection MUST be excluded and escalated under applicable security policy.
- **CAE-052:** Collection-scope expansion requires new authorization before the expanded action occurs.

## 8. Integrity, freshness, and conflict handling

- **CAE-053:** The evidence manifest MUST be deterministically ordered, canonicalized, and digest-bound.
- **CAE-054:** Duplicate evidence MUST be deduplicated by content and provenance without inflating confidence.
- **CAE-055:** Freshness requirements MUST be dimension-specific and defined before conclusions.
- **CAE-056:** Evidence outside its freshness window MUST remain historical and MUST NOT support a current favorable conclusion.
- **CAE-057:** Conflicting evidence MUST link all known sides, affected claims, and reconciliation status.
- **CAE-058:** An unresolved material conflict MUST block the affected gate and conclusion.
- **CAE-059:** Source disappearance or silent replacement MUST invalidate reliance until reconciled.
- **CAE-060:** Snapshots MUST retain prior evidence after expiry, correction, or withdrawal.
- **CAE-061:** Confidence MUST reflect provenance, scope, independence, freshness, and consistency, not document count.
- **CAE-062:** Unknown evidence integrity MUST fail closed.

## 9. Candidate population and scope control

- **CAE-063:** Future authorization MUST define inclusion criteria before evidence is compared.
- **CAE-064:** Inclusion criteria MUST derive from cryptographic behavior, platform support, maintenance, supply chain, legal constraints, and assurance boundaries.
- **CAE-065:** Exclusion criteria MUST be explicit, deterministic where possible, and evidence-backed.
- **CAE-066:** Candidate additions or removals after comparison begins MUST create a new revision.
- **CAE-067:** Scope MUST distinguish verifier, signer, hash-only, canonicalization, key-management, and other capabilities.
- **CAE-068:** Scope MUST distinguish Development, Production, server, phone, tablet, desktop, watch, television, simulator, and other targets.
- **CAE-069:** Unsupported or unassessed combinations MUST remain visible and unavailable.
- **CAE-070:** A deliberately narrow comparison MUST NOT be generalized beyond its bound scope.

## 10. Mandatory assessment dimensions

| Dimension               | Minimum subject                                                                         |
| ----------------------- | --------------------------------------------------------------------------------------- |
| Exact identity          | Source, release, package, artifact, build, dependency, platform, backend, configuration |
| Cryptographic fit       | Pure Ed25519, SHA-256, strict verification, forbidden variants and fallbacks            |
| Canonical-byte boundary | Exact bytes, encoding, prehashing, normalization, truncation, framing                   |
| API safety              | Surface, algorithm selection, errors, ownership, concurrency, misuse resistance         |
| Implementation safety   | Language, unsafe code, FFI, native code, memory, integer, resource behavior             |
| Side-channel posture    | Timing and target-relevant leakage evidence                                             |
| Supply chain            | Publisher, provenance, dependencies, build, reproducibility, compromise exposure        |
| Governance              | Maintainers, ownership, disclosure, releases, support, end of life                      |
| Validation              | OpenClaw vectors, upstream tests, independent evidence, certification scope             |
| Platform fit            | Operating systems, architectures, runtimes, backends, build modes                       |
| Vulnerability history   | Current advisories, historical response, remediation, monitoring                        |
| Operations              | Pinning, integrity, startup, health, updates, suspension, revocation                    |
| Legal                   | License, notices, redistribution, patents, export, support constraints                  |
| Integration boundary    | Separation from authority, canonicalization, policy, custody, mutation logic            |

- **CAE-071:** Every candidate case MUST address every mandatory dimension.
- **CAE-072:** Not applicable MUST include verified rationale and reviewer identity.
- **CAE-073:** Missing evidence MUST be missing, never neutral or favorable.
- **CAE-074:** Evidence for one dimension MUST NOT silently satisfy another.
- **CAE-075:** Candidate self-tests MUST NOT substitute for OpenClaw-specific evidence.
- **CAE-076:** Verifier evidence MUST NOT establish signing, randomness, key-generation, custody, or ceremony behavior.
- **CAE-077:** Conclusions MUST preserve exact platform and capability boundaries.
- **CAE-078:** Undocumented or dynamically selected cryptographic behavior MUST block the affected conclusion.

## 11. Mandatory gates

| Gate                  | Passing condition                                              |
| --------------------- | -------------------------------------------------------------- |
| Identity complete     | Exact candidate unit is immutable and verifiable               |
| Scope complete        | Capabilities, platforms, backends, exclusions are bound        |
| Provenance sufficient | Source, publisher, artifact, build, dependencies are traceable |
| Cryptographic fit     | No known conflict with canonical parameters and strictness     |
| Evidence safe         | No prohibited secret or operational material                   |
| Evidence current      | Required evidence is within freshness windows                  |
| Conflicts resolved    | No material unresolved contradiction                           |
| Critical findings     | No unresolved critical or high finding                         |
| Comparison readiness  | Required dimensions use normalized definitions                 |

- **CAE-079:** Gates MUST be evaluated before weighted or ordinal comparison.
- **CAE-080:** A failed mandatory gate MUST NOT be offset by strengths elsewhere.
- **CAE-081:** Blocked, failed, passed, and not-applicable MUST remain distinct.
- **CAE-082:** Gate definitions MUST be frozen before candidate results are known.
- **CAE-083:** Gate exceptions MUST NOT exist in v1.
- **CAE-084:** A candidate that fails or blocks a gate MAY remain documented but MUST NOT receive a favorable conclusion.

## 12. Comparative-assessment method

- **CAE-085:** Comparisons MUST use the same definitions, scope, evidence cutoff, freshness rules, and gates for every candidate.
- **CAE-086:** Each comparison MUST identify dimension, evidence, scope, uncertainty, and direction of difference.
- **CAE-087:** Absolute assurance findings MUST precede relative ranking.
- **CAE-088:** Ordinal labels MUST have deterministic definitions and MUST NOT imply unmeasured precision.
- **CAE-089:** Numeric scoring MAY organize evidence but MUST NOT determine approval or compensate for gate failure.
- **CAE-090:** Weighting MUST be predefined, versioned, justified, and subjected to sensitivity analysis.
- **CAE-091:** Security-critical requirements MUST NOT be reduced to an aggregate score.
- **CAE-092:** Ties, incomparability, and insufficient evidence MUST remain valid outcomes.
- **CAE-093:** The comparison MUST disclose when evidence availability, not implementation quality, drives a difference.
- **CAE-094:** Candidate order, branding, publisher, popularity, incumbent status, and assessor familiarity MUST NOT alter criteria.
- **CAE-095:** Every comparative cell MUST link to evidence or an explicit missing-data state.
- **CAE-096:** A summary MUST preserve material weaknesses and uncertainty.

## 13. Bias, independence, and repeatability

- **CAE-097:** Assessor affiliations, contributions, financial interests, prior selections, and preferences MUST be disclosed.
- **CAE-098:** A candidate maintainer or integration author MUST NOT be the sole security reviewer.
- **CAE-099:** High-risk findings SHOULD receive independent confirmation.
- **CAE-100:** Criteria MUST NOT change in response to a favored candidate.
- **CAE-101:** Evidence extraction and risk disposition SHOULD be independently reviewed where practical.
- **CAE-102:** Reviewer disagreement MUST be recorded and MUST NOT be averaged away.
- **CAE-103:** A competent reviewer MUST be able to reproduce normalized facts from the frozen manifest.
- **CAE-104:** Non-reproducible analysis MUST be labeled and MUST NOT support a mandatory gate.

## 14. Findings, uncertainty, and confidence

Each finding MUST identify its immutable ID, exact candidate scope, dimension, bounded statement, evidence, severity, likelihood, confidence, uncertainty, disposition, reviewer, and timestamps.

- **CAE-105:** Fact, inference, risk, recommendation, and unresolved question MUST be distinguishable.
- **CAE-106:** Confidence MUST NOT exceed the weakest material provenance or scope dependency.
- **CAE-107:** Unknown likelihood or impact MUST remain unknown rather than defaulting low.
- **CAE-108:** A mitigation MUST identify an enforceable control and evidence; documentation convention alone is insufficient.
- **CAE-109:** Critical and high unresolved findings MUST block favorable assessment.
- **CAE-110:** Lower findings MUST retain explicit scope and future approval-disposition requirements.
- **CAE-111:** Absence of reported vulnerabilities MUST NOT be represented as absence of vulnerabilities.
- **CAE-112:** Conclusions MUST state residual uncertainty and evidence limits.

## 15. Assessment lifecycle

| State           | Meaning                                            | Permitted activity                |
| --------------- | -------------------------------------------------- | --------------------------------- |
| unauthorized    | No assessment authorization exists                 | None                              |
| scoped          | Criteria and boundaries are authorized             | Planning only                     |
| collecting      | Collection is active within authorization          | Collection only                   |
| frozen          | Evidence cutoff and manifest are fixed             | Review and normalization          |
| comparing       | Gate and comparative analysis is active            | Analysis only                     |
| review_required | Findings or conflicts require review               | Review only                       |
| concluded       | Non-authoritative revision is complete             | Reference only                    |
| stale           | Freshness or candidate change invalidates reliance | Historical reference              |
| withdrawn       | Material process or integrity defect exists        | Historical and incident reference |
| superseded      | A newer immutable revision exists                  | Historical reference              |

- **CAE-113:** Transitions MUST be attributable, versioned, time-stamped, and auditable.
- **CAE-114:** No assessment state in v1 grants eligibility or approval.
- **CAE-115:** Missing authorization MUST keep the lifecycle at unauthorized.
- **CAE-116:** Evidence or candidate changes after freeze MUST create a new revision or reopen assessment.
- **CAE-117:** Freshness expiry MUST move affected conclusions to stale.
- **CAE-118:** Integrity compromise MUST move affected assessment to withdrawn pending review.
- **CAE-119:** Supersession MUST preserve prior revisions and links.
- **CAE-120:** Unknown lifecycle state MUST be treated as unauthorized.

## 16. Conclusion and decision separation

- **CAE-121:** A conclusion MUST enumerate passed, failed, blocked, and not-applicable gates for every candidate.
- **CAE-122:** A conclusion MUST identify strengths, weaknesses, uncertainty, and gaps without selecting or approving a candidate.
- **CAE-123:** Approved, authorized, safe, certified for OpenClaw, Production-ready, or selected MUST NOT describe an assessment conclusion.
- **CAE-124:** A future recommendation, if separately authorized, MUST remain advisory and identify criteria and alternatives.
- **CAE-125:** Owner and security reviewers MUST make any later approval decision outside the assessment record.
- **CAE-126:** A later decision MUST NOT silently alter assessment facts, gates, weights, or findings.
- **CAE-127:** No assessment may authorize downloading, installing, integrating, testing, or deploying its subject.
- **CAE-128:** An all-candidates-unsuitable conclusion MUST remain permitted and explicit.

## 17. Audit, preservation, and disclosure

- **CAE-129:** The record MUST preserve authorization, scope, identities, evidence manifest, methods, gates, findings, comparisons, reviews, and conclusion.
- **CAE-130:** Audit records MUST be append-only and distinguish source, collection, and review times.
- **CAE-131:** Redactions MUST identify reason, scope, reviewer, and reproducibility effect.
- **CAE-132:** A public summary MUST NOT overstate conclusions omitted from restricted evidence.
- **CAE-133:** Licensing and redistribution restrictions MUST be honored without concealing material limitations.
- **CAE-134:** Assessment records MUST NOT become an authority root or approval registry.
- **CAE-135:** Preservation failure or digest mismatch MUST invalidate reliance.
- **CAE-136:** Audit availability MUST NOT reveal secrets or operational security material.

## 18. Change and reassessment triggers

- **CAE-137:** A source, release, artifact, build, dependency, platform, backend, configuration, maintainer, publisher, validation-status, or legal change MUST trigger impact review.
- **CAE-138:** A material candidate change MUST create a new candidate unit and revision.
- **CAE-139:** A vulnerability, compromise, silent artifact replacement, or disputed source MUST mark affected conclusions stale or withdrawn.
- **CAE-140:** Method, gate, weight, scope, or evidence-classification changes MUST create a new revision.
- **CAE-141:** Semantic-version labels MUST NOT determine reassessment scope.
- **CAE-142:** Emergency urgency MUST NOT permit stale assessment conclusions to act as approval.
- **CAE-143:** Reassessment MUST preserve comparison with prior conclusions and explain changed evidence.
- **CAE-144:** Unknown change impact MUST require the broader reassessment.

## 19. Failure matrix

| Condition                                  | Required treatment         |
| ------------------------------------------ | -------------------------- |
| No separate assessment authorization       | unauthorized               |
| Candidate lacks exact identity             | not a candidate case       |
| Candidate set changes after freeze         | new revision               |
| Evidence source unknown                    | reject evidence            |
| Content digest mismatch                    | withdraw affected evidence |
| Secret or operational material encountered | exclude and escalate       |
| Publisher claim uncorroborated             | unverified claim           |
| Evidence differs by version or platform    | non-equivalent             |
| Evidence freshness expired                 | stale                      |
| Material sources conflict                  | gate blocked               |
| Required dimension missing                 | missing, not neutral       |
| Mandatory gate failed or blocked           | no favorable conclusion    |
| Critical or high finding unresolved        | blocked                    |
| Aggregate score masks gate failure         | reject method              |
| Criteria changed after results             | new revision               |
| Assessor conflict undisclosed              | review invalid             |
| Analysis cannot be reproduced              | unsupported                |
| Best candidate remains inadequate          | all unsuitable             |
| Assessment described as approval           | reject statement and audit |
| Development generalized to Production      | reject and audit           |
| Assessment record unavailable              | no reliance                |
| Candidate artifact changes                 | reassess exact unit        |
| Model output used as fact                  | reject until verified      |
| Operational urgency                        | remain unauthorized        |
| Unknown condition                          | fail closed                |

## 20. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| CAT-001 | Documentation approval creates no candidate, assessment, eligibility, selection, or operational approval.                            |
| CAT-002 | No package, repository, artifact, or test software is downloaded or executed.                                                        |
| CAT-003 | The governing invariant remains true throughout future assessment.                                                                   |
| CAT-004 | Every candidate binds the complete exact approval-unit identity.                                                                     |
| CAT-005 | Assessment identity binds candidate set, scope, evidence, method, revision, and assessors.                                           |
| CAT-006 | Corrections and new evidence create immutable revisions rather than rewriting history.                                               |
| CAT-007 | Candidate inclusion and exclusion criteria are fixed before comparison.                                                              |
| CAT-008 | Family, version, build, backend, platform, capability, and environment cannot be conflated.                                          |
| CAT-009 | Evidence preserves source, extraction, transformation, inference, and conclusion separately.                                         |
| CAT-010 | Digests prove preserved bytes but cannot substitute for source authenticity.                                                         |
| CAT-011 | Secrets and operational material cannot enter an assessment case.                                                                    |
| CAT-012 | Publisher, community, popularity, and model claims cannot establish assurance facts.                                                 |
| CAT-013 | Collection cannot exceed separately authorized access or execution boundaries.                                                       |
| CAT-014 | Missing or failed collection remains an explicit gap and cannot become favorable evidence.                                           |
| CAT-015 | Manifests are deterministic, integrity-bound, freshness-aware, and conflict-preserving.                                              |
| CAT-016 | Every mandatory dimension has exact evidence or verified not-applicable rationale.                                                   |
| CAT-017 | Verifier evidence cannot establish signer, randomness, custody, or ceremony suitability.                                             |
| CAT-018 | Mandatory gates run before comparison and cannot be offset by strengths or scores.                                                   |
| CAT-019 | Failed, blocked, passed, and not-applicable gates remain distinct.                                                                   |
| CAT-020 | Every comparison uses common definitions, cutoff, scope, and rules.                                                                  |
| CAT-021 | Scores cannot hide security requirements, uncertainty, or incomparability.                                                           |
| CAT-022 | Comparative cells link to exact evidence or explicit missing-data states.                                                            |
| CAT-023 | Conflicts of interest and reviewer disagreements remain visible.                                                                     |
| CAT-024 | Findings distinguish fact, inference, risk, recommendation, confidence, and uncertainty.                                             |
| CAT-025 | Unknown impact, likelihood, or evidence quality cannot default favorable.                                                            |
| CAT-026 | No assessment lifecycle state grants eligibility or approval.                                                                        |
| CAT-027 | Stale, compromised, or superseded revisions cannot support current reliance.                                                         |
| CAT-028 | Conclusions enumerate gates and limitations without selecting or approving.                                                          |
| CAT-029 | The best-ranked inadequate candidate remains unsuitable.                                                                             |
| CAT-030 | Owner and security approval remains a separate future canonical decision.                                                            |
| CAT-031 | Audit preserves authorization, evidence, methods, findings, reviews, and history.                                                    |
| CAT-032 | Candidate, evidence, or method changes trigger bounded reassessment.                                                                 |
| CAT-033 | Development assessment cannot imply Production suitability or approval.                                                              |
| CAT-034 | Missing, ambiguous, stale, conflicting, compromised, or unverifiable evidence fails closed.                                          |
| CAT-035 | No implementation, test, key, signature, credential, anchor, ceremony, migration, database, deployment, or Production action occurs. |
| CAT-036 | The approved-library registry remains empty after this checkpoint.                                                                   |

## 21. Requirement-to-test traceability

| Requirements            | Tests                                            |
| ----------------------- | ------------------------------------------------ |
| CAE-001 through CAE-006 | CAT-001 through CAT-003, CAT-033 through CAT-036 |
| CAE-007 through CAE-012 | CAT-004, CAT-018, CAT-029, CAT-030, CAT-036      |
| CAE-013 through CAE-018 | CAT-001, CAT-036                                 |
| CAE-019 through CAE-026 | CAT-004 through CAT-006, CAT-008                 |
| CAE-027 through CAE-034 | CAT-009 through CAT-011                          |
| CAE-035 through CAE-042 | CAT-010, CAT-012                                 |
| CAE-043 through CAE-052 | CAT-002, CAT-011, CAT-013, CAT-014, CAT-035      |
| CAE-053 through CAE-062 | CAT-015, CAT-034                                 |
| CAE-063 through CAE-070 | CAT-007, CAT-008, CAT-033                        |
| CAE-071 through CAE-078 | CAT-016, CAT-017                                 |
| CAE-079 through CAE-084 | CAT-018, CAT-019, CAT-029                        |
| CAE-085 through CAE-096 | CAT-020 through CAT-022, CAT-029                 |
| CAE-097 through CAE-104 | CAT-023                                          |
| CAE-105 through CAE-112 | CAT-024, CAT-025, CAT-034                        |
| CAE-113 through CAE-120 | CAT-026, CAT-027                                 |
| CAE-121 through CAE-128 | CAT-028 through CAT-030, CAT-033                 |
| CAE-129 through CAE-136 | CAT-011, CAT-031                                 |
| CAE-137 through CAE-144 | CAT-027, CAT-032, CAT-034                        |
| CAE-001 through CAE-144 | CAT-003, CAT-035, CAT-036                        |

## 22. Governing-document traceability

| Governing document                                         | Bound requirements                               | Existing tests          |
| ---------------------------------------------------------- | ------------------------------------------------ | ----------------------- |
| Library Assurance Profile LAP-001 through LAP-156          | CAE-001 through CAE-144                          | LAT-001 through LAT-035 |
| Cryptographic Parameter Profile ACP-001 through ACP-128    | CAE-063 through CAE-112                          | ACT-001 through ACT-032 |
| Compatibility Vector Specification IVS-001 through IVS-092 | CAE-027 through CAE-112                          | IVT-001 through IVT-026 |
| External Authority Anchor EAA-001 through EAA-114          | CAE-001 through CAE-144                          | EAT-001 through EAT-040 |
| Ceremony and Custody Profile CCR-001 through CCR-130       | CAE-001 through CAE-018, CAE-105 through CAE-144 | CCT-001 through CCT-040 |
| Identity and Delegation Policy IDP-001 through IDP-082     | CAE-001 through CAE-018, CAE-097 through CAE-144 | IDT-001 through IDT-038 |
| Authoritative Mutation Protocol AMP-001 through AMP-090    | CAE-001 through CAE-012, CAE-121 through CAE-144 | APT-001 through APT-040 |

## 23. Unresolved decisions

| Decision                                   | Interim fail-closed treatment       | Required review                   |
| ------------------------------------------ | ----------------------------------- | --------------------------------- |
| Candidate inclusion and exclusion criteria | No candidate set                    | Owner and Security                |
| Exact separately authorized candidate set  | Registry remains empty              | Owner and Security                |
| Permitted sources and network access       | No external collection              | Owner and Security                |
| Permitted package or source retrieval      | Prohibited                          | Owner and Security                |
| Permitted executable methods               | No execution                        | Owner and Security                |
| Evidence schema and durable storage        | No canonical evidence case          | Architecture and Security         |
| Canonicalization and digest profile        | No assessment identity valid        | Architecture and Security         |
| Freshness periods by dimension             | Favorable conclusions unavailable   | Security                          |
| Gates and severity definitions             | No comparative conclusion           | Owner and Security                |
| Scoring or ordinal method                  | No aggregate rank                   | Owner and Security                |
| Weighting and sensitivity rules            | No weighted result                  | Owner and Security                |
| Required independent assessment            | High-risk findings blocked          | Owner and Security                |
| Conflict-of-interest policy                | Conflicted review cannot conclude   | Owner and Security                |
| Side-channel evidence threshold            | Sensitive capabilities unsupported  | Security                          |
| Certification requirements                 | No regulatory conclusion            | Owner and Security                |
| Legal and licensing process                | Candidate cannot advance            | Owner                             |
| Restricted evidence disclosure             | No reliance on undisclosed evidence | Owner and Security                |
| Assessment expiry and cadence              | Conclusions immediately non-current | Owner and Security                |
| Future approval-registry relationship      | No eligibility created              | Architecture, Owner, and Security |
| Production assessment policy               | Production out of scope             | Owner                             |

## 24. Explicit non-goals and future deliverables

This specification does not:

- name, enumerate, evaluate, compare, score, rank, prefer, reject, select, approve, install, integrate, or operate any real cryptographic library, provider, module, package, artifact, build, backend, platform, or configuration;
- download, clone, fetch, install, build, import, execute, fuzz, benchmark, validate, or test candidate software;
- write implementation code, configuration, executable tests, assessment tooling, adapters, or runtime enforcement;
- create an assessment record, evidence case, candidate registry, approval record, or operational registry entry;
- generate, import, export, store, use, rotate, revoke, recover, or destroy keys, signatures, secrets, credentials, nonces, or recovery material;
- create, activate, modify, or claim the existence of an authority anchor;
- conduct, rehearse, schedule, or authorize a ceremony;
- inspect, create, restore, rename, or modify Migration 009 or any database migration;
- access Development or Production runtimes, databases, SQL, containers, services, devices, credentials, or operational systems;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- grant authority to any person, service, model, client, tool, automation, assessor, library, or provider.

Future work requires separate authorization and may include:

- a candidate-set scope and evidence-access authorization;
- a non-executing evidence-collection plan;
- an evidence-record canonicalization and integrity profile;
- a separately authorized comparative assessment of exact candidate units;
- an executable validation plan using non-operational material;
- an owner and security review of a frozen assessment;
- a Development-only approval checkpoint for one exact unit, only if supported and separately authorized.

No candidate evaluation, selection, approval, retrieval, installation, integration, execution, implementation, executable testing, key or signature operation, anchor activation, ceremony, migration, deployment, or Production work MAY begin from this specification alone.
