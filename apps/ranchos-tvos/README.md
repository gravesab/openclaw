# RanchOS DEV (multi-platform: macOS / iOS / tvOS)

DEV-only SwiftUI app: PropertyManager live data, livestock browser, and the
Jarvis fixture slice. No Production endpoints; no commits from agents.

## Build & test (M4 Mac)

CoreSimulator/simdiskimaged is down on this Mac, so use `build-for-testing` +
`xcrun xctest` (there is no `RanchOS` scheme — use the per-target schemes):

```sh
cd apps/ranchos-tvos
xcodebuild build-for-testing -project RanchOS.xcodeproj \
  -scheme RanchOSHubTests -destination 'platform=macOS' \
  OTHER_SWIFT_FLAGS="-disable-sandbox" -derivedDataPath /tmp/derived-local
xcrun xctest /tmp/derived-local/Build/Products/Debug/RanchOSHubTests.xctest
xcodebuild build -project RanchOS.xcodeproj -scheme RanchOSMac \
  -destination 'platform=macOS' OTHER_SWIFT_FLAGS="-disable-sandbox"
```

Project is xcodegen-managed (`project.yml`), but `xcodegen generate` does NOT
reproduce the current `project.pbxproj` (it renames hand-added entries), so
membership for new files is hand-added to the pbxproj until a clean regen is
proven. `project.yml` is still updated to declare new test sources.

## Jarvis model chain (phase 1)

One router, one file: `HubSources/ModelRouter.swift`.

1. FoundationModels `.available` → on-device `LanguageModelSession`
   (intent classification + find-term extraction + reply shaping, all
   `@Generable`-structured, over already-retrieved facts only).
2. `.unavailable(.deviceNotEligible)` → PCC considered but NOT wired
   (no remote providers in phase 1) → deterministic fallback + honest label.
3. Any other `.unavailable` reason → deterministic keyword path, never a
   silent remote or local-LLM fallback (none authorized).
4. `RanchFMAnswerer` produces the unified output: deterministic retrieval
   FIRST (unchanged authority), then optional shaping (600-char cap,
   facts-subset grounding check). Every model failure lands on the keyword
   reply with an honest label. No network calls in the Jarvis path.

## Jarvis device proof (Andrew, on-device)

From `20260930-jarvis-fm-m4.md`. Record OS version, Apple Intelligence
ON/OFF, locale, and per-question timings.

1. **AI ON + supported locale** (M4 Mac, Apple Intelligence enabled):
   ask the 3 fixture questions ("How is the herd?", "Who is Maple?",
   "What can you do?"). Expect FM-shaped replies, each with the
   "Reply shaped on-device from sample-herd facts." label and the fixture
   provenance line. Typed and voice ("Start listening") both shape.
2. **AI OFF**: turn Apple Intelligence off (System Settings → Apple
   Intelligence), relaunch, ask the same 3 questions. Expect keyword
   answers with the honest "Apple Intelligence is off…" label; typed
   questions stay fully usable. No silence, no remote fallback.
3. **Airplane mode** (privacy proof): with AI ON, enable airplane mode
   and ask the fixture questions. Expect answers (fixtures are on-device;
   proves no remote dependency).

Stop/report: any FM API mismatch (exact symbol), any speech regression, or
any fixture presented without its label → stop and report, do not redesign.
