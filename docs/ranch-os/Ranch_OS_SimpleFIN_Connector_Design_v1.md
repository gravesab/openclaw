# Ranch OS — SimpleFIN Read-Only Bank Connector Design v1

**Version:** 1.0 (draft for review)
**Status:** Proposed — not approved for DEV implementation
**Scope:** Optional read-only bank and card activity feed for Ranch Finance via the SimpleFIN protocol (SimpleFIN Bridge)
**Production:** Unchanged. DEV only. No credentials, accounts, or network calls are authorized by this document.

## 1. Purpose

Ranch Finance imports activity by staged CSV today (Master Specification v1.1 §8). Manual CSV downloads are tedious, so imports happen less often and the books drift. SimpleFIN is a small, read-only protocol for pulling account balances and transactions. This document designs an **optional** SimpleFIN connector. Fetched activity enters the **same staged, human-confirmed import pipeline** as CSV and gets no shortcuts.

The connector is a source of evidence, not an authority. PostgreSQL stays the only authoritative store. Nothing a connector fetches becomes an actual transaction until an administrator confirms it.

## 2. Governing principles

1. **Read-only, by protocol and by design.** SimpleFIN shares read-only financial data (protocol §Overview). The connector never initiates payments or transfers and never changes accounts. There is no write path to build.
2. **Opt-in exception to local-first.** Master Spec §2.4 says "No cloud financial-data provider is required." SimpleFIN Bridge is a cloud intermediary, so this connector is **optional and off by default**. Each account is opted in separately by an administrator, and CSV import remains the complete fallback.
3. **Human-confirmed commit.** Each sync produces a staged batch. Commit follows the Master Spec §7.2 mutation rules: authenticated actor, idempotency key, revision check, preview, explicit confirmation, and an atomic write with an audit record. Auto-staging is allowed; auto-commit is not.
4. **The Access URL is a secret.** It embeds HTTP Basic credentials (protocol §Access URL). It never reaches logs, AI models, RanchBrain, client apps, app preferences, source control, or crash reports.
5. **Master Spec v1.1 is the contract.** The owner ruled on 2026-11-05 (GAP_ANALYSIS.md P0-5) that the single-entry, signed-amount Master Spec v1.1 is canonical. `ranchbrain_app/docs/RANCH_FINANCE_FOUNDATIONAL_DESIGN.md` is superseded. §8 maps SimpleFIN data to Master Spec staged import rows and `transactions`.
6. **Recoverable and visible.** Quota warnings, authentication failures, and upstream connection errors stop polling and appear to the administrator as a repair-needed state. Polling never retries in a loop.

## 3. Verified protocol and Bridge facts

All facts were retrieved on 2026-11-05 from the sources in §15. Anything a source does not state is marked UNKNOWN.

| Topic | Fact | Source |
|---|---|---|
| Setup | A *SimpleFIN Token* is a Base64-encoded claim URL. `POST` to it once; a 200 returns the Access URL. 403 means the token is unknown or already claimed, which may indicate compromise. | Protocol |
| Credential | The Access URL is "just a URL with included Basic Auth credentials", e.g. `https://user:pass@host/simplefin`. Apps should store it securely. | Protocol |
| Fetch | `GET {access}/accounts`. Optional parameters: `start-date` (inclusive) and `end-date` (exclusive) as UNIX epoch timestamps, `pending=1`, `account=<id>` (repeatable), `balances-only=1`, `version`. | Protocol |
| HTTP codes | 200 OK, 402 payment required, 403 authentication failed. | Protocol |
| Version | The spec is `2.0.0-draft`. `GET /info` lists supported versions; "most servers currently report 1 or 2." In v2, organization data lives in `connections[]`, and errors come in `errlist[]` (objects with `code` and `msg`). The `errors` string array is deprecated. | Protocol |
| Amounts | Balances and amounts are numeric strings. **Positive means money deposited into the account.** | Protocol |
| Timestamps | UNIX epoch. The unit is not stated explicitly, but the examples are seconds. Treat as seconds, and validate the range. | Protocol |
| Transactions | `id`, `posted` (may be `0` if pending), `amount`, `description`, and optionally `transacted_at`, `pending` (default false), and `extra`. Ordered by `posted`. | Protocol |
| ID stability | Transaction IDs must not repeat **within an account**. They may repeat across accounts. | Protocol |
| Error display | Sanitize error text and custom currency strings before display. Use HTTPS with verified certificates. | Protocol |
| Quota | "You are expected to make 24 requests or fewer per day." All-accounts and per-account requests have separate quotas. Overuse produces warnings first; continued overuse disables the Access Token. | Bridge |
| Window | At most **90 days** per request (`start-date` to `end-date`). History depth depends on the institution. Overlapping windows by about 5 days is recommended. | Bridge |
| Freshness | The Bridge provides daily updates. The finer upstream schedule is UNKNOWN. | Bridge |
| Scheduling | Pick a random minute of the hour; traffic peaks at the top of the hour. | Bridge |
| Errors to users | Always show `errlist` and `errors` warnings to the end user. | Bridge |
| Revocation | The user can disable an Access Token at any time; the mechanism is UNKNOWN. | Bridge |
| Upstream data handling | Retention and any third-party aggregator are not described. UNKNOWN; this must be reviewed before opt-in (§11). | Bridge |
| Pending on the Bridge | Not stated. UNKNOWN. | Bridge |

## 4. Position in the Finance contracts

- **Master Spec v1.1 §3.2 defers "direct bank aggregation."** Adding this connector changes that scope, which §15 change control treats as an architectural change. It needs a spec revision and the owner's explicit approval.
- **The foundational design** plans read-only connectors per institution, with a statement-import fallback (§Supported source plan). SimpleFIN fits that plan.
- **Sequencing.** No connector work starts before:
  1. the P0-5 ruling;
  2. Checkpoint 1, read-only data and API with authorization (needs P1-1 identity);
  3. Checkpoint 3, staged CSV import with security tests.

  The connector reuses Checkpoint 3's staging, dedup, preview, confirmation, and exclusion machinery. It adds a new source type, not a new pipeline.

## 5. Architecture

```
Administrator (Finance app)
  → pastes SimpleFIN Token once (Settings → Connections → Add)
  → Finance API (server) decodes, validates the claim host, POSTs the claim
  → stores the Access URL in the server secret store; the client never sees it
  → administrator maps each SimpleFIN account to a Finance account (explicit, confirmed)

Sync worker (server-side, scheduled)
  → GET /info → negotiate version (prefer 2, accept 1)
  → GET /accounts?start-date…&end-date…[&account=…]  (≤ 90-day window, 5-day overlap)
  → validate and normalize → stage source rows (no actuals)
  → exact dedup within account by SimpleFIN transaction id
  → possible-duplicate flags vs CSV and manual rows (never silent)
  → staged batch awaits preview + confirmation (Master Spec §7.2, §8.5–8.6)

Errors / quota warnings / 402 / 403
  → connection state "repair needed", polling stops, administrator notified
```

The connector runs only in the Finance server process, inside the Finance domain. iOS and macOS clients get connection state through the authenticated Finance API (last successful sync, coverage, error, required action, as the foundational design requires). They never hold or display the Access URL.

## 6. Credential handling

1. **Claiming.**
   - The server decodes the token and requires `https`.
   - The decoded claim host must be on an owner-approved allowlist. The default is the SimpleFIN Bridge host only.
   - The claim is POSTed once with redirects disabled. A 403 is surfaced as "token invalid or already used — possible compromise; generate a new token."
   - The setup token is discarded after the attempt and never stored.
2. **Storage.**
   - The Access URL goes into the approved server secret store: `~/.openclaw/credentials/finance/simplefin/<connection-id>`, mode `0600`, owned by the Finance service user (AGENTS.md secrets location). An equivalent OS keychain can be used on Apple-silicon hosts.
   - The database stores only an opaque connection id, the claimed host, the connection name, and status. It never stores the URL or its userinfo.
3. **Use.**
   - The URL is loaded per request, split into host and Basic credentials, and sent with certificate verification.
   - Requests to any host other than the stored claimed host are refused, including after redirects.
4. **Redaction.**
   - The logging layer strips any `user:pass@` userinfo and `Authorization` headers.
   - A test proves that a canary Access URL never appears in logs, exceptions, crash output, API responses, or audit records.
5. **Never shared.** The Access URL never goes to AI models, RanchBrain, Telegram or other channels, client apps, backups outside the secret store's own encrypted backup, or source control.
6. **Disconnect.**
   - An administrator action deletes the local secret, marks the connection disconnected, and keeps all staged and committed history (Master Spec §2.6).
   - The UI tells the administrator to also disable the token at SimpleFIN Bridge, because remote revocation is user-side (§3).

## 7. Sync worker

- **Placement.** A server-side worker, like the recurring-forecast worker (Master Spec §5.8, §14). No device timers and no `pg_cron`.
- **Budget.** The default is **≤ 4 scheduled runs per day per connection**, each a single all-accounts request, at a random minute. Hard cap: **12 requests per day per connection**, all request types combined. That stays well under the Bridge's "24 or fewer" expectation and leaves room for manual "Sync now".
- **Windows.**
  - Incremental runs fetch `[last_success_end − 5 days, now)`, capped at 90 days.
  - The initial backfill walks backward in 90-day windows up to an owner-chosen depth, spread across days within the budget.
  - `start-date` and `end-date` are epoch seconds in UTC.
- **Version.**
  - Call `GET /info` at claim time and weekly.
  - Request `version=2` when it is offered. Otherwise parse the v1 shape: `errors` strings and organization data on the account.
  - Both shapes are parsed by one tolerant normalizer with fixtures for each.
- **Normalization.**
  - `amount`: parse the numeric string as an exact decimal (never float), quantized to cents. Reject zero, non-numeric values, or more than 2 fractional digits (spec §4: zero prohibited; `numeric(14,2)`). The sign is kept: positive means inflow, matching Master Spec §4.
  - Dates: `posted` epoch seconds → **`America/Chicago` calendar date** (Master Spec §2.8, §6.3). `transacted_at`, when present, is kept as source detail.
  - Pending: transactions with `pending: true` or `posted == 0` are **never** staged as actual. Whether to show them as informational "pending" rows is an open decision (§14.4).
  - Currency must match the mapped account (Master Spec §5.6). A mismatch is a row error. Custom currency strings are sanitized.
  - Text: `description` and connection or org names are sanitized for display. Formula-leading characters (`=`, `+`, `-`, `@`) are escaped for any export, mirroring the CSV formula-injection threat (Master Spec §11).
  - `extra` is stored only in an allowlisted subset, inside staged source metadata. It is never canonical.
- **Balances.** `balance`, `available-balance`, and `balance-date` are recorded as dated **observed** statement balances for reconciliation (foundational design §Reconciliation). They never adjust the ledger.

## 8. Mapping to staged import

Each sync creates one **import batch** per mapped account with source type `simplefin`. This is a new value; Master Spec §5.6 currently allows `csv | manual | recurring_confirmation | system_correction`, so it needs a spec revision. Each fetched transaction becomes a **staged source row** that carries:

| Staged field | Source |
|---|---|
| account | Owner-confirmed mapping of SimpleFIN `account.id` → Finance account |
| amount (signed) | `amount` (exact decimal) |
| transaction_date | `posted` → America/Chicago date |
| description / merchant | `description` (sanitized); merchant is null unless the owner adds a rule |
| source_reference | SimpleFIN transaction `id` |
| provenance | connection id, protocol version, request window, fetch time, response digest |

- **Exact duplicate:** the same mapped account plus the same `source_reference`. This is safe because SimpleFIN IDs are unique within an account (§3). The row is skipped by default, as in Master Spec §8.4.
- **Possible duplicate:**
  - Against CSV, manual, or other-source rows, use the Master Spec §8.4 rule (same account, date window, exact cents, normalized description fingerprint).
  - The row is always visible for review and never auto-merged.
  - The first SimpleFIN sync over a CSV-covered period will flag many of these. The preview must group them so one confirmation can resolve a set.
- **Never across accounts**, and a transfer is **never** created automatically (Master Spec §8.4).
- **Commit:** only through the Checkpoint 3 preview and confirmation endpoint. The digest binds the batch to the exact staged content.
- **Undo:** reversible batch exclusion (Master Spec §8.7) works unchanged.

## 9. Errors, quota, and connection state

| Signal | Action |
|---|---|
| `errlist` / `errors` entries | Store a sanitized copy and show it to administrators (Bridge guidance). `con.*` errors mark that connection as needing repair; `act.*` errors mark that account. |
| Quota warning text | Halve the schedule for 72 hours, notify, and never retry immediately. |
| 402 | Connection state "payment required at SimpleFIN"; polling stops. |
| 403 on `/accounts` | Connection state "re-authorize"; polling stops; the administrator must disconnect and reconnect. |
| Network or TLS failure | Back off exponentially to the next scheduled slot; never retry in a loop. |
| Malformed response | Reject the whole fetch and stage nothing. Record the digest and size. |

The connection state API exposes: last successful sync, window covered, accounts covered, last error (sanitized), and the required action.

## 10. Threat model additions

These extend Master Spec §11. Write-capable connector features stay blocked until each one has a passing test.

1. **Access URL disclosure.** Canary redaction across logs, exceptions, API responses, audit, and crash output.
2. **SSRF and claim-host substitution.** Claim and fetch only to allowlisted HTTPS hosts. No redirects. Private, loopback, and link-local address ranges are rejected, as in the Firecrawl design §6.1.
3. **Malicious response content.** Oversized bodies, deep JSON, huge numbers, invalid dates, NUL/control characters, formula-leading descriptions, and unexpected currencies are each rejected or sanitized, with fixtures.
4. **Replay and duplicate fetches.** Overlapping windows and re-run syncs create no duplicate staged rows. Exact dedup holds across retries.
5. **Unconfirmed commit.** Staged connector rows cannot reach actual totals without the §7.2 confirmation. This is tested at the API, not the UI.
6. **AI boundary.** No AI surface can read the Access URL or raw staged connector payloads; models see only approved summaries (Master Spec §2.7, AC 11).
7. **Quota abuse.** The scheduler cannot exceed the per-connection daily cap, even when "Sync now" is pressed repeatedly.
8. **Token theft impact.** The Access URL grants read-only access to financial data. The runbook covers disabling the token at the Bridge and rotating it.

## 11. Privacy and data residency

Using SimpleFIN means account activity transits SimpleFIN Bridge and whatever upstream source it uses for each institution (UNKNOWN; §3). This is a deliberate, owner-approved exception to local-first:

- It is off by default, opted in per account, and fully replaceable by CSV import.
- No household or ranch data is sent *to* SimpleFIN; the connector only reads.
- Before the first opt-in, the owner reviews SimpleFIN Bridge's current terms, privacy policy, and upstream disclosure, and records the decision in the change log.
- Disconnecting stops all further transfer. Already-imported evidence stays local.

## 12. Delivery checkpoints

Each checkpoint is separately approved. Completing one authorizes nothing further.

| ID | Work | Network / credentials |
|---|---|---|
| S0 | Owner approves this design; Master Spec revision for §3.2, `simplefin` source type, and §2.4 exception | None |
| S1 | Offline normalizer and parser for v1 and v2 shapes, with fixtures (§7, §10.3); dedup rules; redaction utility and canary tests | None; fixtures only |
| S2 | Claim flow and secret storage on DEV against a **sample** SimpleFIN account, if one is obtainable; otherwise S1 fixtures only. Host allowlist and SSRF tests. | DEV only; owner-provided test token |
| S3 | Sync worker into staged batches with quota cap, error states, and connection-state API | DEV only |
| S4 | Commit via the Checkpoint 3 preview and confirmation; exclusion and undo; full §10 test pass | DEV only |
| S5 | Production enablement | Separate explicit approval, not covered here |

## 13. Acceptance criteria

1. With the connector disabled, Finance behaves exactly as without it, and CSV import is unaffected.
2. A canary Access URL never appears in any log, exception, response, audit record, or client.
3. Claim and fetch refuse non-allowlisted hosts, HTTP, redirects, and private address ranges.
4. No connector row reaches actual totals without a confirmed commit.
5. Re-running any sync window creates no duplicate staged or committed rows.
6. Possible duplicates against CSV and manual rows are visible and never silently dropped or merged.
7. Pending transactions never appear in actual totals.
8. Amounts are exact decimals with the correct sign, and dates use America/Chicago, with tests at month boundaries.
9. Daily request caps hold under repeated "Sync now".
10. `errlist` / `errors`, 402, and 403 produce visible repair states and stop polling.
11. Disconnect deletes the local secret and keeps all history.
12. No AI surface can access the Access URL or raw connector payloads.

## 14. Open decisions (need Andy)

1. **Go or no-go.** Accept SimpleFIN Bridge as an optional cloud intermediary (§11), or stay CSV-only.
2. **Which accounts.** Which institutions or accounts to opt in first. Keep the list off the repo; record only counts.
3. **Backfill depth.** How far back the first sync should reach, within institution limits.
4. **Pending display.** Hide pending entirely, or show it as informational rows that are never totaled.
5. **Schedule.** Runs per day (default 4; cap 12).
6. **Secret store.** Use the file under `~/.openclaw/credentials/finance/` or the OS keychain on the Finance host.
7. ~~**Contract.**~~ Resolved 2026-11-05: Master Spec v1.1. A confirmed staged row becomes a signed `transactions` row (§8).

## 15. Sources

- SimpleFIN Protocol specification (2.0.0-draft): https://www.simplefin.org/protocol.html — retrieved 2026-11-05.
- SimpleFIN Bridge developer guide: https://beta-bridge.simplefin.org/info/developers — retrieved 2026-11-05.
- Ranch Finance Master Specification v1.1 (`docs/ranch-os/Ranch_Finance_Master_Specification_v1.1.md`) §2, §3.2, §4, §5.6, §5.8, §6.3, §7.2, §8, §11, §15.
- Ranch Finance foundational design (`ranchbrain_app/docs/RANCH_FINANCE_FOUNDATIONAL_DESIGN.md`) §Supported source plan, §Reconciliation, §AI and automation boundary.
- Firecrawl URL Ingestion Design v1 §6 (egress and SSRF posture reused).
- GAP_ANALYSIS.md P0-5, P1-1, P1-10.

---

*End of SimpleFIN Read-Only Bank Connector Design v1 (draft).*
