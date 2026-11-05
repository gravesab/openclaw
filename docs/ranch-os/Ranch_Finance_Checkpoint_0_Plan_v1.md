# Ranch Finance — Checkpoint 0 Plan (contract alignment)

**Version:** 1.0 (draft for review)
**Status:** Proposed — not approved. Plan only: no code, migration, database, or runtime change is authorized by this document.
**Contract:** `Ranch_Finance_Master_Specification_v1.1.md` ("the Spec"), canonical per the owner ruling of 2026-11-05 (GAP_ANALYSIS.md P0-5).
**Production:** Out of scope.

Spec §12 Checkpoint 0 requires three things:

1. Place the Spec in the canonical documentation location.
2. Identify architecture and code conflicts.
3. Produce a file-level implementation and test plan, with no production changes.

It also requires an inspection, before any edit, of the repository instructions, migration conventions, API patterns, package layout, audit and auth services, and test commands. This document records that inspection (§2), the conflicts and proposed resolutions (§3), and the file-level plan (§4–§6).

## 1. Canonical location

The Spec stays at `docs/ranch-os/Ranch_Finance_Master_Specification_v1.1.md`, where the owner placed it alongside the other Ranch OS foundational documents. `RANCH_OS_CURSOR_ONBOARDING.md` should list it in its precedence order as the Ranch Finance contract, replacing `ranchbrain_app/docs/RANCH_FINANCE_FOUNDATIONAL_DESIGN.md`, which is now superseded. **Owner decision D1.**

## 2. Repository conventions found (2026-11-05, from source)

| Area | Convention | Evidence |
|---|---|---|
| Schema | One schema, `ranchos`; module-prefixed tables (`ranchos.livestock_*`, `ranchos.finance_*`) | `ranchbrain_app/migrations/*.sql` (only `CREATE SCHEMA IF NOT EXISTS ranchos`) |
| Enum-like values | `CHECK` constraints; no PostgreSQL enum types (179 CHECKs, 0 `CREATE TYPE`) | migrations |
| Tenancy | Every table has `tenant_id`, `ENABLE` + `FORCE ROW LEVEL SECURITY`, and policies `USING/WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))` | `002_…:456`, `001_ranch_os_tenancy_foundation.sql` |
| Roles | Migrations run as `ranchos_dev_migrator`. The runtime is `ranchos_dev_runtime`: NOBYPASSRLS, `REVOKE ALL … FROM PUBLIC`, then explicit grants | `001_…:11–22`, `005_…:810+` |
| Migration headers | "DEV-only … Never apply this file to Production. Apply only on an isolated … DEV database as ranchos_dev_migrator after NNN." | `005_…:1–3`, `019_…:1–4` |
| Audit | No OpenClaw-wide audit service. Each module has its own append-only audit table (`finance_mutation_audit`, `livestock_mutation_audit`) with an INSERT-only runtime grant | migrations |
| `updated_at` | **No** shared `set_updated_at()` function exists | migrations (none found) |
| Mutation pattern | Transport-free coordinator with parameterized session, `SET LOCAL` principal/tenant/environment, idempotency table with a finalize-only trigger, audit in the same transaction | `livestock_mutation_coordinator.py`, `livestock_pg_session.py`, `005_…` |
| Identity | `VerifiedPrincipal` + `TenantContextResolver` (`tenancy.py`); OIDC claim validation (`identity_oidc.py`); **no signature verifier**, so no authenticated runtime yet | GAP P1-1 |
| HTTP | stdlib `http.server` services (`api/server.py`, `livestock_dev_read_server.py`); no framework | ranchbrain_app |
| Tests | pytest in `ranchbrain_app/tests`; `*_disposable_pg.py` start their own `initdb` cluster; RLS SQL in `tests/rls/`; static `*_migration_contract.py` checks | tests |
| CI | `ranchos-python-tests.yml`: `unit` runs pytest without `*_disposable_pg.py`; `postgres-proofs` runs `*_disposable_pg.py` and the RLS script | `.github/workflows/` |
| Apple apps | One RanchOS app per platform; domains are **compiled feature modules** (module-host contract, approved for DEV planning) | `RANCH_OS_HOME_APPLICATION_SHELL_DESIGN.md:10–14` |
| Swift shared code | `apps/shared/OpenClawKit` Swift package exists | `apps/shared/` |

## 3. Conflicts and proposed resolutions

| # | The Spec says | Repo / governance says | Proposed resolution | Owner? |
|---|---|---|---|---|
| C1 | Logical namespace `finance` (§5) | One `ranchos` schema with prefixed tables | `ranchos.finance_*` tables. The Spec permits "the repository's approved schema convention" (§5). | No |
| C2 | Shared `set_updated_at()` trigger (§5) | None exists | Add `ranchos.set_updated_at()` once, in the Checkpoint 1 migration, as the first shared helper. Other modules may adopt it later. | No |
| C3 | Use OpenClaw's append-only audit service "if one exists" (§5.9) | None exists | Finance-local append-only `ranchos.finance_audit_events` per §5.9, with an INSERT-only runtime grant and a trigger rejecting UPDATE/DELETE | No |
| C4 | Silent on tenancy | `tenant_id` boundary, FORCE RLS, server-derived principal and membership (`MULTI_TENANCY_DESIGN.md`, approved; onboarding invariants) | Every Spec table gains `tenant_id NOT NULL REFERENCES ranchos.tenants`, FORCE RLS, and tenant policies. Uniqueness rules become tenant-scoped (e.g. domain `code` unique per tenant). Domains are seeded per tenant. This adds tenancy without changing the Spec's domain semantics. | **Yes — D2** (acknowledge under §15) |
| C5 | `personal` domain is first-class | Personal-finance records need a **separately approved per-user privacy policy**; tenant membership is insufficient (onboarding §Invariants; shell design :83–88, :421–424) | Checkpoint 1 seeds `personal`, but no Personal-domain records are created, imported, or shown until that policy is approved. Read APIs refuse `domain=personal` and exclude it from "All" until a privacy capability exists. | **Yes — D3** |
| C6 | Tables `accounts`, `categories`, `transactions`, … | Unapplied `005_finance_persistence_foundation.sql` already defines `ranchos.finance_accounts` and 8 other double-entry tables | **Replace 005's contents** with the Spec foundation, but only if no database has 005 applied. Otherwise ship a new migration that drops the never-used double-entry tables first. **Whether 005 was ever applied is UNKNOWN.** The Livestock DEV database very likely had later livestock migrations applied (the Livestock app depends on them); whether 005 was applied in that sequence is not recorded. | **Yes — D4** (after a read-only check) |
| C7 | — | Finance and Livestock share one migration sequence. The live Livestock server source (owner's Mac) may already use `023+` (GAP P0-2) | Choose the Finance migration number only after the Livestock source lands | No (sequencing) |
| C8 | "Native SwiftUI apps for macOS and iOS" (§1, §3.1) | One RanchOS app with compiled modules; AGENTS.md: preserve the single-app/module architecture | Ranch Finance is a **RanchOS feature module** backed by a shared Swift package. It is not a standalone app. | **Yes — D5** (confirm reading) |
| C9 | Mutations "authenticate and authorize the actor" (§7.2) | No signature verifier (P1-1) | Checkpoint 1 builds transport-free read contracts and authorization with an injected principal, fully tested. **No runtime endpoint ships until P1-1 lands.** | No (blocked by P1-1) |
| C10 | `confirmed_by` = "stable authenticated actor identifier" (§5.5) | `VerifiedPrincipal.id` | Use `VerifiedPrincipal.id`; never an email, display name, or client header | No |
| C11 | DEV deployment | `ranchos_livestock_dev` holds real Livestock records (GAP P0-2) | Finance DEV work uses only throwaway `initdb` clusters, then a separately approved **isolated** Finance DEV database. Never the Livestock database. | No |
| C12 | — | ~2,900 lines of double-entry `ranchbrain/finance_*.py` and 6 test files (superseded, never applied) | New Spec code goes in a new package `ranchbrain/finance/`. The old flat `finance_*.py` modules and tests stay untouched until a separately approved cleanup. | **Yes — D6** (cleanup timing) |
| C13 | Apple-first feature-design statements (AGENTS.md) | Not in the Spec | Covered in §6 | No |

## 4. Checkpoint 1 — read-only data foundation (file-level)

**Preconditions:**

- D2–D4 decided.
- The migration number is allocated (C7).
- P1-1 is **not** required to build or test. It is required to expose a runtime endpoint.

| File | Purpose |
|---|---|
| `ranchbrain_app/migrations/NNN_finance_v1_foundation.sql` (or replaced `005`, per D4) | Tables (§5.1–5.3, 5.6, 5.7): `finance_domains`, `finance_accounts`, `finance_categories`, `finance_transactions`, `finance_transfers`, `finance_audit_events`. Includes `ranchos.set_updated_at()` (C2) and Spec constraints: signed nonzero `numeric(14,2)` amount and no direction column (§4); `last_four` exactly 4 digits; category self-parent and 2-level limit enforced in the API; a confirmed transfer has exactly 2 active rows, enforced by a deferred trigger. Also: indexes per §5, the active-row partial index, `tenant_id` + FORCE RLS + policies (C4), grants (runtime: SELECT on domain tables, INSERT-only on audit), and per-tenant domain seed rows via a function the migrator calls. Import, profile, batch, and recurring tables come in Checkpoints 3 and 5. |
| `ranchbrain_app/ranchbrain/finance/__init__.py` | Package marker |
| `ranchbrain_app/ranchbrain/finance/model.py` | Frozen dataclasses for domain, account, category, transaction, transfer. Amount parsing is exact decimal with 2 places, nonzero, ISO 4217. Derived `direction` exists for presentation only. |
| `ranchbrain_app/ranchbrain/finance/reporting.py` | Pure §6 semantics: monthly summary (income, expenses, net, count, transfer count), top categories with Uncategorized, refunds reducing category spend, America/Chicago month grouping, and current/past/future average daily spend with no division by zero (§6.3) |
| `ranchbrain_app/ranchbrain/finance/read_contract.py` | Transport-free read API (§7.1): monthly summary, top categories, paginated transactions, reference data. Responses carry schema version and server revision. Authorization takes `VerifiedPrincipal` + `TenantContextResolver`. `personal` is refused (C5). |
| `ranchbrain_app/ranchbrain/finance/pg_session.py` | Parameterized read session: `SET LOCAL` role, principal, tenant, environment, modeled on `livestock_pg_session.py`. No `connect()` or environment URL inside; the connection is injected. |
| `ranchbrain_app/tests/test_finance_v1_migration_contract.py` | Static SQL checks: every table has FORCE RLS and a tenant policy; no enum types; no direction column; audit has no UPDATE/DELETE grant; header markers present |
| `ranchbrain_app/tests/test_finance_v1_model.py` | Amount and currency rules, zero rejected, sign semantics |
| `ranchbrain_app/tests/test_finance_v1_reporting.py` | §6 cases: transfers excluded, refunds, Uncategorized, Chicago month boundaries (UTC 05:00 edge), daily averages, empty month |
| `ranchbrain_app/tests/test_finance_v1_read_contract.py` | Authorization: no principal, wrong tenant, `personal` refused, pagination, stale revision |
| `ranchbrain_app/tests/test_finance_v1_disposable_pg.py` | Throwaway cluster: migration applies as migrator; constraints and triggers enforce; runtime cannot UPDATE/DELETE audit; transfer pairing; seed per tenant |
| `ranchbrain_app/tests/rls/two_tenant_finance_v1_isolation.sql` | Tenant A cannot read or write tenant B, through `SET LOCAL ROLE ranchos_dev_runtime` |

**Proof:**

- The `unit` CI lane picks up the pure and static tests automatically.
- `postgres-proofs` picks up `*_disposable_pg.py`. The RLS step gains the new SQL file.
- Local proof uses the scratch-venv command set from GAP P1-3. **No shared or live database.**

**Out of scope:** writes, import, the HTTP endpoint (until P1-1), and Swift.

## 5. Checkpoints 2–5 (outline; file-level plans written at each checkpoint's start)

| CP | Scope | Main files | Gate |
|---|---|---|---|
| 2 | Read-only SwiftUI "This Month" (§9) | `apps/shared/RanchFinance` Swift package (`RanchFinanceCore`: API models, client protocol, filters, formatting; `RanchFinanceUI`: This Month views, tokens §9.5), integrated as a RanchOS module (C8); one shared API fixture for AC 13 | CP1 runtime endpoint (needs P1-1); device validation (§6) |
| 3 | Staged CSV import (§8) | migration: `finance_import_profiles`, `finance_import_batches`, staged-row table; `finance/import_*.py` (stage, map, validate, dedup, preview, commit, exclude); confirmation tokens, idempotency, audit; macOS import UI | **§11 threat-model tests must pass before macOS import is enabled** |
| 4 | Transfers and corrections | `finance/mutations.py` coordinator for paired transfers, superseding corrections, conflict and replay tests | §7.2 mutation rules |
| 5 | Recurring forecasts | migration: `finance_recurring_rules`, `finance_forecast_occurrences`; server worker (no `pg_cron`); matching and confirmed conversion; never auto-post | §5.8 |

The SimpleFIN connector (`Ranch_OS_SimpleFIN_Connector_Design_v1.md`) follows CP3 and needs its own approval.

## 6. Apple-first feature statement (AGENTS.md)

- **Native experience.** SwiftUI module inside RanchOS on macOS, iPhone, and iPad: sidebar on Mac, first tab on iPhone, size-class layouts on iPad (§9.2–9.3). Accessibility, Dynamic Type, VoiceOver, dark mode, and localization from the first build (§9.5).
- **Apple Intelligence opportunity.** On-device Foundation Models could *propose* category mappings and import column mappings (Spec §2.5: AI suggests, deterministic rules validate, the owner confirms). This is not in CP1–CP2. It would be evaluated at CP3 with fixtures only; raw finance rows never leave the device or Finance domain (§2.7).
- **FinanceKit / Wallet.** Deferred by Spec §3.2. A Swift package named `RanchFinance*` avoids confusion with Apple's FinanceKit.
- **Availability and fallback.** Every AI-assisted path has a rules-only path. No remote model receives finance data (Hybrid Routing v1 §5 is allowlist-only, and per §8.2 the allowlist starts empty).
- **Device validation plan.** Before CP2 sign-off: a Mac and a physical iPhone and iPad (real devices are checked before simulators, per AGENTS.md); light and dark; largest Dynamic Type; VoiceOver pass; offline and stale states; one API fixture producing identical totals on all three (AC 13).

## 7. Owner decisions

| ID | Decision | Ruling (owner, 2026-11-05) |
|---|---|---|
| D1 | Keep the Spec in `docs/ranch-os/` and update the onboarding precedence to name it | **Accepted.** `RANCH_OS_CURSOR_ONBOARDING.md` rank 2 now names the Spec. |
| D2 | Accept tenant scoping and FORCE RLS on all Spec tables (C4) as a §15-compatible addition | **Accepted** |
| D3 | Personal domain: block until a per-user privacy policy is approved, or approve a privacy policy now | **Accepted: blocked** until a per-user privacy policy is approved |
| D4 | After a read-only check of whether `005` is applied anywhere: replace 005 in place, or add a drop-and-replace migration | **Open.** Needs explicit approval for the read-only DEV database check. |
| D5 | Confirm Ranch Finance is a RanchOS feature module, not a standalone app | **Accepted** |
| D6 | When to remove the superseded double-entry `finance_*.py`, its tests, and 005 | **Open** |

## 8. Blocked by

- **P1-1** (signature verifier) for any runtime endpoint, and so for CP2.
- **P0-2 Livestock source** for migration numbering (C7).
- **A read-only check of 005's applied state** (D4). It needs owner approval to query a DEV database.
