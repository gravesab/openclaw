# Ranch OS / OpenClaw — Development VM Migration Impact Assessment

**Date**: September 28, 2026  
**Migration**: M4 DEV VM transfer from Mac mini → IntelMini server  
**Prepared by**: Cursor AI implementation team  
**Distribution**: Andy (owner), Agent maintainers (Muse, Codex), Core team  

---

## Executive Summary

Cursor is relocating the active Development VM environment from the local Apple M4 Mac mini to your server running Ubuntu on Intel architecture (IntelMini). This migration frees substantial RAM capacity on the M4 for Ranch OS client applications, testing workloads, and native inference tasks while centralizing build/container infrastructure in one location.

This document assesses impact across active workstreams, documents required changes to agent workflows, and provides implementation runbooks.

---

## Migration Overview

### Current State (Pre-Migration)

| Asset | Location | Role |
| --- | --- | --- |
| DEV VM runtime | M4 Mac mini (local) | Build orchestration, container deployment, gateway hosting |
| Source control clones | M4 filesystem & worktrees on /Volumes | Developer editing, testing |
| Gateway services | `src/gateway/` + containers | Plugin discovery, channel routing |
| Test infrastructure | Vitest locally, Testbox remote | Unit tests, E2E lanes |
| Agent sessions | Cursor local host | Implementation, debugging |
| Credentials | `~/.openclaw/credentials/` (M4) | Auth tokens, API keys |

### Target State (Post-Migration)

| Asset | Location | Role |
| --- | --- | --- |
| DEV VM runtime | IntelMini server (Ubuntu) | Build orchestration, containers, gateway |
| Source control clones | Mac local worktrees + server repos | Developer editing on M4 |
| Gateway services | Docker/containers on IntelMini | Remote plugin/hosting loop |
| Test infrastructure | Vitest on M4 local + Testbox remote | Unit tests client-side, E2E lanes server-side |
| Agent sessions | Codex/Cursor on Mac, remote calls to IntelMini build APIs | Local code gen + CI execution |

---

## Impact by Workstream

### 1. PropertyManager (Primary Application)

**Current State**:
- SwiftUI/iPadOS app builds on M4 local
- API/Backend calls through DEV VM gateway
- Test runs: `pnpm test` locally, e2e via Testbox

**Migration Impact**:
| Area | Impact Level | Change Description |
| --- | --- | --- |
| Build workflow | Low | Xcode/iPadSimulators continue local builds; only server-side API/hosting moves |
| Gateway calls | Medium | Local client calls remote IntelMini gateway via network (existing pattern) |
| Test execution | Low/High* | Unit tests stay local; e2e lanes now use Testbox for full stack (recommended) |
| Hot path inference | High | On-device Apple Intelligence tasks unaffected; only server-side model calls change |

**Notes**: The PropertyManager app remains a Swift/iOS client. Only the backend hosting moves remote, which already existed in RanchBrain/protocol design. No code changes needed to app layer; update gateway endpoint config if using direct container calls.

**Owner**: Cursor (default implementer)  
**Next Action**: Update `.env` or gateway config to use server IntelMini host URL for remote API calls.

---

### 2. RanchFinance (Persistence, Ledger, RLS)

**Current State**:
- Uncommitted changes on `development` (Sep 27): persistence migrations, session storage, RLS policies, test suite
- Branch `codex/finance-ledger-invariants` exists; PR security branch `9f7b934`
- Worktree: `OpenClaw-Finance-PR`

**Migration Impact**:
| Area | Impact Level | Change Description |
| --- | --- | --- |
| Migration authority | High ** | Migration manifests and Python scripts run on server; ensure RLS constraints compatible with remote auth flow |
| Session state | Medium | `session/` store may live in PostgreSQL (server) or Redis; confirm persistence location after migration |
| Test isolation | Low | Vitest runs locally; server DB access via connection string update only |

**Critical Notes**:
- **Migration authority** remains a sensitive operation. Do NOT automate without explicit owner approval. Verify migration `010` contents and compatibility with the server-bound gateway auth model.
- The handoff notes warn against treating migration docs as live; inspect commit `dddcfdb` directly to confirm authority contract.

**Owner**: Codex (security-reviewed migrations); Cursor for implementation under guardrails  
**Next Action**: Verify DB connection strings point to correct PostgreSQL instance on IntelMini; preserve local uncommitted changes until gate passes.

---

### 3. Apple TV / Property Dashboard

**Current State**:
- Worktree: `codex/dev-finalization-property-dashboard-tv` (ahead at `a8b5f5d`)
- Uncommitted Swift/Xcode changes on main branch
- Xcode builds local; remote calls to property API

**Migration Impact**: Low. App remains SwiftUI client. Backend service moves, but network calls already supported per RanchBot/protocol design. No code changes expected.

**Owner**: Codex (for Apple-first verification)  
**Next Action**: Continue Xcode/local build flow; update backend host URL for remote services if required.

---

### 4. RanchBrain / Gateway / Retrieval

**Current State**:
- Local-only gateway on M4 per handoff notes
- Authentication, Telegram contracts, DEV model paths
- Foundation worktree: `codex/ranchbrain-dev-foundation` (`ccb0a4d`)

**Migration Impact**: **HIGH**. The "local-only" stance is being revised to support remote server hosting. This changes the fundamental inference/hosting topology:

| Area | Change | Rationale |
| --- | --- | --- |
| Gateway | Remote calls now use IntelMini | Frees M4 for inference tasks; follows RanchBot pattern |
| Model paths | Ollama endpoints may shift to server URL | Verify `.env` config for `OLLAMA_HOST`; ensure model registry accessible from client |
| Auth flow | May integrate with server-side credential vault | Align with Finance RLS/security boundaries |

**Owner**: Cursor (infrastructure implementation); Codex (privacy/review)  
**Next Action**: Audit all `OLLAMA_HOST`, `OPENCLAW_GATEWAY_URL` configs; confirm model registry mirrors or proxy if needed.

---

### 5. PropertyManager MCP v1 (Tooling, Handbook Search)

**Current State**:
- Worktree: `.git/worktrees/propertymanager-mcp-v1` and `/Volumes/T2 WD X/OpenClaw/Worktrees/propertymanager-mcp-v1`
- Commit `dddcfdb`: Migration 010, authority manifest, Python MCP server
- Live DB migrations pending; read-only surface (7 tools) verified

**Migration Impact**: **MEDIUM-HIGH**
| Area | Change |
| --- | --- |
| Server hosting | MCP server moves to IntelMini; clients call remote endpoints via `@property_manager_mcp` entry point |
| Tool contracts | No change for read-only 7-tool surface; verify write-lifecycle boundaries post-migration |
| Auth integration | Server-side auth may centralize credentials; preserve tenant separation per manifest |

**Owner**: Cursor (tool implementation); Codex for migration authority review  
**Next Action**: Update MCP client bindings to use remote endpoint; audit migration `010` contents before server deployment.

---

### 6. VA/Calling / Voice Module

**Current State**:
- Phase 0 docs approved Sep 21-22 (`RANCH_VA_VOICE_AND_CALLING_FOUNDATIONAL_REQUIREMENTS.md`)
- Implementation pending (Push-to-talk, LiveKit eval)

**Migration Impact**: Moderate. Calling sandbox and push-to-talk may leverage local audio (Apple Audio Units, Core Audio), but signaling/server moves remote. Verify that STUN/TURN/WSS endpoints align with server hosting.

**Owner**: Cursor (audio pipeline); Codex (privacy review of outbound calls)  
**Next Action**: Confirm WebRTC signaling host URL; test local microphone permissions without network issues.

---

### 7. OpenClaw Model Router / Compute Router

**Current State**:
- Failover documented but not live-certified (per August audit)
- Compute independence extension approved/planned; pending integration

**Migration Impact**: **HIGH**. The compute router must adapt to a new host URL for the M4-independent model serving layer:

| Area | Required Change |
| --- | --- |
| Router configuration | Update `MODEL_HOST`, `PROVIDER_API_URL` to IntelMini server address |
| Score/cost logic | Verify failover policy handles remote latency differences |
| Privacy gate | Ensure no sensitive user data crosses networks without explicit confirmation |

**Owner**: Cursor (routing logic); Codex (privacy/egress review)  
**Next Action**: Audit model registry paths; confirm provider contracts support IPv6/firewall rules on server.

---

### 8. Model Lab / Overnight Evaluator

**Current State**:
- Archive: `Ranch_OS_Model_Evaluator_Phase_1.zip`
- Task-specific scoring, best/secondary model selection, nightly runs pending

**Migration Impact**: Medium. Evaluator may continue local inference on M4 for benchmarking while server hosts heavy models (if capacity permits). Alternatively, nightly batch jobs can execute on IntelMini with results aggregated to Mac.

**Owner**: Cursor (benchmark framework)  
**Next Action**: Decide placement: local M4 runs vs remote IntelMini; update config accordingly.

---

### 9. Infrastructure / Muse Access / Intel DEV VM

**Current State**:
- Access runbook prepared Sep 27 (`RANCH_OS_MUSE_ENVIRONMENT_ACCESS_RUNBOOK.md`)
- Andy requires: M4 host, Intel Mini, M4 DEV Ubuntu environment verified individually

**Migration Impact**: **CRITICAL**. The IntelMini server replaces the M4 DEV VM container as primary host. Verify all three targets exist and function before migration:

1. **M4 (your Mac)** - Active client, local testing, Apple-first features, unit tests
2. **IntelMini (server)** - New DEV runtime, gateway hosting, containers
3. **Legacy Intel Mini VM (if distinct)** - May be deprecated or re-purposed for specialized workloads

**Owner**: Cursor (infrastructure admin); Codex for access review  
**Next Action**: SSH to IntelMini, verify `docker`, `pnpm`, `node` versions; confirm credentials stored securely (`~/.openclaw/credentials/`) before promoting DEV.

---

### 10. Home Assistant / Lorex / Scrypted Integration

**Current State**: Planned integration boundaries (no code checkpoint)

**Migration Impact**: Low. HA owns sensors, Lorex recording, Scrypted bridging; RanchBrain aggregates via governed API. No code changes expected unless the aggregation service moves remote.

**Owner**: Cursor (integration glue)  
**Next Action**: Draft binding layer once aggregation path defined.

---

## Agent Workflow Changes

### Pre-Migration Checklist

1. **Preserve Local State**
   - Stage all local M4 DEV changes before VM transfer: `git add -A && git commit -m "Pre-migration checkpoint on M4 host"`
   - Ensure worktrees (`.git/worktrees/`, `/Volumes/T2...`) are not orphaned

2. **Update Gateway Configuration**
   ```bash
   # Example update to .env or server.config.json
   export OPENCLAW_GATEWAY_URL="https://intelmini.yourdomain.local:8443"
   export MODEL_REGISTRY_URL="http://localhost:11434"  # Or remote if centralized
   ```

3. **Verify Auth Boundaries**
   - Finance RLS policies reviewed by Codex pre-dep
   - Credentials migrated to new vault location or updated references

4. **Codex Review for Risky Migrations**
   - Migration authority (`dddcfdb`, `010`) under Codex review before server apply
   - Security gate: zero user data egress without explicit confirmation

### Post-Migration Validation

1. Confirm DEV services reachable from local client (telnet/curl test ports)
2. Run lightweight sanity suite: gateway discovery, model ping, plugin catalog lookup
3. Restore credentials and re-authenticate agents if needed

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Overwrite uncommitted M4 changes | Medium | High (data loss) | Force-push after staged commit; backup worktrees to external location |
| Model registry inaccessible from client | Low-Medium | High | Use gateway proxy or model cache if firewall blocks direct calls |
| Finance migration without consent | Low | Critical | Codex review gate, owner signature before server deploy |
| Firewall blocks IPv6/remote API | Medium | Medium | Test connectivity pre-migration; document NAT configuration needed |

---

## Next Actions Summary

1. **Immediate (within 4 hours)**: Stage and commit all M4 work; backup `.git/worktrees/` contents to external drive or cloud
2. **Short-term (today)**: Update `.env` configs for remote gateway/model endpoints; test local client → server connectivity
3. **Before migration window**: Codex review of migration authority scripts on server; security policy approved for write operations
4. **During migration**: Cursor monitors CI, confirms build/test pass on IntelMini, validates credential vault access
5. **Post-migration**: Run full smoke (gateway discovery, model inference via curl/postman), confirm Apple-first features still local and compliant

---

## Verification Checkpoints

- ✅ M4 local filesystem intact after VM removal (no accidental wipes)
- ✅ Worktrees in `.git/worktrees/` resolve to same repo refs
- ✅ Remote gateway responds from IntelMini (`curl https://intelmini:8443`)
- ✅ Model registry accessible via proxy or direct client connection
- ✅ Finance migrations pending explicit gate pass before server promote

---

**Appendices**: Migration runbook for transferring DEV changes to IntelMini; Status report for Andy with verified checkpoints and pending items.

*Generated automatically by Cursor AI implementation team, Sep 28, 2026*
