# Ranch OS — Hybrid Routing Trust Addendum (DRAFT)

**Status:** Draft note for Andy's review — NOT approved, does not amend the v1 design
**Companion to:** `Ranch_OS_Hybrid_Model_Routing_Design_v1.md` (Oct 10, awaiting Andy's rulings on its 5 open decisions)
**Prompted by:** Satya Nadella's Oct 10, 2026 post on AI "trust architecture," reported by TechCrunch Oct 10, 2026, and recirculated in two newsletters in Andy's inbox Oct 12, 2026.

## Why this note exists

Nadella's checklist is, in plain terms, the same philosophy Ranch OS already runs on: assume the model can be compromised, contain it from the start, keep the controls outside the model, log what it does in human-readable form, and keep a human able to stop it mid-task — his phrase is "emergency brake." Most of it is already in the v1 hybrid routing design. Two items are not, and one existing item cuts against it.

## Already covered in v1 (no change needed)

- **Containment / allowlist-only egress** — v1 §5: only owner-approved prompt classes may leave the ranch; everything else fails closed.
- **Fails closed / recoverable** — v1 §2.5 and §7: API path disables itself at spend caps; unreachable API degrades to local-only with notice.
- **Metered, logged calls** — v1 §5 audit log and §7 cost controls record timestamp, trigger, provider, tokens, and cost per call.
- **Model diversity / provider neutrality** — v1 §6: OpenAI-compatible routing, OpenRouter recommended, no single lab hardcoded.

## Gap 1 — The model currently grades itself (affects Open Decision #1)

v1 §4 trigger 1 escalates on a "capability signal" from the local model itself — low confidence, self-reported cannot-handle, or quality scoring. Nadella's core point is that a model should never be the one verifying its own behavior; controls and evaluation belong in the harness around it.

**Draft recommendation for Andy's ruling:** make Open Decision #1 lean external — router-side checks (task-class rules, output-format/length validation, a separate small scorer, or DEV-side quality sampling) decide escalation, with model self-report as at most a secondary input, never the sole trigger.

## Gap 2 — No operator kill switch for a task in flight

v1 stops future calls (budget caps, fail-closed), but nothing lets the owner pause or shut down a model mid-task — the "emergency brake" item.

**Draft recommendation:** add a §7-style control: a local operator command that halts the current routed task and drops the system to local-only until the owner re-enables the API path. Local-only control, no API dependency, logged like any other escalation event.

## Gap 3 — Audit log is specified, tamper-evidence is not

v1 §5 requires the audit log but does not say it must resist later editing. Nadella's version calls for tamper-proof, human-readable evidence of every meaningful action.

**Draft recommendation:** specify the audit log as append-only with a simple hash chain (each entry includes a hash of the previous entry) — cheap on local hardware, makes silent edits detectable, stays human-readable.

## What this does NOT do

- Does not change any of the five open decisions in v1 — it informs #1 directly and adds two candidate items (#6 kill switch, #7 tamper-evident log) for Andy to accept or drop.
- DEV only, like the parent design. No implementation, no provider contact.

## Sources

- TechCrunch, Oct 10, 2026: "Microsoft's Satya Nadella says AI models need an 'emergency brake'" — https://techcrunch.com/2026/10/10/microsofts-satya-nadella-says-ai-models-need-an-emergency-brake/
- Recirculated in Andy's inbox Oct 12, 2026: "What's Up in AI" and "The Shift" newsletters.
