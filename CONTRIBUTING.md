# Contributing to PlayerKit

Thanks for your interest in contributing to PlayerKit. This document describes how to set up a development environment and submit changes.

## Development setup

```bash
git clone https://github.com/refluxio/PlayerKit.git
cd PlayerKit
xcrun swift build
xcrun swift test
```

Requirements: macOS 14.0+, Xcode 16+, Swift 5.9+.

> Use `xcrun swift`, not bare `swift` — some shells have an unrelated `swift`
> binary on PATH (OpenStack client) that doesn't understand `build`.

## Running the MinimalPlayer example

MinimalPlayer is a macOS SwiftUI app under `Examples/MinimalPlayer/`. It has
its own `Package.swift` and depends on the parent PlayerKit package. Build and
run it from inside the example directory:

```bash
cd Examples/MinimalPlayer
xcrun swift build -c debug
```

The raw binary at `.build/<arch>/debug/MinimalPlayer` will not activate the
AppKit GUI on its own — bundle it into a `.app` and `open` it:

```bash
BIN=$(xcrun swift build -c debug --show-bin-path)/MinimalPlayer
APP=/tmp/MinimalPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MinimalPlayer"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MinimalPlayer</string>
  <key>CFBundleIdentifier</key><string>io.zyno.MinimalPlayer</string>
  <key>CFBundleName</key><string>MinimalPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
pkill -f MinimalPlayer 2>/dev/null
open "$APP"
```

## Regenerating FFmpeg

The pre-built xcframeworks are committed under `Sources/CFFmpeg/xcframeworks/`. To regenerate them (e.g. after upgrading FFmpeg):

```bash
scripts/build_ffmpeg.sh
```

This downloads FFmpeg source, builds for the configured Apple platforms, and replaces the 5 xcframeworks in place. Commit the result.

## Code style

- Swift, no tabs, 4-space indent.
- Public API surface is the protocol layer (`Playable`, `MediaProbable`, `VideoRenderer`, `AudioOutputBackend`, `FrameSink`, `PlayerBackend`). Prefer extending protocols over adding concrete types.
- No force-unwraps (`!`) in library code. Failures go through `throws`.
- File header comments: keep to one line, name + license pointer. No multi-paragraph boilerplate.

## Tests

- Unit tests live in `Tests/PlayerKitTests/`. Every public API change should come with a test.
- Run `xcrun swift test` before pushing. CI runs the same.

### Device-dependent tests skipped in CI

GitHub-hosted `macos-15` runners have no reliable display refresh or audio
device: `CVDisplayLink` may be created without ever ticking, and the audio
clock does not advance. Tests that assert real-time AV behavior are therefore
skipped on CI via `PLAYERKIT_CI_SKIP_AV_DEVICE_TESTS=1` (set in `ci.yml` and
`nightly.yml`):

| Test / class | Depends on |
|---|---|
| `NativeBackendSystemDVTests` (whole class) | system DV path, display ticks, audio master clock |
| `AudioUnitOutputControlNonBlockingTests` (whole class) | real-time pause/resume audio clock |
| `AudioUnitOutputPausedEnqueueTests` (whole class) | real-time enqueue/flush pacing |
| `AudioUnitOutputRecoveryTests` (whole class) | real-time burst pacing |
| `AudioDeviceDemotionTests.testDemotedResumeSkipsStartCalls` | HAL start-call wiring |
| `AudioDeviceDemotionTests.testDemotedEnqueueDropsFramesWithoutStart` | HAL start-call wiring |
| `PlaybackSpeedMeasurementTests` (whole class) | real-time 1x/2x playback speed |
| `AVSyncJitterMeasurementTests` (whole class) | real-time A/V offset windows |
| `ResumeAVSyncTests` (whole class) | real-time pause/resume sync |
| `TwoStepStartAVSyncTests` (whole class) | real-time play-then-seek sync |

These tests still run locally and on real devices (default path — just don't
set the variable). If you add a test that waits for real audio/display timing,
guard it the same way:

```swift
override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(ProcessInfo.processInfo.environment["PLAYERKIT_CI_SKIP_AV_DEVICE_TESTS"] == "1",
                  "CI has no real AV device")
}
```

and add it to the table above.

## Commit rules

- One feature per commit. If a change spans multiple files, stage them all together.
- Always `git commit -s` (Signed-off-by). No `Co-Authored-By`.
- No amend / rebase of merged commits. New fix → new commit on top.
- Commit message subject ≤ 70 chars, imperative mood. Optional `scope:` prefix (e.g. `feat(decode): ...`, `fix(sync): ...`).

## Pull requests

- Branch from `main`, rebase before submitting.
- PR description should cover: what, why, how to verify.
- If the PR changes the protocol layer, call that out explicitly — protocol changes are breaking by default.

## Open core boundary

`PlayerKit` (this repo) is the open-source core. HDR passthrough, Atmos/DTS-HD passthrough, DLNA cast, AI frame sampling live in the closed-source `PlayerKitPro` module — do not add them here.

If you're unsure whether a feature belongs in the open core or Pro, open an issue first.

## Reporting security issues

Do not open a public issue for security vulnerabilities. Email security@reflux.io.
