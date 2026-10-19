# Ranch OS DEV VM Migration Runbook

**Date**: September 28, 2026  
**Objective**: Safely transfer Development VM workload from Apple M4 Mac mini to IntelMini server  
**Prepared by**: Cursor AI with Codex security review  
**Approval Required**: Andy (owner), Codex (security/privacy gate) before deployment  

---

## Overview

This runbook documents the safe migration of the OpenClaw DEV environment from your local Apple M4 Mac mini to your Ubuntu-based IntelMini server. The goal is to free M4 RAM capacity for client application testing while maintaining service availability and adhering to Ranch OS governance policies.

**Migration Type**: Hot swap (services continue running during transition)  
**Downtime**: ~10 minutes max for gateway redeployment  
**Credentials**: Preserved via secure vault, not file transfer  

---

## Prerequisites Verification

Run these checks BEFORE migration on the **M4 Mac mini**:

### 1. Repository Hygiene

```bash
cd /Users/andrewgraves/Developer/OpenClaw-DEV

# Stage all local work to prevent accidental loss
git add -A
git commit -m "Pre-migration checkpoint M4 host changes"

# Verify no untracked sensitive files
git status --porcelain | grep -E "(\.pem|\.key|secret)" || echo "No secrets staged"

# List current branches and their SHA refs to document state
git branch -a --format="%(refname:short) %(objectname:short) %an %ar" > /tmp/pre-migration-branches.txt
cat /tmp/pre-migration-branches.txt
```

### 2. Gateway Health Check

```bash
# Test gateway is responding on M4
curl -s https://localhost:8443 || echo "Note: Localhost may differ from server hostname"

# Verify model registry accessible locally (if applicable)
curl -s http://localhost:11434/api/tags | head -c 200 || echo "Model registry check skipped"
```

### 3. Credential Vault Export (Pre-Migration Snapshot)

```bash
# NEVER commit credentials; only document what needs re-auth after migration
ls -la ~/.openclaw/credentials/ 2>/dev/null && \
echo "Credential paths documented for post-migration re-import" || \
echo "Credentials managed by provider auth profiles (finance)"
```

### 4. Worktree Inventory

```bash
# Document all worktrees and their branches before migration
for wt in .git/worktrees/*; do
  name=$(basename "$wt")
  echo "Worktree: $name"
  cd "$wt"
  git branch --showcurrent
  cd /Users/andrewgraves/Developer/OpenClaw-DEV
done
```

**Output to preserve**. Store this list before migration proceeds.

### 5. Docker/Container Status

```bash
# List containers that will redeploy on server
cd /Users/andrewgraves/Developer/OpenClaw-DEV
docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

# Document volumes mounted from Mac filesystem (these WILL be lost during cold swap)
docker volume ls -f dangling=false --format "{{.Name}}" 2>/dev/null || \
echo "No Docker volumes on this host (expected for hot migration)" 
```

---

## Migration Execution Steps

### Phase 1: Client Preparation (On M4 Mac mini)

**Step 1**: Update local environment configuration

Create backup `.env.local.bak` if needed, then update for remote gateway:

```bash
# Example .env updates - adjust URLs based on your server DNS/host
export OPENCLAW_GATEWAY_URL="https://intelmini.yourdomain.local:8443"
export MODEL_REGISTRY_URL="http://localhost:11434"  # Keep local for client
export OLLAMA_HOST="${MODEL_REGISTRY_URL}"

# Test from local shell that remote gateway resolves
curl -s "${OPENCLAW_GATEWAY_URL}/api/health" && echo "Remote gateway reachable" || \
(curl -v "${OPENCLAW_GATEWAY_URL}/api/health" || echo "Gateway unreachable - check network/firewall")
```

**Step 2**: Export current session artifacts (optional, non-critical)

```bash
# These are typically ephemeral and re-created; document if custom hooks exist
cat ~/.openclaw/sessions/*.json 2>/dev/null | head -20 || echo "No persistent sessions to export"

# If using custom agent configs that won't re-sync:
cp ~/.openclaw/agents/* ~/.openclaw/agents-backup-$(date +%Y%m%d) || true 
```

**Step 3**: Commit and push pre-migration checkpoints (if repo permits)

```bash
git status --short
# Review changes; commit or stash if necessary
git push origin development  # Or branch if required
```

---

### Phase 2: Server IntelMini Preparation

**Verify server access on Ubuntu**:

```bash
ssh yourserver-ip <<EOF
# Verify prerequisites exist on server
which docker && docker --version 2>&1 | head -1
which node && node --version 2>&1 | head -1
which pnpm || echo "pnpm not installed; use npm or install with corepack"

# Test network connectivity from M4 to server
M4_IP=$(ifconfig en0 | grep 'inet ' | awk '{print $2}' | tr -d '<>')
echo "Testing from M4 IP $M4_IP to server..."
ping -c 3 yourserver-ip && echo "Network path ok" || echo "Network issue - debug DNS/firewall"

exit
EOF
```

**Install runtime prerequisites on IntelMini** (if not present):

```bash
# SSH into server and run:
sudo apt-get update
sudo apt-get install -y curl gnupg lsb-release  # Basic tools

# Add Node.js GPG key and install LTS (adjust version as needed)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Corepack for PNPM support
corepack enable

# Verify Docker can pull images (if container orchestration exists)
docker run --rm alpine:latest echo "Docker OK"
```

**Clone repo to server** (if not already there):

```bash
# SSH into server:
ssh yourserver-ip <<EOF
cd /home/ubuntu  # Or appropriate user home
git clone https://github.com/gravesab/openclaw.git --depth=1
cd openclaw
npm install || corepack enable && pnpm install
npm run build || pnpm build

# Test gateway starts on server (container or native?)
npm start || node src/index.js 2>/dev/null &
sleep 5 && curl -s localhost:8443/health && echo "Gateway running" || echo "Manual inspection needed"

exit
EOF
```

---

### Phase 3: Safe Migration Swap

**Goal**: Move M4 VM workload to server without data loss.

**Warning**: If using a true "VM/container" abstraction, do NOT cold-reboot the Mac mini expecting continuity. Instead:

1. **Ensure new deployment is running on IntelMini first** (see Phase 2)
2. **Switch your local client configuration** to use IntelMini gateway URL
3. **Let old M4 container/instance die gracefully** (if managed by systemd/docker-compose)
4. **Verify new deployment handles requests** before fully decommissioning old host

**If using Docker Compose on both**:

```bash
# On server: start services
ssh yourserver-ip <<EOF
cd /home/ubuntu/openclaw
docker compose up -d  # Or custom compose file if present

# Check logs for errors in first minute
docker compose logs --tail=30 gateway || echo "No compose; native process"

exit
EOF

# On client M4: confirm new host reachable and old services draining
M4_HOST_URL="https://intelmini.yourdomain.local:8443"
curl -s "${M4_HOST_URL}/api/health" && echo "New server healthy" || \
echo "Server unhealthy - debug before proceeding"
```

**Update local agent configs** (if needed):

Edit `~/.openclaw/config.json` or `.env` to use IntelMini URL. Agents re-discover gateway via config on restart.

---

### Phase 4: Post-Migration Validation

**Test Suite (run from M4 client)**:

```bash
# 1. Gateway discovery and ping
curl -s "${OPENCLAW_GATEWAY_URL}/api/health" | jq -r '.status' || echo "Response not JSON; inspect raw"

# 2. Model registry accessible?
curl -s "${OLLAMA_HOST}/api/tags" 2>/dev/null && echo "Registry reachable" || \
echo "Model registry offline - check OLLAMA_HOST config or use proxy"

# 3. Plugin catalog from remote gateway
curl -s "${OPENCLAW_GATEWAY_URL}/api/plugins" | head -c 500 || \
echo "Plugin discovery skipped; manual test"

# 4. Run smoke tests (lightweight)
cd /Users/andrewgraves/Developer/OpenClaw-DEV
pnpm test smoke 2>/dev/null || \
node scripts/run-vitest.mjs smoke 2>/dev/null || \
echo "Smoke tests not configured; manual validation only"
```

**Verify worktrees still resolve**:

```bash
cd /Users/andrewgraves/Developer/OpenClaw-DEV
for branch in $(git -c core.worktree=/.git/worktrees/* branch -a); do
  name="${branch#remotes/}"
  if [ -d "$name" ]; then
    echo "Worktree $name OK"
  else
    echo "Worktree missing: $name"
  fi
done

# Ensure all local files present (M4 disk still mounted)
ls -la | grep -E "(src|ui|packages)" && echo "Local app structure intact" || echo "Filesystem issue - investigate"
```

**Re-import credentials securely**:

```bash
# Re-authenticate to providers via secure vault on IntelMini
openclaw auth:reinit --vault ~/.openclaw/credentials 2>/dev/null || \
echo "Use provider CLI tools per official docs (no automated re-export keys)"

# Finance-specific RLS policies remain server-side; no local auth tokens needed
```

---

## Rollback Procedure (If Migration Fails)

If validation fails in Phase 4, revert within the maintenance window:

1. **Kill new deployment** on server (if unhealthy)
   ```bash
   ssh yourserver-ip <<EOF
   # Gracefully stop services
   systemctl stop openclaw-gateway || docker compose down || node src/index.js -s 2>/dev/null & 
   exit
   EOF
   ```

2. **Restore local config** pointing to old gateway host (if applicable)
   ```bash
   export OPENCLAW_GATEWAY_URL="http://localhost:8443"  # Or original IP/hostname
   ```

3. **Restart M4 services** if container managed locally by systemd/Dockerfile on that machine

**Note**: This assumes server was not fully decommissioned before validation. Always spin up new deployment BEFORE stopping old one.

---

## Security Considerations (Codex Review Required)

### Before Deploying to Server

- [ ] Migration authority scripts (commit `dddcfdb`, migration 010) reviewed by Codex
- [ ] Finance RLS policies verified compatible with remote auth flow
- [ ] No sensitive user data cached in local temp dirs will be transferred without explicit consent
- [ ] Firewall rules allow M4 client → server on API ports (8443, etc.)
- [ ] Credentials re-authenticated via provider vault (no key export/import between hosts)

### After Migration

- Review agent logs for unexpected egress attempts from client to unknown registries
- Ensure model registry proxy (if used) terminates HTTPS and validates certs
- Finance ledger queries confirmed authorized per RLS before any cross-network call

**Codex Gate**: Run `openclaw security:audit --target=new-migration` prior to production approval.

---

## Monitoring & Alerting

Deploy these minimal checks on new host:

```bash
# Add to server cron or systemd timer for health
*/5 * * * * curl -s http://localhost:8443/health | grep -q healthy || logger -t openclaw "Gateway unhealthy"
```

---

## Documentation Handoff

Update these pages after migration completes successfully:

1. **AGENTS.md** – Section on compute independence and local-only AI policy (updated host URL)
2. **RANCH_OS_MIGRATION_ASSESSMENT.md** – Fill in "Post-Migration Status" with dates, test results
3. **PROJECT_CONTEXT.md** – Document new infrastructure topology

---

## Sign-Off

**Approved by**:  
[  ] Andy (owner): ________________________ Date: _______________  
[  ] Codex (security review): _______________ Date: _______________  

**Migration Executed By**: Cursor AI with human oversight  
**Timestamp**: TBD after validation success  

---

*End of runbook. For questions, refer to OPERATIONS_RUNBOOK.md in project root.*
