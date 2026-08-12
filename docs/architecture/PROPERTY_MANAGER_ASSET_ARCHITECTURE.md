---
title: "PropertyManager Asset Architecture"
version: "1.4"
status: "Architecture — Phase 3 deployed (production)"
owner: "OpenClaw Architecture"
last_reviewed: "2026-07-30"
category: "Architecture"
source_document: "PROPERTY_MANAGER_ASSET_ARCHITECTURE.md"
---

# PropertyManager Asset Architecture

Version: 1.4
Status: **Phase 3 deployed on production Intel Mini**
Authority: Requirements in [PropertyManager Foundational Requirements](../foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md)
Last Updated: 2026-07-30

---

## Purpose

Track operating meters (runtime hours, mileage, cycles) for ranch equipment and vehicles. Connect preventive-maintenance schedules to **absolute meter triggers** (run hours / mileage due thresholds) and manufacturer repeat intervals. Provide one shared REST API for all client surfaces.

**Phase 3 deployed on production Intel Mini (2026-07-29).** See `reports/propertymanager/phase3-production-evidence.md`.

---

## Design principles

- **Postgres is the system of record** (production Intel Mini). Clients never connect to Postgres directly.
- **REST API is the only integration boundary** for Mac, iOS, Dashboard, Telegram, and RanchBrain CLI.
- **Auto-sync.** Mac and iPhone read/write through the API; local JSON cache is offline-derived only.
- **Dashboard-first QR entry.** Scanning a label opens a mobile web page; write actions require auth beyond the QR token (see [QR access policy](#qr-access-policy)).
- **Five-minute learning.** Asset pages show current reading and remaining until next service.
- **Manufacturer manual is PM source of truth for intervals.** Repeat intervals (`meter_interval_*`) are stored at manual import and keep origin/source provenance. The **run hours trigger** (`next_due_meter_value`) is an absolute operator scheduling decision (no new authorship column).
- **Audit-first meter history.** Every reading is reconstructable; corrections append new rows.
- **One-way trusted-record projection.** OpenClaw may retain idempotent canonical projections for cross-domain use, but Property Manager remains authoritative and all operational writes return through this REST API. See [Canonical Trusted Records](/foundation/CANONICAL_TRUSTED_RECORDS#property-manager-projection).

---

## Client topology

All clients talk to the PropertyManager REST API only. Postgres is reachable only from the API service on the host.

```mermaid
flowchart LR
  subgraph clients [Clients]
    Mac[Mac app]
    iOS[iPhone / iPad]
    Dash[Dashboard QR page]
    TG[Telegram / Ranch Bot]
    RB[RanchBrain CLI]
  end

  API[PropertyManager REST API]

  subgraph prod [Production host — Intel Mini]
    API --> PG[(PostgreSQL propertymanager)]
  end

  Mac --> API
  iOS --> API
  Dash --> API
  TG --> API
  RB --> API
```

| Client                           | Role                                                                                                                                            |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Mac                              | Asset admin, manual import with meter intervals, meter entry, completion meter capture, mapping approval, optional Apple Calendar day-plan push |
| iPhone / iPad                    | Field meter entry, voice, QR deep link                                                                                                          |
| Dashboard `/pm/asset/<qr_token>` | QR landing, meter display, authenticated update                                                                                                 |
| Telegram                         | Natural-language meter updates (via API)                                                                                                        |
| RanchBrain CLI                   | Display current meter and PM remaining from API                                                                                                 |

Local JSON cache on Mac/iOS: read-through / write-behind against API; **not** a second system of record.

### Apple Calendar day plan

Mac PropertyManagerApp may push today’s due/overdue calendar-scheduled tasks into the existing Calendar.app calendar titled **OpenClaw** as timed blocks (configurable day start, default 08:00; duration = `estimated_minutes`).

```mermaid
flowchart LR
  PM[PropertyManager Mac UI]
  API[REST API / Postgres SoR]
  Cal[Calendar.app OpenClaw]

  PM -->|"complete / reschedule"| API
  PM -->|"one-way push day plan"| Cal
```

- **Plan/schedule view only.** Calendar.app is not a PropertyManager database.
- **One-way:** Mac → OpenClaw. No Calendar → PropertyManager reverse sync.
- Operator may **delete a calendar event** to clear the calendar view; that must not change tasks, `next_due`, or Mac/iOS caches.
- When a task is **completed in PropertyManager** (Mac or iPhone), remove that task’s PM-managed OpenClaw event(s) (Mac EventKit cleanup by stable marker). Still one-way PM → Calendar.
- Task create / edit / complete / reschedule only via PropertyManager Mac or iPhone → REST API.
- Incomplete tasks roll forward on later pushes until completed in PropertyManager.
- DEV-tagged events must be deleted before production cutover of this feature.

Policy: [Foundational Requirements — Apple Calendar day plan](../foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md#apple-calendar-day-plan-mac--open-claw).

---

## Entity model

### `assets`

Canonical ranch asset registry. Join key to RanchBrain JSON is `external_id` (e.g. `EQ-DEERE-MOWER-001`).

| Column                                                  | Notes                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------- |
| `id`                                                    | UUID primary key                                              |
| `external_id`                                           | Unique RanchBrain asset id                                    |
| `ranchbrain_guid`                                       | Optional link to JSON `guid`                                  |
| `name`, `manufacturer`, `model`, `category`, `location` | Display and voice matching                                    |
| `aliases`                                               | JSON array of nicknames                                       |
| `qr_token`                                              | Opaque routing token for QR URLs — **not** an auth credential |
| `is_active`                                             | Soft lifecycle                                                |
| `meter_proposed_type`, `meter_proposed_unit`            | Set at import; pending operator review                        |
| `meter_activated_at`                                    | Null until operator confirms meter defaults                   |

### `asset_meter`

One row per asset (1:1). Active only after operator confirms proposed defaults at import.

| Column              | Notes                                                                                                                                                                                                      |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `meter_type`        | `runtime_hours`, `mileage`, `cycles`, or `none`                                                                                                                                                            |
| `current_value`     | Cumulative total — latest **chronologically** accepted absolute reading in current epoch. Entry may be absolute face or positive **delta** (hours/miles since last); server stores the resulting absolute. |
| `unit`              | `hrs`, `mi`, or `cycles`                                                                                                                                                                                   |
| `latest_reading_at` | Timestamp of reading that set `current_value`                                                                                                                                                              |
| `meter_epoch`       | Incremented on replacement or rollover; isolates reading chains                                                                                                                                            |
| `row_version`       | Optimistic concurrency for updates                                                                                                                                                                         |

**Proposed defaults at import** (operator must confirm before activation):

| Category             | Proposed `meter_type` | Proposed `unit` |
| -------------------- | --------------------- | --------------- |
| Equipment            | `runtime_hours`       | `hrs`           |
| Vehicles / Vehicle   | `mileage`             | `mi`            |
| Tractor, Shop, other | `none`                | —               |

### `asset_meter_reading`

Append-only history. Corrections and rejections are new rows; accepted rows are never UPDATEd or DELETEd.

| Column                 | Notes                                                                  |
| ---------------------- | ---------------------------------------------------------------------- |
| `id`                   | UUID primary key                                                       |
| `asset_id`             | FK to `assets`                                                         |
| `meter_epoch`          | Epoch at entry time                                                    |
| `meter_type`           | Snapshot at entry                                                      |
| `unit`                 | Snapshot at entry                                                      |
| `value`                | Decimal-safe numeric                                                   |
| `reading_at`           | Operator-entered or completion time (`timestamptz`)                    |
| `created_at`           | Server insert time                                                     |
| `entry_method`         | `manual`, `voice`, `qr`, `api`, `telegram`, `completion`               |
| `status`               | `accepted`, `rejected`, `corrected` (see semantics below)              |
| `previous_reading_id`  | Prior accepted reading in same epoch (null for first in epoch)         |
| `corrects_reading_id`  | When correcting a prior accepted reading                               |
| `correction_reason`    | `replacement`, `rollover`, `correction` when value < previous in epoch |
| `usage_since_previous` | Server-computed delta within epoch                                     |
| `operator_id`          | Authenticated operator (nullable for integrations)                     |
| `integration_id`       | Registered integration identity (Telegram, CLI, etc.)                  |
| `idempotency_key`      | Unique per asset + key; dedupe retries                                 |
| `note`                 | Optional free text                                                     |

**Status semantics:**

- `accepted` — contributes to history and may update `current_value` if chronologically latest
- `rejected` — preview declined or validation failed; audit only
- `corrected` — marks a superseding row; original remains; `corrects_reading_id` points to superseded accepted reading

### Task extensions (`maintenance_tasks`)

| Column                                        | Notes                                                                                         |
| --------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `asset_id`                                    | FK to `assets`                                                                                |
| `schedule_kind`                               | `calendar`, `meter`, or `both`                                                                |
| `next_due_meter_value`                        | Absolute meter reading at which the task becomes due (run hours trigger; operator scheduling) |
| `meter_interval_value`, `meter_interval_unit` | Repeat every N units after complete — from manufacturer manual; never converted to days       |
| `last_done_meter_value`                       | Meter at last completion; set by recalc on complete                                           |
| Calendar fields                               | `warning_days`, `next_due` — unchanged for calendar / hybrid                                  |

**Task title / list grouping**

- **Stored `item`:** canonical `Asset Name: Task Name`. Upsert/PATCH normalize strips duplicated `{group}:` prefixes (same idea as ManualImport’s don’t-double-prefix guard).
- **Group key (UI):** linked asset `name` when `asset_id` is set; otherwise `area` (Pool / Spa / Hot Tub style tasks).
- **Display:** section header = group name; row title = `item` with leading `{group}:` removed. iOS shows `Estimated time: N minutes` on list and detail.
- One-time historical backfill: `tools/property_manager/db/normalize_task_titles.py` (`--dry-run` / `--apply`); do not mass-rewrite without operator approval.

**Hybrid (`both`):** Use only when the manual (or operator) intentionally keeps calendar dates with a meter trigger ("whichever comes first"). Engine evaluates calendar due and meter due independently; task is due when **either** threshold is met. Do not silently upgrade `calendar` → `both` when only a meter trigger is added.

### Completion extensions (`maintenance_completions`)

| Column                      | Notes                                            |
| --------------------------- | ------------------------------------------------ |
| `meter_value_at_completion` | Confirmed or newly entered meter at service time |
| `meter_reading_id`          | FK to reading created or linked on completion    |
| `operator_id`               | Who confirmed the meter reading                  |

### RanchBrain mapping (`asset_task_mapping_proposals`)

Review queue — **no auto-apply**.

| Column                       | Notes                             |
| ---------------------------- | --------------------------------- |
| `ranchbrain_task_ref`        | Source task identifier            |
| `proposed_asset_id`          | Suggested asset FK                |
| `match_rationale`            | area, item, text similarity, etc. |
| `confidence`                 | Score for operator sorting        |
| `status`                     | `pending`, `approved`, `rejected` |
| `reviewed_by`, `reviewed_at` | Operator audit                    |

Approved rows create or update `maintenance_tasks.asset_id`; rejected rows are retained for audit.

---

## Recalculation rules

### Current meter value

After every **accepted** reading:

1. Sort accepted readings in the asset's current `meter_epoch` by `reading_at ASC`, `created_at ASC`.
2. Set `asset_meter.current_value` and `latest_reading_at` from the **last** row in that ordering **only if** the new reading is that last row.
3. Backdated insertions that are not chronologically latest **do not** change `current_value`.

### Usage deltas

Within the same `meter_epoch`, recompute `usage_since_previous` for all accepted readings in chronological order after any insert or acceptance.

### PM remaining / due / overdue (meter schedules)

After every accepted reading or task completion that affects meter state (Decimal compare):

```
remaining_meter = next_due_meter_value - current_meter_value
due_meter       = current_meter_value == next_due_meter_value
overdue_meter   = current_meter_value >  next_due_meter_value   # strict >; never >=
```

| Condition            | Flags                                    |
| -------------------- | ---------------------------------------- |
| `current < trigger`  | remaining positive; not due; not overdue |
| `current == trigger` | `due_meter` true; **not** overdue        |
| `current > trigger`  | `overdue_meter` true; remaining negative |

### Run hours trigger (runtime_hours tasks)

**Run hours trigger** = the absolute hour-meter reading at which the task becomes due (not the repeat interval alone). Example: due when the mower hits **150.0** hours. No new migration — uses `next_due_meter_value` from `005_assets_and_meters.sql`.

| Role             | Column / field                        | Notes                                                            |
| ---------------- | ------------------------------------- | ---------------------------------------------------------------- |
| Absolute trigger | `next_due_meter_value`                | Operator scheduling decision; Decimal                            |
| Current meter    | `asset_meter.current_value`           | Compared per due/overdue/remaining rules above                   |
| Repeat interval  | `meter_interval_value` (+ unit `hrs`) | Manufacturer interval; advances trigger on complete when present |

**Controlling rule:** linked asset must be activated with `meter_type == runtime_hours`. Task category is **not** authoritative.

**Schedule kind — no silent promotion:**

- Non-null `next_due_meter_value` requires explicit `schedule_kind` in `{meter, both}`.
- Upsert/PATCH must **not** silently change `calendar` → `meter`.
- UI default: prefer `both` when calendar fields are already meaningful; still send explicitly.

**Validation (API):**

- Require `asset_id` and linked activated `runtime_hours` meter.
- Unit `hrs`; nonnegative finite numeric; reject blank/`""` (blank ≠ 0) and non-numeric.
- Trigger `<` current → saveable with `warnings[]`.

**UI:**

- Field labels: "Due when meter reaches (hours)" / "Run hours trigger"
- Badges: "N hrs left" / "Due now" / "Overdue"
- Deliberate Save only after valid Decimal parse — no autosave of partial trigger
- Editing trigger must not strip manufacturer `origin` / `source_manual_name` / `manualImport`

**On task complete** with a meter schedule (after operator confirms meter), atomically (`BEGIN…COMMIT` as one multi-statement script):

- `last_done_meter_value = meter_value_at_completion`
- If interval present: `next_due_meter_value = meter_value_at_completion + meter_interval_value`
- If one-time (no interval): **clear** `next_due_meter_value`

Calendar `next_due` recalculation unchanged for `calendar` / `both` schedules. **Never** derive calendar dates from meter hour intervals.

**Scope:** `runtime_hours` meters (any category). Vehicles / mileage follow the same absolute-trigger + interval pattern later.

Policy baseline: [Foundational Requirements — Run hours trigger](../foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md#run-hours-trigger-meter-pm).

### Meter epoch changes

On **replacement** or **rollover** confirmation:

1. Increment `asset_meter.meter_epoch`.
2. First reading in new epoch has `previous_reading_id = NULL`.
3. Do not compute `usage_since_previous` across epoch boundaries.

---

## Lower-reading workflow

Two-step flow; single POST with `correction_reason` alone is **rejected**.

### Step 1 — Preview (`POST .../meter-readings` or dedicated preview endpoint)

Request includes `value`, `reading_at`, `entry_method`, optional `idempotency_key`.

If `value < previous_accepted_in_epoch` and no confirmed correction:

**Response 409** structured body:

```json
{
  "code": "LOWER_READING_CONFIRMATION_REQUIRED",
  "previous_value": "1250.5",
  "proposed_value": "12.5",
  "options": ["replacement", "rollover", "correction"],
  "preview_token": "<short-lived token>"
}
```

### Step 2 — Confirm (`POST .../meter-readings/confirm`)

Body includes `preview_token`, `correction_reason`, `operator_id`, optional `note`.

- Creates `asset_meter_reading` with `status=accepted`, `previous_reading_id`, operator identity.
- On `replacement` or `rollover`: increment `meter_epoch` before persisting reading.
- On `correction`: set `corrects_reading_id` if superseding a specific row.

---

## Maintenance completion flow

1. Client fetches live meter from `GET /assets/<id>` (not local cache alone).
2. UI displays current reading and prompts: **Confirm** or **Enter new reading**.
3. If new reading differs or cache was stale, create reading first (standard or confirm flow).
4. Complete task with `meter_value_at_completion` and `meter_reading_id`.
5. Recalc PM meter fields.

**Forbidden:** silently submitting completion with cached/stale meter without operator acknowledgment.

---

## REST API contract (Phase 1 target)

Base path: `/v1/` on PropertyManager API port (dev VM first). Production host: Intel Mini after Phase 3 gate.

### Cross-cutting

| Header / field             | Purpose                                    |
| -------------------------- | ------------------------------------------ |
| `Authorization`            | Bearer or session token for mutating calls |
| `Idempotency-Key`          | Duplicate-safe retries                     |
| `If-Match` / `row_version` | Optimistic concurrency on meter update     |

Errors:

```json
{
  "code": "VALIDATION_ERROR",
  "message": "Human-readable summary",
  "field": "value",
  "details": [{ "code": "...", "message": "..." }]
}
```

Values: decimal strings in JSON (e.g. `"1250.5"`) to avoid float drift.

Timestamps: ISO 8601 with timezone offset; stored as `timestamptz`.

Lists: cursor pagination `?cursor=<opaque>&limit=50`.

### Assets

- `GET /v1/assets` — list with embedded meter summary and PM remaining
- `GET /v1/assets/<id>` — detail + linked tasks
- `GET /v1/assets/by-external-id/<external_id>`
- `GET /v1/assets/by-qr/<qr_token>` — **read-only** asset summary for QR landing; write requires separate auth
- `POST /v1/assets`, `PATCH /v1/assets/<id>`
- `POST /v1/assets/<id>/activate-meter` — operator confirms proposed meter defaults

### Meter readings

- `GET /v1/assets/<id>/meter-readings?cursor=&limit=50`
- `POST /v1/assets/<id>/meter-readings` — create absolute or delta reading; may return 409 preview for lower reading
  - Body: **either** `{ "value": "<absolute>" }` **or** `{ "delta": "<hours_or_miles_since_last>" }` (not both, not neither)
  - `delta` must be finite and **> 0** (blank ≠ 0). Server computes `absolute = current_value + delta`, then runs the normal accept path (audit trail, `usage_since_previous`, lower-reading preview if the resulting absolute would go down).
  - Response includes `value` (absolute written), `current_value` (meter after accept), and `delta` when delta mode was used (`null` for absolute).
  - PM remaining is unchanged: `remaining_meter = next_due_meter_value - current_value` (absolute trigger − cumulative total).
- `POST /v1/assets/<id>/meter-readings/confirm` — lower-reading confirmation

### Mapping (RanchBrain)

- `GET /v1/mapping-proposals?status=pending` — review report
- `POST /v1/mapping-proposals/<id>/approve`
- `POST /v1/mapping-proposals/<id>/reject`

### Voice parse

- `POST /v1/meter-readings/parse` — `{ "text": "..." }` → `{ asset_id, value, delta, entry_mode, unit, confidence }`
  - Absolute phrases (e.g. "mower 42.5 hours") set `value` / `entry_mode=absolute`.
  - Phrases like "add 2.5 hours on …" set `delta` / `entry_mode=delta` (`value` null). Client should POST that `delta` to meter-readings.

### Health

- `GET /health` — includes `api_version`, `schema_version` (`006` as of Phase 1), `api_process`, `postgres_reachable`, and `schema_available` (required tables present). Returns HTTP 503 when Postgres or schema checks fail; client body stays sanitized (diagnostics in logs).

### WSGI runtime (development VM)

Flask remains the app framework. Normal service operation uses **Gunicorn** (not Flask `app.run` / debug / reloader):

| Piece            | Path                                                                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| WSGI entry       | `tools/property_manager/api/wsgi.py` → `application`                                                 |
| Gunicorn target  | `wsgi:application` (WorkingDirectory = `tools/property_manager/api`)                                 |
| Config           | `tools/property_manager/api/gunicorn.conf.py` (2 sync workers, bind `:5062`, timeout 120s)           |
| Launcher         | `tools/property_manager/api/run_api.sh`                                                              |
| Dev systemd unit | `tools/property_manager/deploy/propertymanager-api.service`                                          |
| Runbook          | [PropertyManager API Development Runbook](../foundation/PROPERTY_MANAGER_API_DEVELOPMENT_RUNBOOK.md) |

DB default is docker-exec-per-query (process-safe across workers). Migrations stay explicit operator actions — never on worker import. Production Intel Mini units are unchanged until operator approval.

### Phase 1 implementation notes (dev VM)

| Area                                            | Status                      |
| ----------------------------------------------- | --------------------------- |
| Migration 006 audit fields                      | Implemented                 |
| `/v1/` asset and meter endpoints                | Implemented                 |
| Lower-reading preview + confirm                 | Implemented                 |
| Backdated reading recalc                        | Implemented                 |
| Idempotency-Key + cursor pagination             | Implemented                 |
| Optimistic locking (`row_version` / `If-Match`) | Implemented                 |
| Proposed meter + activate-meter                 | Implemented                 |
| Mapping proposals + CLI                         | Implemented                 |
| Dashboard QR auth policy                        | Implemented (PIN / API key) |
| Completion confirm-or-enter                     | Implemented on API          |
| Mac/iOS client wiring                           | Phase 2 complete (dev VM)   |
| Full test matrix (concurrency, offline sync)    | Phase 3 prerequisites       |

---

## QR access policy

| Surface                                     | Anonymous QR token                                              | Authenticated operator |
| ------------------------------------------- | --------------------------------------------------------------- | ---------------------- |
| Asset name, location, current meter display | Allowed on dashboard if operator enables public read            | Allowed                |
| Submit meter reading                        | **Denied** — requires session, PIN, or signed short-lived token | Allowed                |
| Asset metadata edit                         | **Denied**                                                      | Allowed                |

QR URL format: `/pm/asset/<qr_token>` — token identifies asset for routing only.

---

## Migration and rollout (dev-first)

### Phase 1 — Development VM only

1. Apply schema migration (audit fields, `meter_epoch`, mapping proposals) — **dry-run first**
2. Run RanchBrain asset import with **proposed** meter defaults (not auto-activated)
3. Generate mapping report; operator approves matches in dev
4. Re-import manufacturer manuals for meter intervals
5. Execute full [test matrix](../foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md#test-matrix-required-before-production)

### Phase 3 — Production Intel Mini (after operator authorization)

1. Backup production Postgres
2. Apply tested migration from dev
3. Deploy API version pinned in acceptance evidence
4. Enable dashboard QR (with auth policy)
5. Mac rebuild + iOS deploy against production API
6. Optional Telegram meter path

Each step requires rollback notes in the operations runbook. **No production step without Phase 2 acceptance evidence from dev VM.**

---

## RanchBrain join

RanchBrain JSON assets include `propertymanager_asset_id` and `asset_id`. PropertyManager Postgres owns operational meters and meter-based PM. Join key: `propertymanager.assets.external_id` = RanchBrain `asset_id`.

Task→asset linking uses the mapping proposal workflow; see [RanchBrain Architecture](../RanchBrain-Architecture.md).

---

## Related documents

- [PropertyManager Foundational Requirements](../foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md)
- [PropertyManager API Development Runbook](../foundation/PROPERTY_MANAGER_API_DEVELOPMENT_RUNBOOK.md)
- [RanchBrain Architecture](../RanchBrain-Architecture.md)
- [OpenClaw Development Directive](../foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE.md)
- Deprecated alias: [PROPERTYMANAGER_ASSETS_AND_METERS.md](PROPERTYMANAGER_ASSETS_AND_METERS.md) (pointer only)

---

## Phase 0 → Phase 1 handoff

| Deliverable                                      | Owner                  | Blocker      |
| ------------------------------------------------ | ---------------------- | ------------ |
| Operator sign-off on this doc + requirements doc | Operator               | Phase 0 gate |
| Schema DDL on dev VM                             | Engineering            | 3, 4, 8      |
| API `/v1/` implementation                        | Engineering            | 10, 11, 12   |
| Preview/confirm lower reading                    | Engineering            | 5            |
| Backdated recalc engine                          | Engineering            | 4            |
| Completion confirm-or-enter (all clients)        | Engineering            | 6            |
| Mapping report UI/CLI                            | Engineering            | 9            |
| Test matrix evidence pack                        | Engineering + Operator | 13           |
| Production rollout                               | Operator authorized    | 1            |
