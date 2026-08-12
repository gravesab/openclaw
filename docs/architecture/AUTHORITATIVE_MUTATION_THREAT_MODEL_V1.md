---
title: "Authoritative Mutation Threat Model v1"
summary: "Canonical implementation-independent threat model for OpenClaw authoritative mutations, confirmations, transactions, audit, replay, recovery, and environment boundaries"
version: "1.0"
status: "Architecture Baseline"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-04"
category: "Architecture"
source_document: "AUTHORITATIVE_MUTATION_THREAT_MODEL_V1.md"
read_when:
  - Designing, reviewing, or testing an authoritative mutation path
  - Evaluating clients, models, tools, offline replay, service identities, administration, or recovery
  - Assessing confirmation, concurrency, idempotency, audit, Production, or fail-closed security boundaries
---

# Authoritative Mutation Threat Model v1

Version: 1.0
Status: Architecture Baseline
Owner: OpenClaw Architecture
Last Updated: 2026-08-04

This threat model extends the [Server-Enforced Mutation and Proposal Contract v1](/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1), [Canonical Confirmation Policy v1](/architecture/CANONICAL_CONFIRMATION_POLICY_V1), and [Atomic Authoritative Write and Audit Transaction Design v1](/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1). Those contracts remain normative. This document identifies threats, security requirements, and implementation-independent acceptance criteria without granting implementation or operational authority.

Threats use stable **AMT** identifiers, security requirements use **AMR** identifiers, and acceptance tests use **AMTST** identifiers. Examples and misuse cases do not grant authority.

## 1. Scope and security objectives

The principal objective is to prevent any authoritative mutation that is unauthorized, unconfirmed when required, improperly sourced, stale, duplicated, partially committed, unaudited, or falsely represented as successful.

| Objective               | Protected property                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Authenticity            | The server proves the actor, service identity, client context, and authoritative result.                                                     |
| Authorization           | Current deterministic policy permits the exact actor, operation, target, and scope.                                                          |
| Integrity               | Proposals, digests, versions, confirmations, state, audit, idempotency, and events cannot be substituted or partially applied.               |
| Confidentiality         | Credentials, verification material, protected evidence, personal data, and security internals remain least-privilege and minimally retained. |
| Availability            | Failure or attack may deny service but MUST NOT induce fail-open mutation.                                                                   |
| Provenance              | Evidence origin, integrity, version, and authorization remain bound and independently validated.                                             |
| Freshness               | Current identity, policy, validator, target, trusted time, and revocation state govern application.                                          |
| Replay resistance       | A request, proposal, confirmation, result, or restored state cannot authorize unintended repetition.                                         |
| Idempotency             | Identical retries resolve to one durable outcome; changed content cannot reuse identity.                                                     |
| Concurrency correctness | Races, stale versions, write skew, and multi-instance execution cannot violate invariants.                                                   |
| Confirmation integrity  | Confirmation is exact, single-use, current, non-transferable, and separate from admissibility.                                               |
| Atomic auditability     | Mutation, required audit, idempotency outcome, confirmation consumption, and required event commit together.                                 |
| Accountable evidence    | Protected evidence links actor, authority, proposal, confirmation, transaction, and result where required.                                   |
| Recoverability          | Recovery preserves truth without fabrication, replay, split brain, or rollback ambiguity.                                                    |
| Authority separation    | Authoritative records remain distinct from proposals, caches, projections, logs, dashboards, and offline copies.                             |

Missing, inconsistent, unavailable, compromised, or unverifiable authority state MUST fail closed.

## 2. Protected assets

| Class                 | Assets                                                                                                            | Authority classification                                                           |
| --------------------- | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Business state        | Authoritative records, relationships, deletions, completions, financial, safety, privacy, and configuration state | Authoritative                                                                      |
| Concurrency           | Resource versions, lock predicates, invariant state, and target manifests                                         | Authoritative                                                                      |
| Proposal              | Typed proposals, canonical representations, digests, provenance, policy and validator versions                    | Non-authoritative until accepted; identity metadata becomes authoritative evidence |
| Identity              | Actor authentication, sessions, roles, capabilities, delegations, revocations, and service identities             | Authority-bearing                                                                  |
| Confirmation          | Challenges, material-effect summaries, single-use records, bindings, and consumption state                        | Authority-bearing                                                                  |
| Replay control        | Idempotency scopes, keys or protected references, reservations, and durable outcomes                              | Authoritative                                                                      |
| Audit                 | Immutable audit records, integrity metadata, transaction and correlation identities                               | Authoritative evidence                                                             |
| Policy                | Operation matrix, authorization policy, validator versions, handler allowlists, and classifications               | Authority-bearing                                                                  |
| Provenance            | Evidence references, checksums, source identity, version, and authorization metadata                              | Authority-bearing evidence                                                         |
| Delivery              | Transactional outbox rows, stable event identities, ordering, and delivery state                                  | Authoritative delivery evidence                                                    |
| Cryptography and time | Verification material, key references, rotation state, trusted time, and expiry evidence                          | Authority-bearing                                                                  |
| Operations            | Administrative, developer, CI/CD, deployment, migration, configuration, and break-glass paths                     | Privileged control plane                                                           |
| Recovery              | Backups, checksums, restore manifests, snapshots, recovery audit, and disaster-recovery state                     | Potential authority source only after verified restoration                         |
| Derived state         | Projections, caches, search indexes, dashboards, synchronization queues, model context, logs, and offline copies  | Non-authoritative                                                                  |

A representation MUST NOT become authoritative because it is recent, signed by an untrusted client, displayed by a trusted UI, produced by a model, stored internally, or restored from backup.

## 3. Actors, identities, and assumed capabilities

| Actor or source                                                  | Assumed capability and trust posture                                                                               |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Authorized human                                                 | May request allowed operations; identity, authority, and confirmation remain server-verifiable and current.        |
| Unauthorized or unauthenticated human                            | May send arbitrary input and observe bounded public responses.                                                     |
| Compromised account                                              | Possesses some legitimate credentials but MUST NOT gain capabilities outside current policy.                       |
| Client or UI                                                     | May prepare proposals and display results; MUST NOT determine authority, policy, confirmation, or success.         |
| App Intent or device integration                                 | May initiate bounded proposals; device possession alone is not authority.                                          |
| Local or cloud model and provider                                | May produce inert typed suggestions; is untrusted and MUST NOT possess mutation credentials.                       |
| Retriever or knowledge store                                     | Supplies untrusted evidence candidates; content is data, never instruction or policy.                              |
| Tool or MCP-style integration                                    | Returns untrusted data or initiates bounded proposals; MUST NOT bypass the server boundary.                        |
| Automation or scheduler                                          | Uses explicit least-privilege identity and current policy; cannot confirm CF-2 or CF-3 for a human.                |
| Offline client or replay queue                                   | Retains non-authoritative drafts and attempts; cannot preserve obsolete authority or extend expiry.                |
| Synchronization service                                          | Reconciles only through canonical APIs and cannot choose winners authoritatively.                                  |
| Service identity                                                 | Is bounded by action, target, tenant or module, duration, environment, and policy.                                 |
| Administrator or infrastructure operator                         | Has privileged operational access but is not inherently authorized for business mutation.                          |
| Developer                                                        | May change Development artifacts under governance; is not inherently authorized for Production or direct mutation. |
| CI/CD or build identity                                          | May perform narrowly approved build or deployment steps; compromise is high impact.                                |
| Database, backup, or recovery operator                           | May control infrastructure but MUST follow separate accountable authorization and recovery policy.                 |
| External integration                                             | Is untrusted until authenticated, authorized, provenance-validated, and scoped.                                    |
| Malicious insider                                                | May combine legitimate access with intent to bypass accountability.                                                |
| Compromised dependency or service                                | May falsify input, responses, policy, time, delivery, or verification state.                                       |
| Multi-instance server                                            | Is mutually untrusted for process-local state; shared authoritative replay controls are required.                  |
| Network, device, log, backup, or partial-infrastructure attacker | May observe, delay, alter, replay, suppress, or restore partial state.                                             |

Administrator, developer, internal-network, service-identity, and model status MUST NOT imply mutation trust.

## 4. Trust boundaries and authoritative data flow

| Boundary | Crossing                                                             | Required treatment                                                                      |
| -------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| TB-01    | User or external actor to client                                     | Treat identity claims, device time, UI state, and content as untrusted.                 |
| TB-02    | Client, model, automation, tool, or integration to proposal boundary | Accept only bounded typed proposals; no authoritative success or policy claims.         |
| TB-03    | Proposal boundary to server admission                                | Reparse, authenticate, authorize, validate provenance, canonicalize, and classify.      |
| TB-04    | Server admission to authoritative transaction                        | Recheck mutable authority, policy, versions, confirmation, idempotency, and invariants. |
| TB-05    | Authoritative transaction to datastore                               | Use one controlled transaction, least-privilege role, constraints, and atomic evidence. |
| TB-06    | Commit to outbox and post-commit consumers                           | Consumers observe committed events only and remain idempotent and non-authoritative.    |
| TB-07    | Online service to offline queue and synchronization                  | Revalidate current authority, time, policy, confirmation, and versions on arrival.      |
| TB-08    | Development, administration, backup, and recovery                    | Require separate identities, approvals, evidence, environment binding, and audit.       |
| TB-09    | Development to Production                                            | Block without explicit owner authorization and accepted evidence.                       |
| TB-10    | External provider or integration                                     | Minimize disclosure, validate responses, bind provenance, and deny authority claims.    |

The canonical flow is: untrusted input becomes a typed proposal; server admission establishes current identity and eligibility; confirmation is issued and verified when policy requires; the transaction rechecks all mutable facts; mutation and required evidence commit atomically; the committed result is returned or recovered through durable idempotency; outbox consumers deliver post-commit effects. Eligibility for consideration is not authoritative acceptance, and acceptance is not commit.

## 5. Threat classification and risk method

This model uses STRIDE categories where useful: spoofing, tampering, repudiation, information disclosure, denial of service, and elevation of privilege. Every threat also receives an OpenClaw effect classification:

- authority bypass;
- identity substitution or capability escalation;
- proposal, digest, provenance, policy, validator, or trusted-time tampering;
- confirmation theft, substitution, replay, or double consumption;
- idempotency collision, concurrency exploitation, or offline replay;
- audit suppression, partial transaction, or direct database mutation;
- derived-state authority confusion;
- credential disclosure, administrative misuse, service-identity overreach, or cross-environment contamination;
- backup, restoration, infrastructure, or availability failure intended to induce fail-open behavior.

Risk is qualitative and considers exploitability, authoritative impact, detectability, recoverability, blast radius, privacy, financial, safety and security sensitivity, survival of atomic evidence, and fail-open potential.

| Risk     | Meaning and required disposition                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Critical | Plausible authority bypass or broad irreversible impact with weak evidence or recovery. Affected operation MUST remain blocked.     |
| High     | Serious unauthorized, replayed, unaccountable, or cross-environment mutation. Mitigation and review MUST precede enablement.        |
| Medium   | Constrained impact or substantial prerequisites with preserved evidence. Explicit mitigation and residual-risk review are required. |
| Low      | Defense-in-depth weakness with narrow authoritative effect. Track and test; it MUST NOT weaken fail-closed behavior.                |

Numerical probability MUST NOT be invented. Unresolved high-impact threats block the affected operation.

## 6. Canonical threat register

Each row is normative. “Existing controls” references the three governing contracts. “Additional requirement” references this model. Open items remain blocked by the named owner.

| ID      | Threat and class                                                               | Actor/source                   | Entry and boundary            | Target and precondition                          | Attack or failure path and authoritative impact                                             | Existing controls                               | Additional requirement                                   | Risk and residual risk                         | Fail-closed response and evidence                                      | Tests                                      | Status and owner                            |
| ------- | ------------------------------------------------------------------------------ | ------------------------------ | ----------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------- |
| AMT-001 | Forged client authority or payload; spoofing/elevation                         | Client, attacker               | API, TB-01 to TB-03           | Identity, proposal; server accepts client claims | Client asserts authorization, confirmation class, or success and creates unauthorized state | Mutation contract sections 2 to 5               | AMR-001 to AMR-006                                       | Critical; credential compromise remains        | Reject; audit actor, request, reason, correlation                      | AMTST-001, AMTST-002, AMTST-004            | Controlled; Security                        |
| AMT-002 | Stale or tampered client state; tampering                                      | Client, device attacker        | Client cache, TB-01, TB-07    | Versions; stale cache or local edit              | Old or altered values overwrite current state                                               | Mutation contract section 9                     | AMR-007 to AMR-010                                       | High; conflict disclosure remains              | Version conflict; evidence links expected/current versions             | AMTST-011, AMTST-020                       | Controlled; Architecture                    |
| AMT-003 | Device, session, or UI deception; spoofing                                     | Thief, malicious client        | UI/session, TB-01             | Identity, confirmation                           | Stolen session or misleading summary confirms different effects                             | Confirmation policy sections 5 to 7             | AMR-011 to AMR-015                                       | Critical; social engineering remains           | Reauthenticate/bind/reject; preserve challenge and presentation digest | AMTST-005 to AMTST-008                     | Open binding decision; Owner/Security       |
| AMT-004 | Ambiguous retry or fabricated success; repudiation                             | Client, network failure        | Response path, TB-06 to TB-07 | Result; lost acknowledgement                     | Client retries or displays success without proven commit, causing duplicate or false state  | Atomic design sections 8 and 12                 | AMR-016 to AMR-019                                       | High; temporary unavailability remains         | Resolve authoritative idempotency state or block                       | AMTST-017, AMTST-018, AMTST-031            | Controlled; Architecture                    |
| AMT-005 | Prompt or retrieved-content injection; tampering                               | Attacker, poisoned source      | Model/retrieval, TB-02, TB-10 | Proposal, policy                                 | Malicious instructions become mutation or alter policy                                      | Mutation contract sections 2 and 11             | AMR-020 to AMR-023                                       | Critical; model deception remains              | Treat content as inert, reject unvalidated values                      | AMTST-003, AMTST-038                       | Controlled; AI Security                     |
| AMT-006 | Malicious artifact or provider compromise; supply chain                        | Provider, artifact author      | Retrieval/provider, TB-10     | Provenance, confidentiality                      | Corrupted manual or provider substitutes facts or exfiltrates context                       | Mutation contract provenance controls           | AMR-020 to AMR-025                                       | High; provider visibility remains              | Quarantine/unavailable; preserve checksum and source evidence          | AMTST-003, AMTST-032                       | Open assurance decision; Security           |
| AMT-007 | Hallucinated identity, permission, confirmation, or result; spoofing           | Model, retriever               | Proposal boundary, TB-02      | Identity and result                              | Fabricated authority is accepted as fact                                                    | Mutation contract sections 2 and 11             | AMR-001, AMR-020, AMR-026                                | Critical; output may remain persuasive         | Ignore claim, independently derive, record participation               | AMTST-001, AMTST-038                       | Controlled; Architecture                    |
| AMT-008 | Tool confusion, excessive authority, or direct mutation; elevation             | Tool, MCP server, model        | Tool call, TB-02 to TB-05     | Credentials, datastore                           | Tool substitutes target or receives direct write capability                                 | Mutation contract sole-boundary invariant       | AMR-001, AMR-022, AMR-027 to AMR-029                     | Critical; tool compromise remains              | Deny path and revoke capability; security telemetry                    | AMTST-001, AMTST-022                       | Controlled; Security                        |
| AMT-009 | Credential disclosure or cross-context replay; disclosure                      | Model provider, logs, tool     | TB-02, TB-10                  | Credentials, private data                        | Secrets enter prompts, outputs, logs, or another user context                               | All contracts prohibit secret exposure          | AMR-024 to AMR-029                                       | Critical; endpoint compromise remains          | Revoke, block, redact; incident evidence without secret                | AMTST-025, AMTST-032                       | Open custody decision; Security             |
| AMT-010 | Delayed automation after authority change; replay                              | Scheduler, compromised account | Automation, TB-02, TB-07      | Policy, identity                                 | Previously eligible work executes after revocation                                          | Confirmation policy section 9                   | AMR-030 to AMR-034                                       | High; queued volume remains                    | Reauthenticate and reauthorize current state                           | AMTST-020, AMTST-030                       | Controlled; Architecture                    |
| AMT-011 | Queue poisoning, duplicate, or out-of-order delivery; tampering                | Attacker, defect               | Queue, TB-07                  | Proposal, ordering                               | Inserted or reordered work changes outcome                                                  | Idempotency and versions in governing contracts | AMR-030 to AMR-036                                       | High; ordering complexity remains              | Reject unknown provenance and stale sequence                           | AMTST-010, AMTST-020, AMTST-021            | Open ordering profiles; Architecture        |
| AMT-012 | Replay across actor, device, operation, target, or environment                 | Attacker, offline client       | Replay, TB-07, TB-09          | Confirmation, idempotency                        | Valid material is transferred to another scope                                              | Confirmation policy sections 6 and 9            | AMR-011 to AMR-019, AMR-033                              | Critical; theft remains                        | Binding mismatch; consume nothing; audit scope                         | AMTST-007 to AMTST-010, AMTST-030          | Controlled; Security                        |
| AMT-013 | Synchronization conflict manipulation or derived divergence                    | Sync service                   | Sync, TB-07                   | Versions, projections                            | Sync chooses winner or presents cache as authoritative                                      | Mutation contract section 9                     | AMR-007, AMR-030, AMR-035 to AMR-037                     | High; stale display remains                    | Conflict and refresh from authoritative API                            | AMTST-021, AMTST-031                       | Controlled; Architecture                    |
| AMT-014 | Multi-instance duplicate, retry storm, or lost acknowledgement                 | Server fleet, network          | TB-04 to TB-07                | Idempotency, confirmation                        | Instances race and double apply or overload controls                                        | Atomic design sections 7 to 9                   | AMR-016 to AMR-019, AMR-038                              | Critical; availability loss remains            | Shared reservation, bounded retry, one outcome                         | AMTST-008, AMTST-010, AMTST-017, AMTST-030 | Controlled; Architecture                    |
| AMT-015 | Service-identity overreach or shared credentials; elevation                    | Service, operator              | API/admin, TB-03, TB-08       | Identity, capability                             | Broad identity mutates unrelated operation or target                                        | Mutation contract section 2                     | AMR-004, AMR-027 to AMR-029, AMR-039                     | Critical; host compromise remains              | Deny outside exact allowlist and environment                           | AMTST-022, AMTST-026                       | Open issuance policy; Owner/Security        |
| AMT-016 | Administrator direct database edit or control bypass                           | Administrator, insider         | DB/admin, TB-08 to TB-05      | Business state, audit                            | Manual write bypasses proposal, confirmation, and audit                                     | Sole API boundary and database defense in depth | AMR-001, AMR-040 to AMR-043                              | Critical; infrastructure root remains          | Block role; detect and quarantine unverifiable state                   | AMTST-023, AMTST-024                       | Open separation duties; Owner/Security      |
| AMT-017 | Policy, validator, or configuration downgrade                                  | Admin, dependency, attacker    | Control plane, TB-08          | Policy, validator                                | Old or malicious policy weakens admissibility or confirmation                               | Version binding in all contracts                | AMR-005, AMR-044 to AMR-046                              | Critical; authorized change risk remains       | Reject rollback/unversioned state; audit change                        | AMTST-012, AMTST-033                       | Open signing/integrity; Security            |
| AMT-018 | Developer debug or maintenance bypass and Production contamination             | Developer                      | Debug/admin, TB-08, TB-09     | Production state                                 | Convenience path bypasses controls or targets Production                                    | Development Directive                           | AMR-040 to AMR-043, AMR-047 to AMR-050                   | Critical; human error remains                  | Disable path; environment mismatch blocks                              | AMTST-027, AMTST-028                       | Controlled policy; Owner                    |
| AMT-019 | CI/CD compromise or unauthorized deployment/migration                          | Build identity, attacker       | Pipeline, TB-09               | Code, schema, config                             | Unreviewed artifact changes mutation controls or data                                       | Development Directive and confirmation matrix   | AMR-047 to AMR-051                                       | Critical; supply chain remains                 | Block deployment/migration; preserve artifact evidence                 | AMTST-028, AMTST-029                       | Open Production ceremony; Owner/Security    |
| AMT-020 | Break-glass, insider, destructive error, or false manual attribution           | Admin, operator                | Admin/recovery, TB-08         | State and evidence                               | Emergency access mutates or claims system authorization                                     | AI Governance and atomic audit                  | AMR-040 to AMR-043, AMR-052                              | Critical; privileged insider remains           | Separately governed strong confirmation or block                       | AMTST-023, AMTST-038                       | Open break-glass policy; Owner/Security     |
| AMT-021 | Backup alteration or stale restore                                             | Backup attacker, operator      | Restore, TB-08                | Recovery state                                   | Modified or old backup becomes current authority                                            | Restore Manifest verification                   | AMR-053 to AMR-057                                       | Critical; backup loss remains                  | Verify checksum, identity, date, snapshot, approval or block           | AMTST-030                                  | Open full reconciliation; Owner             |
| AMT-022 | Restore mismatch of audit, confirmation, idempotency, or outbox                | Recovery defect                | Restore, TB-08                | Atomic evidence                                  | Partial restore re-enables consumed authority or loses proof                                | Atomic design unresolved recovery decision      | AMR-053 to AMR-058                                       | Critical; historical reconciliation unresolved | Keep mutation disabled until consistency proof                         | AMTST-030, AMTST-034                       | Unresolved; Owner/Security                  |
| AMT-023 | Split-brain authority or unverified disaster recovery                          | Infrastructure failure         | Failover, TB-05, TB-08        | Datastore                                        | Multiple primaries or unverified copy accept mutations                                      | Atomic authoritative datastore rule             | AMR-053 to AMR-058                                       | Critical; regional design unresolved           | Fence writers and block until one authority proven                     | AMTST-030, AMTST-034                       | Unresolved; Owner/Security                  |
| AMT-024 | Lost update, write skew, or check-then-act race                                | Concurrent clients, defect     | Transaction, TB-04 to TB-05   | Versions, invariants                             | Concurrent valid-looking writes violate invariant                                           | Atomic design section 9                         | AMR-007 to AMR-010, AMR-038                              | Critical; contention remains                   | Conflict/serialization failure, no partial commit                      | AMTST-010, AMTST-011                       | Controlled; Architecture                    |
| AMT-025 | Concurrent confirmation or idempotency claim                                   | Multi-instance server          | Transaction, TB-04 to TB-05   | Confirmation, replay control                     | Two transactions claim the same authority                                                   | Atomic design sections 7 and 8                  | AMR-011 to AMR-019, AMR-038                              | Critical; availability remains                 | Atomic predicate/reservation, at most one winner                       | AMTST-008 to AMTST-010                     | Controlled; Architecture                    |
| AMT-026 | Partial transaction or missing required evidence                               | Defect, DB failure             | Transaction, TB-05            | State, audit, idempotency, confirmation, outbox  | Any required component commits without all others                                           | Atomicity invariant                             | AMR-059 to AMR-063                                       | Critical; storage failure remains              | Roll back all and return sanitized failure                             | AMTST-014 to AMTST-016, AMTST-034          | Controlled design; Architecture             |
| AMT-027 | Commit ambiguity, crash, failover, or corrupted transaction state              | Infrastructure                 | Commit, TB-05 to TB-06        | Result and evidence                              | Outcome becomes unknown or is misreported                                                   | Atomic design sections 8 and 12                 | AMR-016 to AMR-019, AMR-059 to AMR-063                   | Critical; temporary block remains              | Resolve authoritative result or failed-safe                            | AMTST-017 to AMTST-019                     | Controlled design; Architecture             |
| AMT-028 | Unauthorized direct write or insufficient isolation                            | Insider, defect                | DB, TB-05, TB-08              | Datastore                                        | Direct SQL or weak isolation violates protected invariant                                   | Sole API boundary and transaction design        | AMR-001, AMR-009, AMR-040, AMR-059                       | Critical; root access remains                  | Deny/detect; quarantine unverifiable records                           | AMTST-023, AMTST-034                       | Open DB role design; Security               |
| AMT-029 | Challenge substitution, misleading summary, or phishing                        | Malicious client, attacker     | Confirmation UI, TB-01        | Challenge                                        | User approves effects different from transaction                                            | Confirmation policy section 5                   | AMR-011 to AMR-015                                       | Critical; human deception remains              | Digest/binding mismatch; reject and preserve evidence                  | AMTST-006                                  | Open presentation assurance; Owner/Security |
| AMT-030 | Wrong actor, operation, target, digest, or version confirmation                | Attacker, defect               | Confirmation, TB-03 to TB-04  | Confirmation                                     | Record transfers to materially different request                                            | Confirmation policy sections 6 to 9             | AMR-011 to AMR-015                                       | Critical; stolen session remains               | Exact-binding rejection                                                | AMTST-005 to AMTST-007                     | Controlled; Security                        |
| AMT-031 | Expired, cancelled, superseded, or consumed confirmation replay                | Attacker, offline queue        | Replay, TB-07                 | Confirmation                                     | Terminal record is reused                                                                   | Confirmation policy lifecycle                   | AMR-011 to AMR-019                                       | Critical; DoS remains                          | Reject terminal record without mutation                                | AMTST-007, AMTST-020                       | Controlled; Architecture                    |
| AMT-032 | Cryptographic, policy, validator, time, or multi-instance confirmation failure | Dependency, attacker           | Verifier, TB-04, TB-10        | Verification state                               | Unverifiable or downgraded binding is accepted                                              | Confirmation policy sections 8 to 11            | AMR-011 to AMR-019, AMR-044 to AMR-046                   | Critical; key service outage remains           | Block issuance/consumption                                             | AMTST-008, AMTST-012, AMTST-013, AMTST-032 | Open crypto/time design; Security           |
| AMT-033 | Missing, fabricated, selectively omitted, or mismatched audit                  | Defect, insider                | Audit, TB-05                  | Audit evidence                                   | Success lacks truthfully linked evidence                                                    | Atomic design section 6                         | AMR-059 to AMR-066                                       | Critical; privileged storage attack remains    | Roll back or quarantine; never claim success                           | AMTST-014, AMTST-024, AMTST-034            | Open integrity mechanism; Security          |
| AMT-034 | Audit/log tampering, truncation, correlation or clock manipulation             | Admin, attacker                | Observability, TB-06, TB-08   | Evidence                                         | History is altered or events cannot be linked                                               | Atomic IDs and trusted time                     | AMR-044, AMR-064 to AMR-067                              | High; external evidence design unresolved      | Detect mismatch; block recovery conclusions                            | AMTST-013, AMTST-024                       | Open integrity/retention; Security          |
| AMT-035 | Secret or verification-material leakage in audit/logs                          | Defect, operator               | Logs, TB-06                   | Credentials, privacy                             | Sensitive material enables replay or disclosure                                             | Redaction requirements in all contracts         | AMR-024 to AMR-026, AMR-065                              | Critical; endpoint access remains              | Redact, revoke, incident response                                      | AMTST-025                                  | Controlled requirement; Security            |
| AMT-036 | Derived state or delivery failure misrepresented as authority                  | Dashboard, consumer            | Projection/outbox, TB-06      | Result, projection                               | Cache claims commit, rejection claims mutation, or delivery failure claims rollback         | Atomic design section 11                        | AMR-035 to AMR-037, AMR-062 to AMR-064                   | High; display lag remains                      | Label derived state; query authoritative result                        | AMTST-019, AMTST-031                       | Controlled; Architecture                    |
| AMT-037 | Development credentials or data cross environment                              | Developer, client              | TB-08 to TB-09                | Credentials, privacy                             | Development identity reaches Production or Production data reaches Development              | Development Directive                           | AMR-047 to AMR-051                                       | Critical; operator error remains               | Environment binding and denial; security audit                         | AMTST-026, AMTST-027                       | Controlled policy; Owner                    |
| AMT-038 | Branch, worktree, migration, test, or configuration confusion                  | Developer, CI                  | TB-08, TB-09                  | Deployment state                                 | Wrong lineage or test mutates Production; migration conflict changes schema                 | Development Directive                           | AMR-047 to AMR-051                                       | Critical; manual process remains               | Verify repo/branch/artifact/environment; block                         | AMTST-027 to AMTST-029                     | Open deployment control; Owner              |
| AMT-039 | Availability attack intended to induce fail-open                               | Attacker, outage               | Any boundary                  | Policy, key, time, DB                            | Exhaustion or dependency outage pressures bypass                                            | Fail-closed rules in all contracts              | AMR-006, AMR-038, AMR-068                                | High; service denial remains                   | Return unavailable and preserve state                                  | AMTST-032, AMTST-033                       | Controlled principle; Security              |
| AMT-040 | Compromised dependency or verification service                                 | Supply chain, operator         | TB-03, TB-04, TB-10           | Policy, keys, provenance, time                   | Dependency returns false authority or verification                                          | Versioning and independent validation           | AMR-005, AMR-023 to AMR-025, AMR-044 to AMR-046, AMR-068 | Critical; assurance unresolved                 | Reject unverifiable results and disable affected operation             | AMTST-012, AMTST-013, AMTST-032            | Open assurance; Security                    |

## 7. Client and device threat controls

Clients MUST NOT submit authoritative decisions, select confirmation class, bypass proposal creation, or claim success. The server MUST reject forged authority, stale versions, device-clock expiry, and offline replay after identity, policy, validator, confirmation, or target change. A displayed result MUST distinguish committed authoritative state from pending, cached, projected, rejected, or unknown state. Session theft, shared devices, malicious App Intents, confirmation-text mismatch, local-state tampering, and ambiguous retry map to AMT-001 through AMT-004, AMT-012, AMT-029 through AMT-032, and AMT-036.

## 8. Model, provider, retrieval, and tool threat controls

Models and providers MUST return only inert typed proposals. They MUST NOT possess authoritative credentials, select capabilities, consume confirmation, open the authoritative transaction, or directly mutate state. Retrieved manuals, knowledge, web content, and tool responses MUST remain untrusted evidence candidates; instructions embedded within them MUST remain inert. Proposal values, source identity, checksums, authorization, and provenance MUST be independently validated. Cross-user context, provider compromise, hallucinated commands, fabricated identity or success, tool-call substitution, replayed output, and retrieval poisoning map to AMT-005 through AMT-009 and AMT-040.

## 9. Automation, offline, replay, and synchronization threat controls

Automation requires an explicit service identity and current allowlist. Offline storage MUST NOT extend proposal or confirmation validity or preserve obsolete authority. Replayed work MUST bind actor, device where required, operation, target, environment, proposal digest, versions, policy, validator, and idempotency identity. Queues and synchronization MUST NOT choose authoritative conflict winners, and multi-instance processors MUST share durable replay controls. These threats map to AMT-010 through AMT-014 and AMT-031.

## 10. Administrator, developer, and service-identity threat controls

Privileged actors MUST use individual, least-privilege, environment-bound identities. Shared credentials SHOULD be prohibited. Business mutation, database administration, deployment, backup, and security policy SHOULD use separation of duties. Break-glass access MUST be separately governed, strongly authenticated, time bounded, independently reviewed, and audited; absent that policy, it is prohibited. Debug, maintenance, CI/CD, direct-database, manual-repair, and recovery paths MUST NOT claim ordinary system authorization. These threats map to AMT-015 through AMT-023, AMT-037, and AMT-038.

## 11. Transaction, concurrency, and datastore threat controls

Lost updates, write skew, check-then-act races, confirmation double-use, concurrent idempotency claims, partial mutation, audit-only records, consumed confirmation without mutation, mutation without durable idempotency, omitted required outbox rows, commit ambiguity, failover, corruption, restore replay, unauthorized writes, and insufficient isolation MUST be handled exactly as required by the Atomic Authoritative Write and Audit Transaction Design. These threats map to AMT-024 through AMT-028 and AMT-033.

## 12. Confirmation-specific threat controls

Challenge substitution, misleading effects, phishing, wrong actor or device/session, proposal/digest/operation/target/version mismatch, expiration, cancellation, supersession, consumption replay, cryptographic failure, policy or validator change, trusted-clock failure, multi-instance double-use, and attempts to override failed authorization or CF-0 MUST follow the Canonical Confirmation Policy. Confirmation proves only exact assent and MUST NOT make an inadmissible operation admissible. These threats map to AMT-003, AMT-012, AMT-025, and AMT-029 through AMT-032.

## 13. Audit, observability, and evidence threat controls

A successful mutation MUST link proposal, digest, actor, authority, policy, validator, provenance, confirmation when required, idempotency, versions, transaction, result, and required outbox event. Required audit failure MUST roll back mutation. Rejection evidence MUST NOT imply commit. Logs, metrics, traces, projections, and dashboards MUST NOT become alternative authority sources. Correlation identifiers are routing evidence, not authority, and sensitive data MUST be redacted. These threats map to AMT-033 through AMT-036.

## 14. Backup, restoration, and disaster-recovery threat controls

Restore MUST verify archive integrity, checksum, date, host and environment, branch or artifact identity, available storage, safety snapshot, and explicit operator confirmation. A restored datastore MUST NOT accept mutations until audit, confirmations, idempotency, policies, validators, outbox, versions, trusted time, and writer fencing are proven mutually consistent. Stale authority, consumed confirmations, completed idempotency keys, policy rollback, split brain, unverified backups, missing recovery audit, confidentiality compromise, and bypass of admission map to AMT-021 through AMT-023. Full authoritative recovery reconciliation remains unresolved and blocked.

## 15. Development and Production separation

Development credentials MUST NOT authenticate to Production. Production data MUST NOT be copied into Development without separately governed sanitization and authorization. Development clients, tests, branches, worktrees, debug tools, migrations, schemas, configuration, and artifacts MUST NOT target or alter Production without explicit owner authorization and accepted evidence. Repository, branch, commit, artifact, environment, credentials, and target MUST be verified before any future Production action. Migration 009 remains untouched and unauthorized. These threats map to AMT-018, AMT-019, AMT-037, and AMT-038.

## 16. Abuse and misuse cases

| Case                                       | Prevention and detection                           | Required evidence and recovery                                           | Test                 |
| ------------------------------------------ | -------------------------------------------------- | ------------------------------------------------------------------------ | -------------------- |
| Model attempts direct mutation             | No credentials or direct handler; deny and alert   | Model participation, attempted operation, stable denial; no state change | AMTST-001            |
| Client presents authorization              | Server derives current decision                    | Actor, proposal, policy, denial; client must repropose                   | AMTST-004            |
| Automation replays expired confirmation    | Trusted-time and terminal-state check              | Confirmation and replay references; no consumption                       | AMTST-007, AMTST-020 |
| Compromised administrator edits data       | DB role separation and anomaly detection           | Quarantine unverifiable record; accountable recovery                     | AMTST-023            |
| Developer targets Production               | Environment-bound identity and target gate         | Denial with repo/artifact/environment evidence                           | AMTST-027            |
| Service identity exceeds class             | Exact action and target allowlist                  | Identity, requested scope, denial, revocation review                     | AMTST-022            |
| Retriever injects instruction              | Retrieved content remains inert                    | Provenance, source checksum, validation denial                           | AMTST-003            |
| Two servers consume one confirmation       | Shared atomic state predicate                      | One transaction and one consumption or none                              | AMTST-008            |
| Client retries after lost response         | Durable idempotency lookup                         | Original transaction/result returned                                     | AMTST-018            |
| Audit write fails after mutation begins    | One atomic transaction                             | Full rollback and audit-unavailable reason                               | AMTST-014            |
| Backup restores inconsistent replay state  | Restore consistency gate                           | Mutation disabled until proof or corrective governed restore             | AMTST-030            |
| Dashboard presents projection as authority | Explicit derived labeling and authoritative lookup | Projection version and authoritative result                              | AMTST-031            |
| Policy or validator downgrade              | Monotonic approved versions and binding            | Rejection and protected control-plane audit                              | AMTST-012            |
| Direct payload lacks proposal provenance   | Typed proposal and provenance required             | Stable rejection without handler invocation                              | AMTST-002            |

## 17. Security requirements

- **AMR-001:** Only the authoritative API MAY coordinate an authoritative mutation.
- **AMR-002:** Every mutation MUST begin from a bounded typed proposal with server-verified provenance.
- **AMR-003:** Clients and non-authoritative systems MUST NOT assert successful commit or authority.
- **AMR-004:** The server MUST independently authenticate and authorize human and service identities for the exact scope.
- **AMR-005:** Current versioned policy, validator, handler, and operation classification MUST be verified at application.
- **AMR-006:** Missing, conflicting, compromised, unavailable, or unverifiable authority state MUST fail closed.
- **AMR-007:** Every mutable target MUST carry an expected version or equivalent atomic precondition.
- **AMR-008:** Stale state MUST conflict and MUST NOT be silently merged or rebased.
- **AMR-009:** Multi-row invariants MUST use approved isolation and locking that prevents write skew.
- **AMR-010:** Derived and cached state MUST remain visibly non-authoritative.
- **AMR-011:** Confirmation MUST remain separate from admissibility and authorization.
- **AMR-012:** Required confirmation MUST bind exact actor, proposal, digest, operation, target, versions, policy, validator, and context.
- **AMR-013:** Confirmation MUST be current, single-use, non-transferable, and verified at application.
- **AMR-014:** Material-effect presentation MUST be bound to the confirmed canonical proposal.
- **AMR-015:** CF-0 and unresolved CF-3 MUST remain blocked regardless of confirmation.
- **AMR-016:** Durable idempotency MUST bind identity, operation, environment, proposal, target set, and confirmation when applicable.
- **AMR-017:** Identical replay MUST return one original outcome; changed content under the same key MUST fail.
- **AMR-018:** Ambiguous outcomes MUST be resolved from authoritative state before retry or confirmation reuse.
- **AMR-019:** Shared replay controls MUST prevent multi-instance duplicate mutation and confirmation consumption.
- **AMR-020:** Models, providers, retrievers, and tools MUST produce only non-authoritative data or proposals.
- **AMR-021:** Prompt and retrieved-content instructions MUST remain inert.
- **AMR-022:** Models and general-purpose tools MUST NOT receive authoritative mutation credentials or direct transaction capability.
- **AMR-023:** Proposal values and evidence MUST receive deterministic server validation.
- **AMR-024:** External disclosure MUST be minimum necessary and policy authorized.
- **AMR-025:** Provider, dependency, artifact, and provenance identity and integrity MUST be verifiable.
- **AMR-026:** Secrets and reusable verification material MUST NOT enter prompts, outputs, logs, audit, or ordinary clients.
- **AMR-027:** Service identities MUST use least privilege and exact action, target, module, duration, and environment bounds.
- **AMR-028:** Shared credentials SHOULD be prohibited; identity use MUST remain individually accountable.
- **AMR-029:** Identity issuance, rotation, revocation, and compromise response MUST be governed and auditable.
- **AMR-030:** Offline, automation, queue, and synchronization work MUST pass all current server checks on arrival.
- **AMR-031:** Offline state MUST NOT extend expiry or preserve revoked authority.
- **AMR-032:** Queue provenance, ordering, size, and retry MUST be bounded and validated.
- **AMR-033:** Replay material MUST NOT transfer across actor, device where bound, operation, target, or environment.
- **AMR-034:** Automations MUST NOT satisfy human confirmation requirements.
- **AMR-035:** Synchronization MUST NOT select an authoritative conflict winner outside server policy.
- **AMR-036:** Post-commit consumers MUST be idempotent and process committed events only.
- **AMR-037:** Projections and dashboards MUST expose their derivation, freshness, and non-authoritative status.
- **AMR-038:** Rate, resource, retry, lock, and transaction bounds MUST preserve fail-closed behavior under load.
- **AMR-039:** Service-identity policy MUST be at least as strict as human policy for equivalent effect.
- **AMR-040:** Administrators and developers MUST NOT bypass proposal, authorization, confirmation, transaction, or audit controls.
- **AMR-041:** Database, policy, deployment, backup, and business-mutation privileges SHOULD be separated.
- **AMR-042:** Break-glass access MUST be separately approved, strongly authenticated, bounded, and independently audited or remain prohibited.
- **AMR-043:** Manual actions MUST NOT be represented as ordinary server-authorized transactions.
- **AMR-044:** Policy, validator, configuration, key, and trusted-time changes MUST be versioned and rollback protected.
- **AMR-045:** Unverified downgrade, retired key, clock rollback, or incompatible version MUST fail closed.
- **AMR-046:** Control-plane changes MUST produce accountable protected evidence.
- **AMR-047:** Development and Production MUST use distinct environment-bound identities, targets, and authorization.
- **AMR-048:** Production access, mutation, migration, deployment, or debugging MUST require separate explicit owner authorization.
- **AMR-049:** Repository, branch, commit, artifact, configuration, schema plan, and environment MUST be verified before Production action.
- **AMR-050:** Tests and Development clients MUST be unable to mutate Production.
- **AMR-051:** CI/CD identities and artifacts MUST be least-privilege, provenance-bound, and protected from unauthorized promotion.
- **AMR-052:** Privileged destructive or emergency action MUST use separately governed strong confirmation and recovery evidence.
- **AMR-053:** Backups MUST be integrity, identity, environment, date, and authorization verified before restoration.
- **AMR-054:** A safety snapshot and rollback evidence MUST precede authoritative restore.
- **AMR-055:** Restored confirmation, idempotency, audit, policy, validator, outbox, version, and time state MUST be consistency verified.
- **AMR-056:** Split-brain writers MUST be fenced before restored authority accepts mutations.
- **AMR-057:** Unverified backups or incomplete recovery evidence MUST NOT become authoritative.
- **AMR-058:** Recovery MUST NOT fabricate success, erase accountability, or silently re-enable replay material.
- **AMR-059:** Mutation, required audit, idempotency outcome, confirmation consumption, and required outbox event MUST commit atomically.
- **AMR-060:** Any required evidence write failure MUST roll back the entire mutation.
- **AMR-061:** Transaction rollback or crash before commit MUST NOT be represented as success.
- **AMR-062:** Commit acknowledgement loss MUST use authoritative result recovery.
- **AMR-063:** Post-commit delivery failure MUST NOT reverse or misrepresent a committed mutation.
- **AMR-064:** Audit MUST link proposal, authority, provenance, confirmation, idempotency, transaction, versions, and result.
- **AMR-065:** Audit and logs MUST minimize sensitive data and redact secrets and verification material.
- **AMR-066:** Ordinary actors MUST NOT alter or delete authoritative audit evidence.
- **AMR-067:** Correlation and trusted-time evidence MUST be server generated or independently verified.
- **AMR-068:** Unavailable policy, key, provenance, time, audit, idempotency, confirmation, or datastore services MUST block affected mutation.

## 18. Acceptance tests

| ID        | Required proof                                                                                                                               |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| AMTST-001 | Direct model or tool mutation attempt cannot reach an authoritative handler or datastore.                                                    |
| AMTST-002 | Direct client payload without typed proposal provenance is rejected.                                                                         |
| AMTST-003 | Prompt-injected retrieval content remains inert and cannot change authority or tool capability.                                              |
| AMTST-004 | Forged actor, client authorization, or capability claim is ignored and rejected.                                                             |
| AMTST-005 | Valid confirmation cannot override failed authentication, authorization, or CF-0.                                                            |
| AMTST-006 | Challenge, material-effect summary, proposal, or digest substitution invalidates confirmation.                                               |
| AMTST-007 | Expired, cancelled, superseded, or consumed confirmation replay cannot mutate.                                                               |
| AMTST-008 | Concurrent confirmation use across instances produces at most one consumption and mutation.                                                  |
| AMTST-009 | Idempotency-key reuse across different proposals, actors, targets, or environments fails closed.                                             |
| AMTST-010 | Concurrent duplicate requests produce one durable outcome and one success audit.                                                             |
| AMTST-011 | Stale target version conflicts without overwrite or silent merge.                                                                            |
| AMTST-012 | Policy or validator rollback, change, or unknown version blocks affected mutation.                                                           |
| AMTST-013 | Trusted-clock failure, rollback, or excessive skew blocks issuance and application.                                                          |
| AMTST-014 | Required audit persistence failure rolls back mutation, idempotency completion, and confirmation consumption.                                |
| AMTST-015 | Transaction failure after mutation logic begins leaves no partial authoritative state.                                                       |
| AMTST-016 | Server crash before commit leaves mutation, audit, idempotency, confirmation, and required event uncommitted.                                |
| AMTST-017 | Server crash after commit before response preserves exactly one complete outcome.                                                            |
| AMTST-018 | Client timeout followed by identical retry returns the original committed result only.                                                       |
| AMTST-019 | Outbox replay is idempotent and post-commit delivery failure cannot misrepresent transaction state.                                          |
| AMTST-020 | Offline replay after identity, authorization, policy, confirmation, expiry, or target change fails safely.                                   |
| AMTST-021 | Malicious synchronization conflict or derived divergence cannot select authoritative state.                                                  |
| AMTST-022 | Overprivileged service identity cannot act beyond exact operation, target, module, duration, or environment scope.                           |
| AMTST-023 | Administrator direct-database mutation is prevented or detected and cannot appear as a valid transaction.                                    |
| AMTST-024 | Audit alteration, deletion, fabrication, truncation, or selective omission is prevented or detected.                                         |
| AMTST-025 | Audit, logs, errors, prompts, and telemetry reveal no credentials or reusable verification material.                                         |
| AMTST-026 | Development credentials cannot authenticate to Production and Production credentials cannot be reused in Development.                        |
| AMTST-027 | Development client, test, debug, or maintenance path targeting Production is blocked.                                                        |
| AMTST-028 | Unauthorized deployment or configuration change is blocked before Production effect.                                                         |
| AMTST-029 | Unauthorized, conflicting, unknown, or unapproved migration attempt is blocked.                                                              |
| AMTST-030 | Backup restoration with inconsistent audit, confirmation, idempotency, policy, version, outbox, or writer state cannot accept mutations.     |
| AMTST-031 | Projection, cache, log, dashboard, or client cannot claim authoritative success without committed result proof.                              |
| AMTST-032 | Unavailable or unverifiable policy, key, provenance, clock, identity, validator, or confirmation service blocks mutation.                    |
| AMTST-033 | Unknown mutation class, handler, field, or policy fails closed without fallback.                                                             |
| AMTST-034 | A successful authoritative mutation cannot exist without required audit, idempotency, confirmation consumption, and required event evidence. |
| AMTST-035 | Restore-induced replay cannot re-enable consumed confirmation or duplicate a completed idempotent mutation.                                  |
| AMTST-036 | Multi-row write-skew attempt cannot violate a protected invariant.                                                                           |
| AMTST-037 | Retry storm or resource exhaustion cannot induce bypass or partial transaction.                                                              |
| AMTST-038 | A model, retriever, tool, administrator, or client claim of success is non-authoritative and cannot alter result state.                      |

No executable tests are created by this documentation task.

## 19. Traceability

### 19.1 Threat to requirement and test traceability

| Threats                 | Requirements                                                                         | Tests                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| AMT-001 through AMT-004 | AMR-001 through AMR-019, AMR-037                                                     | AMTST-002, AMTST-004 through AMTST-018, AMTST-020, AMTST-027, AMTST-031        |
| AMT-005 through AMT-009 | AMR-001, AMR-020 through AMR-029                                                     | AMTST-001, AMTST-003, AMTST-022, AMTST-025, AMTST-032, AMTST-038               |
| AMT-010 through AMT-014 | AMR-011 through AMR-019, AMR-030 through AMR-038                                     | AMTST-007 through AMTST-010, AMTST-017 through AMTST-021, AMTST-030, AMTST-037 |
| AMT-015 through AMT-020 | AMR-001, AMR-027 through AMR-029, AMR-039 through AMR-052                            | AMTST-022, AMTST-023, AMTST-026 through AMTST-029, AMTST-038                   |
| AMT-021 through AMT-023 | AMR-044 through AMR-046, AMR-053 through AMR-058                                     | AMTST-012, AMTST-013, AMTST-030, AMTST-035                                     |
| AMT-024 through AMT-028 | AMR-007 through AMR-010, AMR-011 through AMR-019, AMR-038, AMR-059 through AMR-063   | AMTST-008 through AMTST-018, AMTST-034, AMTST-036, AMTST-037                   |
| AMT-029 through AMT-032 | AMR-004 through AMR-006, AMR-011 through AMR-019, AMR-044 through AMR-046            | AMTST-005 through AMTST-013, AMTST-032, AMTST-033                              |
| AMT-033 through AMT-036 | AMR-003, AMR-024, AMR-026, AMR-037, AMR-059 through AMR-067                          | AMTST-014 through AMTST-019, AMTST-024, AMTST-025, AMTST-031, AMTST-034        |
| AMT-037 through AMT-038 | AMR-040 through AMR-051                                                              | AMTST-026 through AMTST-029                                                    |
| AMT-039 through AMT-040 | AMR-005, AMR-006, AMR-023 through AMR-025, AMR-038, AMR-044 through AMR-046, AMR-068 | AMTST-012, AMTST-013, AMTST-032, AMTST-033, AMTST-037                          |

### 19.2 Requirement to test traceability

| Requirements            | Tests                                                                   |
| ----------------------- | ----------------------------------------------------------------------- |
| AMR-001 through AMR-006 | AMTST-001 through AMTST-005, AMTST-032, AMTST-033, AMTST-038            |
| AMR-007 through AMR-010 | AMTST-010, AMTST-011, AMTST-021, AMTST-031, AMTST-036                   |
| AMR-011 through AMR-015 | AMTST-005 through AMTST-008                                             |
| AMR-016 through AMR-019 | AMTST-008 through AMTST-010, AMTST-017, AMTST-018, AMTST-020, AMTST-035 |
| AMR-020 through AMR-026 | AMTST-001, AMTST-003, AMTST-025, AMTST-032, AMTST-038                   |
| AMR-027 through AMR-029 | AMTST-004, AMTST-022, AMTST-026                                         |
| AMR-030 through AMR-034 | AMTST-007, AMTST-009, AMTST-020, AMTST-021                              |
| AMR-035 through AMR-039 | AMTST-010, AMTST-019 through AMTST-022, AMTST-031, AMTST-037            |
| AMR-040 through AMR-043 | AMTST-023, AMTST-027 through AMTST-029, AMTST-038                       |
| AMR-044 through AMR-046 | AMTST-012, AMTST-013, AMTST-024, AMTST-032, AMTST-033                   |
| AMR-047 through AMR-052 | AMTST-026 through AMTST-029                                             |
| AMR-053 through AMR-058 | AMTST-030, AMTST-035                                                    |
| AMR-059 through AMR-063 | AMTST-014 through AMTST-019, AMTST-034                                  |
| AMR-064 through AMR-068 | AMTST-024, AMTST-025, AMTST-031 through AMTST-034                       |

The tables above provide complete threat-to-requirement, threat-to-test, and requirement-to-test coverage. Individual threat-register rows provide exact primary mappings.

## 20. Unresolved decisions and interim treatment

| Decision                                                   | Affected operation or boundary             | Interim fail-closed treatment                                                   | Owner              |
| ---------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------- | ------------------ |
| Exact qualitative risk rubric and residual-risk acceptance | All operations                             | Critical/high unresolved operations remain blocked                              | Owner and Security |
| Identity assurance levels                                  | TB-01 to TB-04                             | Use strongest current verified identity; uncertain identity rejects             | Owner and Security |
| Device and session binding                                 | CF-2/CF-3                                  | No transferable or weakly bound confirmation                                    | Owner and Security |
| Administrative separation of duties                        | TB-08                                      | No direct business mutation or self-approved recovery                           | Owner              |
| Break-glass procedure                                      | Security, destructive, restore, Production | CF-3 operation remains prohibited                                               | Owner and Security |
| Service-identity issuance and rotation                     | Automations and integrations               | No identity without exact scoped policy and revocation                          | Owner and Security |
| Cryptographic algorithms and key custody                   | Digests, confirmation, audit               | No custom or unverifiable construction; affected operation blocked              | Security           |
| Audit-integrity mechanism and retention                    | TB-05 to TB-08                             | Required audit must remain in atomic store; unverifiable recovery blocked       | Owner and Security |
| Trusted-time implementation                                | Confirmation and expiry                    | Clock uncertainty blocks issuance and consumption                               | Security           |
| Backup and recovery reconciliation                         | TB-08                                      | Restored authority cannot accept mutations until consistency proof              | Owner and Security |
| Production deployment authorization                        | TB-09                                      | No Production action without separate explicit approval                         | Owner              |
| Incident-response and compromise recovery                  | All privileged boundaries                  | Revoke or disable affected capability; no silent repair                         | Security           |
| Data, audit, replay, and proposal retention                | All stores                                 | Retain minimum required evidence; deletion cannot weaken replay protection      | Owner and Security |
| Monitoring and alert thresholds                            | Audit and outbox                           | Missing alert policy cannot justify fail-open operation                         | Security           |
| Dependency and provider assurance                          | TB-10                                      | Unverifiable provider or dependency blocks affected operation                   | Security           |
| Distributed or multi-region authority                      | TB-05                                      | Single proven writer only; split brain fenced                                   | Owner and Security |
| Multi-party approval                                       | CF-3                                       | CF-3 remains blocked until separately governed                                  | Owner              |
| Penetration-testing scope                                  | All boundaries                             | No inference of assurance from missing testing                                  | Owner and Security |
| Residual-risk acceptance authority                         | All operations                             | Only the owner may accept documented residual product risk with security review | Owner              |

## 21. Explicit non-goals

This deliverable does not:

- implement application, client, server, API, database, or security code;
- create executable security tests;
- inspect or modify SQL;
- create, authorize, inspect, renumber, or apply Migration 009;
- define concrete database schemas or DDL;
- create the external authority anchor;
- configure identities, credentials, cryptographic keys, or secrets;
- grant models, tools, retrievers, clients, automations, administrators, developers, or service identities authoritative mutation capability;
- modify PropertyManager;
- access Development or Production runtimes;
- access databases, services, containers, or networks;
- deploy, migrate, restart, or configure anything;
- perform penetration testing;
- select final cryptographic algorithms or key custody;
- begin implementation or the next architecture deliverable.

Implementation MUST NOT begin until applicable unresolved decisions receive owner and security approval.
