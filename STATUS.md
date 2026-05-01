# MusePlus — STATUS

**Last updated:** 2026-05-01

## Gate Status

| Gate | Description | Status |
|------|-------------|--------|
| 0 | Skeleton + SDK reference app | ✅ Done |
| 1 | MuseClient CI build + TestFlight upload | ✅ CI Done / 🔄 Device test pending |
| 2 | EEGPipeline (FFT band-power) + DepthScore | ⬜ Not started |
| 3 | UI flow | ⬜ Not started |
| 4 | Audio chimes + soundscapes | ⬜ Not started |
| 5 | Spotify integration | ⬜ Not started |
| 6–7 | Family TestFlight + polish | ⬜ Not started |

## Current Blocker (user action needed)
ASC TestFlight → Internal Testing → create group → add Apple ID → build 18 will appear on device.

## Last CI Run
- Run: 25211471748 (build 18) — **SUCCESS**
- Compiled, archived, uploaded to TestFlight ✓
- Runner: macos-15 (Xcode 26 / iOS 26 SDK)

## Key Config
- Bundle ID: `com.drchord.museplus`
- Display name: `Muse++`
- Framework: `Frameworks/Muse.framework` (fat static, arm64+x86_64)
- Device family: iPhone only (TARGETED_DEVICE_FAMILY=1)
- Deployment target: iOS 17.0

## Continuation Prompt (paste at next session start)

```
MusePlus iOS app — Muse S EEG meditation app. Project at C:\Users\sugat\MusePlus.

STATE: Gate 1 CI build succeeded (run 25211471748, build 18). Compiled with Xcode 26 on macos-15 runner, archived, uploaded to TestFlight. 

PENDING: User needs to confirm TestFlight install on physical device and verify EEG packets streaming (Gate 1 device test). If confirmed working, move to Gate 2: EEGPipeline.swift using vDSP FFT for band-power computation, DepthScore.swift, and calibration phase.

KEY FACTS:
- Framework: Frameworks/Muse.framework (fat static binary, embed:false)
- Transitive deps explicitly declared: CoreBluetooth.framework + libc++.tbd
- ObjC→Swift: all listener methods are receive(_:muse:), getMuses() is nonnull [IXNMuse]
- Enum cases: .EEG1/.EEG2/.EEG3/.EEG4, .chargePercentageRemaining, register as .hsi
- App name: Muse++ (ASC), CFBundleDisplayName: "Muse++"
- App icons: generated in CI by Python PNG writer (placeholder solid blue)
- TARGETED_DEVICE_FAMILY=1 (iPhone only)
- Deferred: SpotifyiOS.xcframework restore (Task 0.5)

Read STATUS.md and JOURNAL_MusePlus.md before doing anything.
```
