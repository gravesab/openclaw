# Muse-Terminal: Next Work Assignment

**Date**: September 29, 2026  
**From**: OpenCode (local Qwen 3.5 9B)  
**To**: Muse Terminal session on SSH-Dev  

## Context Recap

RanchOS development threads:
1. **DEV app build** — Finished, HubTests 66/66 pass. Awaiting Andrew's human test of new IP endpoint (`100.85.188.74:5062`). Reinstall held until verified by Andrew.
2. **PropertyManager API TCP mode** — `~/.config/openclaw/db.env` ready on SSH-Dev; systemd override prepared by Cursor. Wait for TCP cutover confirmation before testing `/tasks` latency drop (target <2s).
3. **RanchBrain M3 grounding**:
   - P1 OIDC identity: 73 tests pass ✅
   - P2 tenant-scoped memory/search: isolation-tests spec drafted
   - P3 HTTP service: to be spec'd after P2 lands + Cursor review

## Your Assignment

Develop the **P3 HTTP service specification** for RanchBrain.

### Spec Content Requirements

Per handoff template in `~/team/handoffs/README.md`:

1. **Title**: P3 — Tenant-scoped HTTP service (REST/gRPC, auth, rate limits)
2. **Scope boundary**: 
   - Builds on P2 isolation (tenant-per-request or scoped sessions)
   - Exposes read-only memory/query endpoints to client apps
   - No direct DB writes; delegates mutation to PropertyManager RLS policies
3. **Acceptance criteria**:
   - Tenant ID extracted from JWT/OIDC claims
   - Endpoints: `/search/*`, `/memory/list`, `/memory/fetch`
   - Rate limit: X requests/sec per tenant (define)
   - Error handling for cross-tenant queries
4. **Apple-first design**:
   - Native Swift client SDK or Foundation-based REST layer
   - Background fetch semantics compatible with iOS/Apple Watch
   - Offline cache strategy per Apple's privacy guidelines (on-device-only PII)
5. **Dependencies**: RanchBrain core, PropertyManager DB connection pool, existing OIDC auth flow
6. **Threat model**: Cross-tenant leakage prevention via RLS; no PII leaves device without explicit consent

### Deliverables

Write `20260929-p3-http-service-spec.md` using canonical header format:

```
---
title: P3 Tenant-scoped HTTP service
date: 2026-09-29
status: draft
owner: Muse
priority: medium
dependencies: [P2 isolation-tests, existing OIDC auth]
related-issue: RANCH-XXX (if known)
---

## Overview

[One paragraph]

## Scope & Boundaries

[What's in scope; what lands in PropertyManager]

## Acceptance Criteria

[List as bullet points or numbered tests]

## API Endpoints

[Table of methods, auth requirements, rate limits, error codes]

## Apple-first Implementation

[Swift/iOS integration notes]

## Security & Privacy

[Threat model summary]

## Dependencies

[External services, DB connections]
```

### Testing Notes

Once spec is drafted:
- Hand to Cursor for implementation review
- No commits/pushes from this session (Muse never deploys)

## Environment Gotcha Reminder

- M4 sandbox blocks Tailscale/SSH directly; if needing real network test → escalate once with Andrew
- `muse.edit_file` may EPERM in current checkout; use bash/perl fallback or Cursor to write file on remote host if needed
- Do NOT run legacy RanchBrain tests unless tagged tenant-safe per P2 spec

Awaiting Muse action; OpenCode ready to assist with small tasks (docs, logs, unit tests post-spec).