# Ranch OS API-Exposure Audit — Copy-Ready Prompt v1 (Draft, 2026-10-30)

Paste this into a terminal Muse window or Cursor on the M4 Mac. It is a plan and
a prompt for local execution. It does not run from Segundo's side.

## Scope — read this first

- DEV ONLY. The audit covers the Ubuntu DEV VM on the M4 Mac.
- PRODUCTION IS OUT OF SCOPE. The Intel Mini runs production. Do not probe,
  scan, or change anything on it.
- Goal: prove that no Ranch OS API is reachable from anywhere it should not be,
  and that everything reachable requires authentication. "Fully secure" is not
  the bar — a verified exposure inventory is.

## Phase 0 — Inventory (read-only, no changes)

1. List every listening TCP and UDP service on the DEV VM (`ss -tlnp`,
   `ss -ulnp`) with the process behind each port.
2. Identify each service: FastAPI apps, OpenClaw, Home Assistant, PostgreSQL,
   Qdrant, MCP servers, anything else. Record port, process, and bind address:
   `127.0.0.1` (local only), `0.0.0.0` (all interfaces), or a Tailscale IP
   (tailnet only).
3. List what each service exposes: FastAPI routes (`/docs`, `/openapi.json` if
   present), MCP tool lists (mark each tool read vs write), Home Assistant API
   endpoints.

## Phase 1 — Reachability probing (read-only requests only)

4. For each API, test unauthenticated access from three vantage points:
   (a) localhost on the DEV VM, (b) another device on the tailnet,
   (c) a device on the home LAN that is NOT on the tailnet. Use harmless
   read-only requests only (GET health/docs/root). Record which endpoints
   answer without auth from each vantage point.
5. Tailscale: check `tailscale status`, the tailnet ACL policy, and whether any
   device runs `tailscale serve` or `tailscale funnel` (public internet
   exposure). Any funnel/serve entry is a finding until Andy confirms it is
   intended.
6. Home Assistant remote path: confirm how it is reachable remotely — Tailscale
   only, Nabu Casa, or a router port forward. A router port forward to Home
   Assistant (or anything else) is a finding.
7. Router: list port forwards and UPnP mappings. Any forward pointing at a DEV
   service is a finding.
8. Databases: PostgreSQL and Qdrant bind addresses and auth. Anything listening
   on `0.0.0.0` without auth, or reachable from the tailnet/LAN without
   credentials, is a finding.
9. MCP servers: confirm each MCP endpoint's transport (stdio/local vs network).
   Any MCP server listening on a network interface is a finding until confirmed
   intended.

## Reporting

- Findings list: service, port, bind address, reachable from
  (localhost / tailnet / LAN / internet), auth required (yes/no),
  verdict (OK or FIX).
- Verify every finding by re-testing before reporting it. A finding is not real
  until reproduced.
- Log every command and result.
- STOP after inventory + probing. Do not change any configuration, firewall
  rule, bind address, or password. Each fix needs Andy's go-ahead, one at a time.

## Hard rules

- DEV only. Production on the Intel Mini is never in scope.
- Read-only probing only. No state-changing requests, no login attempts with
  guessed credentials, no destructive tests.
- If AI is used for analysis, local model only. Nothing about this audit —
  code, configs, or findings — goes to an external API.
- If a step cannot be verified, say UNKNOWN. Do not infer.
