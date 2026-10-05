---
title: "RanchBrain AI Intelligence Layer"
summary: "Model evaluation and routing behind the native Apple application experience."
read_when:
  - Designing AI routing or Apple Intelligence integration
  - Evaluating supporting local and open-source models
---

# RanchBrain AI Intelligence Layer

## Purpose

The AI Intelligence Layer selects the most appropriate model for each OpenClaw task while protecting private ranch data, controlling cost, and requiring benchmark evidence before model promotion.

## Native Apple product boundary

The [development directive](/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE#apple-first-application-and-intelligence-direction)
is the governing source for Apple-first product design and feature evidence.
The AI Intelligence Layer supports the native RanchOS experience by evaluating
and coordinating appropriate models behind the scenes. Evaluate Apple
Intelligence opportunities first, then justify supporting open-source/local or
other approved models with workload evidence and privacy constraints.

An on-device Apple capability may execute inside the native application; do not
assume it is exposed as a server provider or already connected to `ai.execute`.
Any bridge or adapter needs a separately verified public API and bounded DEV
implementation. All execution paths preserve domain authorization and review
requirements. The runtime status below does not prove native Apple integration.

## Components

1. **Model Registry** — known models, deployment, privacy, cost, and operational status.
2. **Model Scorecard** — weighted OpenClaw-specific capability ratings.
3. **Routing Policy** — task-specific preferred and fallback models.
4. **Benchmark Suite** — repeatable tests for engineering, safety, and reliability.
5. **Technology Watch** — candidates such as Kimi K3 and Muse Glimmer that should be evaluated.
6. **Recommendation Engine** — deterministic first-stage model selection.
7. **Execution Engine** — bounded provider execution with ordered, policy-compliant fallback.
8. **Gateway Boundary** — typed operator requests delivered to the execution engine through the `ai.execute` RPC.

## Operating principles

- Local-first for private property, asset, household, and personal records.
- Cloud models may be used for approved nonprivate, difficult engineering work.
- Scores remain provisional until supported by benchmark evidence.
- No model is promoted solely from marketing claims or public hype.
- A human reviews production-routing changes.
- Routing designs must define approved, privacy-compatible fallback behavior;
  when no eligible model is available, return an explicit unavailable result.
- Runtime entry points must validate requests and responses at trust boundaries.
- Runtime AI execution must fail closed and remain disabled until explicitly enabled for an approved environment.
- Detailed provider and database errors belong in protected operational logs, not client responses.

## Runtime architecture

The OpenClaw Gateway is the control-plane entry point for AI Intelligence execution. Authorized operators submit a typed `ai.execute` request. The Gateway validates the request, invokes the database-backed execution engine through a bounded process bridge, validates the result, and returns the selected model and ordered attempt history.

```text
Authorized operator
        |
        | ai.execute (operator.write)
        v
OpenClaw Gateway
        |
        | bounded JSON process bridge
        v
AI Execution Engine
        |
        +--> AI Intelligence database
        |
        +--> primary model --> approved fallbacks
```

This boundary is additive. It does not replace the existing agent, chat, or channel message pipelines. Components must migrate deliberately after development verification.

The Gateway integration is disabled by default. An approved environment enables it with:

```text
OPENCLAW_AI_INTELLIGENCE_GATEWAY_ENABLED=1
```

The bridge has a bounded timeout and output limit. Client-facing failures are normalized, while operational details remain in Gateway logs. Database credentials are loaded from the runtime environment or the protected AI Intelligence credentials file; they are never accepted from an RPC caller.

## Implementation status

Phase 2F.4G is implemented and activation-proved on the loopback Gateway:

- database-backed execution engine and ordered fallback are implemented;
- constructor and configuration validation are implemented;
- the typed `ai.execute` Gateway boundary is implemented;
- the development Gateway image packages the bridge and its pinned Python dependency;
- focused Gateway, TypeScript, and AI Intelligence tests pass;
- live `ai.execute` primary success is demonstrated for `telegram_ranch_bot`;
- live primary failure with approved fallback success is demonstrated;
- client errors stay sanitized while Gateway logs retain operational detail;
- activation and rollback checkpoint is recorded under `reports/architect/`;
- usage and failover telemetry persist to `ai_intelligence.observed_model_usage`;
- Daily Executive Briefing and OpenClaw dashboard surface routing telemetry status.
- the OpenClaw dashboard exposes scorecard evidence and audit history, with
  approval and promotion actions restricted to exact-ID loopback requests.

## Kimi K3 decision

Kimi K3 is registered as an evaluation candidate, not a production default. Its likely strengths are long context, repository comprehension, and code generation. It must complete the OpenClaw benchmark suite before promotion.

## Muse evaluation decision

Research checked September 24, 2026. Queue **Muse Glimmer 30B Q4_K_M** for
isolated DEV evaluation on a 24 GiB Apple Silicon host. This is a size-fit
recommendation, not a measured winner or an installation approval.

[Meta released Glimmer on August 10](https://research.meta.ai/blog/introducing-muse-glimmer-open-agentic-model)
under Apache 2.0 for local agent workflows, including tool use, coding and image
understanding. [Muse Spark 1.3, released September 2](https://research.meta.ai/blog/introducing-muse-spark-1-3),
is the latest verified Spark release. [Meta lists Spark as hosted and Glimmer as
self-hosted](https://dev.meta.ai/docs/models); Spark remains a cloud watch item
for approved nonprivate comparisons.

### Choose the local build

The choice is quantization of the 30B model, rather than a verified family of
smaller standalone Glimmer models.

| Build               | Published weight size   | Evaluation decision          |
| ------------------- | ----------------------- | ---------------------------- |
| Official Q4_K_M     | 16.8 GB text weights    | First candidate for 24 GiB   |
| Official Q4_K_XL    | 19.7 GB text weights    | Defer; less host headroom    |
| Community MLX 4-bit | 19.4 GB repository size | Secondary runtime comparison |
| Full precision      | Over 55 GB memory       | Exclude on a 24 GiB host     |

The [official GGUF card](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF/blob/main/README.md)
specifies llama.cpp build b10353 or newer, a 1.4 GB image encoder and an optional
1.6 GB speculative drafter. Start without either companion. The
[MLX conversion](https://huggingface.co/mlx-community/Muse-Glimmer-30B-4bit)
uses mlx-vlm; its availability does not establish compatibility with the installed
oMLX service. Weight size excludes operating-system, application and runtime
overhead. A fit claim for dedicated GPU memory does not prove shared-memory fit.

### Run the evaluation gates

`config/ai_intelligence/technology_watch.json` records the queue. It does not
schedule execution. The existing local benchmark runner uses fixed Ollama
candidates; it does not automatically execute this GGUF candidate. Registry and
scorecard entries wait for evidence rather than invented ratings.

1. Record available memory, swap baseline, storage, runtime version, model
   revision and checksum. Use an isolated DEV endpoint; preserve active services.
   Begin with one slot and an 8,192-token context as a project trial setting.
   Stop on allocation failure, sustained swap growth or degraded responsiveness.
2. Prove the runtime and evaluation adapter with synthetic inputs: final-answer
   parsing, strict JSON, tool arguments, tool-result continuation, timeouts and
   malformed-output rejection. Confirm reasoning text cannot become a proposal.
   Use the candidate smoke runner below before integrating scored results into
   the existing evaluation pipeline.
3. Run all ten tasks in `config/ai_intelligence/benchmarks.json` against the
   registered Qwen 3.5 9B, Gemma 4 12B and Hermes 3 8B comparators where available.
   Use identical fixtures and repeat each case three times. Record missing models
   as skipped; retain every timeout and invalid response.
4. Record peak memory, swap change, time to first token, total latency, throughput,
   schema validity, tool success and source-citation accuracy. Include manual
   extraction, unsupported-fact rejection and confirmation-boundary cases.
   Use synthetic or public fixtures. Human-reviewed references remain authoritative.
5. Increase context to 16K and 32K only after the initial capacity pass. Evaluate
   image input and speculative decoding separately, retaining their added memory
   costs. Do not infer long-manual performance from a short-context pass.
6. Apply the existing promotion gate: at least eight completed benchmarks,
   overall score at least 8.0, safety score at least 8.0 and human review. Require
   measured benefit over a comparator on a named workload with acceptable latency
   and memory use. Keep runtime activation and production routing separately gated.

### Candidate smoke runner

`tools/ai_intelligence/run_local_candidate_eval.py` provides a separate DEV
observation path. It shares the five executable prompts with the existing
Ollama runner and adds deterministic synthetic extraction and simulated tool
continuation checks. The ten-task suite above remains the target; five prompts
plus two smoke checks do not satisfy the eight-benchmark promotion minimum.

From the repository root, preview the plan without network requests:

```bash
python3 -m tools.ai_intelligence.run_local_candidate_eval
```

After capacity and artifact checks, prepare an isolated compatible server with
the model alias `muse-glimmer-30b-dev`, a single slot, 8,192 context tokens and
an explicit loopback port. The runner does not download, start or reconfigure
a server. Inspect its installed version and launch configuration separately.
Then run against that endpoint, choosing a new output filename each time:

```bash
mkdir -p reports/ai_intelligence/candidate_runs
python3 -m tools.ai_intelligence.run_local_candidate_eval \
  --execute \
  --base-url http://127.0.0.1:18081/v1 \
  --model muse-glimmer-30b-dev \
  --repeats 3 \
  --output reports/ai_intelligence/candidate_runs/muse-first-run.json
```

This uses the [llama.cpp server contract](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
Only explicit HTTP loopback IP addresses are accepted; proxies and redirects are
disabled. The catalog must contain the requested alias, but that alone does not
prove the weight revision or checksum. Record those independently.

Each call has a 60-second socket timeout and a 2,048-token output budget. These
are initial smoke settings, not a complete long-context quality benchmark.
The runner checks final text separately from reasoning, rejects incomplete
responses, and never executes model-selected tools. It reports per-case latency
and returned token usage. Time to first token, peak memory, swap growth and
manual quality scoring require separate observation.

`passed` applies only to the deterministic smoke fixtures. Benchmark answers
remain `needs_human_review`; failed calls remain in the report. Exit status 1
means a failed check or blocked endpoint. Reports always have
`promotion_eligible: false` and never replace evaluation-lab reports or scores.

## Next implementation phase

Formal production-promotion review still requires the broader Phase 2F acceptance checklist. Usage and failover telemetry now feed the Daily Executive Briefing and OpenClaw dashboard; continue refining scorecard presentation in RanchBrain as needed.
