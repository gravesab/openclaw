---
title: "Authoritative Identity, Service Identity, and Delegation Policy v1"
summary: "Normative identity, service identity, capability, delegation, session, environment, revocation, and accountability policy for authoritative OpenClaw mutations"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-05"
category: "Architecture"
source_document: "AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md"
read_when:
  - Designing or reviewing human or service identity for an authoritative mutation
  - Defining capabilities, delegation, sessions, reauthentication, revocation, or environment binding
  - Evaluating automation, administrative, developer, CI/CD, recovery, model, tool, or client authority
---

# Authoritative Identity, Service Identity, and Delegation Policy v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-05

This policy extends the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1), and [Authoritative Mutation Threat Model v1](/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1). Those documents remain normative.

Policy requirements use stable **IDP** identifiers and acceptance tests use **IDT** identifiers. Examples are explanatory and do not grant authority.

## 1. Governing invariant

> AI proposes; deterministic rules validate; Andy, as owner, authorizes; OpenClaw records and audits.

Authentication establishes a server-verifiable principal. Authorization determines whether that principal may request an exact operation. Delegation narrows an authority source to a bounded delegate. Confirmation proves exact assent when separately required. None of these concepts substitutes for another.

- **IDP-001:** Only the authoritative OpenClaw server MAY establish an identity or authority context eligible for authoritative mutation.
- **IDP-002:** A model, provider, retriever, tool, client, automation, or external integration MUST NOT mint, select, expand, or assert authoritative identity or capability.
- **IDP-003:** Owner authority MUST be represented by server-verifiable identity and current policy, never by a name, message, client claim, model statement, device possession, network location, or retrieved document alone.
- **IDP-004:** Authentication, authorization, delegation, confirmation, and transaction admission MUST remain separate deterministic decisions.
- **IDP-005:** Missing, ambiguous, conflicting, expired, revoked, compromised, unavailable, or unverifiable identity or authority state MUST fail closed.
- **IDP-006:** Every committed mutation MUST link the effective principal, authority source, delegation when applicable, policy, confirmation class, transaction, and audit result.

## 2. Scope and security objectives

This policy governs identities that can propose, evaluate, confirm, authorize, administer, deploy, recover, or otherwise influence authoritative mutations across OpenClaw and PropertyManager.

The policy protects:

- principal authenticity and stable identity;
- least privilege and default denial;
- explicit separation of human, service, administrative, developer, deployment, and recovery identities;
- non-transferable sessions, capabilities, confirmations, and delegations;
- current revocation, expiration, policy, validator, environment, and target binding;
- accountable attribution without falsely treating client or model metadata as authority;
- credential and verification-material confidentiality;
- replay-resistant, concurrency-safe authority evaluation;
- Development and Production separation;
- atomic mutation and audit evidence;
- recoverability without silent authority restoration or fabricated attribution.

## 3. Identity and authority taxonomy

| Concept                 | Normative meaning                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Principal               | Server-recognized human or non-human identity with an immutable identifier.                                              |
| Human actor             | A natural person authenticated through an approved mechanism.                                                            |
| Owner                   | The human principal holding final product authority under current policy.                                                |
| Service identity        | Non-human principal representing one bounded workload, automation, integration, or service purpose.                      |
| Administrative identity | Separately scoped principal for infrastructure, identity, policy, or database administration.                            |
| Developer identity      | Principal permitted to perform approved Development work, not implied Production or business authority.                  |
| CI/CD identity          | Non-human principal bounded to approved artifact, environment, workflow, and promotion operations.                       |
| Recovery identity       | Separately governed principal for backup verification or restoration operations.                                         |
| Client context          | Verified application, device, session, channel, and instance metadata; context is not a principal by itself.             |
| Model participation     | Provider, model, and role metadata; it grants no identity, capability, delegation, or confirmation authority.            |
| Capability              | Server-policy permission for an exact operation and bounded resource scope.                                              |
| Delegation              | Server-issued record narrowing an existing authority source to a specific delegate and validity window.                  |
| Effective authority     | Intersection of current principal status, capabilities, delegation, environment, target, operation, session, and policy. |
| Anonymous context       | Request without an authenticated principal; it cannot perform authoritative mutation.                                    |

- **IDP-007:** Principal identifiers MUST be immutable, non-reassignable, and distinct from names, email addresses, phone numbers, device labels, or other mutable presentation fields.
- **IDP-008:** Human and service identities MUST remain different principal types even when controlled by the same person.
- **IDP-009:** Administrative, developer, CI/CD, recovery, and ordinary business identities SHOULD be separate when their privileges differ materially.
- **IDP-010:** A client, device, session, channel, IP address, network, host, process, model, or provider MUST NOT become a principal merely because it is recognized.

## 4. Authentication, authorization, delegation, and confirmation

| Decision       | Question                                                                                                          | Authority                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Authentication | Who or what is presenting this request now?                                                                       | Approved server verifier                     |
| Authorization  | May this principal request this operation on this target now?                                                     | Current deterministic server policy          |
| Delegation     | Has a valid authority source granted a narrower bounded scope to this delegate?                                   | Server-issued delegation plus current policy |
| Confirmation   | Has the eligible human confirmed the exact proposal when required?                                                | Canonical confirmation verifier              |
| Admission      | Are all proposal, provenance, identity, policy, concurrency, idempotency, and transaction requirements satisfied? | Authoritative mutation coordinator           |

- **IDP-011:** Successful authentication MUST NOT imply authorization, delegation, confirmation, or admissibility.
- **IDP-012:** Capability possession MUST NOT lower the confirmation class selected by current policy.
- **IDP-013:** Confirmation MUST NOT create identity, capability, delegation, or authorization.
- **IDP-014:** A delegation MUST NOT grant authority the delegator does not currently possess or authority prohibited by policy.
- **IDP-015:** The server MUST recompute effective authority at application time using current authoritative state.

## 5. Identity assurance and binding

The server MUST evaluate an identity-assurance profile appropriate to the operation. The profile MAY consider credential type, verifier strength, session age, reauthentication, device or channel binding, compromise status, and recovery history. The client MUST NOT select the profile or claim it is satisfied.

- **IDP-016:** Every operation class MUST define a minimum approved identity-assurance profile before enablement.
- **IDP-017:** An unknown or insufficient assurance profile MUST reject the operation without fallback to a weaker mechanism.
- **IDP-018:** Reauthentication MUST establish fresh identity evidence and MUST NOT silently extend confirmation or delegation.
- **IDP-019:** Device and session binding MAY strengthen identity evidence but MUST NOT replace principal authentication or authorization.
- **IDP-020:** Identity recovery MUST invalidate affected sessions, confirmations, delegations, and credentials according to separately approved policy.

Exact assurance levels and approved authenticators remain unresolved. Operations requiring an undefined profile remain blocked.

## 6. Principal lifecycle

| State       | Meaning                                                 | Mutation treatment                     |
| ----------- | ------------------------------------------------------- | -------------------------------------- |
| pending     | Enrollment is incomplete or unverified.                 | Prohibited                             |
| active      | Current identity evidence and policy permit evaluation. | Eligible for independent authorization |
| suspended   | Temporarily blocked pending review.                     | Prohibited                             |
| revoked     | Authority permanently withdrawn.                        | Prohibited and terminal                |
| expired     | Time-bounded identity ended.                            | Prohibited                             |
| compromised | Evidence indicates loss of control or integrity.        | Prohibited pending governed recovery   |
| archived    | Retained only for attribution and history.              | Prohibited                             |

- **IDP-021:** Enrollment MUST verify principal type, owner, purpose, environment, assurance profile, and accountable approver.
- **IDP-022:** Lifecycle transitions MUST be server-controlled, versioned, authorized, and audited.
- **IDP-023:** Suspension, revocation, expiration, or compromise MUST take effect for new admission immediately under current authoritative state.
- **IDP-024:** Principal deletion MUST NOT erase historical audit attribution; archived immutable identity references MUST remain.
- **IDP-025:** A revoked or archived identifier MUST NOT be reassigned.
- **IDP-026:** Recovery MUST create explicit evidence and MUST NOT rewrite the historical principal state as though compromise never occurred.

## 7. Human actor policy

- **IDP-027:** Human principals MUST use individual identities; shared human accounts SHOULD be prohibited.
- **IDP-028:** The server MUST bind authorization to the exact authenticated human principal, not an entered operator name.
- **IDP-029:** Owner-only authority MUST require current owner identity under the applicable assurance and confirmation policy.
- **IDP-030:** A human acting through a client, automation, administrator tool, or service MUST remain distinguishable from the executing service identity.
- **IDP-031:** Impersonation features MUST be prohibited unless separately governed with visible attribution, strict scope, and independent audit.
- **IDP-032:** A human rejection, cancellation, or revocation MUST NOT be converted into assent by a model, automation, delegate, or retry.

## 8. Service identity policy

Every service identity MUST represent one documented workload purpose. A service identity is not a synthetic human and does not inherit the authority of its operator.

Required service-identity record:

| Field                             | Required semantics                                                   |
| --------------------------------- | -------------------------------------------------------------------- |
| identity_format_version           | Exact supported schema version.                                      |
| service_identity_id               | Server-generated immutable identifier.                               |
| workload_name and purpose         | Human-readable bounded description; not authorization by itself.     |
| owning_principal or team          | Accountable owner for lifecycle and review.                          |
| environment                       | Exact Development, Production, recovery, or other approved boundary. |
| allowed_operations                | Stable operation identifiers only.                                   |
| resource_scope                    | Modules, resource types, immutable targets, or bounded selectors.    |
| client and channel constraints    | Approved invocation surfaces where policy requires.                  |
| credential or verifier reference  | Protected reference, never raw secret in the policy record.          |
| assurance_profile                 | Required verification and workload-attestation profile.              |
| issued_at, not_before, expires_at | Trusted server times and maximum lifetime.                           |
| policy_version                    | Exact governing policy version.                                      |
| rotation and review state         | Last rotation, next required rotation, and review evidence.          |
| status and revocation_version     | Current lifecycle state and monotonic revocation state.              |

- **IDP-033:** A service identity MUST use least privilege across operation, target, resource, module, environment, duration, and channel.
- **IDP-034:** Service identities MUST NOT share credentials with humans or other workloads.
- **IDP-035:** Service identities MUST NOT confirm CF-2 or CF-3 operations on behalf of a human.
- **IDP-036:** Service identities MUST NOT receive implicit capabilities from host location, process ownership, internal networking, deployment role, or access to another credential.
- **IDP-037:** Credential issuance, storage, rotation, revocation, and use MUST be individually attributable and audited without recording the secret.
- **IDP-038:** Expired, suspended, revoked, compromised, unknown, or unreviewed service identities MUST fail closed.
- **IDP-039:** Service-identity review MUST verify continued purpose, owner, environment, operations, targets, credentials, dependencies, and observed use.
- **IDP-040:** Unused or orphaned service identities SHOULD be suspended promptly and revoked after governed review.

## 9. Delegation contract

Delegation is optional and prohibited until its exact server-verifiable profile is approved. When enabled, the canonical delegation record MUST contain:

| Field                              | Required semantics                                                              |
| ---------------------------------- | ------------------------------------------------------------------------------- |
| delegation_format_version          | Exact supported version; unknown fields and versions reject.                    |
| delegation_id                      | Server-generated immutable identifier.                                          |
| delegator_principal_id             | Current authority source.                                                       |
| delegate_principal_id and type     | Exact human or service principal receiving narrower authority.                  |
| operation_scope                    | Stable allowlisted operations.                                                  |
| resource_scope                     | Exact modules, resource types, targets, or bounded selectors.                   |
| environment                        | One exact environment; cross-environment delegation is prohibited.              |
| constraints                        | Amount, count, time, channel, provenance, or other deterministic limits.        |
| not_before and expires_at          | Trusted-time validity window.                                                   |
| policy_version                     | Policy under which delegation was issued.                                       |
| assurance_profile                  | Required assurance for issuance and use.                                        |
| confirmation_treatment             | Explicit statement that confirmation remains independently governed.            |
| issuance_proposal and confirmation | Canonical issuance evidence when policy requires.                               |
| parent_delegation_id               | Absent by default; present only under separately approved non-transitive rules. |
| status and revocation_version      | Active, suspended, revoked, expired, or superseded plus monotonic version.      |
| issued_by, reason, and audit_id    | Accountable server-derived issuance evidence.                                   |

- **IDP-041:** Delegation MUST be explicit, server-issued, typed, bounded, time-limited, environment-bound, and auditable.
- **IDP-042:** Effective delegated authority MUST be the intersection of current delegator authority, delegate authority, delegation scope, operation policy, environment, target, assurance, and validity.
- **IDP-043:** Delegation MUST NOT be transitive, transferable, sublicensable, or renewable by the delegate unless a separately approved policy explicitly permits it.
- **IDP-044:** Delegation MUST NOT permit direct database writes, policy changes, identity administration, credential administration, Production action, destructive recovery, or CF-3 operations unless a separately approved stronger policy explicitly allows the exact class.
- **IDP-045:** Delegation issuance, amendment, renewal, suspension, revocation, and use MUST use optimistic concurrency or equivalent atomic version control.
- **IDP-046:** A material scope, principal, policy, assurance, target, environment, or validity change MUST create a new delegation identity or version and invalidate prior dependent confirmation.
- **IDP-047:** Delegation expiration or revocation MUST NOT be extended or bypassed by offline storage, replay, idempotency, client time, or cached policy.
- **IDP-048:** The delegate MUST NOT exercise authority after the delegator loses the underlying authority.
- **IDP-049:** Delegated requests MUST record both delegator and delegate without obscuring the executing service or initiating human.
- **IDP-050:** Ambiguous delegation state MUST block the affected operation.

## 10. Capability policy

A capability is a deterministic server-policy decision, not a bearer label supplied by a client.

- **IDP-051:** Capabilities MUST use stable operation identifiers and bounded target scopes.
- **IDP-052:** Unknown operation, resource, module, target, environment, or capability MUST default to deny.
- **IDP-053:** Capability evaluation MUST use current policy, principal state, delegation state, revocation, environment, and target version.
- **IDP-054:** Roles MAY group capabilities for administration, but the server MUST evaluate the resulting exact capabilities rather than trusting the role name.
- **IDP-055:** Conflicting allow and deny rules MUST use the approved deterministic precedence; absent an approved rule, deny wins.
- **IDP-056:** Bulk authority MUST be separately explicit and MUST NOT be inferred from authority over one item.
- **IDP-057:** Read authority MUST NOT imply proposal, confirmation, mutation, administrative, export, or recovery authority.
- **IDP-058:** Capability and policy changes MUST be versioned, reviewed, rollback-protected, and audited.

## 11. Sessions, devices, and reauthentication

- **IDP-059:** Sessions MUST bind one principal, verifier context, issuance time, expiry, revocation state, and environment.
- **IDP-060:** Session identifiers and device tokens MUST be unpredictable, protected, rotatable, and non-authoritative without server verification.
- **IDP-061:** Session theft, device loss, account recovery, credential rotation, or compromise MUST trigger policy-defined invalidation.
- **IDP-062:** Client clocks are advisory; trusted server time governs session, delegation, credential, and confirmation validity.
- **IDP-063:** A session from one principal, device context, environment, or assurance profile MUST NOT transfer authority to another.
- **IDP-064:** Long-lived or unattended sessions MUST NOT satisfy freshness or reauthentication requirements unless explicitly approved for the operation.

## 12. Credential and verification-material isolation

- **IDP-065:** Raw credentials, private keys, signing secrets, recovery secrets, and reusable verification material MUST be available only to the minimum approved verifier or workload.
- **IDP-066:** Credentials MUST NOT enter proposals, model prompts, retrieval context, tool arguments, client-visible audit, logs, dashboards, or source control.
- **IDP-067:** Credential references MUST NOT grant authority without current principal, policy, scope, environment, and revocation validation.
- **IDP-068:** Rotation MUST preserve exact key or verifier version evidence and MUST fail closed when prior-version treatment is uncertain.
- **IDP-069:** Cross-environment credential reuse MUST be prohibited.
- **IDP-070:** Suspected disclosure MUST trigger revocation or suspension, bounded incident evidence, and reissuance under approved recovery policy.

## 13. Models, tools, clients, automations, and integrations

Models, providers, retrievers, general-purpose tools, clients, and presentation layers are not principals for authoritative mutation. They MAY participate in proposal preparation and MAY carry server-issued opaque references, but MUST NOT receive reusable mutation credentials or select identity, capability, delegation, confirmation, or success.

Automations and integrations MAY use an approved service identity. Their model participation, tool execution, queue, and client context remain non-authoritative. Provider substitution MUST NOT change effective authority.

## 14. Administrative, developer, CI/CD, and recovery identities

- **IDP-071:** Administrative, developer, CI/CD, database, deployment, backup, and recovery identities MUST be purpose-specific, least-privilege, environment-bound, and separately accountable.
- **IDP-072:** Possession of infrastructure or database access MUST NOT be represented as ordinary business authorization.
- **IDP-073:** Debug, maintenance, migration, deployment, and recovery paths MUST NOT bypass the canonical mutation boundary or fabricate canonical audit.
- **IDP-074:** Break-glass authority MUST remain prohibited until separately approved with scope, assurance, confirmation, duration, monitoring, review, and recovery rules.
- **IDP-075:** CI/CD identities MUST bind approved artifact identity, source revision, workflow, target environment, and promotion authorization.
- **IDP-076:** Backup and recovery identities MUST NOT restore or reactivate identity, credential, delegation, confirmation, or replay state without consistency verification.

## 15. Development and Production separation

- **IDP-077:** Development and Production MUST use distinct identities, credentials, verifiers, sessions, delegations, capabilities, configuration, and audit contexts.
- **IDP-078:** A Development identity, client, automation, test, tool, or delegation MUST NOT authenticate or authorize against Production.
- **IDP-079:** Production authority MUST require separate explicit owner authorization and accepted Development evidence.
- **IDP-080:** Branch, worktree, repository, artifact, configuration, schema plan, environment, and target identity MUST be verified before any separately authorized Production action.
- **IDP-081:** Production data and credentials MUST NOT enter Development without separately governed authorization and protection.
- **IDP-082:** Migration 009, deployment, Production configuration, and Production access remain unauthorized by this policy.

## 16. Normative authority evaluation sequence

For every authoritative mutation attempt, the server MUST:

1. parse a bounded typed proposal and reject unknown fields or versions;
2. establish the presented credential and verifier context without exposing secrets;
3. resolve the immutable principal and principal type;
4. verify lifecycle state, assurance profile, session, trusted time, environment, and revocation;
5. load current capabilities and deterministic deny rules;
6. load and verify any delegation, delegator authority, scope, validity, and revocation;
7. calculate effective authority as the intersection of all applicable constraints;
8. validate proposal provenance, operation, resource, target, and handler allowlists;
9. determine confirmation class independently;
10. verify current confirmation when required;
11. recheck identity, authority, delegation, policy, validator, target versions, and idempotency inside the authoritative transaction;
12. atomically commit mutation and required identity, delegation, confirmation, idempotency, outbox, and audit evidence;
13. return or recover only the committed authoritative outcome.

No client, model, tool, cache, prior decision, role label, or internal network claim MAY skip a step.

## 17. Audit and atomic accountability

Every successful mutation audit MUST record or securely reference:

- immutable effective principal and principal type;
- initiating human, executing service identity, and authority source where applicable;
- delegation identity, version, delegator, delegate, and exact scope;
- capability, policy, validator, assurance, session, and environment versions;
- proposal, digest, provenance, operation, target, and expected/resulting versions;
- confirmation class and record when required;
- idempotency, transaction, correlation, and required outbox identities;
- stable outcome and trusted server time.

Identity, service-identity, capability, and delegation lifecycle changes MUST have immutable accountable audit. Required audit failure MUST roll back the governed change. Ordinary clients MUST NOT alter or delete identity or authority audit evidence.

## 18. Replay, concurrency, offline, and synchronization controls

Identity, delegation, session, confirmation, and capability decisions MUST use authoritative current state. Offline queues MAY store proposals but MUST NOT store continuing authority. Concurrent revocation and mutation MUST resolve under a documented atomic rule that prevents a mutation from committing with authority proven invalid at transaction evaluation. Idempotency MUST NOT preserve expired or revoked authority, though an identical retry MAY retrieve a result already committed while authority was valid.

Synchronization MUST NOT reactivate principals, credentials, sessions, capabilities, or delegations. Restored or replicated authority state MUST remain blocked until version, revocation, audit, trusted-time, and writer consistency are proven.

## 19. Fail-closed matrix

| Condition                                                       | Required result                         | Audit or evidence                                 |
| --------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------- |
| Unknown principal or type                                       | Reject without capability evaluation    | Stable identity_unknown reason                    |
| Invalid, expired, or unverifiable credential                    | Reject                                  | Verifier and correlation reference without secret |
| Suspended, revoked, expired, compromised, or archived principal | Reject                                  | Principal state and version                       |
| Insufficient or unknown assurance                               | Reject; do not downgrade                | Required and observed profile references          |
| Session or device mismatch                                      | Reject                                  | Bounded mismatch reason                           |
| Unknown operation, target, capability, or environment           | Deny                                    | Stable policy reason                              |
| Conflicting policy without approved precedence                  | Deny                                    | Policy versions and conflict reference            |
| Missing, invalid, expired, revoked, or superseded delegation    | Reject delegated authority              | Delegation identity and state                     |
| Delegator no longer holds authority                             | Reject                                  | Delegator, delegate, policy, and version          |
| Delegation scope or environment mismatch                        | Reject                                  | Exact requested and allowed scope                 |
| Transitive or transferred delegation                            | Reject                                  | Delegation chain evidence                         |
| Required confirmation missing or mismatched                     | Reject without consuming another record | Confirmation reason                               |
| Identity or delegation changes before commit                    | Conflict and re-evaluate                | Expected and current versions                     |
| Concurrent revocation and use                                   | At most one policy-consistent outcome   | Transaction and revocation ordering               |
| Idempotent retry after committed success                        | Return original outcome only            | Original identity and transaction evidence        |
| Replay after revocation before commit                           | Reject                                  | Current revocation evidence                       |
| Trusted-time failure                                            | Reject issuance and use                 | Protected time-health evidence                    |
| Credential or verifier compromise                               | Suspend or revoke affected authority    | Incident and lifecycle audit                      |
| Audit persistence failure                                       | Roll back governed change               | Sanitized audit_unavailable result                |
| Production request using Development authority                  | Reject and alert                        | Environment mismatch evidence                     |
| Model, tool, or client asserts identity or success              | Ignore claim and independently verify   | Participation metadata and result                 |
| Restored authority state is inconsistent                        | Disable affected mutation               | Recovery consistency report                       |
| Internal dependency unavailable                                 | Reject affected operation               | Sanitized dependency reason                       |
| Break-glass requested without approved policy                   | Reject                                  | Protected attempt audit                           |

## 20. Implementation-independent acceptance tests

| ID      | Required proof                                                                                                           |
| ------- | ------------------------------------------------------------------------------------------------------------------------ |
| IDT-001 | A client-supplied principal, role, capability, or authorization decision cannot establish authority.                     |
| IDT-002 | A model, provider, retriever, or general-purpose tool cannot obtain a mutation principal or credential.                  |
| IDT-003 | Anonymous and unknown principals cannot perform authoritative mutation.                                                  |
| IDT-004 | Mutable display labels cannot substitute for immutable principal identifiers.                                            |
| IDT-005 | Successful authentication without capability fails authorization.                                                        |
| IDT-006 | Capability without required confirmation cannot mutate.                                                                  |
| IDT-007 | Valid confirmation cannot cure failed authentication, authorization, delegation, or CF-0.                                |
| IDT-008 | Unknown or insufficient identity assurance fails without downgrade.                                                      |
| IDT-009 | Reauthentication does not extend proposal, confirmation, or delegation validity.                                         |
| IDT-010 | Suspended, revoked, expired, compromised, or archived principal fails closed.                                            |
| IDT-011 | Revoked identifiers cannot be reassigned and historical audit attribution remains intact.                                |
| IDT-012 | A service identity cannot act outside its operation, target, module, environment, duration, or channel scope.            |
| IDT-013 | Human and service identities cannot share one authoritative credential or principal identity.                            |
| IDT-014 | A service identity cannot satisfy human CF-2 or CF-3 confirmation.                                                       |
| IDT-015 | Host, process, network, or deployment location cannot grant implicit capability.                                         |
| IDT-016 | Orphaned, expired, unreviewed, or compromised service identity fails closed.                                             |
| IDT-017 | Delegation cannot grant authority absent from the current delegator.                                                     |
| IDT-018 | Delegation cannot transfer across delegate, operation, target, module, environment, or validity window.                  |
| IDT-019 | Transitive, sublicensed, or delegate-renewed authority fails without separately approved policy.                         |
| IDT-020 | Delegator revocation or authority loss invalidates delegated use.                                                        |
| IDT-021 | Delegation scope change creates a new identity or version and invalidates dependent confirmation.                        |
| IDT-022 | Concurrent delegation amendment, revocation, and use produces one policy-consistent outcome.                             |
| IDT-023 | Offline replay cannot extend or revive identity, session, capability, confirmation, or delegation authority.             |
| IDT-024 | Idempotency cannot authorize a new mutation after authority expires or is revoked.                                       |
| IDT-025 | Identical retry of an already committed result returns original attribution without mutating again.                      |
| IDT-026 | Wrong or stolen session, device context, assurance profile, or environment fails closed.                                 |
| IDT-027 | Credential rotation and retired verifier versions follow exact version policy or fail closed.                            |
| IDT-028 | Credentials and reusable verification material do not appear in prompts, tools, clients, logs, audit, or source control. |
| IDT-029 | Development identity, credential, session, client, test, or delegation cannot target Production.                         |
| IDT-030 | Production authority cannot be inferred from Development approval, branch, network, administrator, or deployment access. |
| IDT-031 | Debug, maintenance, migration, restore, or direct-database access cannot fabricate an ordinary authorized mutation.      |
| IDT-032 | Break-glass use remains blocked while its governing policy is unresolved.                                                |
| IDT-033 | Required identity or delegation audit failure rolls back the governed change.                                            |
| IDT-034 | Committed mutation audit links effective principal, authority source, delegation, policy, confirmation, and transaction. |
| IDT-035 | Restored inconsistent identity, revocation, delegation, or credential state cannot accept mutations.                     |
| IDT-036 | Unavailable identity, policy, verifier, trusted-time, delegation, audit, or revocation service blocks affected mutation. |
| IDT-037 | Concurrent multi-instance use of one service credential cannot bypass idempotency, confirmation, or revocation.          |
| IDT-038 | A client, model, tool, dashboard, or automation success claim cannot replace committed result proof.                     |

No executable tests are created by this documentation task.

## 21. Traceability

### 21.1 Requirement-to-test traceability

| Requirements                 | Tests                                                                                                |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| IDP-001 through IDP-006      | IDT-001 through IDT-003, IDT-005 through IDT-007, IDT-034, IDT-038                                   |
| IDP-007 through IDP-015      | IDT-001, IDT-004 through IDT-007, IDT-013                                                            |
| IDP-016 through IDP-020      | IDT-008 through IDT-010, IDT-026                                                                     |
| IDP-021 through IDP-026      | IDT-010, IDT-011, IDT-016, IDT-035                                                                   |
| IDP-027 through IDP-032      | IDT-004 through IDT-007, IDT-013, IDT-038                                                            |
| IDP-033 through IDP-040      | IDT-012 through IDT-016, IDT-027, IDT-028, IDT-037                                                   |
| IDP-041 through IDP-050      | IDT-017 through IDT-023, IDT-032                                                                     |
| IDP-051 through IDP-058      | IDT-001, IDT-005 through IDT-007, IDT-012, IDT-017, IDT-030                                          |
| IDP-059 through IDP-064      | IDT-009, IDT-010, IDT-023, IDT-026                                                                   |
| IDP-065 through IDP-070      | IDT-002, IDT-013, IDT-027, IDT-028, IDT-036                                                          |
| IDP-071 through IDP-076      | IDT-030 through IDT-035                                                                              |
| IDP-077 through IDP-082      | IDT-029 through IDT-032                                                                              |
| Normative sequence and audit | IDT-005 through IDT-007, IDT-017, IDT-022 through IDT-025, IDT-033, IDT-034, IDT-036 through IDT-038 |

### 21.2 Threat-to-requirement and test traceability

| Threats from the Authoritative Mutation Threat Model | Identity-policy requirements                                       | Tests                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------- |
| AMT-001 through AMT-004                              | IDP-001 through IDP-026, IDP-051 through IDP-064                   | IDT-001 through IDT-010, IDT-023 through IDT-026, IDT-038 |
| AMT-005 through AMT-009                              | IDP-002, IDP-010, IDP-065 through IDP-070                          | IDT-002, IDT-015, IDT-027, IDT-028, IDT-038               |
| AMT-010 through AMT-015                              | IDP-015, IDP-023, IDP-033 through IDP-050, IDP-059 through IDP-064 | IDT-012 through IDT-026, IDT-037                          |
| AMT-016 through AMT-020                              | IDP-009, IDP-027 through IDP-032, IDP-071 through IDP-082          | IDT-030 through IDT-034                                   |
| AMT-021 through AMT-023                              | IDP-020, IDP-026, IDP-070, IDP-076                                 | IDT-010, IDT-027, IDT-035, IDT-036                        |
| AMT-024 through AMT-028                              | IDP-015, IDP-023, IDP-045 through IDP-050                          | IDT-020 through IDT-025, IDT-033, IDT-034, IDT-037        |
| AMT-029 through AMT-032                              | IDP-004, IDP-011 through IDP-020, IDP-046                          | IDT-006 through IDT-010, IDT-021, IDT-026, IDT-027        |
| AMT-033 through AMT-036                              | IDP-006, IDP-024, IDP-026, IDP-049, IDP-066, IDP-070               | IDT-011, IDT-028, IDT-033, IDT-034, IDT-038               |
| AMT-037 through AMT-038                              | IDP-069, IDP-071 through IDP-082                                   | IDT-029 through IDT-032                                   |
| AMT-039 through AMT-040                              | IDP-005, IDP-017, IDP-038, IDP-050, IDP-068, IDP-070               | IDT-008, IDT-016, IDT-027, IDT-036                        |

## 22. Unresolved decisions and interim defaults

| Decision                                              | Affected identity or operation                  | Interim fail-closed treatment                                              | Owner              |
| ----------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------- | ------------------ |
| Identity-assurance levels and approved authenticators | All principals and operation classes            | Operation remains blocked without an approved sufficient profile           | Owner and Security |
| Owner identity enrollment and recovery                | Owner-only authority                            | No alternative identity may infer owner status                             | Owner and Security |
| Device and session binding strength                   | CF-2, CF-3, mobile, offline                     | Unverifiable binding rejects; device possession alone is insufficient      | Owner and Security |
| Human account recovery                                | Sessions, credentials, confirmation, delegation | Suspend affected authority until governed recovery completes               | Owner and Security |
| Service-identity issuance and maximum lifetime        | Automations and integrations                    | No service authority without explicit issuance profile                     | Owner and Security |
| Credential form, custody, rotation, and attestation   | Human and service identity                      | No custom or unverifiable mechanism; affected use blocked                  | Security           |
| Capability schema and deny precedence                 | Authorization                                   | Unknown or conflicting policy denies                                       | Owner and Security |
| Delegation enablement and schema                      | All delegation                                  | Delegation remains prohibited                                              | Owner and Security |
| Delegable operation classes                           | Business mutation                               | No operation is delegable by default                                       | Owner              |
| Delegation duration and scope limits                  | Delegated operations                            | Missing limit blocks issuance and use                                      | Owner and Security |
| Transitive delegation                                 | All delegates                                   | Prohibited                                                                 | Owner and Security |
| Delegated confirmation treatment                      | CF-2 and CF-3                                   | Delegation cannot satisfy confirmation                                     | Owner and Security |
| Administrative separation of duties                   | Identity, policy, database, deployment          | No self-approved bypass or direct business mutation                        | Owner              |
| Break-glass identity and procedure                    | Security, destructive, recovery, Production     | Prohibited                                                                 | Owner and Security |
| CI/CD workload identity and artifact attestation      | Deployment                                      | No Production promotion authority                                          | Owner and Security |
| Revocation propagation and concurrent-use ordering    | Multi-instance application                      | Recheck in authoritative transaction; ambiguity blocks                     | Security           |
| Identity and delegation audit integrity and retention | Audit and recovery                              | Required audit failure blocks change; unverifiable history blocks recovery | Owner and Security |
| Production identity authority and activation          | Production                                      | No Production identity use without separate explicit approval              | Owner              |
| Backup restoration of identity state                  | Recovery                                        | Restored authority remains disabled until consistency proof                | Owner and Security |
| Residual-risk acceptance                              | All identity classes                            | Only owner acceptance with security review may unblock documented risk     | Owner              |

## 23. Explicit non-goals

This policy does not:

- implement identity, authentication, authorization, service-identity, delegation, session, capability, confirmation, or audit code;
- create executable tests or configuration;
- create users, credentials, keys, roles, capabilities, service identities, delegations, or break-glass access;
- grant authoritative capability to a user, service, model, tool, client, automation, administrator, developer, or integration;
- define concrete database schema, DDL, API endpoints, cryptographic algorithms, or key custody;
- inspect or modify SQL or any migration, including Migration 009;
- create the external authority anchor;
- modify PropertyManager or another application;
- access Development or Production runtimes, databases, services, containers, or external providers;
- deploy, migrate, restart, reconfigure, promote, or access Production;
- begin implementation or the next architecture deliverable.

Implementation MUST NOT begin until applicable unresolved decisions receive owner and security approval.
