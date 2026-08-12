---
title: "Canonical Trusted Records"
version: "1.0"
status: "Foundational"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-03"
category: "Governance"
source_document: "CANONICAL_TRUSTED_RECORDS.md"
---

# Canonical Trusted Records

Version: 1.0
Status: Foundational
Owner: OpenClaw Architecture
Last Updated: 2026-08-03

## Purpose

Trusted records are OpenClaw's durable, provenance-bearing representation of facts used across product domains. They provide one record shape, immutable correction history, explicit data availability, access policy enforcement, and audit evidence.

This document governs the record schema, authority boundary, creation contract, and integration behavior. Domain systems may project records into OpenClaw without surrendering their own system-of-record authority.

## Authority model

Every trusted record has exactly one owner domain and one authoritative source.

- OpenClaw is authoritative for records created and owned by OpenClaw.
- An external system remains authoritative for records projected from that system.
- A projection is a durable derived copy, not a second write authority.
- Operational mutations must use the authoritative system's supported API.
- OpenClaw corrections to an external projection may annotate or supersede the projection, but must not claim to mutate the source system.
- Source conflicts are preserved and surfaced; they are never silently merged by AI.

## Canonical schema contract

Every record must include:

- stable record and revision identifiers;
- record type and owner domain;
- title, optional summary, occurrence time, and lifecycle state;
- explicit data state, including unavailable and error states;
- source identity, capture time, original-record link, and external reference;
- provenance inputs and derivation metadata;
- sensitivity, owner identity, and access-policy identity;
- immutable version lineage and correction reason;
- typed relationships to other records;
- domain data that preserves source precision.

Absence is never represented as a numeric zero. Unknown, unavailable, stale, processing, error, and not-applicable values use explicit data states with null values.

Health and finance records must be private or restricted. Authorization denials must not reveal whether a record exists.

## Revision and deletion rules

- Revisions are append-only. Updating a fact creates a new immutable revision.
- Corrections require a reason and a link to the previous revision.
- Source versions must not be applied out of order.
- Duplicate source deliveries must be idempotent.
- Records with dependents cannot be deleted without a dependency preview and explicit resolution.
- External-source deletions become lifecycle revisions such as archived or withdrawn; they do not erase audit history.

## Creation contract

Record creation and access-policy provisioning are separate administrative operations.

1. A trusted access policy is provisioned before ingestion.
2. The ingesting actor is mapped by the server; callers cannot self-assert actor identity.
3. The request references an existing policy whose owner matches the record owner.
4. The record store validates the complete canonical schema and commits one immutable revision.
5. A durable source-version key prevents duplicate delivery and rejects stale delivery.
6. Audit evidence records the actor, decision, record, policy, and time.

An ingestion endpoint must not create a policy and a record across independent stores in one request. That would expose a partial-commit failure mode. New policy grants require a separate reviewed administrative path.

## External projection identity

External projections use deterministic identifiers derived from stable source identity:

- record key: source system, entity type, and external entity ID;
- revision key: record key and authoritative source version;
- idempotency key: source system, entity type, external entity ID, and source version.

The implementation may hash these components to satisfy identifier-format constraints. It must store the unhashed source identifiers in provenance fields for audit and reconciliation.

## Property Manager projection

Property Manager remains authoritative for assets, meters, readings, schedules, task completion, and its audit history. OpenClaw consumes those facts through the Property Manager REST API or a signed event produced by that API. It never reads Property Manager Postgres directly.

Initial record mappings:

| Property Manager entity | Trusted record type               |
| ----------------------- | --------------------------------- |
| Asset                   | `property.asset`                  |
| Asset meter             | `property.asset_meter`            |
| Accepted meter reading  | `property.asset_meter_reading`    |
| Maintenance schedule    | `property.maintenance_schedule`   |
| Maintenance completion  | `property.maintenance_completion` |

Projection requirements:

- preserve decimal values as strings;
- preserve source timestamps with timezone offsets;
- preserve source entity ID, row version, and audit references;
- reject stale row versions and accept exact retries without a new revision;
- link readings and maintenance records to their asset record;
- represent inactive or deleted source entities with lifecycle revisions;
- route operational changes back through Property Manager's authenticated API.

## Environment boundary

The current runtime and HTTP boundary are development-only and opt-in. Development proof must cover authentication, authorization, idempotency, stale-version rejection, restart persistence, audit reconstruction, and source reconciliation before any production-enablement proposal.

Production enablement requires a separate operator decision covering encryption, backup and restore, recovery objectives, key management, monitoring, reconciliation, and rollback.
