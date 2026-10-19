# RanchOS DEV (multi-platform: macOS / iOS / tvOS)

DEV-only SwiftUI app: PropertyManager live data, livestock, and finance.
Jarvis is not part of this app. No Production endpoints; no commits from agents.

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

Jarvis has no screen in this app. Its webpage will follow a separate design.
