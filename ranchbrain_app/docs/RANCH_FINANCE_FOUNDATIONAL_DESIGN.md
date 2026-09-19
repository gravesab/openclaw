# Ranch Finance foundational design

Status: DEV-only in-memory foundation complete; unapplied disposable persistence
SQL is `005_finance_persistence_foundation.sql`. This document authorizes no
Production migration, account connection, credential storage, deployment, or
money movement. A future livestock confirmation-challenges migration must use
`006`, not `005`.

Ranch Finance is the household and ranch financial system within Ranch OS. It
owns the canonical double-entry ledger, account reconciliation, imported-source
provenance, and financial reporting. It does not own livestock care records,
property maintenance, asset meter readings, or Home Assistant device events.
Those systems own their operational facts and may link a financial allocation to
the canonical Ranch Finance posting.

## Product outcome

You and your spouse can use the Ranch OS iPhone app to understand the household
and ranch financial picture in one place. You can see ordinary household costs
such as groceries, medicine, utilities, insurance, and subscriptions alongside
ranch expenses such as feed, hay, veterinary care, mower oil, fuel, repairs,
and land costs. Every reported total can be traced to balanced postings and to
the imported statement, receipt, or manual-entry evidence that originated it.

Ranch OS remains the focal point. Finance is a first-class Ranch OS module, not
a separate consumer-finance product or an OpenAI service.

## Scope and non-goals

The initial product supports read-only financial data ingestion, reviewable
classification, reconciliation, budgets, recurring-bill awareness, and reports.
It supports manual and CSV statement imports for sources that cannot be safely
or reliably connected.

The initial product must not:

- initiate payments, transfers, trades, card applications, or account changes;
- expose bank credentials, access tokens, raw statements, or unredacted receipts
  to language models;
- silently create, delete, or rewrite financial facts;
- treat an AI categorization suggestion as an approved accounting entry;
- conflate household, ranch, or tenant data; or
- infer legal, tax, or accounting advice from categories or reports.

## Users, authority, and recovery

The household workspace starts with two equal administrators: Andrew and his
spouse. A second equal Finance administrator is a second tenant owner. Tenant
owner means full Ranch OS owner authority, not Finance-only authority. Each
administrator has an independent identity, authentication factor, device
enrollment, and recovery method. Either administrator can add or repair a
read-only account connection, import a statement, classify transactions, and
manage budgets and rules.

The system must record who performed each action and when. Actions with elevated
risk require fresh authentication and a clear confirmation preview:

- removing an administrator or their recovery method;
- replacing or deleting a financial connection;
- changing account identity or opening balance;
- posting a manual adjustment, correction, or reconciliation exception; and
- changing an automated rule that can create accounting interpretations.

The system must retain at least two independently usable recovery paths. It must
not make either administrator's personal AI account, laptop, phone, or one
shared password a recovery dependency. A recovery action must be auditable and
must notify the other administrator through an available approved channel.

## Financial model

### Double-entry ledger

Every accepted financial interpretation produces a balanced journal entry:

```text
Debit  Expense: Household: Groceries            $150.00
Credit Liability: Apple Card                    $150.00
```

The journal entry is immutable after posting. A correction creates a reversing
or superseding entry that links to the original. The imported bank/card activity
is also immutable: it is source evidence, not an editable ledger row.

Transfers, credit-card payments, refunds, reimbursements, loan payments,
interest, and escrow must be represented by their actual account effects. They
must not be counted as income or expense merely because money appears in or
leaves an account.

### Starting chart of accounts

The first chart is structured for reports but uses familiar names in the app.
Administrators can add accounts and categories later without weakening the
system accounts needed for balancing and reconciliation.

```text
Assets
  BancFirst: Checking
  BancFirst: Savings
  Cash
  Accounts receivable

Liabilities
  Citibank credit cards
  American Express credit cards
  Amazon credit card
  Apple Card
  First United Bank: Home mortgage
  First United Bank: Back 20 acres loan

Income
  Household income
  Ranch income
  Reimbursements

Expenses
  Household: Groceries, medicine, utilities, insurance, subscriptions
  Ranch: Livestock: Feed, hay, supplements, medication, veterinary
  Ranch: Property: Grounds, mowing, repairs, utilities
  Ranch: Equipment: Fuel, oil, maintenance, repair
  Ranch: Land: Taxes, interest, maintenance, improvements

Equity
  Opening balances
  Owner contributions and draws
```

The home mortgage and the back-20-acres loan are distinct liability accounts.
Each loan payment splits principal, interest, and escrow where applicable. The
land loan links to the land asset; it is not mixed into household spending.

### Categories, dimensions, tags, and rules

A category selects the accounting destination. Dimensions describe why and
where the spending occurred. Tags support flexible, cross-cutting reporting but
do not replace categories or dimensions.

| Concept           | Example                              | Purpose                                           |
| ----------------- | ------------------------------------ | ------------------------------------------------- |
| Category          | `Ranch: Livestock: Feed`             | Double-entry reporting and budget rollups.        |
| Domain link       | `Livestock`                          | Links to the owning Ranch OS module.              |
| Allocation target | `Cattle herd` or `Mower`             | Attributes cost to a specific operational target. |
| Project           | `Back 20 acres fence repair`         | Groups bounded work across categories.            |
| Tag               | `Tax review 2026`                    | Flexible, optional reporting and review.          |
| Rule              | `Merchant contains "Tractor Supply"` | Proposes repeatable classification.               |

A transaction can split by exact amount, percentage, or quantity-derived cost.
All split amounts must equal the imported transaction amount before posting.

```text
$68 Tractor Supply receipt
  $42  Ranch: Livestock: Feed       target: cattle herd
  $16  Ranch: Equipment: Oil        target: mower
  $10  Household: Pet supplies
```

### Operational links

Livestock, Property, Equipment, and the future Home Assistant retain ownership
of their operational records. Finance stores a typed link to the target and
records the allocation's provenance; it does not copy or become the source of
truth for operational histories.

- Livestock supplies animal, herd, feed, hay, supplement, and care context.
  Finance reports the associated costs and can calculate per-head or per-period
  costs only when the necessary consumption/count facts are available.
- Property and Equipment supply assets, tasks, maintenance, meters, and runtime
  hours. Finance links mower oil, fuel, and repair costs to the mower and can
  report cost per runtime hour only when an attributable meter exists.
- Land records supply parcel or asset identity. Finance links the back-20-acres
  loan, taxes, maintenance, and improvements to that land.
- Home Assistant may supply observed meter readings, device runtimes, or a
  proposal that a recurring event needs review. It may not post or modify the
  ledger.

## Ingestion and evidence

### Supported source plan

The planned first source catalog is:

| Institution or source                | Intended initial path                               | Notes                                               |
| ------------------------------------ | --------------------------------------------------- | --------------------------------------------------- |
| BancFirst checking and savings       | Read-only connector, then statement import fallback | Primary cash and savings view.                      |
| Citibank cards                       | Read-only connector, then statement import fallback | One source record per actual card account.          |
| American Express cards               | Read-only connector, then statement import fallback | Preserve card/account identity.                     |
| Amazon credit card                   | Read-only connector, then statement import fallback | Do not assume its issuing institution.              |
| Apple Card                           | Guided CSV import first                             | Make download/import instructions part of the flow. |
| First United Bank home mortgage      | Read-only connector or statement import             | Track principal, interest, and escrow separately.   |
| First United Bank back-20-acres loan | Read-only connector or statement import             | Link to the land asset.                             |

All connectors are read-only. A connector holds its own minimum necessary
credential material in an approved secret store; Ranch Finance and every AI
surface receive only scoped financial data. Connection state must expose the
last successful sync, source coverage, error, and required repair action.

### Guided Apple Card import

The app must make the manual path friendly for a spouse or future administrator:

1. Select **Add account**, then **Apple Card statement import**.
2. Show current, platform-appropriate instructions for downloading the monthly
   CSV from Apple Card.
3. Receive the chosen file locally and validate its format before creating any
   ledger interpretation.
4. Display the source period, account identity, transaction count, and malformed
   rows. Reject a file whose account identity cannot be safely established.
5. Detect likely duplicates by source identity, date, amount, description, and
   import lineage. Never silently discard ambiguous duplicates.
6. Preview proposed categories, splits, and matched rules. An administrator
   approves the import and any resulting interpretations.
7. Retain source-file metadata, content digest, importer, time, parser version,
   and the link from each imported activity to its source file.

The same staged-import structure applies to any CSV source. Original files and
receipts require tenant-scoped storage, encryption, access auditing, retention
rules, and a user-visible export path before live use.

## Review, reconciliation, and reports

### Daily review

The iPhone app presents new activity as a small review queue. Each card shows
the source account, merchant text, amount, suggested category and split, prior
rule, and confidence/provenance. Administrators can accept, edit, split, defer,
or mark an item as a transfer/refund/reimbursement. A choice can create a
proposed reusable rule, but creating or enabling that rule is a separate,
visible action.

### Reconciliation

Reconciliation compares the ledger balance to a dated statement balance for one
account and statement period. It must show imported items, matched postings,
unmatched activity, and any proposed adjustment before final confirmation.
Reconciliation does not delete transactions or mutate imported source facts.

### iPhone-first dashboard

The first dashboard should provide:

- cash, card, loan, and net-position summaries with data freshness;
- an **In review** count with direct access to exceptions;
- spending by household and ranch category for the selected period;
- budgets for groceries, medicine, feed, equipment, and other chosen categories;
- recurring bills and subscriptions with upcoming dates;
- configurable watch cards, such as feed spending, grocery spending, mower cost,
  medicine, or the back-20-acres loan; and
- drill-down from a summary to source activity, balanced posting, receipt, and
  linked Ranch OS entity.

No dashboard total may mix transfers, credit-card payments, refunds, income, and
expenses without stating the applicable accounting treatment.

## AI and automation boundary

Claude and approved local models may use a typed, tenant-scoped Finance assistant
API to read sanitized transactions, report aggregates, explain balances,
propose categories/splits, detect likely recurring activity, and prepare a
review queue. They must receive source and confidence metadata and must explain
when evidence is insufficient.

They must not receive connector secrets, raw credential material, unrestricted
statement files, shell/database access, or a generic financial-write tool. They
must not initiate money movement or auto-post accounting entries.

The initial automation policy is conservative:

1. Models and rules propose classifications.
2. An administrator reviews and approves the first occurrence and the rule.
3. An explicitly approved rule may create a visible, reversible proposed
   interpretation for later matching transactions.
4. A user-visible review queue remains available; disabling a rule stops future
   use without rewriting historical decisions.

This policy may be relaxed only through a separately approved financial
confirmation policy and adversarial validation.

## Security, tenancy, and audit requirements

Every financial object must carry tenant/workspace ownership. Authorization is
derived server-side from a verified principal, active workspace selection,
membership, and capability; a client must not supply an effective role, tenant,
or permission.

Financial writes require idempotency keys, optimistic version checks, atomic
audit records, and a durable provenance chain. The production persistence layer
must apply row-level tenant isolation and prove it with non-superuser,
two-tenant adversarial tests. DEV fixture data does not prove these controls.

DEV-only unapplied persistence is `005_finance_persistence_foundation.sql`.
Every Finance table uses `ENABLE` plus `FORCE ROW LEVEL SECURITY`. The runtime
role has no `BYPASSRLS`, no domain-table `UPDATE`/`DELETE`, and audit
`INSERT`-only access. Source artifacts persist metadata only: no file bodies
and no `bytea`. Tenant context is derived only from `VerifiedPrincipal`,
requested workspace, membership, and capability. A future livestock
confirmation-challenges migration must use `006`, not `005`.

The audit history must distinguish:

- observed source fact;
- parser normalization;
- duplicate/match decision;
- human or rule-based interpretation;
- posted journal entry;
- reversal or supersession; and
- connector/recovery/permission events.

## Delivery sequence

1. Approve this design and record unresolved choices.
2. Build a DEV-only, sample-data Finance foundation: chart of accounts, balanced
   postings, source evidence model, account and transaction navigation, split
   editor, and deterministic tests. Do not add credentials, live APIs, database
   migrations, or deployment.
3. Add the Finance API and tenant-safe persistence, including RLS, in a
   separately approved DEV-only slice. Unapplied SQL is `005`. Reconciliation
   contracts remain later. Livestock confirmation-challenges SQL, if landed,
   must be `006`.
4. Add guided Apple Card CSV import with parser fixtures, duplicate cases, and
   end-to-end local proof.
5. Add read-only connector infrastructure, then onboard one institution at a
   time with disconnect/recovery, deduplication, and reconciliation proof.
6. Add Ranch OS operational links and reports.
7. Add the constrained AI proposal API only after the review and audit flows are
   established.

Each stage is independently gated. A completed design or sample-data UI is not
proof of live financial correctness, secure credential handling, Production
readiness, or money-movement authorization.

## Decisions still open

- Which specific Citi, AmEx, and Amazon card accounts should appear in the
  initial sample catalog?
- Which reporting boundaries should be visible by default: household, ranch,
  individual ranch, property, and/or personal accounts?
- What retention and export policy should apply to statements and receipts?
- Which notifications should reach both administrators, and through which
  approved channels?
- Should any human-approved classification rule move from proposed to
  auto-posted in a future release? The answer is no for the initial release.
