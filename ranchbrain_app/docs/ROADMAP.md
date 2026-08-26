# RanchBrain Roadmap

## 1.0 Alpha - Foundation

- Clean Python package
- CLI
- memory model
- JSON index
- basic search
- system report ingestion
- tests

## 1.1 - Memory

- structured memories
- tags
- source tracking
- import history

## 1.2 - Budget

- CSV imports
- transaction categorization
- monthly summaries
- ranch/property expense reporting

## 1.3 - Property

- equipment
- repairs
- maintenance
- manuals
- projects

## 1.4 - Livestock Management application

- dedicated Ranch OS Livestock Management UI, domain API, workflows, dashboards, and tests
- controlled species, production-type, and optional breed catalogs
- tenant-safe animal identity, identifier history, and routine lifecycle events
- first-class tenant-safe veterinary observations, conditions, treatments, surgeries, vaccinations, medication administration, and care schedules
- controlled livestock-input plans, allocations, consumption, supplier or batch references, and permitted animal or herd attribution for feed, hay, mineral, supplements, and future approved inputs
- immutable operational-cost attribution with provenance and optional canonical Ranch Finance record links; Ranch Finance remains the only ledger and accounting authority
- authorized herd-overview indicators for active care, upcoming treatments, feed needs, recent surgeries, and cost trends after herd semantics are approved
- authorized Livestock read/query API or versioned read model for RanchBrain and OpenClaw AI facts, including tenant context, provenance, and uncertainty
- application blueprint: `LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md`
- Ranch Health is human health only; Property, herd assignment, Finance integration mechanics, and cross-tenant transfer contracts require separate approval

## 1.5 - Health

- glucose notes
- blood pressure notes
- medication history
- appointment history

## 2.0 - Executive

- daily recommendations
- cross-module reasoning
- Good Morning Andy briefing

## Cross-cutting foundation - Multi-tenancy

Before Ranch OS is made available to multiple ranches, implement the approved
[Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) in DEV, including
tenant ownership, membership authorization, tenant-scoped storage and search,
and database row-level-security isolation tests.
