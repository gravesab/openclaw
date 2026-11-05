# Ranch Finance — Master Specification

**Version:** 1.1

**Status:** Refined implementation contract

**Architecture baseline:** OpenClaw Architecture 1.0 and approved Apple-first extension

**Initial deployment:** Development only

**Owner and final authorization authority:** Andy Graves

## 1. Purpose

Ranch Finance is the governed finance module of Andy's unified Ranch Operating System. It provides one authoritative view of personal, ranch, and Zero-G LLC financial activity while preserving domain boundaries, provenance, privacy, and auditability.

The module consists of a PostgreSQL finance schema, server-enforced OpenClaw APIs, a staged macOS-first CSV import flow, native SwiftUI apps for macOS and iOS, replaceable device caches, and approved summaries for RanchBrain and the Executive Dashboard.

This document is the canonical v1 implementation contract. If repository conventions conflict with it, Codex must document the conflict and stop for review rather than silently changing the contract.

## 2. Governing Principles

1. **One authoritative store.** PostgreSQL is authoritative. SwiftData, Core Data, and other device stores are replaceable caches only.
2. **API-only application access.** macOS and iOS clients never connect directly to PostgreSQL. Reads and mutations pass through authenticated OpenClaw APIs.
3. **Unified view with explicit domains.** Personal, Ranch, and Zero-G LLC are first-class finance domains, not values hidden in categories or JSON.
4. **Local-first and portable.** Core operation remains local and portable to supported Apple-silicon hosts. No cloud financial-data provider is required.
5. **Human-authorized mutation.** AI may suggest mappings, categories, or corrections. Deterministic rules validate them. Andy confirms material changes. OpenClaw records the result.
6. **Evidence preservation.** Import provenance, checksums, mapping decisions, warnings, corrections, and exclusions are retained. Rollback excludes entries; it does not destroy source evidence.
7. **Privacy by default.** Raw finance data stays inside the Finance domain. RanchBrain receives only explicitly approved summaries or relationships.
8. **Time-aware reporting.** Month boundaries use `America/Chicago`, not server UTC.
9. **Small, testable releases.** Work proceeds in development through reviewed checkpoints. Production promotion requires separate explicit approval.
10. **No silent beta dependency.** Apple beta frameworks may be evaluated in development. Production requires runtime checks, compatibility documentation, and graceful fallback.

## 3. Scope

### 3.1 Included in v1

- account, category, and finance-domain management;
- staged macOS CSV import with mapping, preview, deduplication, confirmation, commit, and reversible batch exclusion;
- transaction provenance, categorization, notes, reconciliation, and reversible correction;
- explicit paired transfers;
- monthly summaries, top categories, domain filtering, and account filtering;
- shared SwiftUI “This Month” experiences for macOS, iPhone, and iPad;
- server authorization, idempotency, audit recording, and sync-version validation;
- recurring-rule definitions and forecast occurrences; and
- localization keys, accessibility, dark mode, and Dynamic Type.

### 3.2 Deferred

- direct bank aggregation, FinanceKit/Wallet ingestion, and iOS file import;
- investment lots, tax basis, depreciation, payroll, invoicing, and formal accounting reports;
- multi-currency conversion and transaction splits;
- autonomous AI financial mutations;
- automatic posting of recurring forecasts as actual transactions; and
- destructive deletion of imported evidence.

## 4. Canonical Terms and Amount Semantics

| Term | Meaning |
| --- | --- |
| Finance domain | `personal`, `ranch`, or `zero_g`; the operating context assigned to an account or transaction. |
| Actual transaction | A posted or manually confirmed financial event included in actual reporting. |
| Forecast occurrence | An expected event from a recurring rule; excluded from actual totals until confirmed or matched. |
| Transfer | Two actual entries, equal and opposite, joined by one explicit transfer record. |
| Exclusion | A reversible state that removes a transaction from normal totals without deleting history. |
| Correction | A new transaction that supersedes an earlier entry; the earlier entry remains auditable. |

`transactions.amount` is signed and authoritative: positive is inflow, negative is outflow, and zero is prohibited. The database must not store an independently editable `direction` field. API responses may expose a derived direction for presentation.

All v1 monetary values use `numeric(14,2)`. Currency uses ISO 4217 codes and defaults to `USD`.

## 5. PostgreSQL Data Contract

Use the repository's approved schema convention; the logical namespace here is `finance`. Mutable tables use UUID primary keys from `gen_random_uuid()`, required `created_at` and `updated_at` timestamps, and the shared `set_updated_at()` trigger. Use check constraints for enum-like values unless the repository consistently uses PostgreSQL enums.

### 5.1 `finance_domains`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `code` | text | Unique and immutable; seed `personal`, `ranch`, `zero_g`. |
| `name` | text | User-facing name. |
| `sort_order` | integer | Default `0`. |
| `is_active` | boolean | Default `true`. |
| `created_at`, `updated_at` | timestamptz | Required. |

Index `code` uniquely and index `is_active`.

### 5.2 `accounts`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `default_domain_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `name` | text | Required. |
| `account_type` | text | `checking`, `savings`, `credit`, `investment`, or `cash`. |
| `institution` | text | Nullable. |
| `currency` | char(3) | Required; default `USD`. |
| `opening_balance` | numeric(14,2) | Default `0.00`. |
| `opening_balance_date` | date | Required when opening balance is nonzero. |
| `last_four` | text | Nullable; exactly four digits when present. Full account numbers are prohibited. |
| `is_active` | boolean | Default `true`. |
| `metadata` | jsonb | Default `{}`; noncanonical display/configuration only. |
| `created_at`, `updated_at` | timestamptz | Required. |

Index domain, active state, and case-insensitive name. Never store credentials, routing numbers, or full account identifiers in `metadata`.

### 5.3 `categories`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `domain_id` | uuid FK | Nullable; null means reusable across domains; `ON DELETE RESTRICT`. |
| `parent_id` | uuid FK | Nullable self-reference; `ON DELETE RESTRICT`. |
| `name` | text | Required. |
| `category_type` | text | `income`, `expense`, or `transfer`. |
| `color` | text | Nullable `#RRGGBB`. |
| `icon` | text | Nullable SF Symbol identifier. |
| `sort_order` | integer | Default `0`. |
| `is_active` | boolean | Default `true`. |
| `created_at`, `updated_at` | timestamptz | Required. |

Names are unique case-insensitively within parent/domain scope. A category cannot parent itself. The v1 API limits hierarchy to two levels. Inactive categories remain readable historically.

### 5.4 `import_profiles`

Reusable institution/account parsing preferences are separate from individual batches.

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `account_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `name` | text | Required. |
| `header_fingerprint` | text | Required. |
| `column_mapping` | jsonb | Versioned API-validated mapping. |
| `sign_convention` | text | `signed`, `positive_expense`, or `positive_income`. |
| `date_format` | text | Explicit parser format. |
| `is_active` | boolean | Default `true`. |
| `created_at`, `updated_at` | timestamptz | Required. |

Active profiles are unique by account and header fingerprint.

### 5.5 `import_batches`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `account_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `profile_id` | uuid FK | Nullable; `ON DELETE SET NULL`. |
| `source_filename` | text | Required basename only. |
| `source_sha256` | text | Required 64-character lowercase hex checksum. |
| `source_evidence_ref` | text | Governed local evidence reference, never a public URL. |
| `status` | text | `staged`, `previewed`, `committed`, `partial`, `failed`, or `excluded`. |
| `total_row_count` | integer | Nonnegative. |
| `valid_row_count` | integer | Nonnegative. |
| `imported_count` | integer | Nonnegative. |
| `duplicate_count` | integer | Nonnegative. |
| `error_count` | integer | Nonnegative. |
| `warning_count` | integer | Nonnegative. |
| `mapping_snapshot` | jsonb | Exact versioned mapping used. |
| `confirmed_at` | timestamptz | Set after user confirmation only. |
| `confirmed_by` | text | Stable authenticated actor identifier. |
| `created_at`, `updated_at` | timestamptz | Required. |

Index account/date, status, and source checksum. The same source checksum cannot commit twice for the same account.

### 5.6 `transactions`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `account_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `domain_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `category_id` | uuid FK | Nullable; `ON DELETE SET NULL`. |
| `transfer_id` | uuid FK | Nullable; `ON DELETE RESTRICT`. |
| `import_batch_id` | uuid FK | Nullable; `ON DELETE RESTRICT`. |
| `supersedes_transaction_id` | uuid FK | Nullable self-reference; `ON DELETE RESTRICT`. |
| `amount` | numeric(14,2) | Required, signed, and nonzero. |
| `currency` | char(3) | Required; must match the account in v1. |
| `description` | text | Required, trimmed, nonempty. |
| `normalized_description` | text | Deterministically generated; not user-editable. |
| `merchant` | text | Nullable. |
| `transaction_date` | date | Required. |
| `posted_date` | date | Nullable. |
| `source_type` | text | `csv`, `manual`, `recurring_confirmation`, or `system_correction`. |
| `source_row_number` | integer | Required for CSV entries. |
| `source_reference` | text | Nullable institution transaction identifier. |
| `dedup_fingerprint` | text | Required versioned fingerprint. |
| `notes` | text | Nullable. |
| `reconciliation_status` | text | `unreconciled` or `reconciled`. |
| `record_status` | text | `active`, `excluded`, `voided`, or `superseded`. |
| `metadata` | jsonb | Default `{}`; noncanonical source details only. |
| `created_at`, `updated_at` | timestamptz | Required. |

Index account/date, domain/date, category/date, import batch, transfer, source reference, and dedup fingerprint. Add a partial index for active rows. Actual reporting includes only active rows. The v1 API never physically deletes transaction history.

### 5.7 `transfers`

| Column | Type | Requirements |
| --- | --- | --- |
| `id` | uuid PK | Generated UUID. |
| `from_account_id` | uuid FK | Required; `ON DELETE RESTRICT`. |
| `to_account_id` | uuid FK | Required; `ON DELETE RESTRICT`; different from source. |
| `transfer_date` | date | Required. |
| `currency` | char(3) | Required. |
| `amount` | numeric(14,2) | Required and greater than zero. |
| `status` | text | `pending`, `confirmed`, `excluded`, or `broken`. |
| `notes` | text | Nullable. |
| `created_at`, `updated_at` | timestamptz | Required. |

A confirmed transfer has exactly two active transaction rows: `-amount` on the source and `+amount` on the destination. Both share `transfer_id`. Transfer rows are excluded from income, expense, net, and category totals. The API changes the transfer and both entries atomically.

### 5.8 `recurring_rules` and `forecast_occurrences`

Recurring rules create forecasts only in v1.

`recurring_rules` contains UUID, name, account, domain, optional category, signed amount, currency, frequency (`weekly`, `biweekly`, `monthly`, `quarterly`, `yearly`), start date, optional end date, next forecast date, default description, active state, timestamps, and metadata.

`forecast_occurrences` contains UUID, rule ID, expected date, signed expected amount, status (`expected`, `matched`, `skipped`, `confirmed`), optional matched transaction ID, timestamps, and uniqueness on rule plus expected date.

An OpenClaw server worker generates forecasts idempotently. It never creates actual transactions automatically. Matching or conversion requires an authenticated confirmation.

### 5.9 `audit_events`

Use OpenClaw's approved append-only audit service if one exists. Otherwise implement a finance-local append-only table with event UUID/time, authenticated actor, action, object type/UUID, correlation ID, redacted before/after representations, confirmation reason, and approved device metadata. Application roles may insert but not update or delete audit events.

## 6. Reporting Semantics

Implementation may use SQL views or parameterized read models consistent with repository conventions.

### 6.1 Monthly summary

Group by month, domain, and optionally account:

- `total_income`: positive active nontransfer actual transactions;
- `total_expenses`: absolute value of negative active nontransfer actual transactions;
- `net`: signed sum of active nontransfer actual transactions;
- `transaction_count`: active nontransfer actual transactions; and
- `transfer_count`: distinct confirmed transfers, reported separately.

### 6.2 Category totals

Group active negative nontransfer actual transactions by month, domain, and category. Null categories appear as **Uncategorized**. Refunds or credits categorized as expenses reduce category spending rather than appearing as income.

### 6.3 Date rules

- Group by `transaction_date` in the configured finance timezone.
- API month parameters use `YYYY-MM`.
- Current-month average daily spend divides by the local calendar day number.
- Past-month average daily spend divides by the days in that month.
- Future-month average daily spend is `0.00` and marked not applicable.
- Division by zero is prohibited.

## 7. OpenClaw API Contract

Route prefixes may adapt to existing conventions; behavior is mandatory.

### 7.1 Reads

Provide monthly summary and top categories by month with optional domain/account filters, paginated transactions, active reference data, and import/transfer/forecast status. Responses include schema version and server revision so clients can invalidate stale caches.

### 7.2 Mutations

Every finance mutation must:

1. authenticate and authorize the actor;
2. accept an idempotency key;
3. validate the current object revision or sync token;
4. return a human-readable proposal/preview for material changes;
5. require explicit confirmation for import commit/exclusion, transfer changes, correction, and forecast conversion;
6. write the database change and audit event in one server transaction; and
7. return the new revision and correlation ID.

Clients cannot bypass confirmation through a lower-level endpoint. Expired or reused confirmation tokens fail closed. Stale revisions return a conflict and require reload.

### 7.3 Privacy and transport

- APIs listen only on approved local or Tailscale-restricted interfaces.
- Secrets use approved OS/server secret storage, never source control or app preferences.
- Logs redact raw CSV rows, full account identifiers, and authentication material.
- Finance details are not exposed to general RanchBrain memory ingestion.
- Backup, restore, retention, and encryption follow approved OpenClaw governance.

## 8. macOS-first CSV Import

### 8.1 Entry

Use **File → Import CSV…** with **⌘I**, or drag one `.csv` file onto the macOS window. The client sends the file to the local finance API for staged processing; it never writes transactions directly.

### 8.2 Stage

The server computes SHA-256, records governed evidence, detects encoding (UTF-8, UTF-8 BOM, then Windows-1252/Latin-1), detects delimiter/header, enforces safe file limits, rejects empty/unsafe files, and detects exact-file reimports. Nothing becomes actual during staging.

### 8.3 Map

Show at least 10 rows and map transaction date (required), posted date, amount or separate debit/credit columns (required), description (required), merchant, category, institution reference, notes, or skip.

Auto-detection may propose mapping, date format, and sign convention. The proposal remains visible and editable. Confirmed mappings may become an import profile for that account/header fingerprint.

### 8.4 Validate and deduplicate

Each row receives `valid`, `exact duplicate`, `possible duplicate`, `warning`, or `error`.

Errors include invalid/missing date, invalid/missing/zero amount, missing description, unsupported currency, and conflicting debit/credit columns.

Deduplication has two levels:

1. **Exact duplicate:** same account and stable institution reference, or committed source-file/source-row identity. Default to skipped.
2. **Possible duplicate:** same account, normalized date, exact cent amount, and normalized description fingerprint within the configured date window. Require visible review; never silently discard.

The versioned fingerprint is server-owned. Dedup never crosses accounts and never automatically creates a transfer.

### 8.5 Preview and confirm

Show all row-status counts, inflow/outflow totals, category/domain assignments, reasons for skipped/invalid rows, and the exact number of transactions to create. Disable **Import** until required errors are resolved or explicitly excluded. Confirmation identifies account, counts, net amount, checksum, and preview revision.

### 8.6 Atomic commit

The server validates preview revision and confirmation token, inserts transactions, records counts/mapping, marks batch state, writes audit evidence, and returns a new revision in one database transaction. Reusing an idempotency key returns the original result without duplication.

### 8.7 Reversible exclusion

“Undo import” first proposes affected transactions and changed totals. Confirmation atomically excludes eligible batch transactions and the batch. Reinstatement is separately confirmed and audited. Evidence/history remain intact.

## 9. “This Month” UI

### 9.1 Shared layout

1. **Month header:** month/year, previous/next, and **Today** when viewing another month.
2. **Filters:** domain (`All`, `Personal`, `Ranch`, `Zero-G LLC`) and optional account.
3. **Cards:** Income, Expenses, Net; transfers excluded.
4. **Top categories:** five adjusted expense categories, including **Uncategorized** when applicable, with icon/color, amount, percentage, and bar.
5. **Quick stats:** transaction count, confirmed transfer count, uncategorized count, and average daily spend.
6. **Data status:** subtle stale/offline cache indicator when data is not current.

The first UI checkpoint is read-only. Mutation surfaces appear only after API, authorization, and security gates pass.

### 9.2 macOS

- Default main view with collapsible sidebar.
- Destinations: This Month, Transactions, Accounts, Import, Categories, Recurring Rules. Unimplemented destinations are visibly disabled.
- Three cards in a row where space permits; full-width category list below.
- Month shortcuts: **⌘←** and **⌘→**.
- Minimum window: 800 × 600 points.

### 9.3 iPhone and iPad

- First tab in a tab view; only implemented destinations are active.
- Cards stack in compact width and form a row in regular width.
- Month gestures may use subtle haptics when supported and allowed by accessibility settings.
- iPad split view follows effective size class.

### 9.4 States

- **Empty:** `$0.00` cards, “No transactions for this month,” zero quick stats.
- **Loading:** stable-layout, nonflashing placeholders.
- **Offline/stale:** cached data with timestamp and clear stale indicator.
- **Error:** retain last valid view when possible and offer retry. Never replace a valid total with an ambiguous blank.

### 9.5 Accessibility and localization

Use semantic colors where possible; color is never the only indicator. Meet WCAG AA for text/essential indicators. Support VoiceOver, keyboard focus, Dynamic Type, Reduce Motion, dark mode, and locale-aware currency/dates. Store strings in localization resources from the first implementation.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `incomeAccent` | `#248A3D` | `#4FC870` | Income and positive net. |
| `expenseAccent` | `#C8452D` | `#FF7A5C` | Expense and negative net. |
| `cardBackground` | system secondary background | system secondary background | Summary cards. |
| `rowBackground` | system background | system background | Category rows. |

System colors take precedence when accessibility or platform consistency requires it.

## 10. Client Architecture and Sync

- Use a shared Swift package for API models, client protocol, filters, formatting, and import-preview types.
- View models depend on the client protocol, not database/network implementations.
- Device persistence is cache and queued-command storage only; it is not an independent 1:1 database authority.
- Cache records include server revision and last-synced time.
- Queued mutations retain idempotency key and expected revision.
- Reconnection triggers server revalidation before a queued mutation is reconfirmed or submitted.
- Financial conflicts never use last-write-wins.

## 11. Threat-model Gate

Write-capable features are blocked until tests demonstrate defenses against:

- unauthorized local-network/Tailscale access;
- replayed import, confirmation, transfer, correction, or exclusion requests;
- stale-device writes and tampering between preview and commit;
- path traversal, malicious filenames, CSV formula injection, and oversized imports;
- duplicate/partial commits after timeout or retry;
- logs/crash reports disclosing finance data;
- client attempts to bypass confirmation; and
- compromised AI suggestions attempting unapproved mutation.

Tests must prove fail-closed behavior and safe audit correlation.

## 12. Implementation Sequence

All work begins on `development`. Before editing, Codex inspects repository instructions, migration conventions, API patterns, package layout, audit/auth services, and test commands.

### Checkpoint 0 — Contract alignment

- Place this specification in the canonical documentation location.
- Identify architecture/code conflicts;
- produce a file-level implementation and test plan; and
- make no production changes.

### Checkpoint 1 — Read-only data foundation

- Add migration for domains, accounts, categories, transactions, transfers, and reporting models.
- Add constraints, triggers, seed data, rollback-safe migration behavior, read APIs, authorization, and tests.

### Checkpoint 2 — Read-only SwiftUI

- Add shared finance client/models and “This Month.”
- Verify macOS, iPhone, iPad, dark mode, accessibility, month boundaries, and empty/error/stale states.

### Checkpoint 3 — Staged import

- Add profiles, batches, staging, preview, checksum, dedup, confirmation, idempotency, audit, and reversible exclusion.
- Enable macOS import only after security tests pass.

### Checkpoint 4 — Transfers and corrections

- Add atomic paired transfers, reversible exclusion, superseding corrections, and conflict/replay tests.

### Checkpoint 5 — Recurring forecasts

- Add rule management, idempotent forecast generation, matching, and confirmed conversion.
- Never auto-post forecasts as actual transactions.

Every checkpoint starts clean, stays scoped, passes tests, documents manual verification, receives review, and ends in an intentional commit. Production promotion is separate and not authorized here.

## 13. Acceptance Criteria

1. PostgreSQL is the only authoritative finance store; clients cannot connect directly.
2. Personal, Ranch, and Zero-G LLC filters return correct isolated and combined totals.
3. Transfers never change income, expense, net, or category totals.
4. Signed amount semantics cannot conflict with a second direction field.
5. The same CSV cannot commit twice for one account.
6. Possible duplicates are visible and never silently discarded.
7. Preview and committed content are cryptographically tied by checksum/revision.
8. Idempotent retries create no duplicates.
9. Stale revisions fail closed and require reload.
10. Undoing an import excludes entries without deleting provenance/audit history.
11. Raw finance records do not enter general RanchBrain memory without approved transformation.
12. Current, past, and future daily averages follow section 6.3.
13. One API fixture produces equivalent totals across macOS, iPhone, and iPad.
14. Accessibility, localization, dark mode, offline/stale, empty, loading, and error QA passes.
15. Unauthorized, replayed, tampered, or confirmation-bypassing writes fail closed.
16. No undocumented beta-only dependency is required in production.
17. No production mutation or deployment occurs without separate approval.

## 14. Resolved Decisions

| Question | Resolution |
| --- | --- |
| Section name | Use **PostgreSQL Data Contract** because it defines persistent requirements. |
| Guidance level | Keep design and implementation details, separated into requirements and checkpoints. |
| SQL/color placement | Keep behavior and compact tokens inline; generate exact DDL after repository inspection. |
| Recurring execution | OpenClaw server worker creates forecasts idempotently; no device timer, `pg_cron`, or auto-posting. |
| Transfers | Explicit transfer record plus exactly two equal-and-opposite transaction rows. |
| Swift persistence | PostgreSQL through OpenClaw APIs is authoritative; device storage is cache-only. |
| Mutation safety | Authorization, preview/proposal, confirmation, audit transaction, idempotency, and revision validation are mandatory. |

## 15. Change Control

Changes to amount semantics, transfer treatment, domain separation, mutation authorization, audit retention, API-only database access, or production policy are architectural changes requiring a specification revision and Andy's explicit approval.

Minor wording, nonsemantic layout adjustments, and repository-convention adaptations may be documented in the implementation plan if they do not alter behavior or weaken acceptance criteria.

---

*End of Ranch Finance Master Specification v1.1.*
