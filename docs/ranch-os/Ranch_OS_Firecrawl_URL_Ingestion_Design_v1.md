# Ranch OS — Firecrawl URL Ingestion Design v1

**Version:** 1.0 (draft for review)
**Status:** Proposed — not yet approved for DEV implementation
**Scope:** Self-hosted Firecrawl as the URL-source fetcher for Handbook Ingestion v1
**Production:** Unchanged. DEV only.

## 1. Purpose

Handbook Ingestion v1.1 already defines `source_kind: pdf | url` for manual versions. The `pdf` path is upload-driven. This document designs the `url` path: a self-hosted Firecrawl instance that fetches manufacturer documentation pages and returns clean markdown for the existing DEV ingestion pipeline.

Firecrawl never writes to PostgreSQL directly. It is a fetch-and-convert service only. Everything downstream — staging, SHA-256, chunking, review gates, activation — follows the already-approved Handbook Ingestion v1.1 schema and the ingestion decision tree unchanged.

## 2. Governing principles

1. **Local-first.** Self-hosted Firecrawl on the owner's Ubuntu host. No page content leaves the property network. The Firecrawl cloud API is explicitly out of scope for v1.
2. **Owner-controlled.** The stack runs under the owner's infrastructure, on the owner's schedule, with the owner's configuration.
3. **Human-approved.** Fetched content enters as a DEV draft. Nothing becomes searchable until the existing review/approval gates pass.
4. **Provenance-preserving.** Every fetch records source URL, fetch timestamp, content checksum, and Firecrawl job metadata in the version's `provenance` JSON.
5. **Fail-closed.** URL validation, egress restrictions, and size caps reject unsafe or unusable fetches before they reach staging.

## 3. Deployment

- **Host:** Ubuntu host (Intel Mac Mini running Linux; VM acceptable). Not on the M4 Mac — keeps browser-worker CPU/RAM off the primary workstation.
- **Runtime:** Docker Compose stack from the upstream Firecrawl repository (API, workers, Redis, RabbitMQ, PostgreSQL, Playwright service). The Playwright browser ships inside the container; no host browser required.
- **Resources:** Reserve 6–8 GB free RAM for the stack (Playwright workers are the heavy part) plus a few GB of disk for images.
- **Network binding:** Bind the API to `127.0.0.1` only. Remote access, if needed, goes over the existing Tailscale private network — never a public port. The stack's default no-authentication configuration is acceptable only behind this binding; enabling `USE_DB_AUTHENTICATION` is recommended before any network exposure.
- **Lifecycle:** `restart: unless-stopped` on all services. Disposable for DEV; no production SLA in v1.

## 4. Data flow

```
Operator (or approved DEV job)
  → submits canonical URL + target asset/document_key
  → ingestion service validates URL (section 6)
  → Firecrawl scrape (formats: markdown)
  → ingestion service computes SHA-256 over fetched bytes
  → duplicate check against staged/active source_sha256
  → stage DEV draft manual version (source_kind = 'url')
  → existing pipeline: chunk → DEV draft → human review → approval → activation
```

The existing safety gates apply without modification: draft manuals are inactive until reviewed, supersession is atomic, removed versions are retained for audit, and MCP `search_asset_manual` only ever sees extracted/approved/active versions.

## 5. Contract mapping to Handbook Ingestion v1.1

| Schema field | URL-source value |
|---|---|
| `source_kind` | `url` |
| `source_locator` | Canonical source URL (max 4,096 chars). Stored for provenance; never returned by MCP. |
| `source_display_name` | Safe human-readable name, e.g. manufacturer + document title (max 255 chars). |
| `source_sha256` | Lowercase hex SHA-256 computed over the exact fetched bytes by the ingestion service, not by Firecrawl. |
| `mime_type` | `text/markdown` for converted fetches. |
| `source_retrieved_at` | Timestamp the fetch completed. |
| `provenance` (JSON) | `{"fetcher": "firecrawl-selfhosted", "fetcher_version": "<image tag>", "source_url": "<canonical URL>", "fetch_started_at": "...", "fetch_completed_at": "...", "http_status": 200, "firecrawl_job_id": "<id>"}` — bounded to the 65,536-byte provenance limit. |
| `extractor_name` / `extractor_version` | `firecrawl` / image tag. |

Fetched markdown is chunked by the existing ingestion pipeline under the authoritative 32,000-character chunk content limit. Firecrawl output that cannot be chunked within limits fails the fetch rather than truncating silently.

## 6. Safety gates (URL-specific)

These sit in front of the existing decision-tree gates:

1. **Egress allowlist posture.** Default-deny for non-public targets. Block private IP ranges (10/8, 172.16/12, 192.168/16), link-local, loopback, and metadata endpoints — a self-hosted scraper on a private network is an SSRF vector against Home Assistant, router admin pages, and internal services. Resolve-and-check DNS at fetch time; reject DNS-rebinding results.
2. **Scheme restriction.** `https` only in v1 (`http` only with explicit operator override for legacy manufacturer sites).
3. **Size caps.** Reject fetched content above a configured byte ceiling before staging; oversized pages are an operator decision, not an automatic retry.
4. **Robots and rate discipline.** Respect robots.txt; one concurrent fetch per host; backoff on 429/5xx. This is a documentation fetcher, not a crawler.
5. **Content sanity.** Reject empty markdown, login-wall/captcha pages, and binary payloads mislabeled as documents. These surface as `ingestion_failed` with a reason, per the existing state machine.
6. **Secret hygiene.** `source_locator` (the URL) is stored but never returned by MCP — URLs can carry session tokens or internal hostnames. Same rule as the existing schema: safe display name only.

## 7. Explicitly deferred

- Firecrawl cloud API (`api.firecrawl.dev`) and any paid provider.
- Scheduled/automated crawling or change-detection re-fetches.
- Deep crawls (multi-page site traversal); v1 is single-URL fetch only.
- Firecrawl search API; v1 uses direct URLs supplied by the operator.
- AI extraction features (would require an OpenAI key or local Ollama wiring — revisit under RanchBrain, not ingestion).
- Production migration or production use of fetched content.

## 8. Open decisions (need Andy)

1. Confirm host: Intel Mac Mini (Ubuntu) vs. a VM on it vs. the M4 Mac. Recommendation is the Mini, keeping workers off the workstation. Known 2026-09-26: the Mini has 64 GB RAM / 4 cores, the M4 Mac has 24 GB unified RAM — headroom on the Mini is confirmed ample (6–8 GB stack on a 64 GB host).
2. ~~Confirm RAM headroom on the chosen host (6–8 GB free for the stack).~~ Resolved by specs above.
3. Whether to enable `USE_DB_AUTHENTICATION` from day one even behind localhost binding.
4. Operator UX for submitting a URL: CLI in the DEV worktree first, or a minimal DEV-only page.

## 9. Acceptance criteria

1. Firecrawl stack runs on the designated Ubuntu host, API reachable on `127.0.0.1:3002`, no public exposure.
2. A submitted manufacturer documentation URL produces a staged DEV draft with correct `source_kind`, checksum, provenance, and chunking — or a clean `ingestion_failed` with reason.
3. SSRF probes (private IPs, metadata endpoints, DNS rebinding) are rejected before any fetch.
4. Fetched content cannot reach MCP search results without passing the existing human review/approval gates.
5. No page content leaves the property network during any fetch.
6. No production database, config, or deployment is touched.

## 10. License note

Firecrawl is AGPL-3.0. Self-hosting unmodified for personal use is fine. If the stack is ever modified and offered as a network service beyond the household, license obligations trigger — revisit before any such step.

---

*End of Firecrawl URL Ingestion Design v1 (draft).*
