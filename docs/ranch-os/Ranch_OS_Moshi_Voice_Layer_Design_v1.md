# Ranch OS — Moshi Voice Layer Design v1

**Version:** 1.0 (draft for review)
**Status:** Proposed — not yet approved for DEV implementation
**Scope:** Kyutai Moshi as the full-duplex voice layer for Jarvis — the mouth and ears, not the brain
**Production:** Unchanged. DEV only.

## 1. Purpose

Jarvis needs to hold a spoken conversation the way people actually talk: interruptible, overlapping, with pauses and backchanneling — not push-to-talk turns. This document designs Moshi as that voice layer. Moshi handles the conversation. The existing Ranch OS stack (local models, router, MCP tools) still does the thinking and the acting.

This is a voice front-end design. It does not replace the model router, the tool layer, or the human-approval rule.

## 2. Governing principles

1. **Local-first.** Voice runs entirely on the owner's hardware. No audio leaves the ranch. There is nothing to redact on this path because nothing egresses.
2. **Voice is not authority.** A spoken request never executes a ranch action on its own. Every action goes through the existing approval path, with a spoken confirmation before it commits.
3. **Swappable.** Moshi is one voice component, not the architecture. The voice layer speaks to the rest of Ranch OS through the text stream (section 4), so a different speech model can replace it without rewiring the tools.
4. **Give-away compatible.** Moshi's weights are CC-BY 4.0 and its code is MIT/Apache. Attribution is the only license condition. That fits the Ranch OS endgame.
5. **Recoverable.** If the voice layer fails, Jarvis degrades to text, not to silence and not to a guessed answer.

## 3. What Moshi is

Moshi is Kyutai's open full-duplex speech-to-speech model: audio in, audio out, no transcription stage in the middle. It listens and talks at the same time, handles interruptions and backchanneling, and runs at roughly 200 ms latency in practice.

- **Base model:** Helium, a 7B language model, plus Kyutai's Mimi neural audio codec (24 kHz audio down to a 12.5 Hz stream).
- **Streams:** three — the user's audio, Moshi's audio, and an inner-monologue text stream. The text stream is the integration hook (section 4).
- **Voices shipped:** two synthetic voices, Moshiko (male) and Moshika (female). No voice cloning; Moshi cannot be made to sound like the owner.
- **Backends:** PyTorch (needs a ~24 GB VRAM GPU), Rust (production service), MLX (Apple Silicon).
- **Weights:** `kyutai/moshika-*` and `kyutai/moshiko-*` on Hugging Face, ungated, CC-BY 4.0. Code: github.com/kyutai-labs/moshi.
- **Languages:** dialogue is English-focused. Sibling Kyutai models cover French; that is out of scope for v1.
- **Status:** experimental. Kyutai's own characterization is that responses can be unreliable or nonsensical. Treat every voice answer as untrusted until the tool layer verifies it.

Related watch item, not part of this design: Block's Dessa (announced October 23, 2026) is the same shape of model but has no released weights, API, or license. It cannot be used in Jarvis today. If it ships, evaluate it as a replacement voice component under this same architecture — it does not change the design.

## 4. Architecture

```
Voice in (mic)
  → Moshi voice loop (MLX, on the M4 Mac host)
      → audio out (speaker) — conversation, interruptions, backchanneling
      → inner-monologue text stream (real time)
          → Jarvis intent detection on the text stream
              → chat: Moshi keeps talking
              → actionable intent: route to the existing model router / MCP tools
                  → tool result returns
                  → Moshi speaks the result, then asks for spoken confirmation
                      → confirmed: action commits through the normal approval path
                      → not confirmed: nothing happens
  → voice layer failure: degrade to text interface, notify operator
```

Key points:

- The text stream is what the rest of Ranch OS reads. It is available programmatically as Moshi generates it, so intent detection does not wait for the conversation to end.
- Moshi never calls a tool directly. Tool calls happen in the existing stack, on the text the voice layer produced.
- A spoken result is a report, not a commitment. The commit step is separate and requires confirmation.
- The voice layer holds no ranch state. Property, livestock, and finance data stay behind the tool layer, exactly as they do for text callers.

## 5. Hardware placement

- **Voice host: the M4 Mac, on macOS itself.** The MLX backend needs 16 GB+ unified memory and is tested on M3 MacBook Pro hardware. The owner's 24 GB M4 clears that floor at 4-bit quantization (`moshi_mlx`, `-q 4`). This is the only box in the current inventory that fits the voice layer.
- **Not the Intel Mini.** The PyTorch path needs a ~24 GB VRAM GPU. No GPU is on record for the Mini, so it is not a real-time voice host. The Mini keeps its role as the server for everything else.
- **Not inside the Ubuntu DEV VM.** MLX is macOS-native. The voice service runs on the Mac host and reaches the rest of the stack over the local network (Tailscale). This is a deployment fact, not a preference: the VM cannot run the MLX backend.
- **Field use is unproven.** Echo cancellation lives in Moshi's web UI, not the command-line client, and ranch noise, wind, and machinery are conditions nobody has demonstrated this layer in. Microphone and speaker placement in the field is a DEV test item, not an assumption.

## 6. Data boundaries and safety

- Audio never leaves the property network. No cloud STT, no cloud TTS, no API call on the voice path.
- Voice input is treated as untrusted text, same as any other caller input. Prompt-injection rules apply unchanged: spoken words are data, never instructions to the tool layer, unless they pass through intent detection and approval.
- No voice-only execution. A spoken command that would change ranch state (log a move, record a sale, adjust inventory) requires an explicit spoken confirmation naming the action, then commits through the normal path.
- Attribution: any redistribution of Ranch OS including Moshi weights carries the CC-BY 4.0 attribution to Kyutai. This is a packaging note, not a runtime behavior.

## 7. Limitations (carried, not solved, by v1)

1. Experimental reliability — voice answers can be wrong or nonsensical. The tool layer, not Moshi, is the source of truth for any figure it speaks.
2. English-focused dialogue.
3. Two synthetic voices only. No custom or cloned voice.
4. Echo cancellation only in the web UI; field acoustics untested.
5. No native tool use. Every action crosses the text-stream boundary by design, which adds a step but keeps the approval boundary clean.
6. Latency figures (~200 ms) are Kyutai's, measured on their hardware. The owner's M4 numbers are unverified until the DEV trial.

## 8. DEV trial plan (not authorized — see section 9)

1. Run the MLX 4-bit build on the M4 Mac host. Talk to it. Measure interruption handling and latency on the owner's hardware.
2. Tap the inner-monologue text stream. Print detected intents in real time without acting on them.
3. Wire one intent end-to-end (a read-only ranch lookup first) with spoken confirmation, then stop. No state-changing intent enters the trial until step 3 is clean.

The trial runs on the owner's Mac. It cannot run from here: machine access (SSH) is still undelivered, and no prototype work is authorized until the owner says so.

## 9. Open decisions awaiting the owner's ruling

1. **Command detection.** How does Jarvis tell chat apart from a command — a wake word, a command phrase, or a push-to-talk fallback?
2. **Voice persona.** Moshiko or Moshika as the Jarvis voice?
3. **Confirmation phrasing.** What exactly does Jarvis say back before committing a spoken action?
4. **First wired intent.** Which read-only lookup goes first in the trial?
5. **Long-term host.** Does the voice service stay on the M4 Mac permanently, or move if a GPU lands in the Mini later?
6. **Voice failure fallback.** Text interface only, or also a degraded half-duplex voice mode?
7. **Dessa watch.** If Block releases Dessa weights or an API, re-evaluate it as a drop-in voice component under this architecture, or stay with Moshi?

## 10. Related documents

- `Ranch_OS_Hybrid_Model_Routing_Design_v1.md` — the router and API-fallback design this voice layer feeds into.
- `Ranch_OS_Hybrid_Routing_Trust_Addendum_Draft.md` — the three trust gaps (model grades its own fallback, no mid-task kill switch, no tamper-evident egress log). The voice layer inherits the kill-switch gap: a spoken "stop" must halt a running task, and that control does not exist yet.
- `Ranch_OS_Firecrawl_URL_Ingestion_Design_v1.md` — same draft status, same DEV-only rule.
