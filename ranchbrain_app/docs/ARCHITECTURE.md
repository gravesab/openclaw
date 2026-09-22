# RanchBrain 1.0 Alpha Architecture

Codename: Foundation

## Mission

RanchBrain is the local-first memory and intelligence engine for RedBud Ranch.

OpenClaw uses RanchBrain for long-term knowledge, search, reasoning, budgeting, property history, livestock records, health notes, and executive intelligence.

## Separation of Responsibilities

OpenClaw:

- automation
- watchdogs
- Telegram
- Home Assistant integration
- dashboards
- service monitoring

RanchBrain:

- memory
- indexing
- search
- budget tracking
- property knowledge
- livestock knowledge
- health knowledge
- project history
- reasoning support

## Core Components

1. CLI
2. Memory Engine
3. Ingestion Engine
4. Search Engine
5. Budget Engine
6. Property Engine
7. Livestock Engine
8. Health Engine
9. Executive Intelligence

## Storage

Phase 1:

- Markdown
- JSON metadata
- local files

Future:

- PostgreSQL
- pgvector
- semantic search

## Rule

Every RanchBrain feature must create knowledge, improve knowledge, or use knowledge to make a better decision.

## Tenancy boundary

RanchBrain is currently a local, single-ranch alpha. Its approved future
multi-ranch ownership, authorization, storage, search, job, and database
boundary is defined in [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md).
That document is the source of truth for DEV tenancy work.

Ranch OS livestock ownership, lifecycle, authorization, and tenant-isolation
requirements are defined in [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md).

The proposed DEV-only Apple TV Today vertical slice is defined in
[Ranch OS Apple TV Phase 1 design and test plan](RANCH_OS_APPLE_TV_PHASE_1_DESIGN_AND_TEST_PLAN.md).
