# Ranch OS Local Red-Team Pass — Design v1

**Version:** 1.0 — Draft for review
**Status:** Proposed — plan only. The pass itself is NOT authorized to run.
**Scope:** DEV only. Production is never in scope.

## Purpose

Use a locally-hosted AI model to hunt vulnerabilities in Ranch OS–OpenClaw before anyone else does, without any code, prompts, or findings leaving the ranch. This is the execution arm of the October 22 prompt-injection audit: inventory, trace, then probe — with the model doing the probing under human approval.

## Governing principles

1. **Local only.** The model runs on Andy's own hardware. No API calls to external providers during the pass — no DeepSeek API, no OpenRouter, no anyone. Nothing leaves the ranch.
2. **DEV only.** Targets are DEV instances and DEV data. Production is out of scope, no exceptions, no matter what a probe finds.
3. **Human approved.** Read-only probing runs under the pass approval. Anything state-changing or destructive (deletes, drops, config changes) needs explicit approval per probe, in advance.
4. **Verify, don't trust.** The model produces candidates, not verdicts. A finding counts only after it is reproduced.
5. **Log everything.** Prompts, probes, outputs, and findings go in a run log kept with the run.

## Model and placement

A local open-weight coder model on the M4 Mac (24 GB unified RAM), for example Qwen3-Coder 30B at 4-bit quantization via MLX, llama.cpp, or Ollama — or DeepSeek-R1-Distill-Qwen-32B at 4-bit, i.e. the DeepSeek model without DeepSeek's servers. MLX is macOS-native, so the model runs on the Mac host, not inside the Ubuntu DEV VM (same placement rule as the Moshi voice layer).

If the chosen model doesn't fit or runs too slowly, narrow the scope or drop to a smaller coder (7B–14B class). Do not fall back to an external API to make up the difference.

## Target inventory (DEV)

In priority order — point it here first:

1. **Telegram channel.** Is the webhook secret set? Is OpenClaw at or above 2026.2.1? (CVE-2026-25474 — still unverified, sits with Andy.) Attempt forged webhook updates against the DEV bot.
2. **Input-channel inventory.** Every channel that feeds the model, traced to the tool access behind it. Prompt-injection probes per channel: can untrusted input reach an instruction, a tool, or a credential?
3. **MCP servers and tool permissions.** PropertyManager MCP and any others. Can a crafted message reach a destructive tool? Is the reader separated from the doer?
4. **FastAPI endpoints.** Auth on every route. Unauthenticated access attempts. Cross-tenant attempts once SSO lands.
5. **Router egress.** Is the allowlist actually enforced? Does the redaction pass redact before anything leaves? (Trust-addendum gap: the model grades its own fallback decision — test whether fallback triggers leak data.)
6. **Data stores.** Postgres and Qdrant ports and auth in DEV. Tailscale ACLs. What, if anything, is reachable beyond the tailnet?
7. **Home Assistant.** Local-only by design — check the remote-access path.
8. **SSO / multi-tenancy (when it lands).** Tenant isolation: can tenant A read tenant B's livestock or finance data?
9. **Kill switch (trust-addendum gap).** Can a running task be stopped mid-run? Known gap — test it, don't assume it.

## Method

- **Phase 0 — Inventory.** List channels, endpoints, tools, data stores, and versions. No probing.
- **Phase 1 — Static review.** The model reads DEV code and configs and flags candidate vulnerabilities with file, line, and reasoning.
- **Phase 2 — Dynamic probing, read-only first.** Crafted inputs through each channel, auth-bypass attempts, malformed MCP calls. Everything logged.
- **Phase 3 — Verification.** Reproduce each candidate by hand. Mark it confirmed, false positive, or needs-info.
- **Phase 4 — Fix and retest.** Fixes go through the normal DEV workflow with Andy's approval. Re-run the probes that found each issue.

## What it does NOT do

No production targets. No third-party systems. No real credential theft. No destructive payloads without per-probe approval. No external model APIs. No automated exploitation beyond DEV.

## Deliverable per run

A findings list (severity, component, reproduction steps, evidence, suggested fix), plus the run log and retest results.

## Open items and blockers

1. **Machine access.** SSH is still undelivered, so this pass cannot run from here. It runs on Andy's Mac via terminal Muse or Cursor, when he says go.
2. **Model choice.** Qwen3-Coder 30B vs. DeepSeek-R1-Distill-Qwen-32B vs. smaller — Andy's call, sized to what actually runs well on the M4.
3. **Cadence.** One-off pass vs. a standing re-run after major changes — undecided.
4. **SSO tenant-isolation tests** wait until SSO lands on DEV.

## Relationship to prior work

Extends the October 22 prompt-injection audit framework (inventory → trace → probe) and the hybrid model-routing trust addendum (kill-switch gap, egress-log gap). The CVE-2026-25474 version/secret checks from October 22 fold into target 1.
