# Jarvis Voice Roadmap (DEV)

Status: Proposal grounded in approved contracts; M1, M2, and the Jarvis workspace implemented in RanchOS DEV.
Scope: Voice agent that talks with Andrew about the ranch. Read-only toward
ranch records for this stage. No deployment, Production, or live-data authority.

## Design sources found

| File                                                                   | Standing                                       | Relevance                                                                                                                                                   |
| ---------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ranchbrain_app/docs/RANCH_OS_HOME_APPLICATION_SHELL_DESIGN.md`        | Approved module-host contract for DEV planning | One RanchOS app per platform; compiled feature modules; Home owns no records; Apple-first intelligence, OpenClaw coordinates supporting AI behind workflows |
| `RANCH_OS_CURSOR_ONBOARDING.md` (repo root)                            | Approved onboarding index                      | Doc precedence; fixture ≠ authorization; Apple-first direction required per AI feature                                                                      |
| `ranchbrain_app/docs/ARCHITECTURE.md`                                  | Approved (1.0 Alpha)                           | RanchBrain is the local-first memory/knowledge engine OpenClaw uses; Jarvis facts come from here when connected                                             |
| `ranchbrain_app/docs/ROADMAP.md`                                       | Approved plan                                  | Executive briefing ("Good Morning Andy") is the approved conversational precedent (2.0 - Executive)                                                         |
| `ranchbrain_app/docs/API_SPEC.md`, `DATA_MODEL.md`                     | Approved contracts                             | Read-model shapes Jarvis must honor when grounded                                                                                                           |
| `RANCHBOT_ARCHITECTURE.md` (repo root)                                 | Implemented behavior (Telegram ops bot)        | Text command router + briefing precedent; not voice, not Jarvis                                                                                             |
| `tools/briefing/briefing_manager.py`                                   | Implemented behavior                           | Briefing assembly from events/memories; text-only                                                                                                           |
| `~/openclaw-speech/voice_to_openclaw.py` (outside checkout, read-only) | Implemented prototype                          | Prior voice loop: fixed-record mic → faster-whisper → OpenClaw `/run-command` → macOS `say`; ancestor pattern, not shipped                                  |
| `ranchbrain/README.md` → `docs/RanchBrain-Architecture.md`             | Missing                                        | Referenced path does not exist; do not cite it as evidence                                                                                                  |

No Jarvis or voice design document exists in the checkout (searched
`ranchbrain/`, `ranchbrain_app/`, `apps/`, `docs/`, `tools/briefing/` by name
and by voice/speech/briefing/assistant/conversation capability terms).
Absence of the name was verified; absence of a voice design follows from the
capability search, not the name alone.

## Approved decisions reused

- RanchOS stays one native Swift/SwiftUI app per platform with compiled
  feature modules; the approved DEV module set is Property, Livestock,
  Finance (`RanchOSHubModelTests.testDevelopmentFixtureContainsOnlyTheApprovedModules`).
  Jarvis therefore ships as a Home-shell-level conversation feature, not a
  fourth domain module, until a module addition is separately approved.
- RanchBrain owns ranch knowledge; RanchOS modules own no records. Jarvis
  answers must carry provenance and never present fixtures as live facts.

## Intended conversation

1. Andrew explicitly activates Jarvis (reversible choice: explicit
   push-to-talk; M1 fallback is typed input in the Jarvis card).
2. Jarvis captures the request (M1: typed text; M2: on-device speech
   recognition where the OS permits).
3. Jarvis matches a supported intent and reads only approved sources (M1:
   labeled DEV fixtures; M3: RanchBrain read APIs).
4. Jarvis answers with text plus a provenance label, and speaks the answer
   aloud on request via system text-to-speech (M1: explicit Read-aloud button).
5. Follow-ups reuse the same Ask box (M1: stateless; contextual follow-up later).
6. Anything unsupported, unconnected, or stale gets an explicit spoken and
   written acknowledgment ("I don't have live ranch records in this DEV
   slice"), never an invented fact.

## Apple API evaluation (verified in Xcode 27 SDKs on 2026-09-27)

- `AVSpeechSynthesizer` (AVFAudio): `NS_CLASS_AVAILABLE(10_14, 7_0)`,
  present in macOS, iOS, and tvOS SDKs; no entitlement or usage string
  required for speech output. Selected for M1 spoken responses.
  Note: `NS_SWIFT_NONSENDABLE` — use on the main actor only.
- `SFSpeechRecognizer` (Speech framework): present on macOS/iOS,
  `API_UNAVAILABLE(tvos)`. SDK-verified: `supportsOnDeviceRecognition` is
  declared `API_AVAILABLE(ios(13))`, which constrains only iOS — unlisted
  platforms (macOS) remain available, confirmed by the Codex Jarvis Mac
  build compiling the unguarded reference. `requiresOnDeviceRecognition`
  (`ios(13)`, `macos(10.15)`) prevents network audio, honored where
  on-device support holds at runtime. M2 hard-requires on-device on iOS
  and macOS (unsupported → explained-unavailable, typed retained); the
  Talk caption is "Talk uses on-device dictation." on both — never a
  silent remote fallback.
  Permissions: `SFSpeechRecognizer.requestAuthorization` (callback queue
  unspecified — hop to main) and `AVAudioApplication.requestRecordPermission`
  (`ios(17)`, `macos(14)`), with `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription` keys on iOS/Mac plists. tvOS stays
  typed-only; no mic UI is compiled there.
- FoundationModels (`SystemLanguageModel`): SDK-verified
  `@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)`, tvOS/watchOS
  unavailable; runtime additionally needs Apple Silicon, Apple Intelligence
  enabled, and supported language/region. RanchOS deploys to macOS 15 /
  iOS-tvOS 18, so any use must be `#available`-gated with a manual fallback.
  M4 candidate for on-device understanding only; not selected now.
- App Intents / Shortcuts: M5 candidate for system invocation; no API
  selected until a Jarvis intent is defined.

OpenClaw remains the supporting orchestration layer behind native workflows
per the shell contract; no new remote AI routing, paid services,
always-listening microphones, or background recording in any milestone.

## Milestones

- M1 (this stage, implemented): Jarvis card on RanchOS Home (all platforms).
  Typed question → labeled fixture answer → explicit Read-aloud. Read-only.
- M2 (implemented): Explicit push-to-talk on iOS/macOS — Start listening →
  visible listening state with labeled interim text → final transcript auto-asks the
  existing read-only answerer → explicit Read-aloud/Stop. Stop ends and
  transcribes; Cancel abandons with no transcript. Playback always stops
  before recording. No background listening, wake word, saved audio, or
  partial auto-submit. Typed input retained everywhere; tvOS typed-only.
  Plus a full Jarvis workspace (sidebar Assistant entry + compact link,
  sample questions, availability-only Apple Intelligence disclosure)
  reusing the same store and answerer; the Home card is retained on all
  platforms and Jarvis stays out of the approved module set.
  Persona: fixed spoken introduction via explicit Meet Jarvis (never
  auto-plays); workspace styled as a dark HUD with a Jarvis core and
  Ready/Listening/Speaking status. No gestures, no camera.
- M3: Ground supported answers in RanchBrain read APIs with provenance and
  staleness labels; fixtures remain only where explicitly labeled.
- M4: `#available`-gated Foundation Models understanding with manual
  fallback; OpenClaw orchestration through existing adapters.
- M5: App Intents invocation and accessibility audit (VoiceOver, captions
  for spoken output, Dynamic Type).

## M1 acceptance mapping

1. This roadmap cites only files actually found; missing pieces labeled.
2. M1 slice implemented in `apps/ranchos-tvos/` with fixture labeling.
3. HubTests + Mac/iOS/tvOS builds pass.
4. App observations vs test evidence vs unverified behavior reported separately.
5. Next milestone: M2 push-to-talk (needs mic/speech permission UX + usage
   strings + device validation; blocked until then, typed path stays).

## M2 evidence and gaps

- Implemented: Talk/Stop/Cancel flow, listening + interim display, denied /
  unavailable / failed states with guidance, audio teardown (tap removed,
  engine stopped, request ended, task cancelled, iOS session deactivated),
  ranch-name `contextualStrings`, playback/recording mutual exclusion.
- Tests: 8 deterministic speech-state tests over a fake engine (single
  start, partial-never-submits, final handoff, cancel, stop, denied retry,
  unavailable message, playback stop). Live recognizer, permission dialogs,
  audible playback, and actual mic capture are NOT covered by tests.
- Gaps: microphone behavior, audible playback, and the workspace
  layout/suggestions/readiness disclosure unverified until observed
  on-device; interim/final transcript UX polish (auto-scroll, timers)
  deferred. Not ported from the liked Codex build: RealityKit graph,
  Logitech camera preview, and the X300 fixture (workspace keeps the
  approved sample-herd answerer).
- Next milestone: M3 RanchBrain read-API grounding with provenance and
  staleness labels.
