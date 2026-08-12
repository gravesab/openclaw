---
title: "Candidate Assessment Evidence Record Canonicalization and Integrity Profile v1"
summary: "Normative schema, canonicalization, content identity, provenance, manifest, verification, redaction, and fail-closed integrity requirements for candidate-assessment evidence records"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-11"
category: "Architecture"
source_document: "CANDIDATE_ASSESSMENT_EVIDENCE_RECORD_CANONICALIZATION_AND_INTEGRITY_PROFILE_V1.md"
read_when:
  - Designing or reviewing a future candidate-assessment evidence record
  - Canonicalizing, hashing, preserving, redacting, or verifying assessment evidence
  - Building a future evidence manifest, integrity receipt, or assessment revision
---

# Candidate Assessment Evidence Record Canonicalization and Integrity Profile v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-11

This profile specializes the [Candidate-Library Evidence and Comparative-Assessment Specification v1](/architecture/CANDIDATE_LIBRARY_EVIDENCE_AND_COMPARATIVE_ASSESSMENT_SPECIFICATION_V1). Its canonical encoding and digest rules inherit from the [Authority Anchor Cryptographic and Canonicalization Parameter Profile v1](/architecture/AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1) and are checked conceptually against the [Authority Anchor Immutable Non-Secret Compatibility Vector Specification v1](/architecture/AUTHORITY_ANCHOR_IMMUTABLE_NON_SECRET_COMPATIBILITY_VECTOR_SPECIFICATION_V1). It remains governed by the [Authority Anchor Implementation Assurance and Approved Cryptographic Library Profile v1](/architecture/AUTHORITY_ANCHOR_IMPLEMENTATION_ASSURANCE_AND_APPROVED_CRYPTOGRAPHIC_LIBRARY_PROFILE_V1), [External Authority Anchor and Trust-Root Specification v1](/architecture/EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1), and [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1).

Requirements use stable **ERI** identifiers. Implementation-independent acceptance tests use **ERT** identifiers.

## 1. Governing invariant and authorization boundary

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

- **ERI-001:** This profile MUST preserve owner authority and MUST NOT allow a record, digest, manifest, integrity check, model output, or tool result to substitute for owner authorization.
- **ERI-002:** This profile defines a future record format only and MUST NOT create, collect, import, sign, verify operationally, or approve an evidence record.
- **ERI-003:** This profile MUST NOT authorize evaluating a library, downloading or executing software, implementation code, executable tests, keys, signatures, credentials, an authority anchor, ceremonies, Migration 009, database changes, deployment, or Production access.
- **ERI-004:** Record integrity MUST establish only that defined bytes and metadata remain consistent; it MUST NOT establish source truth, candidate suitability, eligibility, or approval.
- **ERI-005:** Missing, malformed, non-canonical, ambiguous, conflicting, stale, compromised, or unverifiable record evidence MUST fail closed.
- **ERI-006:** Development records MUST NOT imply Development approval or Production suitability.

## 2. Record authority and current status

| Property                               | Current value                                    |
| -------------------------------------- | ------------------------------------------------ |
| Canonical profile identifier           | openclaw.candidate-assessment-evidence-record.v1 |
| Schema identifier                      | candidate_assessment_evidence_record             |
| Schema version                         | 1                                                |
| Records created by this profile        | None                                             |
| Manifests created by this profile      | None                                             |
| Approved evidence stores               | None                                             |
| Approved canonicalizer implementations | None                                             |
| Operational use authorized             | No                                               |

- **ERI-007:** This documentation checkpoint MUST create no evidence record, manifest, receipt, signature, or approval entry.
- **ERI-008:** The profile identifier and schema identifier MUST be compared by exact case-sensitive ASCII byte equality.
- **ERI-009:** Unknown profile or schema identifiers MUST reject without fallback.
- **ERI-010:** Version 1 MUST NOT accept extensions, alternate property names, compatibility aliases, or vendor fields.
- **ERI-011:** A syntactically valid record MUST remain non-authoritative until provenance, freshness, assessment scope, and review are separately established.
- **ERI-012:** No record state in this profile grants candidate or library eligibility.

## 3. Top-level record schema

A v1 record contains exactly:

| Property       | Type   | Meaning                                    |
| -------------- | ------ | ------------------------------------------ |
| profile        | string | Exact profile identifier                   |
| schema         | string | Exact schema identifier                    |
| schema_version | string | Exact canonical decimal version            |
| record_id      | string | Content identifier derived under section 7 |
| body           | object | Canonical evidence-record body             |

The body contains exactly:

| Property            | Type           | Meaning                                           |
| ------------------- | -------------- | ------------------------------------------------- |
| assessment_id       | string         | Bound assessment identity                         |
| assessment_revision | string         | Canonical decimal revision                        |
| evidence_id         | string         | Stable evidence identity within the assessment    |
| subject             | object         | Exact candidate unit and dimension                |
| evidence_class      | string         | Controlled provenance class                       |
| source              | object         | Source identity and source-content commitment     |
| publisher           | object or null | Verified publisher claim and identity             |
| collected_at        | string         | Canonical collection timestamp                    |
| valid_at            | string or null | Time represented by source evidence               |
| collector           | object         | Accountable collector and collection method       |
| extraction          | object         | Exact extracted fact and source location          |
| transformation      | array          | Ordered transformations from source to extraction |
| freshness           | object         | Rule, evaluated time, expiry, and status          |
| confidentiality     | string         | Controlled disclosure class                       |
| corroboration       | array          | Canonically ordered evidence references           |
| conflicts           | array          | Canonically ordered conflicting references        |
| disposition         | string         | Evidence treatment, not approval                  |
| notes               | string or null | Bounded non-normative context                     |

- **ERI-013:** Top-level and body schemas MUST contain exactly the enumerated properties.
- **ERI-014:** Every property is required; nullable properties MUST be present with null when no value exists.
- **ERI-015:** Unknown, missing, or duplicate properties MUST reject before ordinary object construction.
- **ERI-016:** Null MUST NOT substitute for an empty string, empty object, empty array, zero, unknown, or not-applicable.
- **ERI-017:** Schema version MUST be the string **1**.
- **ERI-018:** The body MUST bind one evidence item to one assessment revision and one exact subject.
- **ERI-019:** Display labels, filenames, paths, database keys, and UI identifiers MUST NOT replace canonical identities.
- **ERI-020:** A record with an unresolved required identity MUST reject rather than use a placeholder.

## 4. Nested object requirements

| Object               | Required properties                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| subject              | candidate_unit_id, capability, dimension, environment, platform_scope                                    |
| source               | source_kind, source_locator, source_version, source_content_digest, source_media_type, source_size_bytes |
| publisher            | publisher_id, claim_type, verification_state                                                             |
| collector            | collector_id, method, authorization_id                                                                   |
| extraction           | exact_text, source_locator_fragment, language, interpretation                                            |
| transformation entry | sequence, kind, tool, tool_version, input_digest, output_digest, description                             |
| freshness            | rule_id, evaluated_at, expires_at, status                                                                |
| evidence reference   | evidence_id, record_id, relationship                                                                     |

- **ERI-021:** Every nested object MUST use exactly its enumerated properties.
- **ERI-022:** Candidate unit identity MUST reference the complete exact approval-unit identity or a clearly non-eligible provisional family identity.
- **ERI-023:** Source locator MUST be preserved as an exact NFC string and MUST NOT be silently normalized, redirected, shortened, or rewritten.
- **ERI-024:** Source-content digest MUST bind the exact source bytes collected, not rendered or normalized content unless that content is separately recorded.
- **ERI-025:** Source size MUST describe those exact source bytes as a canonical decimal string.
- **ERI-026:** Extraction location MUST be stable within the committed source representation or explicitly unresolved.
- **ERI-027:** Interpretation MUST remain distinguishable from exact extracted text.
- **ERI-028:** Every transformation MUST bind exact input and output digests.
- **ERI-029:** Publisher null MUST mean that no verified publisher object is represented, not that publisher evidence is unnecessary.
- **ERI-030:** Collector identity MUST be accountable but MUST NOT itself grant evidence truth or approval.

## 5. Restricted JSON data model

- **ERI-031:** Canonical records MUST use RFC 8785 JCS with all additional restrictions in this profile and the governing cryptographic profile.
- **ERI-032:** Input MUST be valid UTF-8 without BOM.
- **ERI-033:** Objects, arrays, strings, booleans, and null are permitted; JSON number tokens MUST NOT appear.
- **ERI-034:** Integers, sizes, sequence values, and versions MUST use unsigned canonical decimal strings matching **0** or a nonzero digit followed by digits.
- **ERI-035:** Strings MUST be valid Unicode scalar sequences in NFC before canonicalization.
- **ERI-036:** Canonicalization MUST NOT trim, case-fold, normalize, translate, rewrap, or convert newlines.
- **ERI-037:** Unpaired surrogates, disallowed control characters, invalid UTF-8, and non-NFC strings MUST reject.
- **ERI-038:** Duplicate property names MUST reject before a parser can discard a duplicate.
- **ERI-039:** Unknown properties MUST reject even when their values appear harmless.
- **ERI-040:** A JSON parser configuration that cannot prove these restrictions MUST NOT process a record.

## 6. Canonical serialization procedure

A future conforming canonicalizer MUST perform these ordered stages:

1. Bound raw byte length before parsing.
2. Validate UTF-8 and reject BOM.
3. Parse while preserving and rejecting duplicate property names.
4. Validate exact schemas, types, nullability, enums, scalar syntax, and bounds.
5. Validate NFC without changing code points.
6. Validate array order and uniqueness.
7. Recompute all nested digest relationships.
8. Serialize through RFC 8785 JCS.
9. Encode the JCS result as UTF-8 without BOM.
10. Reparse and reserialize to prove byte stability.
11. Compute the record identity under section 7.
12. Compare claimed and recomputed identity with constant-time comparison where applicable.

- **ERI-041:** Stages MUST occur in the specified order and MUST fail closed on the first unresolvable condition.
- **ERI-042:** Validation MUST occur before hashing is reported successful.
- **ERI-043:** Canonicalization MUST operate on the validated data model, never an implementation-specific object with hidden defaults.
- **ERI-044:** A non-canonical but semantically similar representation MUST reject rather than be silently rewritten as accepted input.
- **ERI-045:** Canonical bytes MUST be stable across conforming platforms and implementations.
- **ERI-046:** Reparse and reserialize mismatch MUST reject.
- **ERI-047:** Display JSON MUST remain derived and MUST NOT be used as canonical identity.
- **ERI-048:** Parser warnings, replacement characters, duplicate-key recovery, and partial parsing MUST reject.
- **ERI-049:** Canonicalization errors MUST produce stable reason classes without echoing prohibited content.
- **ERI-050:** No canonicalizer implementation is selected or approved by this profile.

## 7. Record identity and domain-separated hashing

The exact record-identity domain tag is the ASCII octets:

`openclaw.candidate-assessment-evidence-record.v1`

The record identity input is:

1. the domain-tag octets;
2. one zero octet;
3. an unsigned 64-bit big-endian length of canonical body bytes;
4. the canonical body bytes.

`record_id` is **sha256:** followed by 64 lowercase hexadecimal digits representing SHA-256 of that input.

- **ERI-051:** The record body used for identity MUST exclude the top-level record_id to avoid circular identity.
- **ERI-052:** The body MUST include assessment, subject, source, provenance, transformation, freshness, confidentiality, reference, and disposition fields.
- **ERI-053:** Domain tag, separator, length width, byte order, and component order MUST be exact.
- **ERI-054:** Concatenation without domain and length framing MUST NOT be used.
- **ERI-055:** SHA-1, MD5, truncated SHA-256, platform hashes, and alternate digest encodings MUST reject.
- **ERI-056:** Claimed record_id MUST exactly match independent recomputation.
- **ERI-057:** Digest equality MUST NOT substitute for source authenticity, authorization, freshness, assessment gates, or approval.
- **ERI-058:** A collision or credible collision concern MUST make affected records unavailable and trigger security review.
- **ERI-059:** A record_id MUST never be reassigned to different canonical body bytes.
- **ERI-060:** Copying a record body between assessments or revisions MUST change identity when its bound context changes.

## 8. Source-byte commitment and provenance

- **ERI-061:** Source-content digest MUST use **sha256:** plus SHA-256 of the exact collected source bytes.
- **ERI-062:** Source media type MUST describe the committed bytes and MUST NOT be inferred solely from a filename.
- **ERI-063:** Redirect history, retrieval time, retrieval method, and authenticated source identity MUST be preserved in separately governed collection evidence.
- **ERI-064:** A digest supplied by a publisher or model MUST remain a claim until independently recomputed.
- **ERI-065:** Rendered HTML, extracted text, archive members, source archives, release artifacts, and package artifacts MUST have separate byte commitments.
- **ERI-066:** Decompression, decoding, newline conversion, character conversion, or document rendering MUST be recorded as transformations.
- **ERI-067:** A source that cannot be preserved lawfully MUST retain verifiable metadata and an explicit reproducibility limitation.
- **ERI-068:** Source disappearance or replacement MUST NOT alter the preserved record and MUST trigger freshness or conflict review.
- **ERI-069:** A mutable locator MUST NOT be treated as immutable identity.
- **ERI-070:** Provenance gaps MUST remain explicit and MUST NOT be filled by assumption.

## 9. Timestamps and freshness

- **ERI-071:** Timestamps MUST use exactly UTC RFC 3339 second precision in **YYYY-MM-DDTHH:MM:SSZ** form.
- **ERI-072:** Offsets, fractional seconds, lowercase t or z, leap seconds, and invalid calendar dates MUST reject.
- **ERI-073:** Collected_at records collection time; valid_at records represented source time or null; the two MUST NOT be conflated.
- **ERI-074:** Freshness evaluated_at and expires_at MUST bind the exact rule_id used.
- **ERI-075:** Freshness status MUST be one of **current**, **stale**, **unknown**, or **not-applicable**.
- **ERI-076:** Unknown or stale freshness MUST NOT support a favorable assessment gate.
- **ERI-077:** Clock confidence and trusted-time policy remain separately governed and MUST NOT be inferred from timestamp syntax.
- **ERI-078:** Re-evaluating freshness MUST create a new record or assessment revision rather than mutate historical bytes.

## 10. Enums, identifiers, and text

- **ERI-079:** Field names, profile values, schema values, enum values, and reason codes MUST use case-sensitive ASCII.
- **ERI-080:** Controlled enum values MUST use lowercase ASCII with hyphen separators unless explicitly specified otherwise.
- **ERI-081:** Evidence class MUST be one of **primary-authoritative**, **independent-technical**, **derived**, **publisher-claim**, **community-report**, **model-or-tool-output**, or **unknown**.
- **ERI-082:** Confidentiality MUST be one of **public**, **restricted**, **prohibited**, or **unknown**.
- **ERI-083:** Disposition MUST be one of **accepted-fact**, **bounded-inference**, **unresolved**, or **rejected**.
- **ERI-084:** Friendly aliases MUST NOT replace assessment_id, candidate_unit_id, evidence_id, record_id, or content digests.
- **ERI-085:** Exact extracted text MUST preserve source characters and MUST NOT be translated or summarized in place.
- **ERI-086:** Interpretation, translation, or summary MUST be a transformation output with separate digest and description.

## 11. Arrays, ordering, and references

- **ERI-087:** Transformation entries MUST be ordered by numeric sequence after canonical decimal validation.
- **ERI-088:** Transformation sequence MUST start at **0**, be contiguous, and contain no duplicate.
- **ERI-089:** Each transformation input_digest MUST equal the preceding source or transformation output digest.
- **ERI-090:** Corroboration and conflict references MUST be sorted by evidence_id UTF-8 bytes, then record_id UTF-8 bytes.
- **ERI-091:** Duplicate evidence_id and record_id pairs MUST reject within each reference array.
- **ERI-092:** The same reference MUST NOT appear as both corroboration and conflict without an explicit new record resolving the classification.
- **ERI-093:** Reference cycles MUST be detected and MUST NOT establish self-corroboration.
- **ERI-094:** Missing referenced records MUST make the relationship unresolved, not favorable.

## 12. Confidentiality and redaction

- **ERI-095:** Prohibited or unknown confidentiality MUST reject from an ordinary assessment evidence set.
- **ERI-096:** Restricted records require separately approved access control and MUST NOT be exposed through public summaries.
- **ERI-097:** Redaction MUST create a derivative record with a new record_id and an explicit transformation.
- **ERI-098:** Redaction MUST NOT overwrite or reuse the original record identity.
- **ERI-099:** A redacted record MUST state what class of content was removed and how removal affects reproducibility.
- **ERI-100:** Secret values, operational signatures, credentials, keys, recovery material, and Production data MUST never be embedded, even in restricted records.
- **ERI-101:** Hashing prohibited material MUST NOT make its collection or retention acceptable.
- **ERI-102:** Suspected secret-bearing evidence MUST be excluded and handled under separately authorized security policy.

## 13. Evidence manifests

A future manifest body contains exact profile, schema, version, assessment_id, assessment_revision, ordered record_ids, record_count, created_at, and predecessor_manifest_id or null.

- **ERI-103:** Record_ids MUST be sorted by lowercase hexadecimal digest bytes and MUST be unique.
- **ERI-104:** Record_count MUST be a canonical decimal string equal to the number of record_ids.
- **ERI-105:** Manifest identity MUST use a distinct domain tag **openclaw.candidate-assessment-evidence-manifest.v1**, zero separator, 64-bit big-endian length, canonical manifest-body bytes, and SHA-256.
- **ERI-106:** A manifest MUST bind one exact assessment revision.
- **ERI-107:** Adding, removing, replacing, or reordering a record MUST change or invalidate the manifest.
- **ERI-108:** Predecessor links MUST be explicit and MUST NOT permit rollback or history rewriting.
- **ERI-109:** A manifest digest MUST NOT act as a signature, approval, or trust root.
- **ERI-110:** Missing records, count mismatch, duplicate IDs, broken predecessor, or digest mismatch MUST reject the manifest.
- **ERI-111:** Empty manifests MAY represent an authorized empty snapshot but MUST NOT imply complete evidence.
- **ERI-112:** This profile creates no manifest and approves no manifest implementation.

## 14. Verification pipeline

A future verifier MUST:

1. establish permitted profile and schema;
2. enforce byte, depth, string, array, and object limits;
3. validate restricted JSON and exact schema;
4. validate scalar syntax, enums, timestamps, and nullability;
5. validate transformations, references, and ordering;
6. canonicalize and prove byte stability;
7. recompute source, transformation, record, and manifest digests;
8. validate assessment and revision context;
9. evaluate confidentiality, freshness, provenance, conflicts, and referenced-record availability;
10. emit a deterministic decision, reason class, and audit evidence.

- **ERI-113:** Cryptographic success MUST NOT be reported before structural and contextual validation succeeds.
- **ERI-114:** Verification MUST NOT fetch missing content or records implicitly.
- **ERI-115:** Verification MUST NOT repair, coerce, normalize, default, or upgrade input.
- **ERI-116:** All digest relationships MUST be independently recomputed from exact bytes.
- **ERI-117:** Unknown reason, state, enum, profile, schema, or version MUST fail closed.
- **ERI-118:** Partial success MUST NOT be represented as record acceptance.
- **ERI-119:** Verification result MUST identify record_id, profile, schema, version, decision, reason class, verifier identity, and verification time.
- **ERI-120:** Verification evidence MUST NOT expose source content beyond its confidentiality policy.
- **ERI-121:** Different conforming verifiers MUST produce identical canonical bytes, digests, decisions, and reason classes.
- **ERI-122:** No verifier is implemented, executed, selected, or approved by this profile.

## 15. Revision, correction, and lifecycle

- **ERI-123:** Evidence record bytes are immutable after identity assignment.
- **ERI-124:** Correction, added provenance, changed interpretation, refreshed status, or changed disposition MUST create a new record.
- **ERI-125:** Replacement records MUST reference the superseded evidence_id and preserve historical records.
- **ERI-126:** Record lifecycle MUST distinguish **current**, **stale**, **superseded**, **withdrawn**, and **rejected** outside the immutable record body.
- **ERI-127:** Lifecycle metadata MUST be append-only, attributable, and separately integrity-bound.
- **ERI-128:** A withdrawn or rejected record MUST remain available for audit where lawful but MUST NOT support favorable conclusions.
- **ERI-129:** Rollback or restore MUST NOT reactivate stale, superseded, withdrawn, or rejected evidence.
- **ERI-130:** Unknown lifecycle state MUST be treated as unavailable.

## 16. Storage, transport, and recovery boundaries

- **ERI-131:** Storage location, database key, object key, URL, filename, and transport envelope MUST NOT define canonical record identity.
- **ERI-132:** Transport MUST preserve canonical bytes exactly or carry a separately verified encoding.
- **ERI-133:** Compression and encryption are storage or transport layers and MUST NOT alter canonical identity.
- **ERI-134:** Replicas MUST verify record and manifest identities before being treated as equivalent.
- **ERI-135:** Backup and restore MUST preserve canonical bytes, manifests, lifecycle evidence, and predecessor relationships.
- **ERI-136:** Missing storage, corrupt replica, or incomplete restore MUST make affected evidence unavailable.
- **ERI-137:** Storage authenticity, access control, retention, and deletion require separate design and authorization.
- **ERI-138:** No database or storage system is selected, accessed, or modified by this profile.

## 17. Resource and denial-of-service limits

- **ERI-139:** Implementations MUST bound input bytes, nesting depth, properties, arrays, strings, transformations, and references before expensive work.
- **ERI-140:** Exact numeric limits MUST be owner- and security-approved before implementation.
- **ERI-141:** Until exact limits are approved, no operational parser or verifier is eligible.
- **ERI-142:** Claimed size values MUST be checked against actual byte lengths using overflow-safe arithmetic.
- **ERI-143:** Digest computation MUST be streaming where needed without changing defined input bytes.
- **ERI-144:** Excessive, recursive, cyclic, or adversarial records MUST reject deterministically.
- **ERI-145:** Failure diagnostics MUST be bounded and MUST NOT echo untrusted or prohibited content.
- **ERI-146:** Resource exhaustion MUST fail unavailable and MUST NOT bypass validation.

## 18. Failure matrix

| Condition                                 | Required result               |
| ----------------------------------------- | ----------------------------- |
| Unknown profile, schema, or version       | Reject                        |
| Missing, unknown, or duplicate property   | Reject                        |
| JSON number token                         | Reject                        |
| Invalid UTF-8, BOM, non-NFC, or surrogate | Reject                        |
| Non-canonical representation              | Reject                        |
| Record ID mismatch                        | Reject                        |
| Source or transformation digest mismatch  | Reject                        |
| Source authenticity unproven              | Unresolved                    |
| Publisher digest not recomputed           | Claim only                    |
| Invalid timestamp or decimal string       | Reject                        |
| Transformation sequence gap               | Reject                        |
| Transformation chain mismatch             | Reject                        |
| Duplicate or cyclic reference             | Reject                        |
| Missing referenced record                 | Unresolved                    |
| Stale or unknown freshness                | Cannot support favorable gate |
| Prohibited or unknown confidentiality     | Exclude and escalate          |
| Secret-bearing content                    | Exclude and escalate          |
| Redaction reuses identity                 | Reject                        |
| Manifest count, order, or digest mismatch | Reject manifest               |
| Broken predecessor                        | Reject manifest               |
| Unknown lifecycle                         | Unavailable                   |
| Restore incomplete                        | Unavailable                   |
| Limit exceeded                            | Reject                        |
| Verification disagreement                 | Fail closed                   |
| Operational urgency                       | Remain unauthorized           |
| Unknown condition                         | Fail closed                   |

## 19. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                               |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| ERT-001 | Documentation creates no record, manifest, implementation, candidate, assessment, or approval.                                               |
| ERT-002 | The governing invariant remains true and digest equality cannot grant authority.                                                             |
| ERT-003 | Exact profile, schema, version, and property sets reject unknown or missing values.                                                          |
| ERT-004 | Duplicate properties reject before ordinary object construction.                                                                             |
| ERT-005 | JSON numbers, invalid UTF-8, BOM, non-NFC strings, and invalid Unicode reject.                                                               |
| ERT-006 | Semantically similar but non-canonical JSON rejects.                                                                                         |
| ERT-007 | Canonical bytes are identical across conforming implementations.                                                                             |
| ERT-008 | Record identity uses the exact domain, separator, length, body bytes, and SHA-256 encoding.                                                  |
| ERT-009 | Changing any bound body field changes record identity.                                                                                       |
| ERT-010 | Record identity cannot substitute for authenticity, freshness, assessment, or approval.                                                      |
| ERT-011 | Exact source bytes, media type, and size remain bound without hidden normalization.                                                          |
| ERT-012 | Every transformation forms an unbroken digest chain.                                                                                         |
| ERT-013 | Collected, represented, evaluated, and expiry times cannot be conflated.                                                                     |
| ERT-014 | Unknown or stale freshness cannot support a favorable gate.                                                                                  |
| ERT-015 | Controlled enums and canonical identifiers reject aliases and case changes.                                                                  |
| ERT-016 | Exact extracted text remains separate from interpretation, translation, and summary.                                                         |
| ERT-017 | Arrays obey exact sequence, ordering, uniqueness, and cycle rules.                                                                           |
| ERT-018 | Missing references remain unresolved and cannot become corroboration.                                                                        |
| ERT-019 | Prohibited content and secrets cannot be legitimized by hashing or restricted storage.                                                       |
| ERT-020 | Redaction creates a derivative identity and preserves the original audit relationship.                                                       |
| ERT-021 | Manifest identity binds an exact ordered unique record set and revision.                                                                     |
| ERT-022 | Record, count, predecessor, order, or digest mismatch rejects a manifest.                                                                    |
| ERT-023 | Verification performs structural and contextual checks before reporting digest success.                                                      |
| ERT-024 | Verification never repairs, defaults, upgrades, or implicitly fetches input.                                                                 |
| ERT-025 | Verifiers agree on canonical bytes, digests, decisions, and reason classes.                                                                  |
| ERT-026 | Corrections and freshness changes create new records rather than rewriting bytes.                                                            |
| ERT-027 | Restore or rollback cannot reactivate unavailable evidence.                                                                                  |
| ERT-028 | Storage, filenames, URLs, compression, encryption, and transport cannot change identity.                                                     |
| ERT-029 | Resource limits are proven before any operational implementation becomes eligible.                                                           |
| ERT-030 | Limit failures remain bounded and cannot bypass validation.                                                                                  |
| ERT-031 | Development evidence cannot imply Development approval or Production suitability.                                                            |
| ERT-032 | No software download, execution, key, signature, credential, anchor, ceremony, migration, database, deployment, or Production action occurs. |

## 20. Requirement-to-test traceability

| Requirements            | Tests                                     |
| ----------------------- | ----------------------------------------- |
| ERI-001 through ERI-006 | ERT-001, ERT-002, ERT-031, ERT-032        |
| ERI-007 through ERI-012 | ERT-001 through ERT-003                   |
| ERI-013 through ERI-030 | ERT-003, ERT-009 through ERT-012          |
| ERI-031 through ERI-040 | ERT-004 through ERT-007                   |
| ERI-041 through ERI-050 | ERT-006, ERT-007, ERT-023 through ERT-025 |
| ERI-051 through ERI-060 | ERT-008 through ERT-010                   |
| ERI-061 through ERI-070 | ERT-010 through ERT-012                   |
| ERI-071 through ERI-078 | ERT-013, ERT-014, ERT-026                 |
| ERI-079 through ERI-086 | ERT-015, ERT-016                          |
| ERI-087 through ERI-094 | ERT-012, ERT-017, ERT-018                 |
| ERI-095 through ERI-102 | ERT-019, ERT-020, ERT-032                 |
| ERI-103 through ERI-112 | ERT-021, ERT-022                          |
| ERI-113 through ERI-122 | ERT-023 through ERT-025                   |
| ERI-123 through ERI-130 | ERT-026, ERT-027                          |
| ERI-131 through ERI-138 | ERT-027, ERT-028, ERT-032                 |
| ERI-139 through ERI-146 | ERT-029, ERT-030                          |
| ERI-001 through ERI-146 | ERT-002, ERT-031, ERT-032                 |

## 21. Governing-document traceability

| Governing document                                         | Bound requirements                               | Existing tests          |
| ---------------------------------------------------------- | ------------------------------------------------ | ----------------------- |
| Candidate Assessment Specification CAE-001 through CAE-144 | ERI-001 through ERI-146                          | CAT-001 through CAT-036 |
| Cryptographic Parameter Profile ACP-001 through ACP-128    | ERI-001 through ERI-146                          | ACT-001 through ACT-032 |
| Compatibility Vector Specification IVS-001 through IVS-092 | ERI-031 through ERI-122                          | IVT-001 through IVT-026 |
| Library Assurance Profile LAP-001 through LAP-156          | ERI-001 through ERI-012, ERI-113 through ERI-146 | LAT-001 through LAT-035 |
| External Authority Anchor EAA-001 through EAA-114          | ERI-001 through ERI-012, ERI-123 through ERI-146 | EAT-001 through EAT-040 |
| Identity and Delegation Policy IDP-001 through IDP-082     | ERI-001 through ERI-030, ERI-113 through ERI-146 | IDT-001 through IDT-038 |

## 22. Unresolved decisions

| Decision                                | Interim fail-closed treatment               | Required review           |
| --------------------------------------- | ------------------------------------------- | ------------------------- |
| Evidence schema publication format      | Human-readable profile only                 | Architecture and Security |
| Exact parser and canonicalizer          | No implementation eligible                  | Security                  |
| Exact resource limits                   | No operational parser eligible              | Owner and Security        |
| Unicode version and NFC implementation  | String verification unavailable             | Architecture and Security |
| Collector identity scheme               | No accountable record accepted              | Owner and Security        |
| Assessment and evidence ID syntax       | No operational record accepted              | Architecture              |
| Candidate-unit identity schema          | Candidate binding unresolved                | Architecture and Security |
| Source-locator kinds and validation     | Locator authenticity unresolved             | Security                  |
| Media-type registry and sniffing policy | Source type unresolved                      | Security                  |
| Transformation kind registry            | Unknown transformations reject              | Architecture and Security |
| Evidence and lifecycle storage          | No canonical store                          | Architecture and Security |
| Restricted-record access controls       | Restricted records unavailable              | Owner and Security        |
| Retention, deletion, and legal hold     | No destructive lifecycle action             | Owner and Security        |
| Manifest signing or external anchoring  | Digests remain non-authoritative            | Owner and Security        |
| Exact verification reason-code registry | Unknown reason fails closed                 | Architecture and Security |
| Compatibility vector corpus             | No implementation conformance claim         | Architecture and Security |
| Backup and recovery design              | Records unavailable after uncertain restore | Owner and Security        |
| Evidence freshness rule registry        | Favorable use unavailable                   | Owner and Security        |
| Production policy                       | Production remains unauthorized             | Owner                     |

## 23. Explicit non-goals and future deliverables

This profile does not:

- create, collect, import, export, canonicalize operationally, hash operationally, sign, verify, store, transmit, redact, or delete an evidence record or manifest;
- name, evaluate, compare, rank, select, approve, install, integrate, or operate a cryptographic library;
- download, clone, fetch, install, build, import, execute, fuzz, benchmark, validate, or test software;
- implement a schema, parser, canonicalizer, hasher, manifest builder, verifier, storage system, API, executable test, or compatibility vector runner;
- generate, import, export, store, use, rotate, revoke, recover, or destroy keys, signatures, secrets, credentials, nonces, or recovery material;
- create, activate, modify, or claim existence of an authority anchor;
- conduct, rehearse, schedule, or authorize a ceremony;
- inspect, create, restore, rename, or modify Migration 009 or any database migration;
- access Development or Production runtimes, databases, SQL, containers, services, devices, credentials, or operational systems;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- grant authority to any person, service, model, client, tool, automation, assessor, library, record, or digest.

Future work requires separate authorization and may include:

- a machine-readable evidence-record schema;
- immutable non-secret evidence-record compatibility vectors;
- a parser and canonicalizer implementation-assurance profile;
- an evidence lifecycle, storage, retention, and access-control design;
- a manifest-signing and external-integrity-anchor design;
- a separately authorized non-operational evidence-record implementation;
- an owner and security review before any Development use.

No record creation, evidence collection, candidate assessment, library evaluation, implementation, executable testing, key or signature operation, anchor activation, ceremony, migration, deployment, or Production work MAY begin from this profile alone.
