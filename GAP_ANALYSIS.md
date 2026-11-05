# Ranch OS Gap Analysis

Status: Read-only analysis. No code, config, migration, or service was changed.
Branch: `claude/gap-analysis` (off `development`, HEAD `08d91b12e68`).
Date: 2026-11-05. Environment: DEV VM `openclaw-dev-intel-trial`. PROD was not touched.

## Method and limits

- Read all 11 documents in `docs/ranch-os/`. The 4 PDFs were read as rendered pages because no PDF text tooling is installed on the VM.
- Mapped the documents against these code areas: `ranchbrain_app/`, `ranchbrain/`, `tools/ranchbrain/`, `tools/property_manager/`, `tools/ai_intelligence/`, `config/ai_intelligence/`, `apps/ranchos-*`, `apps/propertymanager-*`, `extensions/firecrawl/`, `src/gateway/server-methods/ai-intelligence.ts`, `docker-compose.yml`, and the root and `docs/foundation|architecture` governance docs.
- **Not done (read-only rule):** I ran no tests, because pytest/xcodebuild would write caches and build output. I probed no ports or services, opened no `.env` file or credential, and contacted no PROD host. I did not inspect Health/Wellness beyond confirming no module exists in the surveyed trees.
- `UNKNOWN` means the fact could not be confirmed from source in this checkout.

## Summary

The repo is further along than the `docs/ranch-os/` designs suggest in four areas: PropertyManager, Livestock, the tenancy/RLS foundation, and a local model router. It is behind them in five: the hybrid API fallback, Moshi, Firecrawl URL ingestion, SimpleFIN, and SSO. The biggest problems are not missing features:

1. Some DEV tools point at PROD by default.
2. Live write paths and exposed endpoints don't follow the repo's own mutation and exposure contracts.
3. Two Finance contracts contradict each other.
4. The governing onboarding index no longer matches the code.

---

## P0: blocks the next build

### P0-1. Some DEV tools default to the PROD host
- **Evidence:**
  - `tools/property_manager/db/save_mac_cache_to_api.sh:5` and `refresh_mac_cache_from_api.sh:5` default to `http://intelmini:5062`.
  - `tools/property_manager/generate_asset_qr.py:44` defaults to `http://100.85.36.72:5000`.
  - `tools/property_manager/swift-mac/patch_mac_api_auth.py:165,185` return `http://100.85.36.72:5062`.
  - AGENTS.md names `intelmini` / `100.85.36.72` as PROD.
- **Why P0:** Running any of these tools with its default settings touches PROD. That breaks the hard rule "Never touch PROD."
- **Done when:** No tool in the repo has a PROD default. A PROD target needs an explicit flag or env var, and the tool refuses to run without it. A test or grep check in CI fails if a PROD hostname or IP appears as a default.
- **Status (2026-11-05, uncommitted on `claude/gap-analysis`):**
  - **Fixed:** `save_mac_cache_to_api.sh` and `refresh_mac_cache_from_api.sh` now exit 2 unless `PROPERTYMANAGER_API_BASE` is set. `generate_asset_qr.py` now requires `--dashboard-base`. Covered by `tools/property_manager/tests/test_no_default_api_target.py` (6 tests, stub `curl`, no network).
  - **Before the fix:** the HEAD version of the refresh script, run with no settings, sent `/health`, `/tasks`, and `/categories` to `http://intelmini:5062`.
  - **Retired (owner decision 2026-11-05):** the whole legacy `tools/property_manager/swift-mac/` patch set, 17 files and 216 KB, deleted but not committed. `patch_mac_api_auth.py` hardcoded the PROD API and stored the API key and PIN in UserDefaults. It was the first step of a chain that patched an external `~/Development/PropertyManagerApp` checkout, which the in-repo `apps/propertymanager-macos` replaces. No test, CI job, or doc referenced the set. Only the historical evidence reports in `reports/propertymanager/phase2-acceptance-evidence.md:24-30` and `phase3-production-evidence.md:154` mention it, and they are left unchanged as records. Recoverable from git history (last touched in `ab03a3330b1`).
  - **Wider inventory, checked 2026-11-05:**
    - **PropertyManager iOS app: intended, not a bug.** This corrects an earlier claim in this report. `apps/propertymanager-ios/Sources/PropertyStore.swift:5-27` uses `#if DEBUG` to pick the DEV VM (`100.85.188.74`) with separate `propertyManager.dev.*` storage keys. Release builds use PROD. `project.yml` sets no custom `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, so `DEBUG` stays limited to the Debug config, whose bundle is `ai.openclaw.propertymanager.dev`. The macOS app does the same (`PropertyManagerApp.swift:57,62`).
    - **Minor:** the DEV build's settings hint still suggests the PROD address (`SettingsView.swift:30`). Make the example match the build.
    - **`tools/system_manager/openclaw-dev-backup.sh:8`: intended.** It backs up DEV to storage on the PROD host. It checks the local hostname (`openclawdev`) and the remote hostname (`intelmini`) before writing. On this VM (`openclaw-dev-intel-trial`) the local check fails, so it exits before any SSH. It writes to PROD, so agents must never run it (AGENTS.md). Open concerns:
      - The `tar` excludes don't skip `.env` or credential files in the checkout, so any secret in the working tree would be copied to PROD storage.
      - DEV and PROD share the Intel Mini hardware, so this may not be an independent copy. Whether `/mnt/ai-storage` is a separate disk is UNKNOWN.
      - The `EXPECTED_HOST` and `REPO` paths are stale for this VM.
    - **Likely intended (ops tools that report on PROD):** `tools/home_manager/collect_trends.sh:87`, `scripts/systemd/openclaw-dashboard-trends.service:10`, `tools/telegram/reboot-status.sh:21,24`, and the `tools/dashboard/install_*.py` messages. Move the hostnames into config as part of P1-8.
    - **CI guard: added (uncommitted).**
      - `tools/ranchos_guard/check_prod_targets.py` scans tracked non-prose files for `100.85.36.72` (anchored) and `\bintelmini\b`, and compares them against `tools/ranchos_guard/prod_targets_allowlist.json`. That file has 17 entries with exact per-file counts, each with a reason and a status of `intended` or `review`.
      - It fails on a new file, a higher count, or a stale entry.
      - Workflow: `.github/workflows/ranchos-prod-target-guard.yml`, which runs the guard's 11 tests, the 6 PropertyManager no-default tests, and the scan.
      - **Proof:** on the HEAD (pre-fix) versions of the three fixed tools and the retired patcher, the guard exits 1 and names all four files.
      - **The 3 `review` items are fixed (uncommitted). The allowlist is now 14 entries, none marked `review`.**
        - `tools/dashboard/app.py`: `OPENCLAW_INTELMINI_STORAGE_HOST` has no default. All six SSH/SCP sites go through `intelmini_storage_target()`, which raises "Remote storage not configured" when the host is unset. The storage panels show that status. Hosts that mount `/mnt/ai-storage` locally (PROD) never take this path.
        - `tools/dashboard/test_scorecard_approval.py`: two test classes now set an explicit test host, because 6 tests had relied on the PROD default. The new `RemoteStorageUnconfiguredTests` (3 tests) proves no `subprocess` call happens without a host. Run against HEAD `app.py`, those tests fail.
        - `tools/home_manager/collect_trends.sh`: the remote storage sample is opt-in. With no host, nothing is SSHed and the field is empty. The systemd unit already sets the host explicitly, so it is unaffected. `tools/home_manager/test_collect_trends_storage_host.py` (2 tests, all commands stubbed) fails on HEAD, which SSHes to `gravesab@100.85.36.72`, and passes now.
        - `apps/propertymanager-ios/Sources/SettingsView.swift`: both hints now interpolate `PropertyManagerBuildEnvironment.apiBaseURL` and `.manualLibraryBaseURL`. The Dashboard hint had the reverse bug: it showed the DEV address in Production builds. **Not compiled:** this VM has no Swift toolchain, so build-check it on the Mac.
        - The workflow now also runs the dashboard (55) and trends (2) tests. Both run with stdlib only (`python3 -S`).
      - Whether GitHub Actions is enabled on the `gravesab/openclaw` fork is UNKNOWN.

### P0-2. The Livestock "read" server writes to the DEV database outside the mutation contract
- **Evidence:**
  - `ranchbrain_app/ranchbrain/livestock_dev_read_server.py:1-7` says the server "does not accept writes, open PostgreSQL". But `do_POST`/`_write` (`:185`, `:243`, `:290-345`) retire animals, record sales, care, costs, herds, and identifiers.
  - `main()` (`:400`) wires `LivestockPostgresRecords`, which runs `ssh SSH-Dev docker exec … psql` (`livestock_dev_postgres.py:103-120`). SQL is built by string interpolation with a hand-written `quote()` (`:136-137`) instead of bound parameters.
  - Confirmation comes from the client: `body.get("confirmed") is True` (`livestock_dev_read_server.py:320,324,342`). The app text says "Saving confirms surgery, vaccination, medication, and cost" (`apps/ranchos-livestock-macos/Sources/LivestockModels.swift:1936`).
  - The tenant, user, and principal are fixed constants (`livestock_dev_postgres.py:13-15`).
  - The Swift client comment says "Read-only … no write verb" (`LivestockRepository.swift:144`), but the client does write.
  - The transport-free `livestock_mutation_coordinator.py`, which follows the contract, is not used on this path.
- **Conflicts with:** `RANCH_OS_CURSOR_ONBOARDING.md` invariants ("UI confirmation is not authorization"; authoritative mutations need confirmation, idempotency, transaction, and audit). It also conflicts with the CONF-021 challenge, which `LIVESTOCK_AUTHORITATIVE_MUTATION_PERSISTENCE_DESIGN.md` still marks design-only. Production schemes already exist (`#60`, `RanchOSLivestockProd.xcscheme`).
- **Done when:**
  - Writes either go through the coordinator, with a server-issued confirmation challenge, idempotency key, revision check, and an audit row in one transaction, or they are removed from this server.
  - SQL uses bound parameters.
  - Docstrings and client comments describe what the code actually does.
  - The Production Livestock backend target is documented. Today it is UNKNOWN: the only database runner hardcodes `SSH-Dev`.
- **Update (2026-11-05):**
  - **The Production app writes to the DEV database.** `apps/ranchos-livestock-macos/Sources/LivestockModels.swift:25` says "PROD drops the DEV prefix; the live ticket and server stay the same." The Production-labeled Livestock app (#60) therefore writes through the same loopback server to `ranchos_livestock_dev` in `openclaw-ai-postgres-dev` on the DEV VM. Real operational livestock records very likely live in the DEV database. That breaks DEV/PROD separation (IDP-077–078), and any DEV migration or test against that database touches real data.
  - **Measured gap:**
    - The DEV server accepts 13 write operations: animal create; herd create, assign/clear, and retire; identifier assign and retire; animal retire/sale; classification; care; feed consumption; cost; lifecycle record and correct.
    - None of them write an idempotency key or an audit row.
    - The contract-following `livestock_mutation_coordinator.py` covers 5 of the 13: animal create, identifier assign/retire, and lifecycle record/correct.
    - The coordinator requires CF-2 confirmations whose issuance (CONF-021) is still design-only. It also depends on P1-1 identity.
  - **The running server's source is not in the repo.** The Livestock Swift client (#56/#60) calls server features that `livestock_dev_read_server.py` and `livestock_dev_postgres.py` on this branch do not implement:
    - the `correctCare`, `correctConsumption`, and `correctCost` routes (`apps/ranchos-livestock-macos/Sources/LivestockRepository.swift:2239,2269,2297`);
    - the `weight_pounds`, `item_name`, and `item_kind` fields;
    - cost links via `lifecycle_event_id`, `care_event_id`, and `consumption_id`.

    The server the app uses runs on the owner's Mac (loopback, ticket in `~/Library/Application Support/RanchOSLivestock/`) from code outside this repository, possibly with schema past migration `022`.
  - **Owner decision 2026-11-05:** harden in place. Leave the Production-to-DEV database question for later, and treat `ranchos_livestock_dev` as real data until then.
  - **Hardening is paused:** it must target the real server source. Changing the stale in-repo copy would protect nothing, and running it would break the app.

### P0-3. The PropertyManager API exposes data without auth and binds to all interfaces
- **Evidence:**
  - Default bind is `0.0.0.0` (`tools/property_manager/api/gunicorn.conf.py:27`, `propertymanager_api.py:1768`).
  - These GET routes have no auth decorator: `/tasks`, `/tasks/<id>`, `/categories`, `/v1/assets`, `/v1/assets/<id>`, asset by external ID, asset by QR, meter readings and meter-reading parse (`assets_api.py:46-59`, `list_assets` at `:463`), and mapping proposals.
  - The test-only route `/v1/test/slow-db` ships in the production app (`propertymanager_api.py:553`).
  - The operator identity recorded on writes comes from the client header `X-Operator-Identity` (`auth.py:32,100`).
  - Setting `PROPERTYMANAGER_AUTH_DISABLED` turns all auth off (`auth.py:18`).
  - `/health` reports the auth mode without auth.
- **Related:** On tvOS, `apps/ranchos-tvos/HubSources/RanchOSPropertyLiveStore.swift:58-63` reaches the DEV API over plain HTTP through a home-LAN relay, `andrew-m4-pro.local:15063` (LaunchAgent `ai.openclaw.propertymanager-dev-lan-relay`). The relay is not versioned in this repo, and the request carries a static API key.
- **Conflicts with:** API-Exposure Audit Prompt §Phase 1 items 4 and 8 (anything reachable from the LAN without auth is a finding), Finance Spec §7.3 (local or Tailscale-only interfaces), and the Red-Team design target 4 (auth on every route).
- **Done when:**
  - The API-Exposure Audit Phase 0/1 inventory has been run on DEV and logged.
  - The API binds to `127.0.0.1` plus the Tailscale interface by default.
  - Reads require auth.
  - The operator identity is derived on the server.
  - The test route is removed or compiled out.
  - The LAN relay is either replaced, for example with a tailnet-capable path or TLS plus per-device credentials, or recorded as an accepted finding with the owner's sign-off.

#### P0-3 status: read auth (2026-11-05, uncommitted)

- **Done:** all 10 PropertyManager reads now require the API key or the operator PIN (`@auth_required(allow_pin=True)`), and they return 401 before any query:
  - `GET /categories`, `/tasks`, `/tasks/<id>`
  - `/v1/assets`, `/v1/assets/<id>`, `/v1/assets/by-external-id/<id>`, `/v1/assets/by-qr/<token>`, `/v1/assets/<id>/meter-readings`
  - `/v1/mapping-proposals`
  - `POST /v1/meter-readings/parse`, which reads asset names

  `/health` stays open. This reverses the July 2026 contract `test_reads_remain_unauthenticated` (`e5f6afdb966`), in line with `PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md` "QR code security": anonymous QR reads are allowed only if the operator enables public read per asset class, and no such setting exists.
- **Tests:** `ReadAuthTests` in `tools/property_manager/tests/test_mutating_route_auth.py`. They fail on HEAD, where all 10 routes answered without credentials, and pass now. `PmAssetPageApiReadAuthTests` checks that the dashboard QR landing sends its key (`tools/dashboard/pm_asset_page.py:_api_get`). CI runs both.
- **Client check, from source:**
  - The iOS, macOS, and tvOS clients attach the key or PIN on every request.
  - PIN-only iPhone setups keep working, because reads accept the PIN.
  - The dashboard's PropertyManager calls already sent the key, except the QR landing (fixed).
  - `list_equipment_tasks_missing_hour_trigger.py` and `propertymanager-mapping-proposals.py` send the key.
  - `refresh_mac_cache_from_api.sh` now needs `PROPERTYMANAGER_API_TOKEN`.
  - `daily-executive-briefing.sh` only reads `/health`.
- **Already broken before this change, now repaired (2026-11-05):** `ranchbrain/src/ranchbrain/show_asset.py`, `tools/property_manager/propertymanager-meter.py` (the Telegram meter command), and `tools/property_manager/generate_asset_qr.py` called unprefixed `/assets…` routes. Those routes exist only under `/v1`, so the calls returned 404, and the meter script posted readings without credentials.
  - All three now use `/v1` paths and send `PROPERTYMANAGER_API_KEY` as a Bearer token, or `PROPERTYMANAGER_OPERATOR_PIN`.
  - Without credentials:
    - the meter script exits 2 with a clear message before any request;
    - the QR generator stops before any request;
    - `show_asset.py` omits the meter section.
  - The meter post also sends an `Idempotency-Key` and prints the API's `message`.
  - **Tests:** `tools/property_manager/tests/test_api_client_scripts.py` (7 tests, `urlopen` stubbed). All 7 fail on the HEAD versions of the scripts.
  - **Deploy note:** the Telegram poller's environment needs `PROPERTYMANAGER_API_KEY` or the PIN for the meter command to work.
- **Deploy notes:**
  - The dashboard needs `PROPERTYMANAGER_API_KEY` set, or the QR landing shows nothing.
  - The live script `test_phase2_meters.py::test_qr_read_anonymous` now fails by design.
  - Not deployed; no running service was changed.
- **Still open, owner decisions:**
  - the default bind `0.0.0.0` (PROD may rely on it)
  - the client-asserted `X-Operator-Identity` on writes
  - the tvOS LAN relay (plain HTTP, static key)
  - the env-gated `/v1/test/slow-db` route
  - the auth details `/health` reveals
  - a per-asset-class public QR read setting, if anonymous QR is wanted

#### API-Exposure Audit Phase 0: DEV VM inventory (2026-11-05)

- **Method:** read-only, as `openclaw-agent` without root. I could not map another user's sockets to processes, so I identified `gravesab` processes from filtered argv tokens: script, module, and `-L` forward specs only. I read one environment variable, an IP address. No probing, no changes, no PROD contact.
- **Log:** the full command log is in the session scratchpad (`api-audit-phase0.log`), not committed.

| Port | Bind | Service (owner, source) | Phase 0 note |
|---|---|---|---|
| 22/tcp | `0.0.0.0`, `[::]` | sshd | Every interface, including `enp6s0` (`192.168.124.10`). Phase 1: test whether the LAN can reach it. |
| 443/tcp | Tailscale IP | `tailscale serve` → `127.0.0.1:18789` (gateway) | Tailnet only. `tailscale funnel` exposes nothing publicly. Gateway auth: Phase 1. |
| 5063/tcp | Tailscale IP | RanchBrain P3 `ranchbrain.api.server` (gravesab, running since 2026-10-03) | **Review.** The running code is not this branch, where `main()` refuses to start (P1-1). **Phase 1, vantage (a), 2026-11-05:** unauthenticated `GET /v1/memory/list` → `401` with `WWW-Authenticate: Bearer`, and `GET /` → `404`. Both bodies are error JSON only (`code`, `message`, `request_id`); no data was returned. Server header: `RanchBrainP3/1.0 Python/3.12.3`. It does refuse requests with no token. Still UNKNOWN: which checkout and commit it runs, and whether it verifies token *signatures*. I did not test the latter, because the audit forbids crafted or guessed credentials. |
| 5062/tcp | `127.0.0.1` | PropertyManager API, gunicorn (gravesab, checkout `openclaw-release-20261008-manuals-api`) | Loopback here, so the bind override is set. iOS DEBUG and tvOS target `100.85.188.74:5062` and `:15063`, so how they actually reach it (tunnel or relay) is UNKNOWN. |
| 5051/tcp | `127.0.0.1` | DEV dashboard (openclaw-agent, checkout `openclaw-dev-dashboard`) | `OPENCLAW_INTELMINI_STORAGE_HOST` is unset, so it uses the PROD default. Its SSH key (`openclaw_dev_backup_ed25519`) is absent for this account, so the PROD SSH calls fail. Not verified from dashboard logs. |
| 8001/tcp | `127.0.0.1` | `ranch-sentinel` (`tools.security.sentinel`, outside this repo) | Loopback. Not in scope of the repo docs. |
| 18789–18790/tcp | `127.0.0.1` | Gateway container `openclawdev-openclaw-gateway-1` | Loopback publish. Reached on the tailnet only through `serve`. |
| 19091/tcp, 39603/tcp | `127.0.0.1`, `[::1]` | Likely the gravesab gateway `openclaw-dev-2026.9.4` (`--bind loopback`) | UNKNOWN mapping. Loopback. |
| 11434/tcp, 11435/tcp | `127.0.0.1` and **`172.17.0.1`** | SSH `-L` forwards to a remote Ollama | Any container on the default Docker bridge can reach Ollama without auth. |
| 18088/tcp | `127.0.0.1` | SSH `-L` forward to a remote `:8088` | Service UNKNOWN. |
| 55432/tcp | `127.0.0.1` | Postgres container `openclaw-ai-postgres-dev` | Loopback publish. |
| 6379/tcp | `127.0.0.1` | Redis `ranch-sentinel-redis` | Loopback publish. |
| 41641/udp, 53, 68 | various | Tailscale WireGuard, resolved, DHCP | Expected. |

- **MCP servers (PropertyManager, AI intelligence):** both call `mcp.run()` with the default transport. No network listener was observed, so they are stdio or not running.
- **Other findings:**
  1. The agent account `openclaw-agent` is in the `docker` group, which is root-equivalent on the VM, and in the `gravesab` group. An agent session has far more power than "read-only" implies.
  2. Running DEV services come from at least four separate checkouts:
     - `openclaw-dev-2026.9.4`
     - `openclaw-release-20261008-manuals-api`
     - `openclaw-dev-dashboard`
     - `~/ai/projects/openclaw`

     None of them is this `~/openclaw` branch, so the code analyzed in this report is not proven to be the code that is running (relates to P0-4).
- **Still needed for Phase 1** (from other vantage points, owner-run):
  - reachability from the tailnet and the home LAN;
  - auth on `:5063` and on the gateway behind `:443`;
  - the M4 relay path;
  - router port-forwards and UPnP;
  - the Home Assistant remote path;
  - the Tailscale ACL policy.

### P0-4. The onboarding index contradicts the code, so agents hit its "stop" rule
- **Evidence:** `RANCH_OS_CURSOR_ONBOARDING.md` contradicts the code in three places:
  - It says `apps/ranchos-tvos/` is an "Untracked DEV fixture … no … live tenant feed" (`:177`). The tvOS app is tracked (98 files) and pulls live PropertyManager data.
  - It says Livestock macOS is "fixture-only … Do not grow live persistence" (`:176`). The app writes to a live DEV database and has Prod/iOS schemes.
  - It says "Do not contact its [PropertyManager] API" (`:162`). The tvOS app does.
- **Related:** `LIVESTOCK_AUTHORITATIVE_MUTATION_PERSISTENCE_DESIGN.md` says migrations `001`–`004` are "unapplied/disposable-only", but `ranchbrain_app/migrations/` runs to `022` and the code queries a persistent `ranchos_livestock_dev` database. The DEV apply state is UNKNOWN.
- **Why P0:** The index tells every agent to stop when docs conflict. As written, any Livestock or tvOS build hits that stop condition.
- **Done when:** The owner approves a refreshed precedence index and status lines that match what is actually deployed in DEV, including which migrations are applied, which apps are live, and which endpoints are approved.

### P0-5. The two Finance contracts contradict each other
- **Evidence:**
  - `docs/ranch-os/Ranch_Finance_Master_Specification_v1.1.md` describes a single-entry ledger: signed `transactions.amount` with no direction field (§4), domains `personal`/`ranch`/`zero_g` (§5.1), and `America/Chicago` month boundaries (§2.8). It defers direct bank aggregation (§3.2) and sets the order CSV import, then "This Month" SwiftUI (§12).
  - The implemented `ranchbrain_app/docs/RANCH_FINANCE_FOUNDATIONAL_DESIGN.md` and `migrations/005_finance_persistence_foundation.sql` describe a double-entry ledger with immutable journal entries, an `allocation_domain` of `household|livestock|property|equipment|land` (`005:203-243`), tenant/workspace ownership, and a plan for per-institution read-only connectors.
  - No `zero_g` / Zero-G LLC domain exists anywhere in the Finance code.
  - No `America/Chicago` handling exists in `finance_model.py`.
  - No Finance HTTP API exists. The RanchBrain server serves only memory and search (`ranchbrain_app/ranchbrain/api/server.py:1-10`).
  - No Swift Finance client exists.
- **Rule:** Master Spec §1 says that on a conflict, the agent must "document the conflict and stop for review". §15 says that changing amount semantics or domain separation is an architectural change.
- **Done when:** The owner rules which ledger model and domain model are canonical. The other document is revised or retired through the §15 change control. A file-level checkpoint plan (Spec §12, Checkpoint 0) exists for the chosen contract.
- **Ruling (owner, 2026-11-05): Master Spec v1.1 is canonical.**
  - `RANCH_FINANCE_FOUNDATIONAL_DESIGN.md` is marked Superseded.
  - Its double-entry model and domains are retired as an implementation contract.
  - Its tenancy, RLS, idempotency, and audit patterns are reused in the Spec's Checkpoint 1 migration.
  - `005_finance_persistence_foundation.sql` and the `finance_*` modules were never applied. They stay in place until a separately approved cleanup.
  - **Checkpoint 0 plan drafted (Proposed):** `docs/ranch-os/Ranch_Finance_Checkpoint_0_Plan_v1.md`. It covers repo conventions verified from source and 13 conflicts with proposed resolutions. Key ones:
    - tenancy and FORCE RLS added to every Spec table (the Spec is silent on tenancy);
    - the Personal domain blocked until a per-user privacy policy is approved;
    - unapplied 005 to be replaced only after a read-only check of its applied state;
    - Finance built as a RanchOS module, not a standalone app;
    - new code in `ranchbrain/finance/`.

    It also has a file-level Checkpoint 1 plan with tests mapped onto the existing CI lanes, an outline for CP2–5, the Apple-first statement, and 6 owner decisions (D1–D6). It is blocked by P1-1 for any runtime endpoint and by the Livestock source for migration numbering.
  - **Owner rulings, 2026-11-05:**
    - D1 accepted: the onboarding doc now names the Spec.
    - D2 accepted: tenancy and FORCE RLS on every table.
    - D3 accepted: the Personal domain is blocked until a privacy policy is approved.
    - D5 accepted: Finance is a RanchOS module.
    - D4 approved: replace 005 in place. A read-only catalog check of the DEV Postgres container found no `ranchos.finance*` tables in any database. That also resolves the C7 numbering dependency.
    - D6 approved: remove the superseded code and its tests in the same change that replaces 005.
  - **Checkpoint 1 in progress (2026-11-05):**
    - `migrations/005_finance_v1_foundation.sql` replaces the old 005 with the Spec tables, tenancy, FORCE RLS, append-only audit, and transfer pairing.
    - New `ranchbrain/finance/` package: model, reporting, read contract, and pg read session.
    - 77 new tests pass locally.
    - The superseded double-entry code (15 files) is removed.
    - **Not yet done:**
      - the disposable-Postgres proof and the two-tenant RLS SQL. The migration SQL has never run against a real Postgres; its first CI run is the proof.
      - redefining the double-entry write capabilities left in `tenancy.py`.
    - **Owner review:** a refund in an expense category counts as income in §6.1 and also nets down its category in §6.2.

---

## P1: needed soon

### P1-1. SSO / identity can't run: there is no token signature verifier
- **Evidence:** `ranchbrain_app/ranchbrain/identity_oidc.py:1-13` validates claims but leaves signature checking to an injected `TokenSignatureVerifier`. No implementation exists outside tests. `api/server.py:416-424` refuses to start ("crypto dependency pending approval"). Membership comes from `api/membership.py`, and its persistent backing store is UNKNOWN.
- **Impact:** Authenticated RanchBrain reads, any Finance API, the Red-Team target 8 cross-tenant tests, and multi-user Finance (two equal admins) are all blocked.
- **Done when:** A JOSE/JWKS library is approved and pinned, a verifier is implemented with key rotation, the server starts in DEV behind loopback plus Tailscale, and the `ranchbrain_app/tests/rls/two_tenant_*.sql` suites run against it as a non-superuser.

### P1-2. PropertyManager has no tenancy or RLS
- **Evidence:** No `tenant_id` or `ROW LEVEL SECURITY` appears in `tools/property_manager/db/*.sql`. By contrast, every table in `ranchbrain_app/migrations/` uses ENABLE + FORCE RLS. The Briefing and Poster list a "Tenant-safe foundation: Context, authorization, RLS" as core, and `MULTI_TENANCY_DESIGN.md` §DEV rollout step 5 says to "Convert each Ranch OS module…".
- **Done when:** A PropertyManager tenancy migration plan exists, covering a bootstrap tenant, backfill, FORCE RLS, and a runtime role without BYPASSRLS, with two-tenant isolation tests. Alternatively, a recorded decision states that PropertyManager stays single-tenant and why.

### P1-3. No CI runs any Ranch OS test
- **Evidence:** No workflow in `.github/workflows/*.yml` references `ranchbrain_app`, `property_manager`, `ai_intelligence`, or `ranchos`. The test suites exist but nothing runs them automatically:
  - `ranchbrain_app/tests` (about 50 files, including RLS SQL)
  - `tools/property_manager/tests` (31 files, including `test_mutating_route_auth.py`)
  - `tools/ai_intelligence/tests` (20 files)
  - Swift `HubTests` and `Tests`
- Current pass/fail state: UNKNOWN (not run; read-only).
- **Done when:** A DEV CI lane runs the Python suites, plus the disposable-Postgres and RLS suites with a throwaway database, on every PR to `development`. Swift tests run on a macOS runner or a documented manual gate.
- **Status (2026-11-05, uncommitted):** `.github/workflows/ranchos-python-tests.yml` added.
  - **`unit` job:** no database. `docker`, `ssh`, `scp`, `psql`, `systemctl`, `pg_ctl`, and `initdb` are stubbed to fail loudly.
  - **`postgres-proofs` job:**
    - the `*_disposable_pg.py` proofs, using the runner's `/usr/lib/postgresql/16/bin`, which is assumed to exist and is checked first;
    - the two-tenant RLS script against a `postgres:16` service, with a non-superuser `ranchos_dev_migrator` and a NOBYPASSRLS `ranchos_dev_runtime`;
    - the PropertyManager container tests on `pgvector/pgvector:pg16`.

    It was **not run locally**: the VM has no Postgres binaries, and I would not start containers on DEV. Its first CI run is the proof.
  - **Local baseline:** scratchpad venv from the repo requirements plus pytest, temporary `HOME`, stubbed binaries.
    - `tools/ai_intelligence`: 165/165 pass.
    - `ranchbrain_app` without the disposable-PG files: 315/315 pass. With them, and no binaries: the 11 Finance tests skip, and the **17 Livestock tests error instead of skipping** (`LiveProofBlocked` is raised, not `skipTest`).
    - `tools/property_manager`, unit set: **237/253 pass; 13 fail and 3 error**. The same failures, plus the 5 in `test_migration_chain`, reproduce on pre-session commit `08d91b12e68`, so they predate this work. Causes:
      - 11 in `test_work_requests` and 2 in `test_migration_authority` are stale after migrations 017/018 (#61, #62). Health expects `017` but sees `018`; the manifest count is 261 vs 260; requests return 500 where the fixtures predate the parent-asset requirement.
      - `test_migration_chain` reports an "ambiguous migration chain" (CI-only).
      - `test_task_completion` and `test_task_photos` make a real `docker exec` call, so they are not hermetic.
      - `test_asset_pseudo` raises "Working outside of application context".
  - The PropertyManager step will be **red** until these are fixed. I did not add an expected-failure list, because repo policy forbids silencing failures without approval.
  - **Fixed (2026-11-05, uncommitted). The local unit job is now green: AI 165/165, RanchBrain 315/315, PropertyManager 255/255 under `unittest` plus 4/4 under pytest. Reverse order and per-module runs also pass, with 0 blocked infrastructure calls.**
    - `test_work_requests`: the health tests compare against `EXPECTED_SCHEMA_VERSION` instead of a hardcoded `"017"`.
      - `setUp` stubs the #62 pseudo-asset guard, which runs its own `pm_db` lookup. Two new tests exercise the real guard: a pseudo asset is rejected with 400 and no write, and a real asset passes through.
      - The generic-upsert test sends the `asset_id` that 017 requires and scripts 017's active-asset lookup.
      - The untriaged-request test compares SQL with whitespace collapsed.
    - `test_migration_authority`: the 018 pins changed from 260 columns / 106 constraints to 261 / 107. I verified that 018 adds `assets.is_pseudo` and `assets_pseudo_root_check`. The canonical category count is 5 (was 8), matching the hash-pinned contract.
      - **Owner-confirmed 2026-11-05 as intended:** the 016 snapshot regenerated in #62 dropped the Hot Tub, Pool, Safety, and Tractor seed categories and added Home.
    - `test_migration_chain`: the chain is extended to 017/018, with the version list and snapshot key derived from `MIGRATIONS`. The 5 mocked tests pass. The container run is CI-only and not yet proven.
    - `test_task_completion` and `test_task_photos`: they now script the #53 bypass-events query.
    - `test_work_requests`, `test_handbook_api`, `test_maintenance_proposals`, `test_task_bypass`, `test_task_completion`, `test_task_photos`: the hardcoded module-reload lists are replaced by "drop every module loaded from `api/`". The old lists missed `task_schedule`, which kept a stale `db` binding, so queries reached a real `docker exec`.
    - `test_asset_pseudo`: it now runs inside a Flask app context and asserts 400 with `field: asset_id`.
    - **Live scripts:** new `tools/property_manager/tests/conftest.py` makes pytest skip `test_meter_delta`, `test_phase1_meters`, `test_phase2_meters`, `test_restart_drain`, and `test_run_hours_trigger` unless `PROPERTYMANAGER_LIVE_INTEGRATION=1`. `test_meter_delta` is a fifth live script: it imports the live helpers. `test_task_title` (pytest-style, pure) had never run under `unittest`. CI now runs it with pytest.
    - **Guard self-scan bug:** once committed, the guard's own allowlist and tests were tracked and matched its patterns, so the guard workflow would have failed. `tools/ranchos_guard/` is now excluded from its own scan, with a test.
    - **Non-hermetic dashboard test:** `test_backup_center_uses_remote_inventory_and_safe_controls` did not patch `backup_center_m4_time_machine()`, so rendering ran a real read-only `ssh andrewgraves@192.168.50.117` (`tmutil status`). It is now patched.
      - **Disclosure:** my earlier unstubbed runs of this file in this session attempted that SSH connection. This account has no M4 key (`openclaw_m4_metrics_ed25519` absent; `BatchMode` and `IdentitiesOnly` set), so it could not authenticate. The target was the M4 workstation, not PROD.
    - **Still open:** the Livestock disposable-PG proofs raise `LiveProofBlocked` as an error, not a skip, when no Postgres is available. That is noise only; CI has the binaries.
  - **Hazard:** `test_phase1_meters.py`, `test_phase2_meters.py`, and `test_run_hours_trigger.py` are pytest-style module functions that call the live API at `127.0.0.1:5062`. `unittest` ignores them, but `pytest tools/property_manager` would run them against the live DEV API. They should move out of `tests/` or be gated behind an env var like `test_restart_drain.py`.

### P1-4. The model-router designs conflict, and the hybrid design's trust controls are missing
- **Evidence:**
  - Hybrid Routing v1 §2–4 puts Qwen on oMLX as the primary model for everything. It escalates on a capability or quality signal, with "one attempt… then route or fail".
  - Implemented Phase 2F (`docs/architecture/phase-2f-runtime-ai-router.md` §7) does automatic failover across a chain on availability errors only.
  - The deployed map uses Ollama Hermes 3 8B as the RanchBrain primary (`config/ai_intelligence/deployment_map.json`).
  - Providers wired: Foundation Models, oMLX, and Ollama only (`tools/ai_intelligence/execution_engine.py:325-331`). No OpenAI-compatible or OpenRouter provider exists, though `model_registry.json` lists cloud models.
  - None of these exist anywhere in `tools/ai_intelligence/`:
    - the egress allowlist
    - the redaction pass
    - per-call or aggregate spend caps
    - an operator kill switch (Addendum Gap 2)
    - a hash-chained audit log (Addendum Gap 3)
    - an external escalation scorer (Addendum Gap 1)
- **Note:** The cloud path is unreachable today, which is safe. The design is "Proposed — not approved", and its 5 open decisions plus the 2 addendum items are still waiting on the owner.
- **Done when:** The owner rules on the v1 open decisions 1–5 and addendum items 6–7. Phase 2F and Hybrid v1 merge into one router contract. The kill switch and tamper-evident telemetry ship before any API tier, because they are useful even when local-only. An API provider is added only with the allowlist, redaction, and caps in place, starting from an empty allowlist.

### P1-5. Host and hardware facts disagree across documents
- **Evidence:**
  - The API Exposure Audit says "the Ubuntu DEV VM on the M4 Mac" (`:8`). AGENTS.md says the DEV VM runs on the Intel Mini.
  - The Firecrawl design §3 and §8.1 recommend deploying on the Intel Mini, which AGENTS.md names as the PROD host, without saying "the DEV VM".
  - The workstation is named `andrew-m4-max-3` (AGENTS.md) and `andrew-m4-pro.local` (tvOS code). Moshi §5 says it has 24 GB.
  - The Ollama host `192.168.50.117` is unidentified (`run_local_llm_handbook_eval.py:30`, `tools/ranchbrain/ranchbrain-review.py:74`).
  - The Red-Team and Moshi docs say "SSH still undelivered", which is stale.
- **Done when:** One owner-approved host inventory exists (machine, role, environment, RAM/GPU, tailnet name), and every design cites it.

### P1-6. Unauthenticated LAN services and published ports
- **Evidence:**
  - Ollama is reached over plain HTTP on the LAN at `192.168.50.117:11434`. Ollama has no built-in auth.
  - The gateway compose publishes `18789`/`18790` on all host interfaces (`docker-compose.yml:63-65`).
  - Postgres, Qdrant, and Home Assistant bind addresses in DEV: UNKNOWN (not probed).
- **Done when:** These appear in the audit inventory from P0-3 with an OK or FIX verdict. Fixes are applied one at a time with the owner's go-ahead.

### P1-7. Firecrawl URL ingestion is not built
- **Evidence:**
  - The schema allows `source_kind IN ('pdf','url')` (`tools/property_manager/db/010_handbook_ingestion_v1.sql:25`).
  - The handbook API accepts only Dashboard-library PDF locators (`api/handbook_api.py:97-112`).
  - There is no URL validator, SHA-over-fetched-bytes step, or Firecrawl job provenance.
  - The upstream Firecrawl plugin defaults to the cloud `https://api.firecrawl.dev` (`extensions/firecrawl/src/config.ts:5`). It does have SSRF guards and a private self-hosted `baseUrl` option (`firecrawl-client.ts:43-47,111`).
  - No self-hosted Firecrawl stack is defined in the repo.
- **Done when:** The Firecrawl design §9 acceptance criteria 1–6 pass in DEV, including the SSRF and DNS-rebinding probes, with the cloud default explicitly overridden.

### P1-8. Private data in the repo blocks the give-away endgame
- **Evidence:**
  - AGENTS.md (uncommitted diff) adds Tailscale IPs and hostnames.
  - `docs/ranch-os/*` names people and quotes the owner's inbox.
  - `RANCH_FINANCE_FOUNDATIONAL_DESIGN.md` names banks and loans.
  - `RANCH_OS_CURSOR_ONBOARDING.md` contains `/Users/andrewgraves/...` paths.
  - Telegram scripts contain `/home/gravesab/...` paths.
  - `docs/ranch-os/` sits outside `docs/internal/`, which is the only directory `scripts/docs-sync-publish.mjs:13` excludes. `docs/CLAUDE.md` also requires public docs to stay generic.
  - The fork's visibility is **private, per the owner (2026-11-05)**. I could not verify it from the VM because `gh` is not installed. Being private makes pushing this branch safe for now. It does not remove the need to scrub before any public release.
- **Done when:** There is a decided home for private operator material, either `docs/internal/` or a separate private repo, plus a placeholder/config pattern for hosts and paths. A secret and PII scan has been run before any public release.

### P1-9. Three RanchBrain codebases, and no vector store
- **Evidence:**
  - Three codebases exist: `ranchbrain/` (scripts plus `src/ranchbrain`), `ranchbrain_app/` (tenant-aware), and `tools/ranchbrain/` (embeddings through LAN Ollama).
  - `ranchbrain_app` search is a substring line scan (`ranchbrain_app/ranchbrain/search_engine.py`).
  - The Poster specifies "Vector DB: Qdrant". `PROJECT_CONTEXT.md` says pgvector. Neither is used in the Ranch OS code.
  - Finance Spec §2.7 and Acceptance Criterion 11 (no raw finance data in RanchBrain) have no enforcement point yet.
- **Done when:** One RanchBrain codebase is designated canonical and the others are archived. The vector store choice is decided. The tenant-scoped RAG path has a "no Finance or Health ingestion without approved transformation" guard with a test.

### P1-10. SimpleFIN has no design and no code
- **Evidence:** No reference to SimpleFIN, Plaid, or FinanceKit anywhere in code or docs. The Master Spec §3.2 defers bank aggregation. The foundational design §Supported source plan wants per-institution read-only connectors. A SimpleFIN Access URL is a bearer credential.
- **Done when:** A design doc covers SimpleFIN scope (read-only), credential storage (OS secret store, never repo or app preferences), sync cadence, dedup against CSV imports, a disconnect/repair UX, and threat-model tests (Spec §11). It goes through the same approval as P0-5 and stays sequenced after CSV import.
- **Status (2026-11-05):** `docs/ranch-os/Ranch_OS_SimpleFIN_Connector_Design_v1.md` is drafted. Status: **Proposed, not approved**.
  - Protocol and Bridge facts are verified from the SimpleFIN spec (`2.0.0-draft`) and the Bridge developer guide (sources cited):
    - read-only;
    - the Access URL embeds Basic credentials;
    - at most 90 days per request;
    - about 24 requests a day expected, and overuse disables the token;
    - positive amounts are inflows;
    - transaction IDs are unique within an account.
  - It follows Master Spec v1.1, per the P0-5 ruling of 2026-11-05. It requires a Master Spec revision for §3.2, the new `simplefin` source type, and an exception to the §2.4 no-cloud-provider principle.
  - It covers: the opt-in cloud exception, the server-only secret store with canary redaction tests, a claim-host allowlist with SSRF tests, a sync worker capped at 12 requests a day, staging into the Checkpoint 3 pipeline with no auto-commit, pending never totaled, America/Chicago dates, exact decimals, error and repair states, and the S0–S5 gated checkpoints.
  - **UNKNOWN:** the upstream aggregator and data retention, pending support on the Bridge, and the revocation mechanism. The owner must review these before opt-in.
  - 7 open decisions await the owner, §14.

### P1-11. App credentials stored in plain app preferences
- **Evidence:** The PropertyManager iOS app keeps `apiKey` and `operatorPIN` in `@AppStorage`, which is UserDefaults (`apps/propertymanager-ios/Sources/PropertyStore.swift:36-39`). There is no Keychain use in `apps/propertymanager-ios/Sources`. Finance Spec §7.3 says secrets must never go in app preferences. The macOS app already does this correctly: `SecureCredentialStore.swift` stores credentials in the Keychain, and `PropertyManagerApp.swift:665-666` moves old values out of UserDefaults and deletes them. The tvOS app also reads its key from the Keychain.
- **Done when:** The iOS app uses the same `SecureCredentialStore` pattern, ideally shared rather than copied, moves and deletes existing UserDefaults values, and has a test proving no credential remains in UserDefaults.

---

## P2: nice to have

### P2-1. Moshi voice layer: no code, and its relation to Apple-first is unaddressed
- **Evidence:** No Moshi, Kyutai, or full-duplex code exists. `tools/voice_service/voice_service.py` is only a heartbeat loop. Jarvis uses Apple on-device `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`, `apps/ranchos-tvos/HubSources/Jarvis/VoiceInput.swift:73`) with `AVSpeechSynthesizer`. That already keeps audio local. AGENTS.md says Apple frameworks are evaluated first, but the Moshi design never compares against them.
- **Done when:** The Moshi design adds the Apple Speech baseline and the reason for departing from it, and the owner decides §9 items 1–7. The §8 trial (read-only intent first) runs on the M4 with logged latency. It depends on the P1-4 kill switch, because a spoken "stop" must halt a task.

### P2-2. Telegram hardening
- **Evidence:** The bot uses polling (`getUpdates`), so the webhook-secret concern in Red-Team target 1 mostly doesn't apply. The chat allowlist fails closed, which is good. But the bot token is passed in the `curl` URL on the command line (`propertymanager-telegram-poll.sh:16-18`), where it shows in the process list. Chat commands can also trigger update and backup scripts (`propertymanager-telegram-command.py:155-240`).
- **CVE status:** The repo version is `2026.5.16-beta.4`, which is at or above 2026.2.1. The deployed DEV version and the CVE-2026-25474 details are UNKNOWN.
- **Done when:** The token is passed through a config file or stdin. Write-capable chat commands require a confirmation step. The deployed version is recorded.

### P2-3. Location data leaves the ranch
- **Evidence:** `RanchVAWeather.swift:94` sends property coordinates to `api.weather.gov`.
- **Done when:** This is listed as an owner-approved egress in the exposure inventory, or the coordinates are coarsened.

### P2-4. Code that no design covers
- tvOS hub, Jarvis workspace, Logitech camera (`apps/ranchos-tvos/HubSources/Jarvis/*`)
- AI evaluation lab, scorecards, benchmarks (`tools/ai_intelligence/*`)
- home_manager scripts
- Livestock bill of sale
- A 1,039-line `AppleIntelligenceDictation.swift` vendored into Livestock (`#60`), duplicating the shared code
- **Done when:** Each has a status line in a design or registry, and the dictation code lives in `apps/shared`.

### P2-5. Smaller loose ends
- PropertyManager migrations skip `007`/`008`. This may be intentional per `migration_authority.json`; UNKNOWN.
- Health + Wellness has no module in the surveyed trees. It needs its own privacy policy first (onboarding invariants), and I did not inspect it further.
- The Poster names "Python FastAPI", but the code is Flask/Gunicorn plus stdlib `http.server`.
- Inventory, Field, and hardware integrations (RFID, scales) are poster-only.

---

## Recommended build sequence

1. **Owner rulings (no code):** Finance contract (P0-5), refreshed onboarding precedence and status lines (P0-4), host inventory (P1-5), router open decisions 1–7 (P1-4), and where private docs live (P1-8).
2. **Safety hygiene:** Remove the PROD defaults (P0-1). Run the API-Exposure Audit Phase 0/1 on DEV, read-only and logged (P0-3, P1-6).
3. **Close the exposures:** Lock down PropertyManager binding and read auth, derive operator identity on the server, remove the test route, and decide the LAN relay's fate (P0-3).
4. **Livestock write path:** Route writes through the coordinator with server-issued confirmation and bound parameters, or remove them. Fix the docs (P0-2).
5. **CI lane** for the Ranch OS Python and RLS suites (P1-3). It guards everything after this step.
6. **Identity:** Approved JOSE verifier, start the RanchBrain service in DEV, two-tenant RLS proof (P1-1). Then plan PropertyManager tenancy (P1-2).
7. **Finance Checkpoints 1→2** on the chosen contract: read API with auth, then read-only "This Month" SwiftUI. Checkpoint 3, CSV import, follows after the §11 threat tests.
8. **Router trust controls:** Kill switch and hash-chained telemetry while still local-only. Add the API tier only if approved, with allowlist, redaction, and caps (P1-4).
9. **Local Red-Team pass** (Phases 0–4) against the hardened DEV system (steps 3–8).
10. **Firecrawl URL ingestion** (P1-7) and **RanchBrain consolidation and vector store** (P1-9).
11. **SimpleFIN design**, then implementation after CSV import is proven (P1-10).
12. **Moshi DEV trial** on the M4, read-only intent first (P2-1).
13. **Give-away readiness:** PII and secret scrub, license and attribution review (Firecrawl AGPL, Moshi CC-BY) (P1-8).
