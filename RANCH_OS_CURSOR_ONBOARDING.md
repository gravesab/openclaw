# Ranch OS Cursor onboarding

Status: Approved DEV Cursor onboarding index; not implementation, migration,
runtime, device, or Production authority. Commit remains a separate operator
decision.
Scope: Cursor onboarding for Ranch OS work inside the OpenClaw DEV checkout
Environment: DEV only

This file is a Cursor routing index. It does not become a design, tenancy,
mutation, identity, or implementation contract after review or commit.
If this file disagrees with a named foundational or architecture contract,
stop and use the contract.

A gate-2 DEV approval covering this file only does not authorize other files,
tests, migrations, services, credentials, builds, commits, or deployments.

## Purpose

This document gives Cursor a bounded, precedence-ordered context for Ranch OS
work. It prevents a generic OpenClaw document, a fixture implementation, or an
uncommitted proposal from being mistaken for authorization to change tenant
data, deploy a service, run a migration, or release to Production.

## Apple-first development direction

Read the [Apple-first application and intelligence direction](https://docs.openclaw.ai/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE#apple-first-application-and-intelligence-direction)
in `docs/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE.md` before planning Apple or AI
features. It governs the native experience, Apple Intelligence evaluation,
supporting-model evidence, privacy-compatible fallbacks, and device validation.
Carry its required feature-design evidence into each relevant implementation
handoff. This standing direction does not change the authorization precedence
below or establish that an integration has shipped.

## Checkout authority

| Checkout | Intended use | Not authority for |
| --- | --- | --- |
| `/Users/andrewgraves/Documents/OpenClaw-DEV` | Canonical active DEV discovery checkout on the `development` branch. It is not blanket implementation, migration, runtime, or device approval. | Clean baseline, Production state, or implicit permission to include unrelated WIP. |
| `/Users/andrewgraves/Documents/OpenClaw-DEV-2026.8.1-reconcile` | Historical reconciled branch evidence. | A second active implementation source. |
| `/Users/andrewgraves/Documents/OpenClaw-DEV-pr35-repair-20260827` | Separate clone of the reconciled branch for repair/PR evidence. | A competing canonical checkout. |
| `/Users/andrewgraves/Documents/OpenClaw-DEV-ranchos-tvos-20260828-shallow` | Isolated Ranch OS tvOS DEV fixture work. | Full Git history or Production authority. |

Tracked or untracked fixture apps, migrations, and `tenancy.py` in this
checkout are not an implementation grant. Do not pull a second worktree into
the same task unless that worktree is the named authorized target.

Other OpenClaw-named local repositories are historical, recovery, or empty
repositories unless explicitly re-established as an authorized target.

## Document precedence

Resolve files under `docs/foundation/` and `docs/architecture/`, never the
root-level copies of the same names. Root copies are migration sources only.

When documents disagree, use this order. Stop for review if the conflict would
affect security, data ownership, confirmation, runtime behavior, or environment
scope. The more restrictive applicable contract wins.

0. Explicit operator authorization for one named gate (design, DEV
   implementation, DEV database, DEV runtime, device, or Production).
   That authorization selects only the named gate and named files; it does not
   waive or weaken a governing tenancy, mutation, confirmation, RLS, identity,
   recovery, or DEV/Production contract.

1. Environment and safety governance:
   - `docs/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE.md`
   - `docs/foundation/AI_GOVERNANCE_MANIFEST.md`
   - `docs/foundation/CANONICAL_TRUSTED_RECORDS.md`
   - `docs/foundation/RESTORE_MANIFEST.md`
   - `docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md`
     (especially IDP-077–082)
   - `docs/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1.md`

2. Foundational index and domain policy:
   - `docs/foundation/FOUNDATIONAL_DOCUMENTS.md`
   - `docs/foundation/OPERATIONS_RUNBOOK.md`
   - `docs/foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md`

3. Named normative mutation contracts only:
   - `docs/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1.md`
   - `docs/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md`
   - `docs/architecture/CANONICAL_CONFIRMATION_POLICY_V1.md`
   - `docs/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md`
   Other files in `docs/architecture/` are not Ranch OS tenancy authority.

4. `ranchbrain_app/docs/MULTI_TENANCY_DESIGN.md` is the sole approved Ranch OS
   tenancy contract for the specifically authorized DEV foundation scope. It
   does not authorize Production deployment, a Production migration, or cloud
   hosting. Its DEV rollout sequence does not itself satisfy gate 3.

5. Other `ranchbrain_app/docs/*.md` files, excluding the rank-4 tenancy
   contract, only after reading their Status line:
   - `Approved for DEV foundation work` → design contract for that scope.
   - `Proposed`, `Living design reference`, sprint, or alpha → not
     implementation authority.
   Do not use Home, Apple TV, livestock persistence, livestock management
   design, livestock blueprint, or the architecture poster as implementation
   authority. `docs/foundation/HUMAN_CENTERED_PERSONAL_INTELLIGENCE_SYSTEM.md`
   is a proposed design baseline and may be used as context only, not authority.

6. Root `AGENTS.md`, `SECURITY.md`, and scoped `AGENTS.md` are OpenClaw
   contributor/process rules. They do not define Ranch OS tenancy. Ignore
   “live-verify when feasible” unless a later task names a DEV endpoint.
   If they conflict with ranks 0–4, stop.

7. Source, tests, fixtures, generated Xcode projects, screenshots, prior
   build/device evidence, `ranchbrain_app/ranchbrain/tenancy.py`,
   `ranchbrain_app/migrations/`, `apps/ranchos-livestock-macos/`, and
   `apps/ranchos-tvos/` are non-authoritative experiments or evidence.
   They must not set the capability matrix, persistence contract, tenant
   model, or live integration path.

The following are proposals, untracked WIP, dirty alpha notes, or fixtures
and must never be promoted to authority by presence in the checkout. Preserve
them unchanged unless a later task names the exact file:

- `ranchbrain_app/docs/LIVESTOCK_AUTHORITATIVE_MUTATION_PERSISTENCE_DESIGN.md`
- `ranchbrain_app/docs/LIVESTOCK_MANAGEMENT_DESIGN.md`
- `ranchbrain_app/docs/LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md`
- `ranchbrain_app/docs/RANCH_OS_APPLE_TV_PHASE_1_DESIGN_AND_TEST_PLAN.md`
- `ranchbrain_app/docs/RANCH_OS_HOME_APPLICATION_SHELL_DESIGN.md`
- `ranchbrain_app/docs/RANCH_OS_ARCHITECTURE_POSTER_REFERENCE.md`
- `ranchbrain_app/docs/ARCHITECTURE.md` (RanchBrain 1.0 Alpha; not the Ranch OS
  tenancy or livestock module contract)
- `ranchbrain_app/docs/ROADMAP.md`
- `ranchbrain_app/ranchbrain/tenancy.py`
- `ranchbrain_app/ranchbrain/livestock_read_model.py`
- `ranchbrain_app/ranchbrain/livestock_write_model.py`
- `ranchbrain_app/ranchbrain/tv_today.py`
- `ranchbrain_app/migrations/`
- `ranchbrain_app/scripts/`
- `ranchbrain_app/tests/` livestock, tenancy, TV, RLS, and migration-contract
  tests
- `apps/ranchos-tvos/**` (untracked DEV fixture)
- `apps/ranchos-livestock-macos/**` (tracked DEV fixture)

Unrelated AI-intelligence and PropertyManager WIP in this checkout is outside
Ranch OS scope and must remain untouched.

## Required Ranch OS invariants

- `tenant_id` is the data-ownership boundary. A client-provided tenant value is
  only a routing hint, never proof of access.
- Every lookup and write requires a server-derived `VerifiedPrincipal`, an
  explicit active tenant selection, active membership, and capability
  authorization.
- PostgreSQL RLS is a mandatory independent boundary. Tenant tables must force
  RLS; runtime roles must not own tenant tables or have `BYPASSRLS`.
- Authoritative mutations require the normative confirmation, validation,
  idempotency, transaction, audit, and recovery contracts. UI confirmation is
  not authorization.
- Fixture data, bundled snapshots, build provenance, and visual demonstrations
  are non-authoritative and must remain visibly DEV-scoped.
- A fixture or local constructor of `VerifiedPrincipal` is test-only and must
  not be loadable or configurable in a deployed DEV runtime.
- Single-ranch DEV bootstrap may use one configured tenant only after principal
  and the one active membership are server-derived. It is not a default-tenant
  authorization model.
- Health and personal-finance records need a separately approved privacy
  policy; tenant membership is not sufficient.
- PropertyManager remains the system of record for assets, meters, and
  maintenance. Do not read its Postgres. Do not contact its API, database, or
  credentials unless a later task names an approved DEV endpoint.
- Development and Production identities, credentials, sessions, and
  configurations are distinct (IDP-077–078). Development approval, branch,
  network, or admin access does not imply Production (IDT-030).
- Examples, posters, screenshots, and AMP/AMR illustrations do not grant
  authority.
- The capability matrix in `tenancy.py` is not the approved tenancy matrix.

## Application map

| Surface | Location | Current boundary |
| --- | --- | --- |
| RanchBrain / tenancy types | `ranchbrain_app/` | DEV types, tests, and a tenancy migration *file*. Not migration, runtime, or livestock-write authority. |
| Livestock macOS | `apps/ranchos-livestock-macos/` | Tracked fixture-only UI; hardcoded presentation data; `VerifiedPrincipal` is intentionally undeployed. Do not grow live persistence from this app. |
| Ranch OS tvOS | `apps/ranchos-tvos/` | Untracked DEV fixture, bundle `ai.openclaw.ranchos.tv.dev`; no trusted ingress or live tenant feed. |
| PropertyManager iOS | `apps/propertymanager-ios/` | Debug bundle is DEV-suffixed. Treat as a separate product surface. Do not verify its runtime, database, or credentials in a Ranch OS task. |

## Approval gates

Cursor must treat the following as independent gates. Completion of an earlier
gate does not authorize a later one.

The OpenClaw Development Directive still applies: work stays on the
`development` branch in DEV; updating `development` is not Production
authorization. Identity policy IDP-080 still requires verifying checkout,
branch, HEAD, configuration, schema plan, and target identity before any
separately authorized Production action. Presence of
`ranchbrain_app/migrations/001_ranch_os_tenancy_foundation.sql` does not
satisfy gate 3. Backup/restore authority is governed by
`docs/foundation/RESTORE_MANIFEST.md`.

1. Design approval: scope, document precedence, tenancy, and threat model.
2. DEV implementation approval: exact files and tests; preserve unrelated WIP.
3. DEV database approval: isolated database, migration authority, forced-RLS
   proof, and backup/restore authority.
4. DEV runtime approval: pinned checkout, service configuration, credentials,
   endpoint, and authenticated behavior verified without exposing secrets.
5. Device approval: a signed install is not visible-device proof; verify the
   intended device and the DEV identity separately. A DEV bundle identifier or
   signed DEV install is not trusted ingress or a live tenant feed.
6. Production approval: explicit authorization plus independent review of
   checkout, configuration, migration, backup/restore, deployment, and runtime
   behavior.

## Cursor operating rules

- Start each task by reading this file as an index, then the rank-1 and rank-4
  documents that apply, then any Status-approved design for the named scope.
  Do not start from fixture apps or `tenancy.py`.
- Before edits, identify the exact checkout, branch, HEAD, Git status, and
  whether the target overlaps pre-existing WIP.
- Do not move, delete, stage, commit, merge, checkout, install, build, run
  migrations, or contact live services without explicit authorization.
- Keep DEV and Production configurations, credentials, database targets,
  commits, deployments, and evidence separate.
- Do not follow root `AGENTS.md` live-verify, GitHub landing, or plugin-core
  rules when they conflict with ranks 0–4.
- Do not treat a successful test, migration file, fixture catalog, or capability
  enum as an approved matrix or persistence contract.
- Do not claim a security, device, runtime, backup, migration, or Production
  outcome from source inspection, a successful build, or installation alone.
- If document precedence or environment ownership is unclear, stop and request
  a bounded decision before changing state.

## Current onboarding backlog

This index is finalized for DEV Cursor use. It remains an untracked review
artifact until the operator explicitly authorizes committing only
`RANCH_OS_CURSOR_ONBOARDING.md`.

Later decisions, not authorized by this file:

- add scoped Ranch OS guidance;
- retire or archive duplicate worktrees only after preservation and
  Git-integrity status are verified;
- any source, test, migration, runtime, device, or Production work.
