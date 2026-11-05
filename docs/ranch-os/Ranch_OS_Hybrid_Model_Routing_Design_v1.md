# Ranch OS — Hybrid Model Routing Design v1

**Version:** 1.0 (draft for review)
**Status:** Proposed — not yet approved for DEV implementation
**Scope:** Local Qwen as the primary model; API connections as fallback for prompts the local model cannot handle
**Production:** Unchanged. DEV only.

## 1. Purpose

Ranch OS runs local-first. The primary inference path is a local Qwen model served via oMLX on the owner's hardware. This document designs the fallback path: when the local model cannot handle a prompt, the request routes to an external API instead of failing or degrading silently.

Local-first does not mean local-only. It means local by default, cloud by exception — with the owner deciding what counts as an exception.

## 2. Governing principles

1. **Local-first.** Every prompt goes to the local Qwen model first. The API path exists only for prompts the local model cannot handle. No prompt leaves the property network unless the fallback fires.
2. **Provider neutral.** The fallback must not hardcode a single lab. The routing layer speaks OpenAI-compatible APIs, so providers can be swapped by configuration, not code.
3. **Human-approved.** The owner defines what data may leave the ranch (section 5). Anything outside those boundaries never routes to an API, even if the local model fails — it fails closed instead.
4. **Cost-visible.** Every API call is metered and logged. The owner sees what the fallback costs, per call and in aggregate. No silent spend.
5. **Recoverable.** If the API path is unreachable, the system degrades to local-only with a clear notice — never a silent wrong answer.

## 3. Architecture

```
Prompt
  → local router evaluates (section 4)
  → Qwen (local, oMLX) attempts the prompt
      → success: return response
      → cannot-handle signal: route to API fallback
  → API fallback (section 6)
      → success: return response, log cost
      → failure/unreachable: fail closed, notify operator
```

The router sits between the caller and both inference paths. Callers use one interface; they do not choose the path themselves.

## 4. Fallback triggers

The router escalates a prompt to the API path when any of the following hold. Triggers are evaluated in order; the first match wins.

1. **Capability signal.** The local model returns a structured cannot-handle signal (low confidence, explicit refusal of capability, or output below a quality threshold). Exact thresholds are a DEV tuning decision.
2. **Task-type routing.** Prompt classes the owner marks as API-only by policy — e.g., tasks requiring current web knowledge, long-horizon reasoning beyond the local context window, or specialized domains where local quality is known-poor.
3. **Explicit override.** The operator flags a request for API handling. Used sparingly; logged like any other escalation.

What the router never does: silently retry locally until something plausible comes out. One attempt, one signal, then route or fail.

## 5. Data boundaries

Fallback means data leaves the ranch. The following rules are mandatory, not advisory:

- **Allowlist, not blocklist.** Only prompt classes the owner has explicitly approved may route to an API. Everything else fails closed on local-only.
- **No credential or identity data** in API-bound prompts. Ever. This includes passwords, tokens, account numbers, and anything that identifies the owner or household beyond what the task requires.
- **Redaction pass.** Before any prompt crosses the boundary, a local redaction step strips fields the owner marks sensitive. The redaction rules live in configuration, reviewable by the owner.
- **Audit log.** Every escalated prompt records: timestamp, trigger (which of section 4 fired), destination provider, token counts, and cost. The prompt text itself is logged only if the owner enables it — default off.

## 6. Provider options

The routing layer targets OpenAI-compatible endpoints. Candidates, in the owner's order of evaluation:

1. **OpenRouter.** One key, many models, per-call model selection, built-in fallbacks. Matches provider neutrality directly. Tradeoff: prompts transit OpenRouter's servers (a privacy hop), and pricing varies by model.
2. **Direct lab APIs** (Anthropic, OpenAI, Meta). Simpler, no middleman. Tradeoff: one lab per integration; swapping providers means code or config changes per lab.
3. **Self-hosted larger models** on the Intel Mini (64 GB RAM). Not an API in the external sense, but a legitimate second tier before anything leaves the network. Tradeoff: hardware-bound; only models that fit.

v1 recommendation: OpenRouter as the API tier, with direct-lab APIs as a documented alternative. The self-hosted tier is a separate design decision and out of scope here.

## 7. Cost controls

- **Per-call budget.** Maximum tokens per API call, configurable. Calls exceeding it are rejected before dispatch.
- **Aggregate budget.** Daily/monthly spend caps. When the cap is hit, the API path disables itself until the next window — local-only with notice.
- **Model selection policy.** The router picks the cheapest configured model that meets the task's capability requirement. Frontier models are opt-in per task class, never the default.
- **Reporting.** Cost per call in the audit log (section 5); periodic summaries available to the owner on request.

## 8. Open decisions

1. **Cannot-handle signal mechanics.** Confidence threshold vs. explicit model self-report vs. output-quality scoring — needs DEV experimentation with the actual Qwen deployment.
2. **API-only task classes.** The owner must define the initial allowlist (section 5). Starts empty; grows by explicit approval.
3. **Provider choice.** OpenRouter vs. direct lab — owner's call after reviewing section 6 tradeoffs.
4. **Redaction rule set.** Which fields and patterns get stripped before the boundary. Draft rules needed before DEV.
5. **Spend caps.** Concrete daily/monthly numbers. Unknown until usage patterns are observed; start conservative.

## 9. Relationship to existing work

- **Ranch OS design principles** (local first, modular, provider neutral, field reliable, human approved, recoverable): this design implements all six for the inference layer.
- **Apple on-device AI + oMLX/Qwen local models**: Qwen via oMLX is the primary path defined here. Apple on-device models remain a separate consideration for device-side tasks.
- **Ranch Finance / PropertyManager / Handbook Ingestion**: downstream consumers of inference. They call the router; they do not implement their own fallback logic.
