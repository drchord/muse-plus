# MusePlus — STATUS

**Last updated:** 2026-05-05

## Build State

| Build | Feature | TestFlight | Notes |
|-------|---------|-----------|-------|
| 40–44 | Crash fix → signal quality | ✅ Uploaded | See archived history |
| 45–49 | Chart/spectral fixes | ❌ Compile/upload limit | Never reached TestFlight |
| 50–51 | Full overhaul (audio + EEG + UI) | ✅ Uploaded | Build 50 = current TF baseline |
| 52 | feat(build51) first attempt | ❌ Compile fail | Accel enum `.x` → `.X` |
| 53 | feat(build51) fixed | ✅ Uploaded | CI run 25351592940 |
| 54 | docs-only re-upload | ✅ Uploaded | Same binary as 53; CI run 25351719451 |
| 55–64 | Build 65 feature development | ⚠️ Intermediate | Never device-tested; superseded by 65 |
| 65 | Build 65 feature set (all new features) | ✅ Uploaded | BROKEN — calibration stuck, spurious chimes |
| **66** | **Root cause fixes for Build 65 bugs** | ✅ **Pushed** | **Ready for CI — Build 66 = target TestFlight** |

**Current CI state:** Build 66 pushed to `main`. CI should be building now. Once uploaded, this is the first build with the full feature set AND working calibration.

---

## What Build 65/66 Contains (over Build 54)

### New EEG / Signal Features
1. **IRASA aperiodic slope (χ)**: `AperiodicSlope.swift` — PSD resampling at h-factors [1.1–1.9], geometric mean → fractalPSD, OLS in log-log space. Requires R² ≥ 0.85 to emit. Display: `χ -1.82` in MeditationView top bar (color-coded: green = deep, yellow = neutral, orange = aroused).
2. **iTPF Kalman tracker**: `ITPFTracker.swift` — log-parabola interpolation of theta peak Hz, cross-session Kalman filter with process noise 0.01 Hz². Displayed in Settings Biomarkers.
3. **8-channel Athena support**: `connectedMuseModel == .ms03` adds AUX1-4 channels. Preset 1041 (not preset 21) for Athena.
4. **Athena Optics heart rate**: `handleOptics()` uses OPTICS7/8 (850 nm inner channels) fed into same autocorrelation BPM pipeline as legacy PPG.
5. **SessionSample extended**: `heartRateBPM`, `faa`, `aperiodicSlopeMean`, `iTPFFrontal` — all Optional, Codable, back-compat with Build 54 JSON (decodeIfPresent).

### New Training Features (DepthGate + ChimeEngine)
6. **Conditioning anchor**: `playConditioningAnchor()` — 200/207 Hz binaural (7 Hz θ beat), fires 20s after entering deep state, once per episode, 5-min cross-episode cooldown. Pavlovian state anchor — brain learns to associate tone with absorption, speeds future induction.
7. **Binaural entrainment fade**: `binauralFadeLevel` [0…1] baked into `fillBinaural` amplitude. Decrements 5% (fast: first deep < 5 min) or 3% (slow) per qualifying session after 3 sessions. Trains independence from entrainment. Reset button in Settings.
8. **Beta-wander cue**: `playBetaCue()` — 1 kHz pure sine tick, 250ms, fires when `frontBeta > calibrationBetaMean + 1.5 * calibrationBetaStd` AND `depth.score < 0.3`. Additive log threshold (correct for log10 µV²). 30s minimum gap. Toggle in Settings.
9. **Adaptive deep threshold**: After ≥ 5 qualifying sessions, `enterThreshold` = 75th percentile of session mean depths, clamped [0.40, 0.85]. Bidirectional. Persisted to UserDefaults `adaptiveDeepThreshold`.

### Session Analytics (post-session)
10. **Session summary sheet**: `SessionSummarySheet` — auto-shown after disconnect if session was recorded. Duration, deep time, induction latency (vs. historical avg), longest deep, episode count, biomarkers (χ, iTPF), practice streak, coaching insight line.
11. **Practice streak**: `computeStreak` counts consecutive days with any session file. Displayed in summary and Settings.
12. **Induction latency comparison**: Historical avg from last 30 sessions (excluding current). Shows +/- % vs history if ≥ 20% difference.
13. **Recording deferred 300s after calibration**: `calibrationFiredRecording` flag. First calibration completion → DispatchWorkItem fires 300s later. Brain is noisy in early meditation; only capture settled state.

### Build 66 Fixes (this session — root causes, not patches)
14. **Calibration stuck (root cause)**: `handleIsGood` rate-limited to 1 event per 5s. Root cause: isGood fires at 10 Hz; poor frontal contact during 60s settle-in flooded `suppressWindows` perpetually → `onBandPowers` never fired → `calibrationProgress` stuck at 0 forever.
15. **Spurious contact chimes (root cause)**: `fitFirstReceived` replaced with `guard self.depth.isCalibrated`. `fitFirstReceived` only suppressed one packet; all subsequent fluctuations during calibration triggered chimes. Now silent until calibrated.
16. **Yellow dots when headband off**: `SignalChipsView.hsiLabel` now uses `< 2.0` = green (matches `allGood` threshold), `2.0–3.5` = orange, `≥ 3.5` = red. HSI=2 (mediocre/off-skin) previously showed yellow (misleading). `SignalQualityView` labels and colors aligned.

---

## Gate Status

| Gate | Description | Status |
|------|-------------|--------|
| 0 | Skeleton + SDK reference app | ✅ Done |
| 1 | MuseClient CI build + TestFlight | ✅ Done |
| 2 | EEGPipeline FFT band-power + DepthScore | ✅ Done |
| 3 | UI flow (depth badge, band chart, signal quality) | ✅ Done |
| 4 | Audio (chimes + soundscapes + timer) | ✅ Done |
| 5 | Spotify Web API + PKCE | ✅ Code done / needs device test |
| 6 | Session recording + export | ✅ Done |
| 7 | Auto-reconnect + idle timer | ✅ Done |
| 8 | Mind Monitor chart + spectral peaks | ✅ Done |
| 9 | IRASA + iTPF biomarkers | ✅ Done (Build 65) |
| 10 | Training system (anchor + fade + beta cue + adaptive threshold) | ✅ Done (Build 65/66) |
| 11 | Athena 8ch + Optics HR | ✅ Done (Build 65) |
| 12 | Session analytics + summary sheet | ✅ Done (Build 65) |
| 13 | fNIRS OpticsPipeline (HbO/HbR) | ⏳ Next — Build 67 |

---

## Key Config

- Bundle ID: `com.drchord.museplus`
- Display name: `Muse++`
- Version: `1.2.0` (MARKETING_VERSION)
- Build number: `github.run_number` (CI auto-increment)
- Framework: `Frameworks/Muse.framework` (fat static, arm64+x86_64, embed:false)
- Device family: iPhone only (TARGETED_DEVICE_FAMILY=1)
- Deployment target: iOS 17.0
- Bluetooth perm: NSBluetoothAlwaysUsageDescription
- Background modes: bluetooth-central, audio
- Files app: UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace

---

## Critical Architecture Notes

- **AVAudioEngine format**: ChimeEngine = stereo (own engine, safe). SoundscapePlayer = stereo (`channels:2`, explicit). `format: nil` causes crash after BT route change.
- **Config change handler**: `asyncAfter(0.5s)` delay required in `AVAudioEngineConfigurationChange` notification.
- **Binaural beat**: `beatHz` captured on main thread before background dispatch (race condition fix).
- **BandPowers struct field order**: `delta,theta,alpha,beta,gamma` then `deltaPeak,thetaPeak,alphaPeak,betaPeak,gammaPeak` — init call must match exactly.
- **chartForegroundStyleScale**: use `domain:/range:` overload with arrays, not `[String:Color]` dict.
- **Frontal channels**: AF7=ch1 (idx1), AF8=ch2 (idx2) for depth scoring and FAA.
- **DepthGate**: EMA α=0.20, 10s sustain (kEnterSustained=20) to enter deep, 10s to exit, 90s cooldown.
- **NotchFilteredEeg + .eeg fallback**: `hasNotchEeg` flag. Prefers `.notchFilteredEeg`; falls back to `.eeg` if Athena never emits notch packets.
- **IsGood rate limit**: `lastQualitySuppression` — 5s gate. CRITICAL: without this, settle-in floods `suppressWindows` and blocks calibration forever.
- **Contact chimes gate**: `guard self.depth.isCalibrated` in fitCheck sink. `fitFirstReceived` was WRONG — only suppressed first packet.
- **Athena preset**: `preset1041` for MS-03. `preset21` for all legacy Muse S/2. Applied AFTER first `.connected` (post-model detection). Preset change triggers reconnect cycle — this is expected.
- **AUX1-4**: only appended to channels array when `connectedMuseModel == .ms03`. Amplitude rejection still only on first 4 channels.
- **Beta cue threshold**: `bm + 1.5 * bs` (additive). Do NOT use multiplicative (`2.0 * mean`) — wrong in log domain when bm is near zero or negative.
- **Binaural fade**: baked into `fillBinaural` amplitude, NOT node volume. Node volume should stay at user-set value.
- **Adaptive threshold lower bound**: 0.40 (not 0.55). 0.55 was too high for beginners; 0.40 allows bidirectional adaptation.
- **PPG heart rate**: queue-serialized buffer. AMBIENT = Green on Muse S 2019. Autocorrelation BPM (lag 19–128 at 64 Hz = 200–30 BPM). AC/power > 0.20 quality gate.
- **Accelerometer enum bridging**: `.X`, `.Y`, `.Z` uppercase. `.x/.y/.z` fails ("type has no member").
- **iCloud entitlement**: `iCloud.com.drchord.museplus` in Apple Developer Portal + MusePlus.entitlements.

---

## Plan Forward — Build 67+

### Build 67: fNIRS OpticsPipeline
**Goal**: Extract HbO/HbR from Athena Optics channels; store in SessionSample (already has placeholders: `hboL/hboR/hbrL/hbrR`). Display HbO/HbR in Settings Biomarkers section.

**Scope:**
- `OpticsPipeline.swift` — modified Beer-Lambert on Optics1-6 (750 nm / 850 nm wavelength pairs), bandpass 0.01–0.2 Hz, compute oxyhemoglobin (HbO) and deoxyhemoglobin (HbR) per channel
- `EEGPipeline.onOpticsUpdate` callback → `Probe.hboL/hboR/hbrL/hbrR`
- Display in `MeditationView` top bar (collapsed, like χ) and Settings Biomarkers
- Only emits on Athena; legacy Muse S/2 sees nil

**Prerequisites**: Build 66 must confirm calibration working on device. DO NOT push Build 67 until Build 66 confirmed.

### Build 68: Spotify device test + HRV (if fNIRS stable)
- Spotify flow needs actual device test (muse-monitor://callback registered in Spotify dev dashboard)
- HRV (RMSSD) from RR intervals derived from PPG/Optics beat-to-beat — requires R-peak detector on cleaned PPG

### App Store Submission
See Phase 1–5 checklist below. Not urgent — wait for fNIRS and HRV to stabilize (~Build 68–70).

---

## App Store Submission Checklist

### Phase 1 — Prepare
1. Stable TestFlight: 1–2 weeks of daily use, no crashes
2. Privacy policy: host on GitHub Pages (app stores sessions on-device only)
3. Screenshots: 6.7" (1290×2796) and 6.5" (1242×2688) — at least 3 per size
4. App icon: 1024×1024 PNG (no alpha)
5. Demo mode: graceful "no device" state for App Store reviewers without a Muse

### Phase 2–5
See previous STATUS.md version for full App Store Connect walkthrough steps.

---

## Continuation Prompt

```
MusePlus iOS app — Native Swift/SwiftUI EEG meditation companion for Muse S / Athena.
Project: C:\Users\sugat\MusePlus. Git remote: drchord/muse-plus.

CURRENT STATE (2026-05-05):
- Build 66 pushed to main. CI building. Fixes calibration stuck + spurious chimes + yellow dots.
- Build 65 in TestFlight (BROKEN — calibration never progresses, random chimes).
- Once Build 66 CI completes → install on device → verify calibration completes in ~60s → no chimes during calibration.

BUILD 66 CONTAINS (complete feature set):
All of Build 54 PLUS:
- IRASA aperiodic slope χ (AperiodicSlope.swift) + iTPF Kalman tracker (ITPFTracker.swift)
- Athena 8-channel EEG (preset1041) + Optics heart rate (OPTICS7/8)
- Conditioning anchor (7 Hz binaural θ, 20s after deep entry, Pavlovian)
- Binaural entrainment fade (binauralFadeLevel, 5%/session after 3 sessions)
- Beta-wander cue (1 kHz tick, +1.5 SD frontal β, shallow only)
- Adaptive deep threshold (75th pct qualifying sessions, [0.40, 0.85])
- Session summary sheet (post-disconnect: duration, deep time, latency, streak, coaching)
- Recording deferred 300s after calibration
- handleIsGood rate-limited 1 event/5s (calibration fix)
- Contact chimes gated behind isCalibrated (spurious chime fix)
- Dot colors: green=HSI<2.0 / orange=2.0-3.5 / red=≥3.5 (yellow removed)

KEY FILES CHANGED IN BUILD 65/66 vs BUILD 54:
App.swift, MuseClient.swift, DepthGate.swift, DepthScore.swift, ChimeEngine.swift,
SoundscapePlayer.swift, SessionRecorder.swift, MuseTypes.swift,
AperiodicSlope.swift (new), ITPFTracker.swift (new)

CRITICAL INVARIANTS (break = crash or broken calibration):
- handleIsGood MUST stay rate-limited (lastQualitySuppression 5s). Remove it → calibration stuck forever.
- Contact chimes MUST be gated behind depth.isCalibrated. fitFirstReceived was the old WRONG fix.
- Beta cue: additive threshold (bm + 1.5 * bs), NOT multiplicative.
- Binaural fade: baked into fillBinaural amplitude, NOT node volume.
- Athena preset: preset1041 for MS-03. preset21 for legacy. Applied post-model-detection.

NEXT BUILD (67): fNIRS OpticsPipeline — HbO/HbR from Athena Optics1-6.
RULE: Do not push Build 67 until Build 66 calibration confirmed working on device.

Run `gh run list --limit 5` first. Read STATUS.md before any work.
```
