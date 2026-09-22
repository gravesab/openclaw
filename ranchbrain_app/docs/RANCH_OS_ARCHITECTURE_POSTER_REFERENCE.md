# Ranch OS architecture poster reference

Status: Living design reference
Scope: One-page Ranch OS architecture poster and the high-level architecture it depicts
Last updated: 2026-08-26

This document keeps the one-page Ranch OS architecture poster aligned with the
foundational design. It is a communication artifact, not an alternate security,
data-model, or implementation authority.

The poster must portray Ranch OS as the product and operating-system boundary.
OpenClaw is a supporting technology foundation, not the product name.

## Authoritative sources

The poster summarizes, but does not override:

- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) for tenant context,
  membership authorization, row-level security, and isolation proof.
- [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md) for animal
  identity, veterinary and care history, lifecycle, inputs, costs, and module
  boundaries.
- [RanchBrain architecture](ARCHITECTURE.md) for RanchBrain responsibilities.
- [RanchBrain data model](DATA_MODEL.md) for durable records and migrations.
- [RanchBrain roadmap](ROADMAP.md) for delivery status and deferred work.

## Current poster contract

The current poster must show these architectural facts:

- Ranch OS is a local-first, private, modular operating system for ranch
  operations that is cloud-ready without requiring a public cloud.
- The primary Ranch OS modules include Property and Equipment, Livestock
  Management, Field Management, Inventory, Finance, Home Automation, and
  RanchBrain.
- Livestock Management covers stable animal identity and identifiers, health and
  vaccinations, breeding, pasture and location, feeding, weights and
  production, and tenant-authorized task and alert history.
- Tenant safety is a core-platform boundary: server-derived `TenantContext`,
  membership authorization, scoped roles, tenant-owned records, PostgreSQL row
  level security, and no runtime `BYPASSRLS`.
- Each user-facing client, API, search, background job, cache, export,
  notification, attachment, and AI query must operate from authorized tenant
  context. A model response, tag, barcode, path, or request parameter never
  establishes tenant authority.
- The AI layer may use local oMLX/Qwen models, Apple Foundation Models, and
  other approved local fallbacks behind Ranch OS authorization and provenance
  boundaries. It must not bypass tenant or domain authorization.
- OpenClaw and MCP appear as supporting local platform technology. MCP tools,
  resources, and prompts do not widen Ranch OS data access.
- Offline-first synchronization, local PostgreSQL storage, audit history, field
  devices, Bluetooth scales, RFID readers, barcode scanners, sensors, and GPS
  trackers remain optional integrations behind the same tenant and authorization
  boundaries.

## Poster update discipline

Update the poster in the same change set whenever a foundational design change
alters any of the following:

1. A Ranch OS module is added, renamed, retired, or changes ownership.
2. Tenant isolation, authorization, RLS, identity, or cloud-readiness policy
   changes.
3. Livestock Management scope, lifecycle, care, input, location, weight,
   production, task, alert, or integration boundaries change.
4. A depicted client, AI provider, data store, hardware integration, or MCP
   contract becomes implemented, deferred, or retired.

Before publishing a refreshed poster, compare every claim with the authoritative
documents above; keep speculative or deferred capabilities visibly labeled as
future or deferred. Visually inspect the rendered one-page output at its
intended print size. All labels must remain inside their containers and remain
legible; concise wording is preferred to reducing text below readable size.

## Delivery boundary

This reference authorizes documentation and poster maintenance only. It does
not authorize application code, schema migrations, database changes, cloud
hosting, credentials, deployment, commit, push, or Production work.
