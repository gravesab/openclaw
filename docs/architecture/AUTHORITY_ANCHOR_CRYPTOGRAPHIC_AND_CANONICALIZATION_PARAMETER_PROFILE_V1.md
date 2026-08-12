---
title: "Authority Anchor Cryptographic and Canonicalization Parameter Profile v1"
summary: "Normative cryptographic, canonical serialization, encoding, domain separation, signature, digest, compatibility, and downgrade-prevention parameters for authority-anchor artifacts"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-05"
category: "Architecture"
source_document: "AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1.md"
read_when:
  - Implementing or reviewing canonical authority-anchor artifact encoding, hashing, signing, or verification
  - Defining identifiers, timestamps, nonces, signature envelopes, algorithm agility, or downgrade prevention
  - Building compatibility vectors or evaluating fail-closed cryptographic behavior
---

# Authority Anchor Cryptographic and Canonicalization Parameter Profile v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-05

This profile specializes the [External Authority Anchor and Trust-Root Specification v1](/architecture/EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1) and the [Authority Anchor Ceremony, Custody, Rotation, and Recovery Profile v1](/architecture/AUTHORITY_ANCHOR_CEREMONY_CUSTODY_ROTATION_AND_RECOVERY_PROFILE_V1). It remains governed by the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1), [Authoritative Mutation Threat Model v1](/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1), [Authoritative Identity, Service Identity, and Delegation Policy v1](/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1), and [Authoritative Mutation Protocol v1](/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1).

Requirements use stable **ACP** identifiers. Implementation-independent acceptance tests use **ACT** identifiers. Examples are non-authoritative unless identified as normative vectors.

## 1. Governing invariant and authorization boundary

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

- **ACP-001:** This profile MUST preserve owner authority and MUST NOT allow cryptographic validity to substitute for owner authorization.
- **ACP-002:** This profile defines formats and parameters only; it MUST NOT be treated as authorization to generate a key, create a signature, activate an anchor, conduct a ceremony, or access Production.
- **ACP-003:** A valid signature MUST NOT authorize an individual mutation or bypass identity, delegation, validation, confirmation, concurrency, idempotency, transaction, audit, or outbox controls.
- **ACP-004:** Every verification decision MUST be deterministic for the same exact bytes, trust state, policy, and trusted time.
- **ACP-005:** Unknown, missing, malformed, non-canonical, ambiguous, weak, deprecated, downgraded, or unverifiable cryptographic input MUST fail closed.
- **ACP-006:** Development and Production keys, signatures, identifiers, envelopes, trust state, and trust domains MUST remain distinct even when both environments use this parameter profile.

## 2. Standards basis and profile status

This v1 profile uses:

- [FIPS 186-5](https://csrc.nist.gov/pubs/fips/186-5/final) and [RFC 8032](https://www.rfc-editor.org/info/rfc8032/) for Ed25519 signatures;
- [NIST SP 800-57 Part 1 Revision 5](https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final) and [NIST SP 800-131A Revision 2](https://csrc.nist.gov/pubs/sp/800/131/a/r2/final) for security strength, key management, and transition principles;
- [RFC 8785](https://www.rfc-editor.org/info/rfc8785/) for the JSON Canonicalization Scheme;
- [RFC 4648](https://www.rfc-editor.org/info/rfc4648/) for base64url;
- [RFC 3339](https://www.rfc-editor.org/info/rfc3339/) for timestamp syntax.

- **ACP-007:** The sole active v1 profile identifier MUST be **openclaw.authority-anchor.crypto.v1**.
- **ACP-008:** The v1 signature algorithm MUST be pure Ed25519 as specified by RFC 8032, not Ed25519ctx, Ed25519ph, X25519, or an implementation-defined variant.
- **ACP-009:** The v1 content-digest algorithm MUST be SHA-256.
- **ACP-010:** The v1 canonical serialization MUST be RFC 8785 JCS with the additional restrictions in this profile.
- **ACP-011:** The v1 textual binary encoding MUST be unpadded base64url under RFC 4648 Section 5 unless a field explicitly requires lowercase hexadecimal.
- **ACP-012:** The v1 classical security target MUST be at least 128 bits.
- **ACP-013:** No alternate or fallback algorithm is active in v1.
- **ACP-014:** Standards conformance MUST NOT imply that a library, module, device, or deployment is approved; implementation assurance requires separate review.

## 3. Normative parameter registry

| Parameter       | Required v1 value                                       | Rejection rule                                            |
| --------------- | ------------------------------------------------------- | --------------------------------------------------------- |
| profile         | openclaw.authority-anchor.crypto.v1                     | Any other value rejects                                   |
| signature       | Ed25519, pure mode, RFC 8032                            | Variant or unknown algorithm rejects                      |
| public key      | 32-byte compressed Ed25519 point                        | Wrong length or invalid point rejects                     |
| signature value | 64-byte canonical Ed25519 signature                     | Wrong length or non-canonical value rejects               |
| content digest  | SHA-256, 32 bytes                                       | Other digest or length rejects                            |
| canonical JSON  | RFC 8785 JCS plus this profile                          | Non-canonical or disallowed data rejects                  |
| text encoding   | UTF-8 without BOM                                       | Invalid UTF-8 or BOM rejects                              |
| binary text     | RFC 4648 base64url without padding                      | Padding, alternate alphabet, or non-canonical bits reject |
| digest text     | sha256: plus 64 lowercase hexadecimal digits            | Other case, prefix, or length rejects                     |
| key identifier  | ed25519: plus base64url of the exact 32-byte public key | Alias or malformed value rejects                          |
| timestamp       | UTC RFC 3339, second precision, uppercase T and Z       | Offset, fraction, lowercase, or leap second rejects       |
| nonce           | 32 random bytes encoded as unpadded base64url           | Wrong decoded length or malformed encoding rejects        |
| schema version  | Unsigned canonical decimal string                       | JSON number, sign, leading zero, or empty value rejects   |
| length prefix   | Unsigned 64-bit big-endian octets                       | Overflow or alternate width rejects                       |

- **ACP-015:** Producers MUST emit exactly the registered values.
- **ACP-016:** Verifiers MUST compare profile and algorithm identifiers by exact case-sensitive byte equality.
- **ACP-017:** An absent parameter MUST NOT acquire a default.
- **ACP-018:** Aliases, friendly names, media-type guesses, registry order, platform defaults, and library defaults MUST NOT select cryptographic behavior.

## 4. Restricted signed data model

- **ACP-019:** Signed JSON MAY contain objects, arrays, strings, booleans, and null only.
- **ACP-020:** JSON number tokens MUST NOT appear in signed input.
- **ACP-021:** Integers, counters, epochs, sequences, lengths, and versions MUST be decimal strings matching either **0** or a nonzero digit followed by zero or more digits.
- **ACP-022:** Negative values, explicit plus signs, leading zeros, exponent notation, decimal points, hexadecimal, and locale-specific digits MUST reject.
- **ACP-023:** Object property names MUST be unique and MUST use printable ASCII from U+0021 through U+007E.
- **ACP-024:** A schema MUST explicitly enumerate every permitted property; unknown properties MUST reject.
- **ACP-025:** Required and optional properties MUST be schema-defined; absent and null MUST remain distinct.
- **ACP-026:** Arrays MUST preserve schema-defined order and MUST NOT be treated as sets unless the schema defines a canonical sort key and duplicate rejection.
- **ACP-027:** Strings MUST be valid Unicode scalar sequences encoded as UTF-8 and MUST be in Unicode Normalization Form C before canonicalization.
- **ACP-028:** A verifier MUST validate Normalization Form C and MUST NOT silently normalize signed input.
- **ACP-029:** Unpaired surrogates, noncharacters prohibited by the schema, control characters outside explicitly allowed fields, and invalid UTF-8 MUST reject.
- **ACP-030:** Schema depth, member count, array length, string length, and total byte limits MUST be checked before expensive cryptographic work.

## 5. Canonical JSON procedure

- **ACP-031:** A parser MUST reject duplicate property names before constructing a map or object that could discard a duplicate.
- **ACP-032:** Canonicalization MUST follow RFC 8785 property ordering by unsigned UTF-16 code-unit comparison of unescaped names.
- **ACP-033:** Canonical output MUST contain no whitespace between tokens and MUST use RFC 8785 string escaping.
- **ACP-034:** Canonicalization MUST preserve string code points exactly and MUST NOT perform case folding, trimming, newline conversion, locale transformation, or Unicode normalization.
- **ACP-035:** The canonical byte sequence MUST be the UTF-8 encoding of the JCS output without BOM.
- **ACP-036:** Verification MUST parse under the restricted model, reserialize canonically, and compare canonical bytes with the supplied canonical component when one is supplied.
- **ACP-037:** A syntactically valid JSON representation that is not canonical MUST reject rather than be silently accepted as an equivalent signed object.
- **ACP-038:** Multiple parse paths, permissive parsers, comments, trailing commas, invalid escapes, or replacement characters MUST reject.
- **ACP-039:** Canonicalization failure MUST occur before signature success can be reported.
- **ACP-040:** Display formatting MUST remain derived and MUST NOT be signed or used as canonical identity.

## 6. Text, identifier, and binary encodings

- **ACP-041:** Field names, enum values, profile identifiers, algorithm identifiers, purpose identifiers, environment identifiers, and trust-domain identifiers MUST be case-sensitive ASCII.
- **ACP-042:** Enumerated values MUST use lowercase ASCII with components separated by period or hyphen as the owning schema defines.
- **ACP-043:** Base64url decoders MUST reject equals padding, whitespace, standard base64 plus or slash, nonzero unused pad bits, and encodings that do not round-trip to the same text.
- **ACP-044:** Lowercase hexadecimal fields MUST reject uppercase, separators, prefixes other than the schema prefix, and non-canonical length.
- **ACP-045:** A key identifier MUST be **ed25519:** followed by the unpadded base64url encoding of the exact 32-byte public key.
- **ACP-046:** A content identifier MUST be **sha256:** followed by the SHA-256 digest of the defined canonical bytes as 64 lowercase hexadecimal digits.
- **ACP-047:** A key alias, certificate subject, username, filename, database identifier, device label, or storage path MUST NOT replace the canonical key identifier.
- **ACP-048:** Identifiers MUST bind bytes, not display text or mutable metadata.

## 7. Timestamp, nonce, and version encoding

- **ACP-049:** A signed timestamp MUST use exactly **YYYY-MM-DDTHH:MM:SSZ** in UTC with uppercase T and Z.
- **ACP-050:** Fractional seconds, offsets, lowercase letters, leap-second value 60, 24:00:00, missing fields, and invalid calendar dates MUST reject.
- **ACP-051:** Parsing MUST validate the calendar value rather than rely only on a regular expression.
- **ACP-052:** Timestamps MUST be evaluated against the separately approved trusted-time and skew policy; syntax alone MUST NOT establish freshness.
- **ACP-053:** A nonce MUST contain 32 bytes from an approved cryptographically secure random source when operational generation is separately authorized.
- **ACP-054:** A nonce MUST be unique within its schema-defined scope and MUST NOT be derived only from time, counters, identifiers, payloads, or model output.
- **ACP-055:** Nonce duplication MUST reject when uniqueness is required and MUST produce security evidence.
- **ACP-056:** Schema, profile, epoch, and sequence versions MUST use canonical unsigned decimal strings and MUST be bounded by the owning schema.
- **ACP-057:** Version comparison MUST be numeric after canonical syntax validation, never lexical.
- **ACP-058:** Unknown, future, retired, or lower-than-required versions MUST reject without fallback.

## 8. Hashing and content identity

- **ACP-059:** SHA-256 MUST operate on the exact canonical byte sequence defined for the field or artifact.
- **ACP-060:** Hash input boundaries and purposes MUST be explicit; concatenation without domain and length framing MUST NOT be used.
- **ACP-061:** Payload digest MUST equal SHA-256 of canonical payload bytes.
- **ACP-062:** Protected-header digest MUST equal SHA-256 of canonical protected-header bytes when such a digest is carried.
- **ACP-063:** Envelope identifier MUST equal SHA-256 of the canonical complete envelope, including the canonical signature set.
- **ACP-064:** Digests MUST be recomputed and compared in constant-time where the implementation boundary supports it.
- **ACP-065:** A digest match MUST NOT substitute for signature, schema, freshness, authorization, lifecycle, or trust-chain verification.
- **ACP-066:** A digest from an untrusted producer is a claim until independently recomputed.
- **ACP-067:** Hash failure, unavailable approved implementation, or inconsistent recomputation MUST fail closed.
- **ACP-068:** SHA-1, MD5, truncated SHA-256, platform hashes, and non-cryptographic hashes MUST NOT be accepted.

## 9. Domain separation and signature input

The exact v1 domain tag is the 38 ASCII octets:

**OpenClaw-Authority-Anchor-Signature-v1**

The signature input is:

1. the exact domain-tag octets;
2. one zero octet;
3. an unsigned 64-bit big-endian length of canonical protected-header bytes;
4. canonical protected-header bytes;
5. an unsigned 64-bit big-endian length of canonical payload bytes;
6. canonical payload bytes.

- **ACP-069:** Pure Ed25519 MUST sign and verify the exact signature input above.
- **ACP-070:** The domain tag, zero separator, length widths, byte order, and component order MUST be exact.
- **ACP-071:** The protected header MUST include profile, schema, schema_version, purpose, environment, trust_domain, created_at, expires_at or null, nonce, payload_digest, epoch, sequence, and predecessor identifier or null.
- **ACP-072:** The payload digest in the protected header MUST be verified against the canonical payload before signature verification is reported successful.
- **ACP-073:** Purpose, environment, trust domain, schema, and version MUST be independently checked against expected policy after cryptographic verification.
- **ACP-074:** The same key MUST NOT sign another protocol or purpose under this domain tag.
- **ACP-075:** Raw payload bytes, a payload digest alone, display JSON, or an implementation-specific object representation MUST NOT be signed as the v1 authority-anchor message.
- **ACP-076:** Length overflow, allocation overflow, component truncation, extra bytes, or alternate framing MUST reject.

## 10. Signed-envelope structure

A v1 envelope contains exactly three top-level properties:

| Property   | Value                                                          |
| ---------- | -------------------------------------------------------------- |
| protected  | Restricted-model object containing all signature-bound context |
| payload    | Schema-defined restricted-model value                          |
| signatures | Canonically sorted array of signature entries                  |

Each signature entry contains exactly:

| Property  | Value                                                     |
| --------- | --------------------------------------------------------- |
| key_id    | Canonical Ed25519 key identifier                          |
| signature | Unpadded base64url encoding of exactly 64 signature bytes |

- **ACP-077:** The envelope MUST contain no unknown top-level or signature-entry properties.
- **ACP-078:** Every signature entry MUST verify the same exact protected header and payload signature input.
- **ACP-079:** Signature entries MUST be sorted by key_id in ascending unsigned ASCII byte order.
- **ACP-080:** Duplicate key identifiers or duplicate public keys MUST reject the complete envelope.
- **ACP-081:** Signature order MUST NOT affect quorum semantics, but non-canonical order MUST reject the encoded envelope.
- **ACP-082:** Removing, adding, or replacing a signature MUST change the complete-envelope identifier.
- **ACP-083:** An empty signature array MUST remain proposed or unsigned and MUST NOT verify as authoritative.
- **ACP-084:** Detached, embedded, streaming, and compact alternate representations are not supported by v1.

## 11. Ed25519 verification requirements

- **ACP-085:** A verifier MUST accept only 32-byte Ed25519 public keys and 64-byte signatures.
- **ACP-086:** Public-key and signature decoding MUST enforce RFC 8032 canonical encodings and reject invalid or non-canonical points and scalars.
- **ACP-087:** Verification MUST reject small-order public keys, invalid points, non-canonical S values, and signatures inconsistent with the approved RFC 8032 verification equation.
- **ACP-088:** A verifier MUST use an independently reviewed Ed25519 implementation and MUST NOT implement curve arithmetic ad hoc.
- **ACP-089:** Verification MUST be resistant to timing and other practical side channels at the implementation boundary.
- **ACP-090:** Batch verification MAY be used only if it is at least as strict as individual verification and cannot convert an invalid individual signature into success.
- **ACP-091:** Qualifying quorum MUST count distinct eligible key identifiers only after each signature independently verifies.
- **ACP-092:** Cryptographic success from an expired, revoked, suspended, superseded, compromised, wrong-purpose, or wrong-environment key MUST reject authority.
- **ACP-093:** Key-generation, storage, custody, and signing implementations remain subject to the separately approved ceremony and custody profile.
- **ACP-094:** No private key, seed, expanded secret, recovery material, or signing intermediate MAY appear in an envelope, vector, log, model context, tool, or documentation.

## 12. Quorum and signature-set semantics

- **ACP-095:** Required signer sets and thresholds MUST come from current verified authority policy, not from the envelope.
- **ACP-096:** Extra valid signatures MUST NOT compensate for a missing required role, signer class, or independence constraint.
- **ACP-097:** Ineligible and invalid signatures MUST NOT count and SHOULD be reported using sanitized reason codes.
- **ACP-098:** An unknown key identifier MUST reject that signature and MUST cause the envelope to fail when quorum or policy cannot still be proven exactly.
- **ACP-099:** Quorum evaluation MUST bind the exact envelope identifier, authority epoch, sequence, purpose, environment, and trusted time.
- **ACP-100:** A signature copied between envelopes, payloads, profiles, schemas, purposes, environments, or trust domains MUST fail.
- **ACP-101:** Threshold policy ambiguity or unavailable key eligibility state MUST fail closed.
- **ACP-102:** The signature set MUST NOT convey delegation or mutation confirmation unless a separate governing schema and policy explicitly says so.

## 13. Algorithm agility and downgrade prevention

- **ACP-103:** Algorithm agility MUST use a new owner-approved profile identifier and explicit compatibility policy.
- **ACP-104:** A successor profile MUST define activation, coexistence, rotation, revocation, test vectors, and retirement of the predecessor.
- **ACP-105:** Negotiation MUST NOT select the first, oldest, common, client-preferred, or library-default algorithm.
- **ACP-106:** Clients and envelopes MUST NOT choose the verifier profile.
- **ACP-107:** Unknown profiles and algorithms MUST reject and MUST NOT be reinterpreted as v1.
- **ACP-108:** A verifier MUST maintain a policy-controlled minimum profile and highest-seen state where required to prevent rollback.
- **ACP-109:** Reinstallation, restore, offline operation, or partial deployment MUST NOT re-enable a retired profile.
- **ACP-110:** Mixed-profile quorum MUST reject unless a separately approved transition profile defines exact cross-signing semantics.
- **ACP-111:** Deprecation MUST occur before known security or platform limits make the profile unsafe.
- **ACP-112:** Emergency algorithm retirement MUST fail closed even when it makes anchor-dependent operations unavailable.

## 14. Parsing, limits, and denial-of-service controls

- **ACP-113:** Parsing MUST be bounded before canonicalization, hashing, or signature verification.
- **ACP-114:** The implementation profile MUST set maximum encoded bytes, decoded bytes, nesting depth, properties, array entries, string bytes, signatures, and candidate keys.
- **ACP-115:** Limit values MUST be policy-controlled, versioned, and no weaker than the schema bounds.
- **ACP-116:** Oversize input MUST reject before allocation proportional to untrusted claimed lengths.
- **ACP-117:** A length prefix larger than available bytes, implementation limits, or unsigned 64-bit range MUST reject.
- **ACP-118:** Verification work MUST be bounded so invalid signature floods cannot starve authoritative processing.
- **ACP-119:** Error responses MUST distinguish stable sanitized reason classes without exposing sensitive key, parser, or timing details.
- **ACP-120:** Resource exhaustion, parser disagreement, or dependency failure MUST report unavailable or rejected, never success.

## 15. Compatibility and test-vector contract

The normative compatibility corpus MUST include:

| Vector family    | Required coverage                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------------- |
| RFC 8032         | Published Ed25519 positive vectors and altered negative cases                                  |
| RFC 8785         | Property ordering, escaping, Unicode, and numeric rejection                                    |
| Restricted model | Number tokens, duplicate names, normalization, unknown fields, depth, and limits               |
| Base64url        | Valid unpadded values and padding, alphabet, length, and pad-bit rejection                     |
| Timestamp        | Exact UTC success and offset, fraction, case, leap-second, and calendar failures               |
| Identifier       | Canonical key and digest identifiers plus case, prefix, and length failures                    |
| Framing          | Exact domain tag, zero separator, lengths, order, truncation, and trailing bytes               |
| Envelope         | Property set, signature order, duplicates, payload digest, and complete identifier             |
| Signature        | Valid, altered message, altered signature, invalid point, non-canonical scalar, and wrong key  |
| Context          | Purpose, environment, trust domain, schema, profile, epoch, sequence, and predecessor mismatch |
| Agility          | Unknown, downgraded, retired, mixed, and partially deployed profiles                           |
| Cross-platform   | Identical canonical bytes, digests, signature input, and decisions on every supported verifier |

Normative serialization examples:

| Input                                                     | Required result                                 |
| --------------------------------------------------------- | ----------------------------------------------- |
| Object with properties b then a and string values 2 and 1 | Canonical bytes are {"a":"1","b":"2"}           |
| Bytes FB FF                                               | Base64url text is -\_8                          |
| Timestamp 2026-08-05T12:34:56Z                            | Accepted syntax, subject to trusted-time policy |
| Timestamp 2026-08-05T12:34:56.0Z                          | Rejected because fractional seconds are not v1  |
| Decimal string 0                                          | Accepted unsigned integer syntax                |
| Decimal string 00                                         | Rejected because of a leading zero              |

- **ACP-121:** A normative vector record MUST identify vector version, profile, schema, input octets, expected canonical octets, expected digests, expected decision, and reason code.
- **ACP-122:** Signature vectors MUST use published non-secret test material or separately approved synthetic material and MUST never use operational keys.
- **ACP-123:** Positive and single-variable negative vectors MUST be immutable and content-addressed.
- **ACP-124:** Every supported implementation MUST produce identical canonical bytes, digests, signature inputs, and verification decisions for the corpus.
- **ACP-125:** A library upgrade, platform change, parser change, Unicode change, or crypto-provider change MUST rerun the complete corpus before eligibility.
- **ACP-126:** A mismatch between implementations or vector versions MUST fail closed and block profile activation.
- **ACP-127:** Examples without complete expected octets and decisions MUST NOT be treated as normative vectors.
- **ACP-128:** This documentation task defines vector requirements and harmless serialization examples only; it does not generate keys, signatures, or executable tests.

## 16. Failure matrix

| Failure                                       | Required result                 |
| --------------------------------------------- | ------------------------------- |
| Missing profile or algorithm                  | Reject                          |
| Unknown or aliased profile                    | Reject                          |
| Alternate or downgraded algorithm             | Reject                          |
| JSON number token                             | Reject                          |
| Duplicate or unknown property                 | Reject                          |
| Invalid UTF-8 or non-NFC string               | Reject                          |
| Non-canonical JCS representation              | Reject                          |
| Padded or non-canonical base64url             | Reject                          |
| Invalid digest or key identifier              | Reject                          |
| Timestamp outside exact syntax                | Reject                          |
| Nonce wrong length or duplicate               | Reject                          |
| Digest mismatch                               | Reject before signature success |
| Domain or framing mismatch                    | Reject                          |
| Invalid key point or signature scalar         | Reject                          |
| Duplicate signer                              | Reject envelope                 |
| Quorum or eligibility ambiguity               | Fail closed                     |
| Cross-purpose or cross-environment reuse      | Reject and audit                |
| Unknown, retired, or restored-old profile     | Reject                          |
| Parser or implementation disagreement         | Fail closed                     |
| Resource or dependency exhaustion             | Unavailable or rejected         |
| Production input under Development profile    | Reject and security audit       |
| Operational key or signature in documentation | Stop and security review        |

## 17. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                                 |
| ------- | ------------------------------------------------------------------------------------------------------------------------------ |
| ACT-001 | Documentation approval cannot generate keys or signatures, activate an anchor, conduct a ceremony, or authorize Production.    |
| ACT-002 | A valid signature cannot independently authorize a mutation.                                                                   |
| ACT-003 | Only the exact v1 profile and pure Ed25519 are accepted.                                                                       |
| ACT-004 | Unknown, alternate, aliased, or downgraded algorithms fail closed.                                                             |
| ACT-005 | JSON numbers, duplicate properties, unknown properties, and invalid Unicode reject.                                            |
| ACT-006 | Independent implementations produce identical restricted JCS bytes.                                                            |
| ACT-007 | A non-canonical but semantically similar JSON representation rejects.                                                          |
| ACT-008 | Padded, alternate-alphabet, non-canonical, or wrong-length base64url rejects.                                                  |
| ACT-009 | Key and content identifiers bind exact bytes and reject aliases or case changes.                                               |
| ACT-010 | Timestamps accept only exact valid UTC second syntax.                                                                          |
| ACT-011 | Nonces decode to exactly 32 bytes and duplicate detection fails closed where required.                                         |
| ACT-012 | Decimal-string versions reject signs, leading zeros, fractions, exponents, and lexical comparison.                             |
| ACT-013 | SHA-256 digests bind the exact defined canonical bytes.                                                                        |
| ACT-014 | Domain tag, separators, lengths, ordering, truncation, or trailing-byte changes invalidate verification.                       |
| ACT-015 | Protected purpose, environment, trust domain, schema, profile, epoch, sequence, and predecessor are signature-bound.           |
| ACT-016 | Payload-digest mismatch rejects before signature success is reported.                                                          |
| ACT-017 | Envelope property, signature order, or signature-set changes alter canonical identity.                                         |
| ACT-018 | Empty, duplicate, invalid, or ineligible signatures cannot satisfy authority.                                                  |
| ACT-019 | Invalid points, small-order keys, non-canonical scalars, altered signatures, and wrong keys reject.                            |
| ACT-020 | Every qualifying signer verifies the same exact signature input.                                                               |
| ACT-021 | Quorum comes only from current verified policy and distinct eligible keys.                                                     |
| ACT-022 | A copied signature fails across payload, profile, purpose, environment, schema, or trust domain.                               |
| ACT-023 | Cryptographic success from revoked, expired, suspended, superseded, or compromised authority rejects.                          |
| ACT-024 | Client preference, library defaults, negotiation order, or restore cannot downgrade the profile.                               |
| ACT-025 | Mixed-profile quorum rejects without a separately approved transition profile.                                                 |
| ACT-026 | Bounded parsing rejects oversize or excessive-depth input before expensive work.                                               |
| ACT-027 | Length overflow, allocation pressure, parser disagreement, and dependency failure never become success.                        |
| ACT-028 | RFC and OpenClaw vector families produce identical cross-platform decisions.                                                   |
| ACT-029 | Operational material cannot enter vectors, logs, tools, model context, source control, or documentation.                       |
| ACT-030 | Development keys, signatures, profiles, and vectors cannot authorize Production.                                               |
| ACT-031 | Signature validity cannot bypass governing protocol controls.                                                                  |
| ACT-032 | Every accepted artifact links canonical bytes, digest, profile, key eligibility, signature result, policy, and audit evidence. |

No executable tests, keys, signatures, anchors, ceremonies, implementations, migrations, databases, deployments, or Production resources are created by this documentation task.

## 18. Requirement-to-test traceability

| Requirements            | Tests                                     |
| ----------------------- | ----------------------------------------- |
| ACP-001 through ACP-006 | ACT-001, ACT-002, ACT-029 through ACT-032 |
| ACP-007 through ACP-018 | ACT-003, ACT-004, ACT-024, ACT-028        |
| ACP-019 through ACP-030 | ACT-005 through ACT-007, ACT-012, ACT-026 |
| ACP-031 through ACP-040 | ACT-005 through ACT-007, ACT-013          |
| ACP-041 through ACP-048 | ACT-008, ACT-009                          |
| ACP-049 through ACP-058 | ACT-010 through ACT-012                   |
| ACP-059 through ACP-068 | ACT-013, ACT-016, ACT-032                 |
| ACP-069 through ACP-076 | ACT-014 through ACT-016, ACT-022          |
| ACP-077 through ACP-084 | ACT-017, ACT-018, ACT-020                 |
| ACP-085 through ACP-094 | ACT-018 through ACT-020, ACT-023, ACT-029 |
| ACP-095 through ACP-102 | ACT-018, ACT-020 through ACT-023          |
| ACP-103 through ACP-112 | ACT-004, ACT-024, ACT-025, ACT-030        |
| ACP-113 through ACP-120 | ACT-026, ACT-027                          |
| ACP-121 through ACP-128 | ACT-006, ACT-028, ACT-029                 |
| ACP-001 through ACP-128 | ACT-031, ACT-032                          |

## 19. Governing-document traceability

| Governing document                                                                                      | Profile requirements                             | Existing tests                   |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------- |
| External Authority Anchor EAA-001 through EAA-114                                                       | ACP-001 through ACP-128                          | EAT-001 through EAT-040          |
| Ceremony and Custody Profile CCR-001 through CCR-130                                                    | ACP-001 through ACP-018, ACP-041 through ACP-128 | CCT-001 through CCT-040          |
| Mutation and Proposal Contract MUT-001 through MUT-020                                                  | ACP-001 through ACP-006, ACP-059 through ACP-084 | Contract acceptance criteria     |
| Confirmation Policy CONF-001 through CONF-074 and CFM-001 through CFM-028                               | ACP-001 through ACP-006, ACP-069 through ACP-084 | Confirmation acceptance criteria |
| Atomic Transaction Design ATX-001 through ATX-069 and ATM-001 through ATM-030                           | ACP-001 through ACP-006, ACP-059 through ACP-084 | Transaction acceptance criteria  |
| Mutation Threat Model AMT-001 through AMT-040, AMR-001 through AMR-068, and AMTST-001 through AMTST-038 | ACP-001 through ACP-128                          | AMTST-001 through AMTST-038      |
| Identity and Delegation Policy IDP-001 through IDP-082 and IDT-001 through IDT-038                      | ACP-001 through ACP-018, ACP-069 through ACP-112 | IDT-001 through IDT-038          |
| Authoritative Mutation Protocol AMP-001 through AMP-090 and APT-001 through APT-040                     | ACP-001 through ACP-006, ACP-059 through ACP-120 | APT-001 through APT-040          |

## 20. Remaining implementation parameters

The v1 algorithm and wire-level choices above are normative. The following operational choices remain unresolved and MUST fail closed until separately approved.

| Decision                                              | Interim treatment                          | Required review           |
| ----------------------------------------------------- | ------------------------------------------ | ------------------------- |
| Approved Ed25519 library and version                  | No verifier or signer eligible             | Security                  |
| Validated-module or regulatory requirement            | Production remains unauthorized            | Owner and Security        |
| Hardware key support and non-exportability            | No operational key created                 | Owner and Security        |
| Approved random source and health tests               | No nonce or key generated                  | Security                  |
| Maximum envelope and field limits                     | No endpoint enabled                        | Architecture and Security |
| Trusted-time source and allowed skew                  | Freshness cannot be proven                 | Security                  |
| Nonce uniqueness store and retention                  | Uniqueness-dependent use blocked           | Architecture and Security |
| Exact authority-artifact schemas and purposes         | Unknown artifact rejects                   | Architecture and Security |
| Signer eligibility and quorum policy                  | No signature set authoritative             | Owner and Security        |
| Profile implementation assurance process              | No implementation eligible                 | Security                  |
| Immutable normative vector corpus                     | No implementation eligible                 | Architecture and Security |
| Unicode version and normalization implementation      | String verification unavailable            | Architecture and Security |
| Audit reason codes and sensitive-detail policy        | No operational audit accepted              | Owner and Security        |
| Algorithm transition and emergency retirement runbook | No successor profile active                | Owner and Security        |
| Production parameter approval                         | Production remains absent and unauthorized | Owner                     |

## 21. Explicit non-goals and future deliverables

This profile does not:

- generate, import, export, store, use, rotate, revoke, recover, or destroy a key, seed, signature, credential, nonce, or recovery material;
- create, activate, modify, verify operationally, or claim existence of an authority anchor;
- conduct, rehearse, schedule, authorize, or claim completion of a ceremony;
- implement a parser, canonicalizer, hasher, signer, verifier, key store, vector runner, API, service, configuration, or executable test;
- create operational or secret test vectors;
- approve a cryptographic library, hardware device, provider, custodian, signer, quorum, or Production profile;
- inspect, create, restore, rename, or modify Migration 009 or any database migration;
- access Development or Production runtimes, databases, SQL, containers, services, devices, key providers, or external operational systems;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- grant authority to any person, service, model, client, tool, automation, or provider.

Future work requires separate authorization and may include:

- an immutable non-secret normative compatibility-vector document;
- an implementation assurance and approved-library profile;
- a Development-only synthetic verifier design;
- an algorithm-transition and emergency-retirement profile;
- a Production parameter and ceremony plan, only if separately authorized.

No implementation, key generation, signature generation, ceremony, anchor activation, or Production work MAY begin from this profile alone.
