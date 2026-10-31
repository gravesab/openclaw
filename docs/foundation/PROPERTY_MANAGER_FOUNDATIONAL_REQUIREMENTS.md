---
title: "PropertyManager Foundational Requirements"
version: "1.4"
status: "Phase 3 deployed — post-deploy verification"
owner: "OpenClaw Operator"
last_reviewed: "2026-07-30"
category: "Governance"
source_document: "PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md"
---

# PropertyManager Foundational Requirements

Version: 1.4  
Status: **Phase 3 deployed on production Intel Mini** — post-deploy verification  
Owner: OpenClaw Operator  
Last Updated: 2026-07-30

---

## Purpose

This document is the authoritative policy and requirements baseline for PropertyManager assets, operating meters, and meter-based preventive maintenance. It governs all schema, API, client, migration, and rollout work.

Implementation details live in [PropertyManager Asset Architecture](../architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md). This document must not be contradicted by implementation.

---

## Phase 0 gate — design approved; Phase 3 deployed on production

**Phase 3 (production Intel Mini) deployed 2026-07-29:**

- Operator authorized production rollout ("Page 3 authorized" = Phase 3)
- Host confirmed: `intelmini` / Tailscale `100.85.36.72`
- Pre-migration Postgres backup taken; migrations 005/006 already present (`schema_version` `006`)
- API restarted with auth enabled (`auth_required: true`, `api_version: v1`)
- RanchBrain import applied (proposed meters; no blind mapping auto-approve)
- Dashboard QR routes live; dashboard auth EnvironmentFile needs operator sudo helper
- Evidence: `reports/propertymanager/phase3-production-evidence.md`
- Remaining: activate meters, rotate secrets if desired, rebuild Mac/iOS against prod URL, Phase 4 monitoring

**Phase 2 (dev VM) delivered 2026-07-29:**

- iOS/Mac clients wired to `/v1/` asset and meter endpoints
- Lower-reading preview → confirm flow (preview_token, operator_identity, correction_reason)
- activate-meter UI for proposed meters
- Task completion: `meter_value_at_completion` or `confirm_current_meter=true` (no silent default)
- Phase 2 client contract tests: `tools/property_manager/tests/test_phase2_meters.py`
- Evidence: `reports/propertymanager/phase2-acceptance-evidence.md`
- Mac M4: `swift build -c release` passed with Phase 2 AssetAPIClient/AssetViews

**Phase 1 (dev VM) delivered 2026-07-29:**

- Migration `006_phase1_meter_audit.sql` applied on development VM
- REST API `/v1/` with auth seam, decimal-safe values, cursor pagination, idempotency, optimistic locking
- Lower-reading preview/confirm workflow
- Backdated reading recalc (conditional `current_value` update)
- Proposed meter defaults + `POST /v1/assets/<id>/activate-meter`
- RanchBrain mapping proposals (no auto-apply) + CLI `propertymanager-mapping-proposals.py`
- Dashboard QR read public / write requires operator PIN or API key
- Smoke tests: `tools/property_manager/tests/test_phase1_meters.py`

**Production (Intel Mini) Phase 3 deployed** — see evidence pack; Phase 4 is post-deploy monitoring.

### Phase 0 design review checklist

| #   | Requirement                                                                                                                       | Blocker ref |
| --- | --------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1   | Dev VM is the sole implementation and test environment until operator approval                                                    | 1           |
| 2   | Production (Intel Mini) is a separate checkpoint requiring explicit operator approval                                             | 1           |
| 3   | `asset_meter_reading` audit fields defined (see architecture doc)                                                                 | 3           |
| 4   | Backdated reading rules: no auto-replace of current meter unless chronologically latest                                           | 4           |
| 5   | Lower-reading preview-and-confirm workflow with operator identity + audit record                                                  | 5           |
| 6   | Maintenance completion cannot silently default to stale meter                                                                     | 6           |
| 7   | Calendar intervals never approximate meter hours to days                                                                          | 7           |
| 8   | Meter defaults proposed at import; operator review before activation                                                              | 8           |
| 9   | RanchBrain task→asset matching is review-only; no auto-apply                                                                      | 9           |
| 10  | API reliability contract defined (versioning, auth, decimals, timezones, pagination, idempotency, concurrency, validation errors) | 10          |
| 11  | QR access policy: opaque token ≠ authorization                                                                                    | 11          |
| 12  | Client diagram: all clients → REST API only, not Postgres directly                                                                | 12          |
| 13  | Extended test matrix defined                                                                                                      | 13          |

---

## Development and deployment boundary

All PropertyManager work follows a **two-environment, two-gate** model aligned with [OpenClaw Development Directive](OPENCLAW_DEVELOPMENT_DIRECTIVE.md).

### Environment roles

| Environment                 | Role                                                                                                                          | Authorization                                       |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| **Development VM**          | Schema design, migration dry-runs, API implementation, dashboard and client integration testing, load and concurrency testing | Normal development on `development` branch          |
| **Production (Intel Mini)** | Authoritative Postgres, live API, operator-facing QR and Telegram paths                                                       | **Explicit operator approval only** after dev proof |

### Deployment phases

| Phase       | Scope                                                                                           | Gate                                  |
| ----------- | ----------------------------------------------------------------------------------------------- | ------------------------------------- |
| **Phase 0** | Requirements and architecture docs (this document + asset architecture)                         | Operator design approval              |
| **Phase 1** | Dev VM: schema migrations, API, dashboard QR page, Mac/iOS client wiring, test matrix execution | Operator Phase 1 authorization        |
| **Phase 2** | Dev VM: end-to-end operator acceptance testing on real workflows                                | Operator acceptance sign-off          |
| **Phase 3** | Production Intel Mini: schema apply, API deploy, client cutover                                 | **Explicit production authorization** |
| **Phase 4** | Production monitoring, rollback readiness, documentation update                                 | Post-deploy review                    |

**Rules:**

- Migrations are dry-run on dev VM first; production apply requires a written rollback plan.
- No client may connect to production Postgres directly (see Client access).
- Committing to `development` does not authorize production deployment.
- Rollout runbooks must list dev proof artifacts before each production step.

---

## System of record and client access

- **PostgreSQL** (`propertymanager` schema) on the Intel Mini is the production system of record for assets, meters, readings, schedules, and audit history.
- **All clients** (Mac, iPhone/iPad, Dashboard QR page, Telegram, RanchBrain CLI) interact **only through the PropertyManager REST API**. No client reads or writes Postgres directly.
- Mac and iOS may maintain a local JSON cache for offline display; cache is a **derived copy**, not authoritative.
- CSV export remains legacy/briefing-only and must not be treated as a write path.
- **Apple Calendar is not a system of record.** The Mac app may push a derived day plan into Calendar.app for planning visibility only. Deleting or editing those events in Calendar.app must not update PropertyManager. Postgres + the REST API (via Mac/iPhone UI) remain the only write path for tasks and schedules.

See the client topology diagram in [PropertyManager Asset Architecture](../architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md#client-topology).

---

## Apple Calendar day plan (Mac → OpenClaw)

PropertyManager may place **today’s due work** on the operator’s Apple Calendar for **planning and scheduling visibility only**. This is a **Mac-only, one-way, on-demand** export into Calendar.app — not bidirectional sync, not an API/server feature, and not a second task database.

**Intent:** use Apple Calendar to see and arrange the day plan. Do **not** use Calendar.app to complete, reschedule, activate, or delete PropertyManager tasks.

**Trial status:** ship and use this on the **Mac development build** in real-world day planning first. Do **not** treat OpenClaw calendar export as production-required or value-proven until the operator confirms after hands-on use. Promotion to production Mac builds, and any behavior such as removal-on-complete, stays **provisional** and may be dropped or changed if it is not value-added.

### Requirements

| Rule                              | Requirement                                                                                                                                                                                                                                                                                               |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host                              | **Mac PropertyManagerApp** only. Menu/button: push today’s due tasks to Calendar.                                                                                                                                                                                                                         |
| Target calendar                   | Existing Calendar.app calendar titled **OpenClaw**. Do not auto-create it; fail clearly if missing.                                                                                                                                                                                                       |
| Event shape                       | **Timed blocks** stacked from a **configurable day start** (default **08:00** local). Each event lasts `estimated_minutes` (fallback 30). No overlap: next start = previous end.                                                                                                                          |
| Eligibility                       | Active tasks with `schedule_kind` in `calendar` \| `both` whose calendar `next_due` local date is **≤ today** (due today or still incomplete/overdue).                                                                                                                                                    |
| Pure meter tasks                  | **Excluded** from Apple Calendar export. Never invent a calendar day from meter hours/miles.                                                                                                                                                                                                              |
| Task mutations                    | Create, edit, complete, reschedule, and soft-delete of tasks happen **only** in PropertyManager Mac or iPhone UI through the REST API.                                                                                                                                                                    |
| Calendar delete is view-only      | The operator **may** delete (or edit) a Calendar.app event to clear it from the calendar view. That action must **never** update PropertyManager Postgres, the REST API, or Mac/iOS local task caches.                                                                                                    |
| Completion removes calendar event | **Provisional default:** when a task is completed in PropertyManager, Mac may remove that task’s PM-managed OpenClaw event(s). Revisit after real-world trial — keep as a single easy-to-disable switch; may be removed entirely if not value-added. Never Calendar-driven completion.                    |
| Completion                        | Completing the task in PropertyManager advances `next_due` via the normal API path; the task leaves the day-plan push until it is due again.                                                                                                                                                              |
| Incomplete roll-forward           | Any task **not completed in PropertyManager** must keep receiving a timed slot on subsequent pushes (rolls forward day to day until done). A prior Calendar.app delete does not mark the task done; a later push may recreate the event.                                                                  |
| Idempotency                       | Re-push updates or replaces PropertyManager-managed events for the day; must not accumulate unbounded duplicates. Stable EventKit marker / URL identifies PM-owned events.                                                                                                                                |
| DEV vs prod                       | DEV builds tag events with a **DEV** marker and provide **Delete DEV PropertyManager calendar events**. Before promoting calendar sync to production, operator must run DEV cleanup and confirm the OpenClaw calendar has no DEV PM events. Prod markers must never be deleted by the DEV cleanup action. |
| Authority                         | Calendar events are **derived presentation only**. Calendar.app is never a write path into PropertyManager.                                                                                                                                                                                               |
| Permissions                       | Requires macOS Calendar (EventKit) access for the Mac app; surface permission failures in the UI.                                                                                                                                                                                                         |

### Out of scope (this feature)

- Writing calendar events from the PropertyManager REST API, Intel Mini, or iOS PropertyManager app (v1)
- Auto-creating the OpenClaw calendar
- Any Calendar.app → PropertyManager reverse sync (delete, edit, complete, or reschedule via calendar)
- Converting meter intervals into Apple Calendar dates

Architecture notes: [PropertyManager Asset Architecture](../architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md#apple-calendar-day-plan).

---

## Operating meters — requirements

### Meter types and defaults

| Asset category                      | Proposed default meter type | Proposed default unit |
| ----------------------------------- | --------------------------- | --------------------- |
| Equipment                           | `runtime_hours`             | `hrs`                 |
| Vehicles / Vehicle                  | `mileage`                   | `mi`                  |
| Tractor, Shop, all other categories | `none`                      | —                     |

**Defaults are proposals only.** At RanchBrain asset import:

1. The system **proposes** a meter type and unit based on category.
2. The operator **reviews and confirms or overrides** before the meter is activated.
3. No meter-based schedules or reading acceptance may run until the operator activates the meter.

### Meter reading entry modes

`asset_meter.current_value` is always the **cumulative absolute total** (hour-meter / odometer face after accept).

Operators may enter readings in either mode:

| Mode     | Request field | Meaning                                                          |
| -------- | ------------- | ---------------------------------------------------------------- |
| Absolute | `value`       | Full meter face reading (existing behavior)                      |
| Delta    | `delta`       | Hours (or miles) **used since last** reading; must be finite > 0 |

Server rule for delta: `new_absolute = current_value + delta`, then the normal accept path (audit trail, usage_since_previous, lower-reading preview/confirm if the resulting absolute would decrease). Reject if both `value` and `delta` are set, or neither. Prefer the name `delta` (not `add_value`).

PM remaining is unchanged and always absolute-based: `remaining_meter = next_due_meter_value − current_value`.

### Meter reading audit requirements

Every `asset_meter_reading` record must support full audit reconstruction. Required fields (detailed in architecture doc):

- `previous_reading_id` — chain to prior accepted reading in the same meter epoch
- `meter_type` and `unit` **at entry time** — snapshot even if asset meter config later changes
- `status` — `accepted`, `rejected`, or `corrected`
- Operator or integration identity (`operator_id`, `integration_id`, or equivalent)
- `idempotency_key` — deduplicate mobile retries and offline sync replays
- `meter_epoch` — integer incremented on meter replacement or rollover; readings in different epochs must not be compared for usage deltas
- Link to record being corrected (`corrects_reading_id`) when status is `corrected`
- Existing fields retained: `value`, `reading_at`, `entry_method`, `correction_reason`, `usage_since_previous`

Append-only history: no UPDATE or DELETE of accepted readings; corrections create new rows.

### Backdated readings

When a reading is inserted with `reading_at` earlier than the current latest accepted reading:

1. It must **not** automatically replace `asset_meter.current_value` unless it is chronologically the **latest** reading after full sort by `reading_at` (tie-break by `created_at`).
2. The system must **recalculate `usage_since_previous`** for all readings before and after the insertion within the same `meter_epoch`.
3. If the backdated reading becomes the chronologically latest, `current_value` and `latest_reading_at` update accordingly.
4. PM remaining calculations must rerun after any backdated acceptance.

### Lower-reading confirmation

A reading lower than the previous accepted reading in the same `meter_epoch` is **never silently accepted**.

Requirements:

1. API returns a **preview** showing previous value, proposed value, delta, and required correction type options (`replacement`, `rollover`, `correction`).
2. Operator must **explicitly confirm** via a second request that includes correction type, operator identity, and optional note.
3. `correction_reason` alone on the initial POST is **insufficient**; confirmation creates an audit record with `status=accepted` and linked `previous_reading_id`.
4. Replacement or rollover increments `meter_epoch` on the asset meter; subsequent readings start a new chain.

### Maintenance completion and meter capture

When completing a meter-scheduled maintenance task:

1. The system must **display the current meter reading** (from API, not stale cache).
2. The operator must **confirm the displayed reading** or **enter a new reading**.
3. Silent default to a stale or cached meter value is **prohibited**.
4. Completion creates or links an `asset_meter_reading` with `entry_method=completion` and captures `meter_value_at_completion` on the completion record.

---

## Schedule requirements — calendar and meter

### Calendar intervals

- **Never** convert meter intervals to approximate calendar days (e.g. do not turn "50 hours" into "~7 days").
- Calendar schedules (`warning_days`, `next_due`) and meter schedules (`next_due_meter_value`, `meter_interval_value`, `meter_interval_unit`) are **independent** fields.
- **Combined schedules** (`schedule_kind=both`) are allowed **only** when the manufacturer manual explicitly specifies "whichever comes first" (or equivalent). Both calendar and meter thresholds must be stored as authored; the recalc engine evaluates each independently.

### Run hours trigger (meter PM)

**Run hours trigger** means the **absolute** meter reading at which a linked task becomes due — not the repeat interval alone. Example: "Check blade when mower hits **150.0** hours."

| Concept                | Column                                           | Meaning                                                                                                                        |
| ---------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Absolute due threshold | `next_due_meter_value`                           | Meter reading at which the task becomes due (absolute trigger; column in `005_assets_and_meters.sql`) — no new migration       |
| Repeat interval        | `meter_interval_value` (+ `meter_interval_unit`) | Repeating interval (e.g. every 50 hours). After completion with an interval: `next_due = meter_value_at_completion + interval` |

#### Controlling rule

Eligibility is determined by the **linked asset**, not by task category:

- Task must have `asset_id` set.
- Linked asset meter must be **activated** with `meter_type == runtime_hours`.
- Asset **category is not authoritative** (a `runtime_hours` meter in a non-Equipment category is allowed).

#### Due vs overdue vs remaining

Compare `asset_meter.current_value` to `next_due_meter_value` (Decimal):

| Condition                         | Meaning   | Enrichment                                                               |
| --------------------------------- | --------- | ------------------------------------------------------------------------ |
| `current < next_due_meter_value`  | Remaining | `remaining_meter = next_due - current` (positive)                        |
| `current == next_due_meter_value` | Due now   | `due_meter = true`; **not** overdue                                      |
| `current > next_due_meter_value`  | Overdue   | `overdue_meter = true` (**strict `>` only**); `remaining_meter` negative |

Expose both `due_meter` and `overdue_meter`. Do **not** treat `>=` as overdue.

#### Schedule kind — no silent promotion

- Saving a non-null `next_due_meter_value` requires **explicit** `schedule_kind` of `meter` or `both`.
- **Forbidden:** silently changing `calendar` → `meter` (or `both`) on upsert/PATCH.
- UI default: when calendar fields are already meaningful, default new trigger saves to `both` (operator must still send explicit `meter` or `both`).

#### One-time trigger (no interval)

When `meter_interval_value` is null/absent and the task completes: **clear** `next_due_meter_value` (one-shot). Do not invent a next trigger.

When an interval is present: `next_due_meter_value = meter_value_at_completion + meter_interval_value` (Decimal). Completion must be **atomic** (single multi-statement `BEGIN…COMMIT`, not separate autocommit execs).

#### Authorship (no new DB column)

- **Manufacturer interval** (`meter_interval_*`) keeps existing provenance: `origin` / `source_manual_name` / `manualImport` (or equivalent). Editing the absolute trigger must **not** strip these.
- **Absolute trigger** (`next_due_meter_value`) is an **operator scheduling decision**. No new authorship column.

#### Validation and save semantics

- Require linked activated `runtime_hours` asset when setting `next_due_meter_value`.
- Unit must be hours (`hrs`); value must be nonnegative finite numeric (Decimal end-to-end).
- Blank / `""` is **not** zero — reject blank and non-numeric input.
- If trigger `<` current meter: allow save with `warnings[]` (trigger behind current).
- Clients: **deliberate Save only** after valid parse — no autosave of partial/invalid trigger fields.
- UI labels: "Due when meter reaches (hours)" / "Run hours trigger"; badges: "N hrs left" / "Due now" / "Overdue".

Vehicles / mileage absolute-trigger + interval follow the same pattern later (out of scope for this `runtime_hours` contract).

Architecture and recalc details: [PropertyManager Asset Architecture — Run hours trigger](../architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md#run-hours-trigger-equipment-tasks).

### Meter-based PM (general)

- Meter schedules require an absolute due threshold (`next_due_meter_value`) evaluated against the asset meter current value per the due/overdue/remaining rules above.
- Repeat intervals (`meter_interval_value`, `meter_interval_unit`) originate from manufacturer manual import when available and drive post-completion advancement of the trigger (or clear on one-time complete).
- Recalc after accepted readings and completions uses the formulas in the run hours trigger contract above.

---

## RanchBrain asset and task matching

- RanchBrain JSON assets expose `asset_id` (e.g. `EQ-DEERE-MOWER-001`) as the join key to `propertymanager.assets.external_id`.
- **No auto-apply** of task→asset matches based on area, item name, or fuzzy text similarity.
- Import and sync must **generate a reviewable mapping report** listing proposed matches with confidence and match rationale.
- Matches are applied **only after operator approval** of each mapping (or an explicit bulk-approve action logged in audit).

---

## API reliability requirements

The PropertyManager REST API must meet these non-functional requirements before production (Phase 3):

| Concern                 | Requirement                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| **Versioning**          | URL or header version prefix (e.g. `/v1/`); breaking changes require new version                       |
| **Authentication**      | All mutating endpoints require authenticated operator or registered integration identity               |
| **Decimal-safe values** | Meter values as decimal/string types end-to-end; no float rounding for odometer or hour meter readings |
| **Timezone rules**      | `reading_at` stored as `timestamptz`; API accepts ISO 8601 with offset; display uses operator locale   |
| **Pagination**          | Cursor-based pagination for list endpoints; stable ordering documented                                 |
| **Idempotency**         | `Idempotency-Key` header or body field; duplicate requests return original result                      |
| **Concurrency**         | Optimistic locking or row versioning on asset meter updates; conflict returns structured 409           |
| **Validation errors**   | Structured JSON error body: `code`, `message`, `field`, `details[]`                                    |

Endpoint shapes and entity definitions are specified in the architecture document. Phase 1 implements against that contract.

---

## QR code security

- QR URLs embed an **opaque token** (`qr_token`) that identifies an asset for **routing only**.
- **Opaque token ≠ authorization.** Possession of a QR URL does not grant write access.
- Access policy (Phase 1 implementation must enforce):

| Action                                   | Policy                                                                                                           |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Read asset name, current meter (display) | May be allowed anonymously on dashboard QR landing **only if** operator enables public read for that asset class |
| Submit meter reading                     | Requires authenticated session, one-time operator PIN, or time-limited signed token issued after auth            |
| Update asset metadata                    | Authenticated operator only; never via QR alone                                                                  |

Exact auth mechanism is a Phase 1 design detail; the **requirement** is that write paths cannot rely on QR token secrecy alone.

---

## Test matrix (required before production)

The following scenarios must pass on the **development VM** before Phase 3 authorization:

| Scenario                                                     | Validates                                                       |
| ------------------------------------------------------------ | --------------------------------------------------------------- |
| Concurrent meter entries on same asset                       | Concurrency protection, no lost updates                         |
| Duplicate mobile retries (same `idempotency_key`)            | Idempotent replay                                               |
| Offline sync: queue readings, replay on reconnect            | Ordering, idempotency, conflict handling                        |
| Backdated reading insertion (middle of history)              | Usage recalc, conditional current_value update                  |
| Backdated reading that becomes latest                        | current_value promotion                                         |
| Meter replacement (`meter_epoch` increment)                  | Epoch isolation, no invalid deltas                              |
| Meter rollover (odometer)                                    | Epoch or correction workflow                                    |
| Transactional rollback on partial failure                    | No orphan readings or inconsistent PM state                     |
| Maintenance completion with stale cache                      | Forces confirm-or-enter; rejects silent default                 |
| Maintenance completion with new reading                      | Reading link, PM recalc                                         |
| Manual entry provenance                                      | operator_id, entry_method, audit chain                          |
| Combined calendar + meter schedule ("whichever comes first") | Independent evaluation, no day/hour conversion; explicit `both` |
| Run hours: current == trigger                                | `due_meter` true; `overdue_meter` false                         |
| Run hours: current > trigger                                 | `overdue_meter` true (strict `>`); remaining negative           |
| Run hours: current < trigger                                 | `remaining_meter` positive; not due/overdue                     |
| Run hours decimal threshold (e.g. 127.4)                     | Decimal compare; no float rounding                              |
| Run hours one-time complete (no interval)                    | Clears `next_due_meter_value`                                   |
| Run hours complete with interval                             | `next_due = meter_value_at_completion + interval`; atomic       |
| Run hours trigger behind current                             | `warnings[]`; still saveable                                    |
| Run hours + `schedule_kind=both`                             | Accepted when explicit                                          |
| Calendar + trigger without explicit meter/both               | Rejected; **no** silent `calendar`→`meter` promote              |
| Blank / invalid / negative trigger                           | Rejected (blank ≠ 0)                                            |
| Unlinked task + trigger                                      | Rejected                                                        |
| `runtime_hours` asset in non-Equipment category              | Allowed (category not authoritative)                            |
| Duplicate/retried completion                                 | Idempotent / safe replay                                        |
| Lower-reading preview-and-confirm                            | Two-step flow, audit record                                     |
| RanchBrain mapping report                                    | No auto-apply without approval                                  |
| QR read without auth vs write with auth                      | Token ≠ authorization                                           |

Test evidence (logs, API responses, DB snapshots) must be archived for operator review at Phase 2 gate.

---

## Related documents

- [PropertyManager Asset Architecture](../architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md) — entity model, API contract, recalc rules, rollout
- [OpenClaw Development Directive](OPENCLAW_DEVELOPMENT_DIRECTIVE.md) — dev/prod governance
- [RanchBrain Architecture](../RanchBrain-Architecture.md) — asset join key
- [Foundational Documents Index](FOUNDATIONAL_DOCUMENTS.md)

---

## Phase 1 scope (after operator approval)

When Phase 1 is authorized, implementation work includes (non-exhaustive):

1. Schema migration on dev VM reflecting audit fields and `meter_epoch`
2. REST API implementing reliability contract
3. Preview-and-confirm lower-reading workflow
4. Backdated reading recalc engine
5. Completion meter confirm-or-enter UI (Mac, iOS, dashboard)
6. RanchBrain mapping report generator (no auto-apply)
7. QR landing page with read/write access policy
8. Test matrix execution and evidence pack

Production deployment (Phase 3) remains blocked until Phase 2 operator acceptance.
