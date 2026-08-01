# PropertyManagerApp Design Document

**Status:** Canonical — Postgres system of record **shipped** (2026-07-26)  
**Canonical location (Intel Mini):** `/mnt/ai-storage/openclaw-documents/Property/PropertyManagerApp-DESIGN.md`  
**Working copy (M4 app repo):** `/Users/andrewgraves/Development/PropertyManagerApp/docs/DESIGN.md`  
**Obsidian index:** `ranchbrain/Property.md` (`[[Property]]`)  
**Property:** RedBud Ranch  
**Platform:** macOS 13+ SwiftUI executable package  
**App path:** `/Users/andrewgraves/Development/PropertyManagerApp`  
**Primary implementation:** `Sources/PropertyManagerApp/PropertyManagerApp.swift`  
**Last updated:** 2026-07-27  
**Authority:** This Intel Mini copy is the knowledge-library source of truth. Update the M4 working copy in the same change, or copy back after edits.

---

## Alignment with RanchBrain Foundation

This app design follows RanchBrain principles in `ranchbrain/Foundation/Design-Principles.md`:

- Local First — Mac keeps an offline JSON cache; Intel Mini Postgres is the system of record
- Family First / Simple Before Clever — maintenance console, not another dashboard
- Knowledge Never Lost — how-to/response/parts/photos live in Postgres; CSV is export-only for legacy paths
- Leave It Better — design recovered from live code so operators are not guessing from empty stubs

---

## Reliability & Usability Design (authoritative product contract)

Best design for high reliability and easy use is not more screens. It is:

1. **One job** — maintain ranch tasks with Postgres as the only authority.
2. **One remote truth** — Intel Mini schema `propertymanager` owns tasks, categories, parts, photo metadata, tools, and completion history.
3. **One offline cache** — Mac `maintenance_tasks.json` / `maintenance_categories.json` are a dirtyable cache, not authority.
4. **Two sync verbs** — **Refresh from Postgres** and **Save to Postgres**.
5. **CSV is export-only** — `maintenance_log.csv` remains a 5-column compatibility bridge for briefing/Telegram until those paths read Postgres directly.
6. **No fake navigation** — no Dashboard / Schedule / Templates / History / Settings until each has a real purpose.

### Sync verbs

| Action | Does | Guarantees |
|---|---|---|
| **Refresh from Postgres** | `GET /tasks` + `GET /categories` via PropertyManager API → rewrite local JSON cache (backup first) | Cache matches Postgres nested payload (parts/photos/tools/kind) |
| **Save to Postgres** | `POST /categories` + `POST /tasks` (upsert) + optional photo uploads for dirty local attachments | Postgres accepts Mac UUID ids; parts replaced as a set; local cache stays until next refresh |

### Ease-of-use rules

- Sync status card shows dirty/clean, last refresh, last save.
- Editor treats rich fields as first-class (they round-trip through Postgres).
- Due/overdue language uses Central Time and matches task rows + Daily Briefing counts.
- Action Result messages are short success/fail with a next step.
- Legacy Pull/Publish CSV scripts remain on disk for recovery only; UI no longer uses them as master sync.

### Non-goals (this design)

Dashboard widgets and Response Templates browser remain out of scope until needed. Apple Calendar export (OpenClaw calendar push) shipped in DEV (2026-07-30) — see §’19. iPhone PropertyManager client is shipped (API-backed; sync via Refresh / Postgres).

---

## 1. Purpose

PropertyManagerApp is the local-first macOS operator console for RedBud Ranch maintenance.

It lets the steward:

- review and edit maintenance tasks;
- track last-done / next-due dates;
- capture how-to / response instructions;
- refresh from / save to Intel Mini Postgres through the PropertyManager API;
- keep a local offline JSON cache on the Mac; OpenClaw scripts/Telegram/briefing may still consume the exported slim CSV until they read Postgres directly.

It is **not** the OpenClaw Gateway Control UI, and it is **not** the Flask dashboard. Those remain separate surfaces.

---

## 2. System Context

```text
┌──────────────────────────────────────────────┐
│  PropertyManagerApp (M4 Mac)                 │
│  SwiftUI · MaintenanceStore                  │
│  Offline JSON cache: Application Support     │
└───────────────┬──────────────────────────────┘
                │ Refresh / Save (CRUD sync)
                │ PropertyManager API :5062
                ▼
┌──────────────────────────────────────────────┐
│  Intel Mini (OpenClaw production host)       │
│  Postgres schema propertymanager (SoT)       │
│  PropertyManager API / Telegram / summaries  │
│  Optional CSV export → maintenance_log.csv   │
│  Daily Executive Briefing (CSV bridge today) │
└──────────────────────────────────────────────┘
```

### Host roles

| Host | Role relative to PropertyManager |
|---|---|
| M4 Mac | Runs PropertyManagerApp; offline JSON cache + attachments |
| Intel Mini | Postgres system of record; API + Telegram + CSV export + briefing |
| UTM / DEV VM | OpenClaw API/migration development only; apply schema to Intel Postgres only with explicit approval |

---

## 3. Product Principles

Aligned with RanchBrain / OpenClaw foundation docs:

- **Family first / five-minute learning** — clear labels, obvious sync buttons, status text.
- **Local first** — tasks persist on the Mac in Application Support.
- **Simple before clever** — one main maintenance workspace; CSV is the interchange format.
- **Safety before overwrite** — pull/push scripts create backups; push requires confirmation.
- **OpenClaw thresholds matter** — `warningDays` / `criticalDays` are first-class fields and map to CSV columns.

---

## 4. Information Architecture

### 4.1 Window layout (implemented)

Three-column `ContentView`:

1. **Sidebar** (~210pt) — branding, Central Time, sync status, Pull/Publish, briefing counts.
2. **Task list** (~330pt) — search, category filters, task rows.
3. **Editor** (flex) — selected task detail / edit form.

Minimum window size: **1050 × 720**.

### 4.2 Sidebar (ops + status)

Left rail is **ops + status**, not a fake multi-screen shell:

- Brand + Central Time
- Sync status card (dirty/clean, last pull, last publish)
- **Pull from Intel** / **Publish to Intel**
- Open Data Folder / Backup Dashboard (secondary)
- Live Daily Briefing counts
- Per-task history remains in the editor (no separate History screen)

Removed placeholders: Dashboard, Response Templates, Schedule, History, Settings.

### 4.3 Sync / ops actions

| Control | Behavior |
|---|---|
| Pull From Intel | Runs pull script, then merges CSV into local JSON (rich fields preserved) |
| Publish To Intel | Saves JSON, writes Application Support staging CSV, confirms, remote backup, SCP, verify |
| Open Data Folder | Opens Application Support `PropertyManagerApp` folder |
| Backup Dashboard | Runs `scripts/dashboard_backup.sh` |

Legacy Export / Push split and Downloads coupling are retired.

---

## 5. Domain Model

### 5.1 `MaintenanceTask` (rich local model)

| Field | Meaning |
|---|---|
| `id` | UUID |
| `area` | Free-text area (e.g. Pool) |
| `item` | Free-text task name |
| `category` | `TaskCategory` enum |
| `priority` | Low / Medium / High |
| `frequency` | Daily → Yearly |
| `taskDescription` | Longer description |
| `responseInstructions` | How-to / response template text |
| `suppliesNeeded` | Supplies list |
| `notes` | Free notes |
| `resultNotes` | Result of last work |
| `completionHistory` | Newest-first completion entries |
| `estimatedMinutes` | Effort estimate |
| `warningDays` | OpenClaw warning threshold |
| `criticalDays` | OpenClaw critical threshold |
| `lastDone` | Last completion date |
| `nextDue` | Next due date |
| `sendTelegramUpdate` | Preference flag |
| `includeInDailyBriefing` | Preference flag |
| `alertIfOverdue` | Preference flag |
| `isActive` | Active vs inactive |
| `kind` | Scheduled vs Work Request (job type) |
| `origin` | **Manufacturer** vs **Owner-added** (procedure provenance; see §18) |
| `manufacturer` | Equipment maker when known |
| `sourceManualName` | Handbook PDF filename used for provenance / Fill How-To |
| `parts[]` / `toolsRequired[]` | Parts and tools (Postgres nested) |

### 5.2 Categories

Built-in `TaskCategory` values:

- Pool
- Home (including the Spa asset)
- Grounds
- Equipment
- House
- Safety

`CategoryDefinition` also supports persisted custom category metadata (`maintenance_categories.json`).


### Repair Next Due Date (Schedule editor)

Normal task saves and completions recalculate calendar schedules automatically. A collapsed **Advanced** control named **Repair Next Due Date** remains available only for imported, legacy, or incorrectly scheduled records. It sets `nextDue = lastDone + frequency interval` (Daily +1d … Quarterly +3mo … Yearly +1y).
`warningDays` / `criticalDays` remain OpenClaw due-soon / critical thresholds — not the repeat interval.
Local draft until **Save to Postgres**. API `POST /tasks/<id>/complete` still advances calendar `next_due` by `warning_days` (legacy); do not change prod without an explicit migration.

### 5.3 Due-state semantics (UI)

Task rows surface status such as **Overdue** based on due dates / thresholds.  
Editor summary cards expose **OpenClaw thresholds** (`warningDays` / `criticalDays`).

---

## 6. Persistence

### Local (Mac)

| File | Location | Role |
|---|---|---|
| `maintenance_tasks.json` | `~/Library/Application Support/PropertyManagerApp/` | Primary rich task store |
| `maintenance_categories.json` | same folder | Category definitions |
| `maintenance_tasks.unreadable.*.json` | same folder | Quarantine copies when JSON cannot be decoded |
| `*.backup-before-pull-sync*` | same folder | Automatic backups before pull reload |

### Interchange (OpenClaw CSV)

Required header (exact):

```text
area,item,last_done,warning_days,critical_days
```

Identity key for merge/import: normalized `(area, item)`.

On import, the app:

- validates the header;
- merges into existing tasks by key when possible;
- derives category / frequency / priority heuristics from area and threshold days;
- stores warning/critical days onto the rich task.

On export, the app writes only the five OpenClaw columns from the current task set.

---

## 7. Sync Architecture

### 7.1 Pull (Intel → Mac)

Script: `scripts/pull-intel-propertymanager-to-swift.sh`

1. SCP Intel  
   `~/ai/projects/openclaw/tools/property_manager/maintenance_log.csv`  
   → `imports/maintenance_log_from_intelmini.csv`
2. Run `scripts/load-propertymanager-csv-into-swift-json.py`
3. Reload / replace Application Support JSON used by the app

Auth: dedicated key  
`~/.ssh/propertymanager_intelmini`  
Host: `gravesab@intelmini` / `intelmini.local`

### 7.2 Publish (Mac → Intel)

Script: `scripts/push-swift-export-to-intel-test.sh <staging-csv-path>`

Typical flow (atomic from the operator’s view):

1. Save local JSON.
2. Write staging CSV under Application Support (`staging_publish.csv`).
3. Confirm Publish in UI.
4. Script verifies OpenClaw header, backs up remote CSV, SCPs staging file, verifies remote.
5. App marks sync clean and records `lastPublishAt`.

Publish refuses non-OpenClaw headers. Downloads-path coupling is removed.

### 7.3 Dashboard / property backup

`scripts/dashboard_backup.sh` SSHs to Intel and runs:

`tools/dashboard/dashboard_property_backup.sh`

---

## 8. OpenClaw Integration Surface

PropertyManagerApp participates in the larger OpenClaw estate as:

| Integration | Direction | Notes |
|---|---|---|
| `maintenance_log.csv` | Bidirectional via scripts | Canonical slim contract for OpenClaw tools |
| PropertyManager API / Telegram | Intel-side | Consumes CSV / related tools; not embedded in Swift app |
| Daily Executive Briefing | Preference flags on tasks | `includeInDailyBriefing` present; live briefing generation is Intel-side |
| AI Intelligence routing | Future / config | Components `property_manager` and `swift_property_manager` exist in OpenClaw deployment map |

---

## 9. UX Design Notes (from live UI)

- Light, utility-focused macOS layout.
- Category color/icon language (pool blue, hot tub purple, etc.).
- Editor is a single-screen “task + response instructions” form.
- Destructive / remote actions use confirmation (push) or status messaging.
- Central Time card reinforces ranch timezone (`America/Chicago`).

---

## 10. Non-Goals (current build)

- Full Dashboard / Schedule / Settings / Response Templates navigation.
- Native iPhone/iPad client (mentioned in OpenClaw deployment map; not this package).
- Direct PostgreSQL or Gateway RPC from the Swift app.
- Replacing RanchBrain knowledge storage.

---

## 11. Known Gaps / Follow-ups

0. ~~Task origin (Manufacturer vs Owner-added) + Fill How-To from Manual~~ — shipped 2026-07-27; see §18.
1. Design recovered from live code; reliability-first contract is now canonical.
2. ~~Sidebar placeholders~~ — removed; ops+status rail only.
3. ~~Daily Briefing static counts~~ — live `BriefingCounts`.
4. ~~Export-before-Push footgun~~ — replaced by atomic **Publish**.
5. Rich JSON fields do not round-trip through the 5-column CSV (by design); UI labels Shared vs Mac-only.
6. OpenClaw dashboard PropertyManager UI was planned historically and is still not shipped.
7. RanchBrain still lists “Integrate PropertyManager knowledge” as remaining work.

---

## 12. Source Map

| Asset | Path |
|---|---|
| App package | `Package.swift` |
| UI + store | `Sources/PropertyManagerApp/PropertyManagerApp.swift` |
| Pull script | `scripts/pull-intel-propertymanager-to-swift.sh` |
| CSV→JSON loader | `scripts/load-propertymanager-csv-into-swift-json.py` |
| Push scripts | `scripts/push-swift-propertymanager-to-intel.sh`, `scripts/push-swift-export-to-intel-test.sh` |
| Dashboard backup | `scripts/dashboard_backup.sh` |
| App backup | `scripts/backup-propertymanager-app.sh` |
| Import staging | `imports/` |
| Local runtime data | `~/Library/Application Support/PropertyManagerApp/` |
| Intel CSV | `~/ai/projects/openclaw/tools/property_manager/maintenance_log.csv` |

---

## 13. Foundational Alignment

This app should remain consistent with:

- RanchBrain Charter / Design Principles (family-first, local-first, simple before clever)
- OpenClaw Restore Manifest (PropertyManager is a priority restore asset)
- OpenClaw Operations Runbook (PropertyManager API recovery ordering on Intel)
- OpenClaw AI Governance Manifest (PropertyManager = property operations responsibility)

Implementation must not contradict those governance docs.

---

## 14. Change Control

When changing PropertyManagerApp:

1. Update this design doc if IA, sync contract, or persistence model changes.
2. Preserve the OpenClaw CSV header contract unless Intel tooling is updated in the same change.
3. Prefer pull → edit → export → confirmed push.
4. Keep backups before destructive remote writes.

---

## 15. External-drive markup surveyed (Intel Mini `/mnt/ai-storage`)

Surveyed 2026-07-25 on the Intel Mini external volume mounted at `/mnt/ai-storage` (and checked `/mnt/qnap-backup`).

### Finding

There is **no dedicated PropertyManagerApp design/spec markdown** on the external drive. Property-related folders exist mostly as **empty classification stubs** or **non-markdown backups**.

### Markup / knowledge documents reviewed

| Path | Relevance to PropertyManagerApp |
|---|---|
| `ranchbrain/Foundation/Design-Principles.md` | UX principles (family/local/simple) |
| `ranchbrain/Foundation/RanchBrain-Charter.md` | Mission: preserve ranch maintenance knowledge |
| `ranchbrain/Foundation/Family-Guide.md` | Family questions include pool-filter / maintenance history |
| `ranchbrain/Foundation/Roadmap.md` | Asset registry + maintenance history planned |
| `ranchbrain/Foundation/Naming-Standards.md` | Equipment naming (JD/DR); not app IA |
| `ranchbrain/Foundation/Governance/RBF-001-RanchBrain-Charter.md` | Governance duplicate of charter |
| `ranchbrain/Foundation/Governance/RBF-010-RanchBrain-History.md` | Foundation milestones; no Swift app design |
| `ranchbrain/Foundation/ADR/ADR-0006-…` | Architect service; not PM UI |
| `ranchbrain/Dashboard.md` | Obsidian hub links `[[Property]]` (note target missing) |
| `ranchbrain/notes/system-inventory.md` | Intel runs PropertyManager API; M4 is AI host |
| `ranchbrain/notes/ranchbrain-start.md` | Goal includes PropertyManager knowledge |
| `ranchbrain/notes/openclaw-history.md` | Remaining: integrate PropertyManager knowledge |
| `openclaw-documents/README.md` | Doc library taxonomy includes `Property/` folder |

### Empty / stub locations (no markup files)

- `openclaw-documents/Property/` — empty
- `ranchbrain/assets/Property/` — empty
- `ranchbrain/manuals/Property/` — category dirs only (Buildings, Fences, Pool not listed; Boundary-Surveys, Bridges, …) with no files
- Obsidian link `[[Property]]` from Dashboard — **no `Property.md` found**

### Non-markup PropertyManager artifacts on the drive

- `openclaw-backups/propertymanager/propertymanager-before-ui-improvements-20260604-172710.tar.gz` — code/data backup, not design docs
- Snapshot paths inside that archive include `tools/property_manager/*` (CSV, summary/telegram scripts)

### QNAP mount

`/mnt/qnap-backup` had no PropertyManager markdown in a shallow search.

### Conclusion for design authority

As of 2026-07-25 this document **is** the PropertyManagerApp design installed into the Intel Mini external library:

1. **Canonical:** `openclaw-documents/Property/PropertyManagerApp-DESIGN.md` (this file)
2. **Obsidian hub:** `ranchbrain/Property.md` via Dashboard `[[Property]]`
3. **Working copy:** M4 `PropertyManagerApp/docs/DESIGN.md` (must stay in sync)
4. Supporting context: live Swift app + scripts; OpenClaw foundation/architecture; RanchBrain Foundation principles

Empty Property stubs were replaced/filled by this install rather than left as a competing empty taxonomy.

---

## 16. Manufacturer Manual PDF Import

**Shipped 2026-07-25**

Operators can create maintenance tasks from manufacturer PDF manuals:

1. Sidebar → **Import from Manual PDF**
2. Choose a PDF (defaults to `~/Downloads/PDFs`)
3. App extracts text locally with PDFKit, then asks **local Ollama** on the Mac (`http://127.0.0.1:11434`; open-source model `gemma3:12b` by default; override with `PROPERTYMANAGER_OLLAMA_MODEL` / `PROPERTYMANAGER_OLLAMA_URL`). No cloud AI.
4. Review sheet lists proposed tasks with part numbers, URLs, tools/socket sizes
5. Selected tasks are imported into the Mac JSON store (Mac-only rich fields)
6. PDF is copied to Application Support `manuals/` for provenance
7. Operator reviews/edits, then **Publish** shared OpenClaw columns when ready

### Extra task fields (Postgres + Mac cache; slim CSV still 5 columns)

- `manufacturer`
- `sourceManualName`
- `origin` (`manufacturer` | `owner`) — set to Manufacturer on import
- `parts[]` / `toolsRequired[]` (`name`, `size`, `notes`)

These round-trip through the PropertyManager API / Postgres. The slim OpenClaw CSV export remains the 5 shared columns only.


### Import from URL (web TOC / section pages)

**Shipped 2026-07-27**

Operators can propose manufacturer tasks from a public manufacturer manual **TOC or section page URL**:

1. Sidebar → **Import from URL**
2. Paste `http(s)` manufacturer page URL → **Fetch**
3. App performs a **bounded** HTML fetch (≤12 section pages, ~≤90k characters total text). Relative links resolved against the page base. TOC-ish links may be harvested; local Ollama may select maintenance-relevant sections only.
4. **SHA256** of the concatenated labeled source corpus is computed **before** Ollama (site-change detection).
5. Local Ollama proposes tasks with **strict separation**:
   - **Source facts:** title/pub/model/serial only when present; interval; fluids; capacities; filters; parts; tools; safety warnings; verbatim excerpt (~≤400 chars); section source URL(s)
   - **AI inference:** `inferredNotes` + confidence (0–1) — never unlabeled mix; do not invent publication/serial numbers or links
6. Review sheet shows provenance (original URL, retrieval ISO timestamp, checksum, identity fields), excerpt, confidence, verification status
7. Selected import sets verification to **user_accepted** and persists `manualImport` on each `MaintenanceTask` (Mac JSON; backward-compatible decode defaults)
8. **Does not** archive or mirror full copyrighted manuals / HTML trees (no `archiveManualPDF` on this path)

Caps and product rules match PDF import for local-Ollama-only processing (`PROPERTYMANAGER_OLLAMA_MODEL` / `PROPERTYMANAGER_OLLAMA_URL`).


## 17. Manufacturer task generation from asset manuals

**Status:** Active (2026-07-25)

### Manual library

- Canonical Intel: `/mnt/ai-storage/ranchbrain/manuals/` filed by asset (`ASSET_MANUAL_INDEX.md`)
- M4 working mirror: `~/Development/PropertyManagerApp/manuals/` (same relative paths)
- App PDF picker defaults to the M4 manuals mirror
- Re-sync script: `scripts/sync-manuals-to-intel.sh`

### Batch importer

`scripts/import-manual-tasks-from-pdfs.py`

1. PDFKit text extraction
2. Local Ollama (`llama3.1:latest` default; override `PROPERTYMANAGER_OLLAMA_MODEL`)
3. Merge into Application Support `maintenance_tasks.json` by `(area,item)` without wiping existing tasks
4. Preserves manufacturer, part numbers, URLs, tools/socket sizes as Mac-only fields
5. Operator reviews in app, then Publish shared OpenClaw CSV columns when ready



---

## 16. Postgres system of record (2026-07-26)

### Schema / API

- Migration: `tools/property_manager/db/002_rich_task_model.sql`
  - Task columns: `kind`, `manufacturer`, `source_manual_name`, `completion_history`, `tools_required`
  - Tables: `maintenance_task_parts`, `maintenance_task_photos`
  - Seeded category **Property**
- API: `tools/property_manager/api/propertymanager_api.py` on port **5062**
  - CRUD categories/tasks, nested parts/photos, photo upload, `POST /export/csv`
  - Bearer token when `PROPERTYMANAGER_API_TOKEN` is set
  - DB access: TCP when password env is set; otherwise `docker exec postgres` on IntelMini
- systemd user unit: `propertymanager-api.service` → `run_api.sh`

### One-time import

- `tools/property_manager/db/import_swift_json_to_postgres.py` upserts Mac JSON + copies attachments under `/mnt/ai-storage/openclaw-documents/Property/attachments/`

### Mac sync scripts

| Script | Role |
|---|---|
| `scripts/refresh-from-postgres.sh` | Replace local JSON cache from API |
| `scripts/save-to-postgres.sh` | Upsert local cache tasks/categories (+ photo upload) to API |

Default API base on M4: `http://192.168.50.104:5062` (override with `PROPERTYMANAGER_API_BASE`).

### Proof checklist (completed)

1. `\d propertymanager.maintenance_task_parts` / photos columns present
2. API create task with 2 parts + photo; GET returns nested payload
3. Mac Refresh wrote 47 tasks / 8 categories with nested parts
4. Mac Save upserted 47 tasks back to Postgres
5. `POST /export/csv` regenerates 5-column `maintenance_log.csv`


---

## 18. Task origin + Fill How-To from Manual (2026-07-27)

### Product framework

Maintenance tasks have two independent axes:

| Axis | Values | Meaning |
|---|---|---|
| **Kind** | Scheduled / Work Request | What kind of job it is |
| **Origin** | Manufacturer / Owner-added | Where the procedure came from |

**Manufacturer** — schedule/procedure comes from the manufacturer's handbook (PDF import, or How-To filled from that manual).

**Owner-added** — the steward added the task because it is judged necessary; not derived from the handbook.

Operators must be able to see the difference at a glance (list/detail badges on Mac and iPhone; Mac origin filter).

### Defaults

| Action | Origin set to |
|---|---|
| New Scheduled Task / New Work Request | Owner-added |
| Import from Manual PDF (bulk create) | Manufacturer (+ `sourceManualName` / `manufacturer`) |
| **Fill How-To from Manual** succeeds | Manufacturer; How-To replaced from PDF via Ollama |
| Fill How-To finds no procedure / cancel / error | Owner-added; generic How-To template |

### Fill How-To from Manual (this task only)

Replaces the old **Create New Response** template buttons.

1. Resolve PDF: App Support `manuals/{sourceManualName}`, then `~/Development/PropertyManagerApp/manuals/`, else file picker (archive pick into App Support).
2. Local Ollama extracts numbered How-To for **this** Area/Item only (does not create new tasks).
3. On hit → update `responseInstructions`, set origin Manufacturer, keep/set manual name.
4. On miss → generic How-To, origin Owner-added, status explains why.

Bulk create remains sidebar **Import from Manual PDF**.

### Local AI for manufacturer PDFs (authoritative)

Manufacturer PDF processing uses **local open-source AI only** — not cloud AI:

- **PDFKit** extracts text on the Mac
- **Ollama** on the Mac (`http://127.0.0.1:11434` by default) proposes maintenance tasks / numbered How-To steps
- Default model: open-source `gemma3:12b` (override `PROPERTYMANAGER_OLLAMA_MODEL` / `PROPERTYMANAGER_OLLAMA_URL`)
- Surfaces: sidebar **Import from Manual PDF** and **Fill How-To from Manual**

### Persistence

- Migration: `tools/property_manager/db/004_task_origin.sql`
  - Column `propertymanager.maintenance_tasks.origin` (`manufacturer` | `owner`)
  - Backfill: non-empty `source_manual_name` → `manufacturer`, else `owner`
- API: `origin` on task GET/POST upsert/PATCH; category delete still requires explicit `reassign_to` when active tasks remain
- Mac Publish/Refresh scripts map `origin` ↔ JSON
- iPhone PropertyManager app shows Manufacturer / Owner-added badges after Refresh

### UX surfaces

- Mac: segmented origin filter (All / Manufacturer / Owner-added); badges on rows + editor; editable Origin control
- iPhone: origin badge on task row; Origin (+ manufacturer / source manual) on detail

---

## 19. Apple Calendar Sync — OpenClaw push (2026-07-30)

**Status:** DEV build on M4. Trial-first — prod deferred until Andrew confirms it adds value in daily planning.

### Design
One-way push only: PM → Apple Calendar. Calendar is a **read-only planning view**.
Deleting or editing a Calendar.app event never modifies PM task data, due dates, or completion.
Completing, rescheduling, or editing tasks is done only through the PM Mac or iPhone UI → REST API.

### Feature
- **Sidebar button:** “Push today's due tasks to OpenClaw”
- Timed blocks stacked from a configurable start time (default 8:00 AM), each block = `estimated_minutes` (fallback 30 min).
- Filter: active tasks, `schedule_kind` in `calendar | both`, `next_due` local date ≤ today.
  - Overdue (incomplete) tasks roll forward automatically: they stay in the push filter every day until marked complete in PM, because `next_due` only advances on completion.
- Target calendar is fixed by the signed app identity:
  - DEV app → **OpenClaw DEV**
  - Production app → **OpenClaw**
  Both calendars must already exist; the app does not create them.
- Idempotent: re-push removes old PM-managed blocks first, then writes fresh ones.
- DEV event title: `[DEV] Asset: Task`; production title: `Asset: Task`.
  Notes include a stable environment marker and task-description snippet.

### DEV / prod marker strategy
Every PM-created event has a stable identifier in its Notes field:
- DEV: `propertymanager://task/<uuid>?env=dev`
- Prod: `propertymanager://task/<uuid>?env=prod`

This provides two independent safety boundaries: separate calendars and separate event markers.
The DEV build displays a persistent orange **PROPERTY MANAGER - DEVELOPMENT** banner,
locks Calendar actions to DEV, and has no operator-selectable production mode.
The **Delete DEV PM calendar events** button operates only on **OpenClaw DEV** and
removes only `env=dev`-tagged events. It cannot inspect or modify **OpenClaw**.

### Pre-prod cutover checklist
1. Verify the production app has the production bundle identifier and does not show the DEV banner.
2. Verify its Calendar label is production and resolves only the **OpenClaw** calendar.
3. Perform a production test push only after explicit operator approval; confirm the event has
   no `[DEV]` title prefix and carries `env=prod` in Notes.

### On Mac complete → calendar cleanup
When a task is marked complete in the Mac app, its OpenClaw calendar event is deleted immediately.
Controlled by UserDefaults `propertyManager.removeCalendarEventOnComplete` (default true).
Set to false to disable without code changes if the product preference changes later.

iPhone-only completions: nextDue advances past today on the next Mac Refresh; the task then falls out
of the push filter, so its block disappears on the next Push Today.

### Settings (UserDefaults keys)
| Key | Type | Default | Purpose |
|---|---|---|---|
| `propertyManager.calendarStartHour` | Int | 8 | Hour (0-23) for first block start |
| `propertyManager.calendarStartMinute` | Int | 0 | Minute offset |
| `propertyManager.removeCalendarEventOnComplete` | Bool | true | Auto-delete event on Mac complete |

### Files
| File | Location |
|---|---|
| `CalendarSyncService.swift` | M4 `Sources/PropertyManagerApp/` + Mini `tools/property_manager/swift-mac/` |
| `PropertyManagerApp.swift` | calendar push/delete/remove methods in MaintenanceStore + SidebarView calendar section |
