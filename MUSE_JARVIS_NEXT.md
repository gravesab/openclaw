# Muse-Terminal: Jarvis Development Assignment

**Date**: 2026-09-29  
**Status**: Draft spec for P3 HTTP service, awaiting your design.

## Current State (Verified)

✅ **RanchOS DEV app** — Built and tested on IntelMini (`100.85.188.74:5062`). HubTests 66/66 pass. Awaiting Andrew's manual validation of the binary. Timeout increased to 45s for `/tasks`.

✅ **PropertyManager API** — Healthy on SSH-Dev, currently using docker-exec psql per-request. TCP mode specs drafted (Cursor owns cutover).

✅ **RanchBrain P2 isolation** — 129/129 tenant scoping tests pass including legacy suite with seeded data. Storage isolation verified. Hand to Cursor for review and implementation pairing.

✅ **Rules push** — Already landed on SSH-Dev. No further rules changes needed.

## Your Task: Draft P3 HTTP Service Spec

Per handoff template in `~/team/handoffs/README.md`, create:

**Filename**: `20260929-p3-http-service-spec.md`  
**Priority**: Medium (blocks Jarvis HTTP client SDK)  
**Dependencies**: RanchBrain core + PropertyManager tenant pool + OIDC auth (already implemented)  

### Key Design Questions to Address

1. **Authentication flow**: How does tenant ID flow from JWT claims? (P2 already scoping; this should pass tenant as query/path param in headers)
2. **Rate limits**: What are per-tenant limits on `/search`, `/memory` endpoints? 
3. **Apple-first considerations**:
   - Background task patterns for iOS/Apple Watch
   - On-device cache policy (no PII leaves without consent)
   - Swift client SDK surface or Foundation-only JSON APIs
4. **Error handling**: How to handle cross-tenant queries, quota exceeded, and partial failures?

### Endpoint Scope

- `/memory/list` — List available memory slots per tenant
- `/memory/fetch/{id}` — Fetch scoped content
- `/search/knowledge/{question}` — P2-isolated retrieval
- Rate limit headers on responses

**Deliverable**: Full spec with acceptance tests, Apple integration notes, security boundaries. Once written:

1. Hand to Cursor for implementation
2. No commits/pushes — Muse never deploys
3. Write to SSH-Dev handoffs dir or have Cursor write remote file per your edit capability

Awaiting your P3 design; OpenCode ready for small tasks (log reading, unit tests) once spec lands.