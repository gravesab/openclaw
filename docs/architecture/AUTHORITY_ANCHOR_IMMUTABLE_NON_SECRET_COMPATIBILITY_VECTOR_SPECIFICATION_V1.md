---
title: "Authority Anchor Immutable Non-Secret Compatibility Vector Specification v1"
summary: "Normative immutable, non-secret compatibility vectors for authority-anchor canonicalization, encoding, hashing, framing, envelope validation, signature verification decisions, downgrade prevention, and cross-platform conformance"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-05"
category: "Architecture"
source_document: "AUTHORITY_ANCHOR_IMMUTABLE_NON_SECRET_COMPATIBILITY_VECTOR_SPECIFICATION_V1.md"
read_when:
  - Reviewing authority-anchor compatibility vectors or cross-platform conformance evidence
  - Validating canonicalization, encoding, hashing, framing, envelope, or signature-decision behavior
  - Defining vector immutability, provenance, negative cases, reason codes, or compatibility gates
---

# Authority Anchor Immutable Non-Secret Compatibility Vector Specification v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-05

This specification specializes the [Authority Anchor Cryptographic and Canonicalization Parameter Profile v1](/architecture/AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1), [External Authority Anchor and Trust-Root Specification v1](/architecture/EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1), and [Authority Anchor Ceremony, Custody, Rotation, and Recovery Profile v1](/architecture/AUTHORITY_ANCHOR_CEREMONY_CUSTODY_ROTATION_AND_RECOVERY_PROFILE_V1). It remains governed by the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1), [Authoritative Mutation Threat Model v1](/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1), [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1), and [Authoritative Mutation Protocol v1](/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1).

Requirements use stable **IVS** identifiers. Implementation-independent acceptance tests use **IVT** identifiers. Normative vector identifiers use **AAV**. Only rows explicitly labeled normative are vectors.

## 1. Governing invariant and authorization boundary

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

- **IVS-001:** This specification MUST preserve owner authority and MUST NOT allow vector conformance to substitute for owner authorization.
- **IVS-002:** This specification defines documentation-only, non-secret compatibility evidence and MUST NOT be treated as authorization to generate, import, export, store, or use a key, secret, credential, nonce, or operational signature.
- **IVS-003:** This specification MUST NOT be treated as authorization to create or activate an anchor, conduct a ceremony, implement vector tooling, access a database, deploy, or access Production.
- **IVS-004:** A passing vector result MUST NOT authorize a mutation or bypass any governing identity, delegation, validation, confirmation, concurrency, idempotency, transaction, audit, or outbox requirement.
- **IVS-005:** Missing, changed, ambiguous, conflicting, secret-bearing, non-canonical, or unverifiable vector evidence MUST fail closed.
- **IVS-006:** Development and Production conformance evidence MUST remain distinct and non-authoritative.

## 2. Vector-set identity and immutability

| Property              | Normative v1 value                                 |
| --------------------- | -------------------------------------------------- |
| vector_set_id         | openclaw.authority-anchor.compatibility-vectors.v1 |
| profile               | openclaw.authority-anchor.crypto.v1                |
| specification_version | 1                                                  |
| status                | immutable-documentation-baseline                   |
| secret_classification | public-non-secret                                  |
| executable_form       | absent and unauthorized                            |
| operational_authority | none                                               |

- **IVS-007:** The exact vector-set identifier MUST refer only to the normative vectors in this v1 document.
- **IVS-008:** A normative vector identifier MUST be globally unique within the vector set and MUST never be reassigned.
- **IVS-009:** A change to normative input, expected bytes, expected value, expected decision, or reason code MUST create a new vector-set version.
- **IVS-010:** V1 vectors MUST NOT be silently corrected, regenerated, reordered into new semantics, or reinterpreted.
- **IVS-011:** A purely editorial correction MAY use an explicit erratum only when it cannot change machine-observable input or outcome.
- **IVS-012:** The committed document bytes, Git object identity, inventory record, and reported SHA-256 digest together SHOULD provide checkpoint evidence without becoming operational authority.
- **IVS-013:** A derived machine-readable corpus MUST identify this vector set and prove exact correspondence, but no such corpus is created by this task.
- **IVS-014:** Partial vector-set adoption MUST NOT be represented as complete conformance.

## 3. Non-secret and provenance requirements

- **IVS-015:** The vector set MUST contain no private key, seed, expanded secret, recovery share, credential, token, password, operational nonce, operational signature, or Production-derived value.
- **IVS-016:** Public standards MAY be referenced by immutable publication and section identifiers without copying secret-key fields into this document.
- **IVS-017:** Referenced signatures or public keys MUST NOT be copied into this specification; implementations MAY obtain public standard vectors directly from the cited standard under separate implementation authorization.
- **IVS-018:** Synthetic examples MUST use visibly non-operational strings and MUST NOT resemble a real person, device, host, account, trust domain, or Production identifier.
- **IVS-019:** Every external vector source MUST identify the publication, section, case, and expected decision.
- **IVS-020:** A moved URL, unavailable source, conflicting erratum, or source-version ambiguity MUST block that referenced vector until reviewed.
- **IVS-021:** Vector provenance MUST distinguish copied bytes, references, derived mutations, and OpenClaw-specific constructions.
- **IVS-022:** A vector MUST NOT be sourced from logs, databases, live traffic, ceremonies, operational envelopes, or captured signatures.

## 4. Normative vector record model

A future representation of each normative vector MUST contain exactly these conceptual fields:

| Field                | Meaning                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------ |
| vector_id            | Stable AAV identifier                                                                      |
| vector_set_id        | Exact v1 set identifier                                                                    |
| component            | Canonicalization, encoding, hash, framing, envelope, signature-decision, policy, or limits |
| source               | OpenClaw construction or immutable standards reference                                     |
| input_representation | Exact interpretation of the documented input                                               |
| input                | Non-secret bytes or structured text                                                        |
| expected_output      | Exact non-secret bytes or value when applicable                                            |
| expected_decision    | accept, reject, proposed_only, or unavailable                                              |
| reason_code          | Stable canonical reason                                                                    |
| covered_requirements | Applicable ACP requirements                                                                |
| notes                | Non-normative clarification only                                                           |

- **IVS-023:** A vector record MUST distinguish absent expected output from an expected empty output.
- **IVS-024:** Exact bytes MUST use lowercase hexadecimal, unpadded base64url, UTF-8 text, or an explicitly defined structural sequence.
- **IVS-025:** Structured text MUST state whether it denotes source JSON, parsed data, or canonical bytes.
- **IVS-026:** Expected decisions MUST use only **accept**, **reject**, **proposed_only**, or **unavailable**.
- **IVS-027:** A reason code MUST be present for every rejection and unavailability decision.
- **IVS-028:** Notes MUST NOT override normative fields.
- **IVS-029:** Unknown fields or values in a machine-readable derivative MUST reject.
- **IVS-030:** Vector ordering MUST be ascending by vector_id but MUST NOT affect vector identity.

## 5. Canonical reason-code registry

| Reason code              | Meaning                                                        |
| ------------------------ | -------------------------------------------------------------- |
| accepted                 | Exact expected value and policy conditions satisfied           |
| proposed_only            | Structurally valid but no authoritative signature state        |
| canonicalization_invalid | Input violates JCS or restricted-model rules                   |
| duplicate_property       | JSON contains a duplicate property name                        |
| number_token_forbidden   | Signed JSON contains a number token                            |
| unicode_invalid          | UTF-8, scalar, normalization, or string rule failed            |
| unknown_property         | Schema does not permit a property                              |
| encoding_invalid         | Base64url or hexadecimal encoding is not canonical             |
| timestamp_invalid        | Timestamp violates exact v1 syntax or calendar rules           |
| integer_invalid          | Decimal-string integer is not canonical                        |
| nonce_invalid            | Nonce encoding or decoded length is invalid                    |
| digest_mismatch          | Expected and recomputed digest differ                          |
| framing_invalid          | Domain separation or length framing differs                    |
| envelope_invalid         | Envelope property, ordering, or structural rule failed         |
| signature_invalid        | Referenced signature case does not verify                      |
| signer_duplicate         | Signature set repeats a key identity                           |
| quorum_unproven          | Eligible distinct quorum cannot be proven                      |
| context_mismatch         | Purpose, environment, trust domain, schema, or version differs |
| profile_unsupported      | Profile or algorithm is unknown or inactive                    |
| profile_downgrade        | Profile is older than required or retired                      |
| limit_exceeded           | Input exceeds an approved structural bound                     |
| dependency_unavailable   | Required source or deterministic dependency cannot be verified |

- **IVS-031:** Implementations MUST use the exact stable reason code for vector comparison.
- **IVS-032:** A more detailed internal error MAY exist but MUST NOT change the normative decision or disclose sensitive data.
- **IVS-033:** An unknown reason code MUST fail conformance and MUST NOT map to accepted.
- **IVS-034:** Multiple applicable failures MUST follow a separately approved deterministic precedence; until defined, the vector MUST isolate one changed variable.

## 6. Normative canonicalization vectors

Each row in this section is normative.

| Vector ID   | Input representation                                         | Expected output or decision                              | Reason                   |
| ----------- | ------------------------------------------------------------ | -------------------------------------------------------- | ------------------------ |
| AAV-JCS-001 | Parsed object with string properties b=2 then a=1            | UTF-8 bytes for {"a":"1","b":"2"}                        | accepted                 |
| AAV-JCS-002 | Source JSON {"a":"1","b":"2"}                                | Same UTF-8 bytes                                         | accepted                 |
| AAV-JCS-003 | Source JSON with spaces around members for the JCS component | Reject                                                   | canonicalization_invalid |
| AAV-JCS-004 | Source JSON {"a":"1","a":"2"}                                | Reject before map construction                           | duplicate_property       |
| AAV-JCS-005 | Source JSON {"a":1}                                          | Reject                                                   | number_token_forbidden   |
| AAV-JCS-006 | Parsed object with boolean true, null, and string values     | Canonical JCS bytes with keys in JCS order               | accepted                 |
| AAV-JCS-007 | String containing U+000A                                     | Canonical JSON escape uses reverse-solidus followed by n | accepted                 |
| AAV-JCS-008 | String containing U+00E9 in NFC                              | Preserve U+00E9 and emit UTF-8                           | accepted                 |
| AAV-JCS-009 | String containing decomposed U+0065 U+0301                   | Reject without normalization                             | unicode_invalid          |
| AAV-JCS-010 | UTF-8 input beginning with BOM                               | Reject                                                   | unicode_invalid          |
| AAV-JCS-011 | Input containing an unpaired surrogate                       | Reject                                                   | unicode_invalid          |
| AAV-JCS-012 | Object containing a schema-unknown property                  | Reject                                                   | unknown_property         |
| AAV-JCS-013 | Object properties z and aa                                   | Canonical order is aa then z                             | accepted                 |
| AAV-JCS-014 | Array with string values 2 then 1                            | Preserve array order                                     | accepted                 |
| AAV-JCS-015 | JSON with a trailing comma or comment                        | Reject                                                   | canonicalization_invalid |

- **IVS-035:** AAV-JCS vectors MUST be evaluated under RFC 8785 plus the restricted model in the cryptographic profile.
- **IVS-036:** A canonicalizer MUST NOT normalize AAV-JCS-009 into AAV-JCS-008.
- **IVS-037:** Source-JSON vectors MUST validate original syntax and duplicate names before ordinary object construction.
- **IVS-038:** Parsed-data vectors MUST construct the stated abstract value without importing source formatting.

## 7. Normative binary and identifier encoding vectors

Each row in this section is normative.

| Vector ID   | Input                                                                       | Expected output or decision        | Reason           |
| ----------- | --------------------------------------------------------------------------- | ---------------------------------- | ---------------- |
| AAV-ENC-001 | Empty byte string for codec behavior                                        | Empty base64url string             | accepted         |
| AAV-ENC-002 | ASCII f                                                                     | Zg                                 | accepted         |
| AAV-ENC-003 | ASCII fo                                                                    | Zm8                                | accepted         |
| AAV-ENC-004 | ASCII foo                                                                   | Zm9v                               | accepted         |
| AAV-ENC-005 | Bytes FB FF                                                                 | -\_8                               | accepted         |
| AAV-ENC-006 | Zg==                                                                        | Reject padding                     | encoding_invalid |
| AAV-ENC-007 | +/8=                                                                        | Reject alphabet and padding        | encoding_invalid |
| AAV-ENC-008 | Zg followed by whitespace                                                   | Reject                             | encoding_invalid |
| AAV-ENC-009 | Zh as an alternate encoding of byte 0x66                                    | Reject nonzero unused bits         | encoding_invalid |
| AAV-ENC-010 | SHA-256 digest text with uppercase A through F                              | Reject                             | encoding_invalid |
| AAV-ENC-011 | sha256: plus exactly 64 lowercase hexadecimal zeroes                        | Canonical digest identifier syntax | accepted         |
| AAV-ENC-012 | sha256: plus 63 lowercase hexadecimal zeroes                                | Reject length                      | encoding_invalid |
| AAV-ENC-013 | ed25519: plus a canonical 43-character base64url value decoding to 32 bytes | Canonical key-identifier syntax    | accepted         |
| AAV-ENC-014 | ed25519: value decoding to 31 bytes                                         | Reject length                      | encoding_invalid |
| AAV-ENC-015 | Friendly key alias instead of canonical key identifier                      | Reject                             | encoding_invalid |

- **IVS-039:** Codec vectors validate encoding only and MUST NOT imply that empty values, all-zero digests, or arbitrary public-key bytes are semantically eligible.
- **IVS-040:** AAV-ENC-013 defines syntax and length only; it contains no actual key and MUST NOT be interpreted as key validity.
- **IVS-041:** A decoder MUST round-trip accepted base64url text exactly.
- **IVS-042:** Hexadecimal comparison MUST remain case-sensitive.

## 8. Normative hash vectors

Each row in this section is normative and uses SHA-256.

| Vector ID   | Exact input bytes                                                   | Expected lowercase hexadecimal digest                            | Reason                   |
| ----------- | ------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------ |
| AAV-HSH-001 | Empty byte string                                                   | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 | accepted                 |
| AAV-HSH-002 | ASCII abc                                                           | ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad | accepted                 |
| AAV-HSH-003 | Same semantic object presented with non-canonical source whitespace | Reject before artifact hashing                                   | canonicalization_invalid |
| AAV-HSH-004 | Claimed digest differing by one hexadecimal digit                   | Reject                                                           | digest_mismatch          |
| AAV-HSH-005 | SHA-1, MD5, truncated SHA-256, or platform hash identifier          | Reject                                                           | profile_unsupported      |

- **IVS-043:** Published SHA-256 values in AAV-HSH-001 and AAV-HSH-002 MUST match exactly.
- **IVS-044:** The v1 hash vectors publish only established non-secret SHA-256 values and explicit rejection decisions.
- **IVS-045:** A future OpenClaw-specific digest vector MUST enter a new approved vector-set version rather than alter v1.
- **IVS-046:** Hash vectors MUST NOT substitute for envelope signature or policy validation.

## 9. Normative timestamp, integer, and nonce vectors

Each row in this section is normative.

| Vector ID   | Input                                                             | Expected decision            | Reason                 |
| ----------- | ----------------------------------------------------------------- | ---------------------------- | ---------------------- |
| AAV-SCL-001 | 2026-08-05T12:34:56Z                                              | Accept syntax                | accepted               |
| AAV-SCL-002 | 2026-08-05T12:34:56.0Z                                            | Reject                       | timestamp_invalid      |
| AAV-SCL-003 | 2026-08-05T12:34:56+00:00                                         | Reject                       | timestamp_invalid      |
| AAV-SCL-004 | 2026-08-05t12:34:56z                                              | Reject                       | timestamp_invalid      |
| AAV-SCL-005 | 2026-08-05T12:34:60Z                                              | Reject leap second           | timestamp_invalid      |
| AAV-SCL-006 | 2026-02-29T12:34:56Z                                              | Reject invalid calendar date | timestamp_invalid      |
| AAV-SCL-007 | Decimal string 0                                                  | Accept syntax                | accepted               |
| AAV-SCL-008 | Decimal string 1                                                  | Accept syntax                | accepted               |
| AAV-SCL-009 | Decimal string 00                                                 | Reject                       | integer_invalid        |
| AAV-SCL-010 | Decimal string +1                                                 | Reject                       | integer_invalid        |
| AAV-SCL-011 | Decimal string 1.0                                                | Reject                       | integer_invalid        |
| AAV-SCL-012 | JSON number token 1                                               | Reject                       | number_token_forbidden |
| AAV-SCL-013 | Base64url nonce decoding to exactly 32 non-operational zero bytes | Accept syntax only           | accepted               |
| AAV-SCL-014 | Base64url nonce decoding to 31 bytes                              | Reject                       | nonce_invalid          |
| AAV-SCL-015 | Padded base64url nonce decoding to 32 bytes                       | Reject                       | encoding_invalid       |

- **IVS-047:** AAV-SCL-001 validates syntax only and MUST NOT establish trusted time or freshness.
- **IVS-048:** AAV-SCL-013 validates syntax and length only and MUST NOT approve all-zero bytes as an operational nonce.
- **IVS-049:** No vector nonce may be used operationally.
- **IVS-050:** Numeric comparison vectors MUST parse canonical decimal strings only after syntax acceptance.

## 10. Normative domain-framing vectors

Each row in this section is normative. The protected-header and payload examples contain no signature or key material.

| Vector ID   | Structural input                                                      | Expected result          | Reason          |
| ----------- | --------------------------------------------------------------------- | ------------------------ | --------------- |
| AAV-FRM-001 | Exact 38-byte ASCII domain tag OpenClaw-Authority-Anchor-Signature-v1 | Accept domain component  | accepted        |
| AAV-FRM-002 | Domain tag with different case                                        | Reject                   | framing_invalid |
| AAV-FRM-003 | Domain tag with trailing space                                        | Reject                   | framing_invalid |
| AAV-FRM-004 | Exact domain tag without following zero octet                         | Reject                   | framing_invalid |
| AAV-FRM-005 | Protected bytes {} with big-endian length 0000000000000002            | Accept component framing | accepted        |
| AAV-FRM-006 | Payload bytes null with big-endian length 0000000000000004            | Accept component framing | accepted        |
| AAV-FRM-007 | Little-endian encoding of protected length 2                          | Reject                   | framing_invalid |
| AAV-FRM-008 | Four-byte rather than eight-byte length                               | Reject                   | framing_invalid |
| AAV-FRM-009 | Declared length exceeds available component bytes                     | Reject                   | framing_invalid |
| AAV-FRM-010 | Trailing octet after the framed payload                               | Reject                   | framing_invalid |
| AAV-FRM-011 | Protected and payload component order reversed                        | Reject                   | framing_invalid |
| AAV-FRM-012 | Payload digest alone in place of canonical payload bytes              | Reject                   | framing_invalid |

- **IVS-051:** AAV-FRM vectors validate exact framing and MUST NOT be signed by this documentation task.
- **IVS-052:** Component length validation MUST occur before allocation or slicing based on untrusted lengths.
- **IVS-053:** Accepted component vectors MUST NOT be represented as a complete accepted envelope.
- **IVS-054:** Any framing variation not explicitly defined by the v1 profile MUST reject.

## 11. Normative envelope and policy vectors

Each row in this section is normative and uses structural placeholders rather than key or signature bytes.

| Vector ID   | Input condition                                                       | Expected decision | Reason                 |
| ----------- | --------------------------------------------------------------------- | ----------------- | ---------------------- |
| AAV-ENV-001 | Exact protected, payload, and empty signatures properties             | proposed_only     | proposed_only          |
| AAV-ENV-002 | Unknown top-level property                                            | reject            | envelope_invalid       |
| AAV-ENV-003 | Missing protected property                                            | reject            | envelope_invalid       |
| AAV-ENV-004 | Missing payload property                                              | reject            | envelope_invalid       |
| AAV-ENV-005 | Missing signatures property                                           | reject            | envelope_invalid       |
| AAV-ENV-006 | Signature entries not sorted by key_id                                | reject            | envelope_invalid       |
| AAV-ENV-007 | Duplicate key_id entries                                              | reject            | signer_duplicate       |
| AAV-ENV-008 | Payload digest claim differs from canonical payload digest            | reject            | digest_mismatch        |
| AAV-ENV-009 | Purpose differs from expected policy                                  | reject            | context_mismatch       |
| AAV-ENV-010 | Development environment used for Production request                   | reject            | context_mismatch       |
| AAV-ENV-011 | Trust domain differs from expected policy                             | reject            | context_mismatch       |
| AAV-ENV-012 | Unknown schema or schema version                                      | reject            | profile_unsupported    |
| AAV-ENV-013 | Unknown cryptographic profile                                         | reject            | profile_unsupported    |
| AAV-ENV-014 | Retired lower profile after higher accepted state                     | reject            | profile_downgrade      |
| AAV-ENV-015 | Eligible quorum state unavailable                                     | unavailable       | dependency_unavailable |
| AAV-ENV-016 | Structurally valid signature placeholders without actual verification | proposed_only     | proposed_only          |
| AAV-ENV-017 | Oversize envelope before cryptographic work                           | reject            | limit_exceeded         |
| AAV-ENV-018 | Parser implementations disagree on accepted structure                 | unavailable       | dependency_unavailable |

- **IVS-055:** Placeholder strings MUST NOT be passed to a cryptographic verifier or interpreted as signatures or keys.
- **IVS-056:** AAV-ENV-001 and AAV-ENV-016 prove only non-authoritative structural treatment.
- **IVS-057:** Context vectors MUST bind expected policy outside the envelope rather than trust envelope claims.
- **IVS-058:** A policy or dependency failure MUST NOT map to accepted.

## 12. Referenced Ed25519 decision vectors

The following vectors are normative references to [RFC 8032](https://www.rfc-editor.org/info/rfc8032/). They include no key, secret, or signature bytes in this document.

| Vector ID  | Immutable source                | Transformation                                                       | Expected decision               |
| ---------- | ------------------------------- | -------------------------------------------------------------------- | ------------------------------- |
| AAV-ED-001 | RFC 8032 Section 7.1, TEST 1    | None                                                                 | accept under RFC verification   |
| AAV-ED-002 | RFC 8032 Section 7.1, TEST 2    | None                                                                 | accept under RFC verification   |
| AAV-ED-003 | RFC 8032 Section 7.1, TEST 3    | None                                                                 | accept under RFC verification   |
| AAV-ED-004 | RFC 8032 Section 7.1, TEST 1024 | None                                                                 | accept under RFC verification   |
| AAV-ED-005 | AAV-ED-001                      | Flip one message bit only                                            | reject with signature_invalid   |
| AAV-ED-006 | AAV-ED-001                      | Flip one signature bit only                                          | reject with signature_invalid   |
| AAV-ED-007 | AAV-ED-002                      | Verify with the public key referenced by TEST 1                      | reject with signature_invalid   |
| AAV-ED-008 | AAV-ED-003                      | Append one message octet                                             | reject with signature_invalid   |
| AAV-ED-009 | RFC 8032 verification case      | Non-canonical S encoding                                             | reject with signature_invalid   |
| AAV-ED-010 | RFC 8032 verification case      | Invalid or small-order public point                                  | reject with signature_invalid   |
| AAV-ED-011 | AAV-ED-001                      | Treat as Ed25519ph or Ed25519ctx                                     | reject with profile_unsupported |
| AAV-ED-012 | Any accepted RFC case           | Substitute OpenClaw domain-framed bytes without a matching signature | reject with signature_invalid   |

- **IVS-059:** RFC 8032 references MUST resolve to the exact published case and applicable accepted errata.
- **IVS-060:** No referenced private-key field MAY be copied into OpenClaw documentation, logs, source control, or generated evidence.
- **IVS-061:** Derived negative transformations MUST change exactly the stated variable.
- **IVS-062:** A future executable corpus MUST obtain standards material through a separately reviewed, integrity-verified process.
- **IVS-063:** Passing RFC vectors alone MUST NOT establish OpenClaw envelope, policy, quorum, context, or implementation eligibility.
- **IVS-064:** Signature decisions MUST remain fail closed when the immutable source cannot be verified.

## 13. Cross-platform conformance matrix

A supported verifier MUST produce identical results for every applicable vector across:

| Dimension                         | Required equality                                              |
| --------------------------------- | -------------------------------------------------------------- |
| Architecture                      | Canonical bytes, digests, framing, decisions, and reason codes |
| Crypto provider                   | Strict accepted and rejected signature cases                   |
| JSON parser                       | Duplicate, number, Unicode, ordering, and syntax decisions     |
| Operating system                  | Bytes and decisions                                            |
| Runtime version                   | Bytes and decisions                                            |
| Unicode implementation            | NFC validation and string preservation decisions               |
| Online or offline mode            | No downgrade or stale acceptance                               |
| Development or Production context | Environment mismatch always rejects                            |

- **IVS-065:** Conformance MUST compare exact bytes, not only semantic objects or success booleans.
- **IVS-066:** Every implementation result MUST identify implementation, version, platform, vector-set identifier, vector identifier, decision, reason code, and output digest where applicable.
- **IVS-067:** A missing vector result MUST fail complete conformance.
- **IVS-068:** A byte, decision, or reason-code mismatch MUST fail complete conformance.
- **IVS-069:** Selective suppression, expected-failure marking, platform waiver, or baseline update MUST NOT convert a mismatch into conformance without owner and security review.
- **IVS-070:** Conformance evidence MUST NOT contain operational material or become authority.
- **IVS-071:** A dependency upgrade MUST invalidate prior conformance evidence for the affected implementation.
- **IVS-072:** Cross-platform agreement on an outcome forbidden by the normative profile MUST still fail.

## 14. Vector lifecycle and change control

- **IVS-073:** V1 is frozen when its canonical documentation commit is accepted.
- **IVS-074:** A new normative vector MUST enter a new vector-set version even when it adds coverage without changing existing outcomes.
- **IVS-075:** A successor vector set MUST retain predecessor vector identifiers or explicitly record retirement and reason.
- **IVS-076:** A successor MUST NOT weaken a rejection into acceptance without a separately approved parameter-profile change.
- **IVS-077:** Vector retirement MUST preserve historical evidence and MUST NOT authorize old behavior.
- **IVS-078:** An erratum MUST identify affected text, prove no machine-observable change, and receive owner and security review.
- **IVS-079:** A source-standard erratum affecting outcome MUST block the vector and require a new OpenClaw vector-set version.
- **IVS-080:** Generated timestamps, path names, object ordering, or tool versions MUST NOT alter normative vector content.
- **IVS-081:** Vector-set content MUST be reproducible without network access once an approved derivative corpus exists.
- **IVS-082:** No derivative corpus, snapshot, or cache may replace the canonical specification and approved integrity evidence.

## 15. Fail-closed handling and prohibited shortcuts

- **IVS-083:** A verifier MUST NOT skip a vector because it is difficult, slow, unsupported, or fails on one platform and still claim complete conformance.
- **IVS-084:** A producer and verifier sharing the same faulty library MUST NOT be treated as independent compatibility evidence.
- **IVS-085:** Regenerating expected output from the implementation under test MUST NOT establish correctness.
- **IVS-086:** Updating expected output to match observed output MUST require a new approved vector-set version.
- **IVS-087:** Human visual similarity, normalized display, logging output, or object equality MUST NOT replace byte comparison.
- **IVS-088:** A fallback parser, hash, signature mode, profile, encoding, or platform default MUST NOT be used.
- **IVS-089:** Vector-runner crash, timeout, truncation, skipped output, or ambiguous result MUST fail conformance.
- **IVS-090:** Secret detection uncertainty MUST stop vector publication and require security review.
- **IVS-091:** Production-derived evidence MUST NOT be sanitized into a test vector.
- **IVS-092:** Models, retrieval, tools, and automation MAY help draft candidates but MUST NOT declare vectors canonical or passing.

## 16. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                                |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| IVT-001 | Documentation approval cannot create keys, signatures, anchor state, executable tooling, migrations, deployments, or Production access.       |
| IVT-002 | Vector conformance cannot authorize a mutation or bypass governing controls.                                                                  |
| IVT-003 | Every normative vector has a unique stable AAV identifier and explicit expected decision.                                                     |
| IVT-004 | Changing normative input or outcome requires a new vector-set version.                                                                        |
| IVT-005 | The specification contains no private, secret, credential, operational nonce, operational signature, or Production-derived value.             |
| IVT-006 | External vectors resolve to exact immutable publication sections without copying key or signature bytes.                                      |
| IVT-007 | Duplicate JSON properties reject before ordinary object construction.                                                                         |
| IVT-008 | JSON numbers, invalid Unicode, non-NFC strings, unknown properties, and non-canonical syntax reject.                                          |
| IVT-009 | Base64url, hexadecimal, digest, and key-identifier syntax produce exact canonical decisions.                                                  |
| IVT-010 | SHA-256 empty and abc vectors match published values exactly.                                                                                 |
| IVT-011 | Timestamp, integer, and nonce vectors distinguish syntax from operational eligibility.                                                        |
| IVT-012 | Domain tag, separator, lengths, order, truncation, and trailing bytes produce exact framing decisions.                                        |
| IVT-013 | Empty or placeholder signature sets remain non-authoritative.                                                                                 |
| IVT-014 | Envelope unknown fields, ordering, digest, context, profile, downgrade, and limit failures reject or become unavailable exactly as specified. |
| IVT-015 | Referenced RFC 8032 positive cases accept and single-variable negative cases reject when separately implemented.                              |
| IVT-016 | No RFC private-key field is copied into OpenClaw documentation or evidence.                                                                   |
| IVT-017 | All supported platforms produce identical bytes, decisions, and reason codes.                                                                 |
| IVT-018 | Missing, skipped, ambiguous, or mismatched vector results fail complete conformance.                                                          |
| IVT-019 | A library or platform change invalidates affected prior evidence.                                                                             |
| IVT-020 | V1 vectors cannot be silently corrected, regenerated, or weakened.                                                                            |
| IVT-021 | Implementation-derived expected output cannot bootstrap its own correctness.                                                                  |
| IVT-022 | Source ambiguity, source errata affecting outcome, or secret uncertainty fails closed.                                                        |
| IVT-023 | Development conformance evidence cannot authorize Production.                                                                                 |
| IVT-024 | Passing vectors cannot approve a library, verifier, signer, ceremony, anchor, or deployment.                                                  |
| IVT-025 | Every accepted vector-set checkpoint links the specification, inventory, commit, digest, and clean-scope evidence.                            |
| IVT-026 | The governing invariant remains true for every vector lifecycle action.                                                                       |

No executable vector runner, machine-readable corpus, key, signature, secret, credential, anchor, ceremony, migration, database operation, deployment, or Production resource is created by this documentation task.

## 17. Requirement-to-test traceability

| Requirements            | Tests                                       |
| ----------------------- | ------------------------------------------- |
| IVS-001 through IVS-006 | IVT-001, IVT-002, IVT-023, IVT-024, IVT-026 |
| IVS-007 through IVS-014 | IVT-003, IVT-004, IVT-020, IVT-025          |
| IVS-015 through IVS-022 | IVT-005, IVT-006, IVT-016, IVT-022          |
| IVS-023 through IVS-034 | IVT-003, IVT-017, IVT-018                   |
| IVS-035 through IVS-038 | IVT-007, IVT-008                            |
| IVS-039 through IVS-042 | IVT-009, IVT-011                            |
| IVS-043 through IVS-046 | IVT-010, IVT-021                            |
| IVS-047 through IVS-050 | IVT-011                                     |
| IVS-051 through IVS-054 | IVT-012                                     |
| IVS-055 through IVS-058 | IVT-013, IVT-014                            |
| IVS-059 through IVS-064 | IVT-006, IVT-015, IVT-016, IVT-022          |
| IVS-065 through IVS-072 | IVT-017 through IVT-019, IVT-023            |
| IVS-073 through IVS-082 | IVT-004, IVT-019, IVT-020, IVT-022          |
| IVS-083 through IVS-092 | IVT-018, IVT-021, IVT-022, IVT-024, IVT-026 |
| IVS-001 through IVS-092 | IVT-025                                     |

## 18. Governing-document traceability

| Governing document                                                                                      | Vector requirements                              | Existing tests                   |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------- |
| Cryptographic Parameter Profile ACP-001 through ACP-128                                                 | IVS-001 through IVS-092                          | ACT-001 through ACT-032          |
| External Authority Anchor EAA-001 through EAA-114                                                       | IVS-001 through IVS-092                          | EAT-001 through EAT-040          |
| Ceremony and Custody Profile CCR-001 through CCR-130                                                    | IVS-001 through IVS-022, IVS-065 through IVS-092 | CCT-001 through CCT-040          |
| Mutation and Proposal Contract MUT-001 through MUT-020                                                  | IVS-001 through IVS-006, IVS-055 through IVS-058 | Contract acceptance criteria     |
| Confirmation Policy CONF-001 through CONF-074 and CFM-001 through CFM-028                               | IVS-001 through IVS-006, IVS-055 through IVS-058 | Confirmation acceptance criteria |
| Atomic Transaction Design ATX-001 through ATX-069 and ATM-001 through ATM-030                           | IVS-001 through IVS-006, IVS-055 through IVS-058 | Transaction acceptance criteria  |
| Mutation Threat Model AMT-001 through AMT-040, AMR-001 through AMR-068, and AMTST-001 through AMTST-038 | IVS-001 through IVS-092                          | AMTST-001 through AMTST-038      |
| Identity and Delegation Policy IDP-001 through IDP-082 and IDT-001 through IDT-038                      | IVS-001 through IVS-022, IVS-055 through IVS-092 | IDT-001 through IDT-038          |
| Authoritative Mutation Protocol AMP-001 through AMP-090 and APT-001 through APT-040                     | IVS-001 through IVS-006, IVS-055 through IVS-092 | APT-001 through APT-040          |

## 19. Unresolved implementation decisions

| Decision                                             | Interim fail-closed treatment                     | Required review            |
| ---------------------------------------------------- | ------------------------------------------------- | -------------------------- |
| Machine-readable vector format                       | No derivative corpus authoritative                | Architecture and Security  |
| Corpus content-addressing and signature policy       | Commit and reported digest are evidence only      | Owner and Security         |
| Approved RFC retrieval and offline-vendoring process | Referenced signature cases blocked                | Security                   |
| Canonical multi-failure reason precedence            | Vectors isolate one failure variable              | Architecture and Security  |
| Structural size and depth limits                     | Limit conformance unavailable                     | Architecture and Security  |
| Supported platform and provider matrix               | Complete conformance unavailable                  | Owner and Security         |
| Independent implementation requirement               | Single-library agreement insufficient             | Security                   |
| Unicode version and NFC validator                    | Unicode conformance unavailable                   | Architecture and Security  |
| Conformance evidence schema and retention            | No implementation eligible                        | Owner and Security         |
| Secret-scanning policy for future corpus             | Corpus publication prohibited                     | Security                   |
| Library and verifier approval criteria               | Passing vectors cannot grant eligibility          | Security                   |
| Development synthetic-material policy                | Signature-envelope vectors remain structural only | Owner and Security         |
| Production conformance policy                        | Production remains absent and unauthorized        | Owner                      |
| Residual-risk acceptance                             | No exception permitted                            | Owner with Security review |

## 20. Explicit non-goals and future deliverables

This specification does not:

- create, generate, copy, import, export, store, use, rotate, revoke, recover, or destroy any key, secret, credential, operational nonce, or operational signature;
- embed a private key, seed, recovery value, credential, operational signature, or Production-derived value;
- create, activate, modify, verify operationally, or claim existence of an authority anchor;
- conduct, rehearse, schedule, authorize, or claim completion of a ceremony;
- implement a machine-readable vector corpus, vector runner, parser, canonicalizer, hasher, signer, verifier, API, service, configuration, or executable test;
- run cryptographic signing or operational verification;
- approve a library, crypto provider, verifier, signer, hardware device, custodian, quorum, or Production profile;
- inspect, create, restore, rename, or modify Migration 009 or any database migration;
- access Development or Production runtimes, databases, SQL, containers, services, devices, key providers, or operational systems;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- grant authority to any person, service, model, client, tool, automation, or provider.

Future work requires separate authorization and may include:

- a machine-readable, content-addressed derivative of this vector set;
- an offline standards-source provenance bundle;
- an implementation assurance and approved-library profile;
- a Development-only synthetic signature-vector policy;
- a cross-platform conformance evidence schema;
- a Production profile, only if separately authorized.

No implementation, executable testing, key or signature operation, anchor activation, ceremony, migration, deployment, or Production work MAY begin from this specification alone.
