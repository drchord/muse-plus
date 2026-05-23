# MusePlus — STATUS

**Last updated:** 2026-05-23 (B122 — 9 new footer fields + NDJSONGateEvent + FAABarView color/label fix: negative FAA now green "depth zone", consistent with WarmupFAAReadiness empirical calibration)

---

## Build State

| Build | TF# | Theme | Status |
|-------|-----|-------|--------|
| 40–83 | — | Foundation → soundscape → HRV → ECDF → instrumentation | ✅ Historical |
| **86** | — | Layout fix attempt 1 (GeometryReader — flawed) | ✅ Superseded by B89 |
| **87** | — | Unified timers, touch targets, fit-event HSI | ✅ Stable baseline |
| **88** | — | frontalContactGood rename, adaptive threshold, Spotify row, JSON scalars | ✅ |
| **89** | — | ScrollView layout fix | ✅ CI run 25615473857 |
| **90** | — | Gong floor 0.85, drone partial fix, chime preview, anchor tone label | ✅ CI run 25618431186 |
| **92** | — | Bowl audio fix, drone race fix (isStopping), proximity duck, depth trace chart | ✅ |
| **94** | — | Kalman depth filter, FAA flow state, iTPF binaural, quality score, forecast, TrendsView | ✅ |
| **95** | — | Deep-state volume overhaul (deepStateGain), crash data preservation, 7 audio bugs | ✅ |
| **96** | — | Church bell gong, alphaPowerRatio live, trajectory coaching, rmssdDepthDelta, NSFileCoordinator, kEnterSustained UserDefault | ✅ |
| **97** | 101 | Gong subdirectory lookup fix, NDJSON footer biomarkers fix, SwiftUI type-checker extraction | ✅ |
| **99** | 103 | mainBeta/Alpha/Theta band means, warmupFAAMean, rmssdDepthDelta wire-in | ✅ |
| **100** | 104 | warmup FAA tracking, calibrationIndexMean wire-in improvements | ✅ |
| **103** | 106 | Spotify depth-responsive volume (6 bugs fixed) | ✅ |
| **107** | 112 | HRV scalars (SDNN/SD1/SD2/DFA α1), physiologicalScore, BLE resilience, TrendsView expansion | ✅ Session 2026-05-18: deepFraction=0.836 |
| **108** | 115 | physiologicalScore rmssdScore fix, NDJSON calibration data export, betaZScore telemetry, 3 new TrendsView charts | ✅ Session 2026-05-19: physScore=47, deepFraction=0 (signal oscillatory, gate correct) |
| **109** | 116 | calibrationBeta ordering fix, scoreComponents export, disconnect HRV attach, grace-expired diagnostics, fitsPerMin fix | ✅ Session 2026-05-20 (motivated B118 analysis — see B118 section) |
| **109** | 116 | calibrationBeta ordering fix, scoreComponents export, disconnect HRV attach, grace-expired diagnostics, fitsPerMin fix | ✅ CI run 26092291419 |
| **118** | 118 | F1 dynamic buildTag (from CFBundleVersion), F2 HR absolute bounds [35,120] + reject counter, F3 forceFinalize → calibrationSummary NDJSON record, F4 calibrationBetaAttached flag in footer, F5 unconditional calibrationBeta Telemetry, F6 faaConvention "af8-af7" in footer + DepthScore comment, F9 metricDefinitions dict (31 formulas with SOURCE cites) in footer, C5 NDJSONCoach + recordCoach() at 8 trigger sites (foundation for B119+ state-contingent coaching) | 🟡 CI run 26158572518 — first attempt 26158289551 failed on ambiguous queue.sync (String.init overload); fix pushed |
| **119** | 120 | Remove Documents/Sounds fallback from EndGongPlayer.bundleURL() — ChimeEngine is now primary fallback for success/failure gong. Remove BowlAudioGenerator.generateIfNeeded() from App init. Long sessions (≥15 min) ending via BLE grace-expiry now receive playSuccess() instead of playFailure(). | ✅ Session 2026-05-22: NDJSON generated but JSON missing (save() bug fixed in B120) |
| **120** | — | (1) Fix `save()` + `CrashRecovery` file protection: `.completeFileProtection` → `.completeFileProtectionUnlessOpen`. (2) Fix `synthesiseRecord()`: decode full NDJSONFooter → 19 biomarkers on crash-recovery. (3) Fix `attachCalibrationBeta` guard: `isRecording` → `current != nil` — root cause of betaZScore=0 every session. (4) Add `sdnn`/`sd1`/`sd2` to NDJSONFooter + `appendFooter()` + `synthesiseRecord()`. (5) Git config: user.name → "Sugato Chakravarty". | 🔴 Pending CI push |
| **121** | — | Temporal contact gate: `doConnect()` defers `startCalibration()` until TP9 + TP10 `hsiStableTier` both ≤ 2 (not-bad, 4-of-5 majority). 15s timeout force-starts calibration if HSI never arrives (firmware/SDK variant). Only TP9/TP10 buffers reset on connect (AF7/AF8 unchanged). `FitStabilityBannerView` shows tier-colored dots + "Seat TP9 + TP10 to begin" while blocked. | ✅ B121 session confirmed: betaZScore=50, calibrationBetaAttached=True, sdnn/sd1/sd2 present, rmssdDepthDelta=+5.64, physiologicalScore=97 |
| **122** | — | (1) `betaZRaw` in footer: unclipped bz before clamping (B121 bz=5.1 masked by score ceiling=50). (2) Signal quality in footer: `signalQualityMeanSpikes`, `signalQualityAlphaPowerRatio`, `potatoFlaggedPct` from denoiseStats accumulator — B121 had 33.3 spikes/frame (5.6× B120) previously invisible in JSON. (3) Relative band power in footer: `alphaRelMean`, `thetaRelMean`, `betaRelMean` (calibration-independent; B121 showed contradictory absolute depth vs relative band power). (4) ecdf peak diagnostics: `ecdfMax`, `ecdfP90` — B121 reached 0.944 max, never sustained for inDeep trigger. (5) `NDJSONGateEvent` record (path=cleared/timeout, tp9Tier, tp10Tier) — gates B121-style were OSLog-only, now in NDJSON. `pendingGateEvents` buffer for pre-session fires. (6) `FAABarView` color + label fix: dot was green for positive FAA (Davidson "approach"), orange for negative. For Sugato negative FAA predicts depth (r=-0.76, n=8). Now green=negative="depth zone", orange=positive="arousal". Consistent with WarmupFAAReadiness which already correctly used green for faa≤-0.08. | 🔴 Pending CI push |

---

## B119 Changes (2026-05-21) — TF build 120

### Motivation — Documents/Sounds fallback was masking real audio path

`BowlAudioGenerator.generateIfNeeded()` wrote `Documents/Sounds/bowl_success.wav` at every launch. `EndGongPlayer.bundleURL()` always found it and returned it **before** reaching the ChimeEngine fallback. Result: 20+ builds of the synthesized mono WAV (grating overtones, no sustained fundamental) instead of ChimeEngine stereo gong synthesis. The bundled `.m4a`/`.mp3` (real recording) was being bypassed entirely.

### Changes

| Tag | File | Change |
|-----|------|--------|
| G1 | `App.swift` (init) | Removed `BowlAudioGenerator.shared.generateIfNeeded()` — no longer generates synthesized WAV at launch |
| G2 | `EndGongPlayer.swift:bundleURL()` | Removed Documents/Sounds branch — lookup is now Bundle root → Bundle Sounds/ subdirectory → nil |
| G3 | `App.swift:performFinalDisconnect` | Sessions ≥15 min that end via BLE grace-expiry now call `playSuccess()` instead of `playFailure()`. Gate: `recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 >= 900` |

### B119 Validation Checklist

1. Session-end gong is ChimeEngine 432 Hz synthesis (or bundled .m4a if present) — NOT a synthesized WAV with grating overtones.
2. `EndGongPlayer` Telemetry shows "synth:ChimeEngine-432Hz" in source field (not "Documents/Sounds").
3. Long session (≥15 min) ending via BLE disconnect → success gong (not 5 alert pings).
4. Short/accidental disconnect (<15 min) → failure chime (5 alert pings unchanged).

### Known issue from 2026-05-22 session on TF120

**B120 session (session_2026-05-22_0340) produced NDJSON but no JSON.** Possible causes:
- `save()` in `SessionRecorder` caught a write error silently — `NSFileCoordinator` may behave differently with Google Drive Files.app provider vs iCloud
- OR: session ended via a path that hit `playSuccess()` before `endSession()`, and ChimeEngine had an audio session conflict

**Root cause confirmed (2026-05-22)**: `_type: "footer"` IS present in NDJSON — `endSession()` completed. All final samples show `appState: "background"`. Timer fired at t=3600s while iPhone screen was locked. `save()` used `.completeFileProtection` which iOS blocks on locked devices. NDJSON survived because it uses `.completeFileProtectionUnlessOpen`. Error was silently caught; JSON never written.

**Fix shipped in B120**:
- `SessionRecorder.save()` now uses `.completeFileProtectionUnlessOpen` (Apple docs: "files with this class may be created while the device is locked")
- `CrashRecovery.swift:73` also fixed (same bug, different location)
- `synthesiseRecord()` now decodes full `NDJSONFooter` to recover physiologicalScore, HRV scalars (rmssd, dfaAlpha1, calibrationRmssd), betaZScore/rmssdScore/coherenceScore, calibrationBeta fields, faaConvention, timeOfDay — previously these were all nil in crash-recovered JSONs

**sdnn/sd1/sd2**: Added to `NDJSONFooter`, `appendFooter()`, and `synthesiseRecord()` footer-decode block in B120. No longer lost on crash recovery.

**Data recovery now**: Launch app on iPhone → `CrashRecovery.recoverOrphans()` synthesizes JSON from NDJSON with full biomarkers (B120 fix). JSON should appear in Google Drive within ~30s.

**Unconfirmed**: Root cause is the strongest-supported hypothesis (footer present = endSession() ran; appState=background = likely locked; .completeFileProtection blocks new file creation when locked). Cannot confirm without the Telemetry log entry "SAVE FAILED for session_2026-05-22_0340.json: ..." from the iPhone Console.

**Session 2026-05-22 data (from NDJSON footer)**: physScore=46 (rmssd=26, coherence=20, betaZ=0), qualityScore=77, rmssd=75ms, dfaAlpha1=0.566, meditationIndexCorrelation=0.93, calibrationIndexMean=−0.42 (strong calibration), episodeCount=1 (sustained deep state), endReason=timer-completed, 60-minute session. betaZScore=0: root cause found and fixed in B120 — `attachCalibrationBeta()` guard was `isRecording` but `startSession()` sets `isRecording=true` via `DispatchQueue.main.async`. The `onResult` callback runs on a background thread (line 744 in App.swift), not main. The background thread immediately calls `attachCalibrationBeta()` → `queue.sync { guard isRecording }`. That serial-queue closure executes synchronously and completes before the pending `DispatchQueue.main.async { isRecording = true }` fires (main.async needs a run-loop cycle; queue.sync runs immediately). Race condition that consistently loses: `isRecording=false` in the closure → guard fires → calibrationBetaMean never written → betaZ=0 every session since B107. Fix: guard now checks `current != nil` (set synchronously in `startSession()`'s `queue.sync` before the async dispatch).

### B120 Architecture Invariants

- `attachCalibrationBeta()` guards on `current != nil`, NOT `isRecording`. `isRecording=true` is dispatched `DispatchQueue.main.async` in `startSession()`. Since `scorer.onResult` fires on a background thread, the immediately subsequent `queue.sync` in `attachCalibrationBeta()` runs before main has a chance to process the async — `isRecording` is still false, guard fires, calibrationBeta silently discarded every session since B107. `current` is set synchronously inside `startSession()`'s `queue.sync`, making it the correct gate.
- `NDJSONFooter` now includes `sdnn`, `sd1`, `sd2`. If you add a new HRV scalar to `SessionRecord`, add it to `NDJSONFooter` + `appendFooter()` + `synthesiseRecord()` footer-decode block simultaneously — otherwise it's lost on crash recovery.
- `.completeFileProtectionUnlessOpen` for all file writes. `.completeFileProtection` (Class A) blocks new file creation on locked devices — NDJSON survives because the file handle is opened while the device is unlocked; `.completeFileProtection` on `save()` prevented JSON creation when timer fired with locked screen.

### B119 Architecture Invariants

- `EndGongPlayer.bundleURL()` no longer has a Documents/Sounds branch — add bundled audio files via Xcode resource target, not BowlAudioGenerator.
- `ChimeEngine.shared.playGong()` is the authoritative fallback for success gong; `ChimeEngine.shared.playFailureChime()` for failure. Both fire-and-forget.
- `performFinalDisconnect` success-vs-failure gong gate: `recordingStartedAt` elapsed time ≥ 900s. Called BEFORE `endSession()` in this path — crash in gong path = no JSON. Monitor.

---

## B118 Changes (2026-05-20)

### Motivation — first B109 session analysis (session_2026-05-20_0338.json, 58.8 min)

Sugato ran B109 TF116 for ~1 hour. Deepdive analysis surfaced multiple defects in current observability AND interpretation backward in the codebase. Key findings:

- `buildTag: "B109"` hardcoded literal — stale across builds, can't tell which binary produced a session
- `betaZScore = 0` AGAIN (despite B109 ordering fix). Root cause traced to time-race: `isCalibrated` is a computed property based on wall-clock; `finalizeBaseline()` only runs on next band-power sample (~500ms latency); warmup→main UI timer can fire before that sample arrives → `calibrationBetaMean` stays at default `0.0` → `bz` formula clamps to 0
- No `calibration` phase emitted to NDJSON → post-hoc tooling cannot tell if calibrationBeta was real or default
- FAA convention undocumented in JSON — my analysis initially misread mid-session FAA jump as "positive affect" when codebase empirically labels positive FAA as the "caution / left-frontal arousal" caution range (r=-0.76 with deepFraction)
- HR PPG spikes >120 BPM and <35 BPM slipped through first-2-sample warmup of rolling-median filter
- Coaching events (`induction-stall-360/600/900`) fire `recordEvent` but log no diagnosis, no speech text, no EEG/HRV state at trigger — cannot test "did this intervention work" post-hoc
- SD1>SD2 anomaly in HRV (70.1 > 61.1) suggests PPG noise/ectopics may inflate RMSSD — flagged but NOT fixed in B118 (offline validation required first)

### Fixes shipped in B118

| Tag | File | Change |
|-----|------|--------|
| F1 | `SessionRecorder.swift:~366` | `static let currentBuildTag` now reads `Bundle.main.infoDictionary["CFBundleVersion"]` → `"B\(version)"` |
| F2 | `App.swift:~1215` | `filteredHeartRate()` rejects raw BPM outside `[35, 120]` BEFORE buffer accumulation; `hrSamplesRejected` counter on Probe + in `SessionDiagnostics` |
| F3 | `App.swift:1010` + `DepthScore.swift:128` | `forceFinalize()` called BEFORE `startSession` so `calibrationBetaMean/Std` are real values, not defaults |
| F3 | `SessionRecorder.swift:204` + `App.swift:1022` | `NDJSONCalibrationSummary` record emitted at warmup→main transition with mean/std/sampleCount/durationSec |
| F4 | `SessionRecorder.swift:1493` | `calibrationBetaAttached: Bool?` flag in footer — true if `attachCalibrationBeta` got non-default values |
| F5 | `SessionRecorder.swift:1487` | Telemetry log moved OUTSIDE `isRecording` guard — always logs attempt+result |
| F6 | `DepthScore.swift:~83` + `SessionRecorder.swift:478` | FAA convention comment at compute site + `faaConvention: "af8-af7"` literal in footer |
| F9 | `SessionRecorder.swift:1085` | `metricDefinitions: [String: String]` dict in footer (31 metrics with `SOURCE=file:line` cites) |
| C5 | `SessionRecorder.swift:218,226,1523` + `App.swift` (8 sites) | `CoachStateSnapshot` + `NDJSONCoach` record + `recordCoach(...)` method + `coachSnapshot()` helper; wired at warmup-faa-readiness, approach-zone, enter-deep, return-nudge, exit-deep-speech, induction-stall-360/600/900 |

### B118 Validation Checklist (post-CI green, on TF install)

1. Footer field `buildTag` reads `"B118"` (NOT `"B109"`). If `"B1"`, F1 fallback path triggered — CI didn't set `CURRENT_PROJECT_VERSION`.
2. `_type: "calibrationSummary"` record present at ~300s (warmup→main transition) with non-zero `calibrationBetaMean`.
3. Footer `calibrationBetaAttached: true`.
4. Footer `betaZScore > 0` if `mainBetaMean < calibrationBetaMean` (which it should be for any decent meditation session).
5. Footer `faaConvention: "af8-af7"` + `metricDefinitions` dict (31 keys, each with `SOURCE=...` annotation where verified).
6. Diagnostics `hrSamplesRejected` field present (may be 0 if PPG was clean this session).
7. At least one `_type: "coach"` record per induction-stall event (if user doesn't enter deep).
8. Each coach record has `stateAtTrigger.ecdfDisplay`, `.beta`, `.faa`, `.heartRateBPM` populated.

### Deferred to B119+ (intentionally NOT in B118)

- **F8 ectopic-RR filter** — needs offline validation against historical sessions before going live (could change scores)
- **C1 state-contingent coaching triggers** — replaces 360/600/900s timers with EEG-state-driven triggers. Needs B118 coach log to baseline current behavior first.
- **C2 differential diagnosis enum** — per-stall reason (highArousal vs overEfforting vs drowsy vs avoidant) → different intervention. Build on C5 log.
- **C3 positive anchoring** — soft tone when `ecdfDisplay ≥ 0.80` sustained ≥3 samples. Anchors near-miss states.
- **C4 post-session teacher paragraph** — generated narrative summarizing best window, blockers, what worked.
- **coachSnapshot side-effect fix** — currently calls `filteredHeartRate()` which mutates buffer. Pure-read helper needed.
- **hrSamplesRejected per-session reset** — counter persists across sessions; needs reset in calibration-end block.
- **6 unverified metricDefinitions formulas** — `rmssdDepthDelta`, `dfaAlpha1`, `sdnn`, `iTPFFrontal`, `aperiodicSlopeMean`, `qualityScore` cite source files but I did not read those source files end-to-end.

### B118 Architecture Invariants

- buildTag is dynamic; never hardcode again.
- All coaching interventions MUST go through `recordCoach()` so future A/B analysis can measure efficacy.
- `metricDefinitions` is authoritative; if a formula changes in code, update the dict in the SAME commit.
- `calibrationBetaAttached: false` in any session footer = DepthScore.forceFinalize() failed (no calibration samples). Treat that session's betaZScore as void.

---

## B109 Changes (2026-05-19)

### What motivated this build — first B108 session analysis (session_2026-05-19_0340.json)

#### Bugs confirmed from data
- **calibrationBetaMean always nil** (every session since B107): `attachCalibrationBeta` was called before `startSession` → `isRecording=false` → guard blocked it → betaZScore=0 always. B108 physScore=47 was 26pts rmssd + 20pts coherence + 0pts betaZ.
- **fitsPerMin=0 in diagnostics**: `recordingStartedAt=nil` at line 374 (non-grace disconnect) and line 1378 (performFinalDisconnect) before `buildDiagnostics` → `sessionMin=0` → `fitsPerMin=0/0=0`.
- **performFinalDisconnect missing diagnostics entirely**: No `buildDiagnostics`, no `attachEventStream`, no HRV attachment block before `endSession`. Grace-expired sessions had skeletal JSON.
- **Non-grace disconnect missing HRV attachment**: `attachEnterThreshold`, `attachHRVScalars`, `attachCalibrationRmssd`, `attachDFAAlpha1` not called → dfaAlpha1/sdnn/sd1/sd2 nil in every disconnect-ended session.
- **scoreComponents not exported**: betaZScore/rmssdScore/coherenceScore were local Float vars only. Score decomposition unverifiable post-hoc.

#### deepFraction=0 root cause (NOT a bug)
Signal was oscillatory — raw ecdfDisplay max=0.9545 but longest consecutive run above 0.65 = 12 windows (6s). Gate requires 20 windows (10s). Historical data: all 4 deep sessions had lr@0.65 ≥ 39. Gate worked correctly. No fix needed.

### Changes

#### Fix 1 — calibrationBeta ordering (`App.swift`, calibration-end block)
- Moved `attachCalibrationBeta` and its Telemetry log from BEFORE `startSession` to AFTER.
- Root cause: `isRecording` guard in `attachCalibrationBeta` blocked every call since the value was always set pre-recording.
- Effect: betaZScore will be non-zero for the first time in B109+.

#### Fix 2 — fitsPerMin ordering (non-grace disconnect path, `App.swift`)
- Moved `recordingStartedAt = nil` to AFTER the `buildDiagnostics` block.
- `buildDiagnostics` computes `sessionMin` from `recordingStartedAt`; clearing it first → `sessionMin=0` → `fitsPerMin=0`.
- Also fixed endReason string in `buildDiagnostics` call: `"disconnect-grace-expired"` → `"disconnect"`.

#### Fix 3 — performFinalDisconnect diagnostics (`App.swift`)
- Added full attachment block before `endSession`: `attachDiagnostics(buildDiagnostics)`, `attachEventStream`, full HRV block.
- Moved `recordingStartedAt = nil` to after `buildDiagnostics` (same ordering fix as Fix 2).
- Grace-expired sessions now get the same richness as graceful-end sessions.

#### Fix 4 — HRV attachment on disconnect paths (`App.swift`, both paths)
- Added `attachEnterThreshold`, `attachHRVScalars`, `attachCalibrationRmssd`, `attachDFAAlpha1` to non-grace path and performFinalDisconnect.
- Previously these only fired on the graceful end path (lines 1150-1168). All non-graceful ends had nil dfaAlpha1, sdnn, sd1, sd2.

#### Fix 5 — scoreComponents export (`SessionRecorder.swift`)
- Changed `computePhysiologicalScore` return type from `Int` to `(total: Int, betaZ: Int, rmssd: Int, coherence: Int)`.
- Added `betaZScore`, `rmssdScore`, `coherenceScore` fields to `SessionRecord` and `NDJSONFooter`.
- Updated `appendFooter` to pass all three components.
- Effect: post-hoc score audits no longer require Console access.

### B109 Validation Checklist
1. Console after calibration: `B109 calBeta mean=X.XXX std=X.XXX` (MUST be non-nil for betaZScore to work).
2. Session JSON footer contains `betaZScore`, `rmssdScore`, `coherenceScore` (check .ndjson file).
3. `physiologicalScore` ≈ betaZScore + rmssdScore + coherenceScore (within 1pt rounding).
4. For a session ending via disconnect: `dfaAlpha1`, `sdnn`, `sd1`, `sd2` must be non-nil in NDJSON footer.
5. `fitsPerMin` > 0 in diagnostics for any session with fit events.

### B109 Architecture Invariants

**B109+:**
- `attachCalibrationBeta` must always be called AFTER `startSession`. ~~Guard depends on `isRecording=true`~~ — B120 fix: guard now checks `current != nil` (isRecording was set async on main, causing guard to always fire).
- `recordingStartedAt` must not be nil before `buildDiagnostics` — clear it only after the diagnostics block.
- All session-end paths (graceful, disconnect, grace-expired) now carry the full HRV attachment block.
- `computePhysiologicalScore` returns a 4-tuple; call site must populate all four fields on `SessionRecord`.

---

## B108 Changes (2026-05-18)

### What motivated this build — data analysis of 19 sessions (2026-05-02 to 2026-05-18)

Full analysis artifacts: `C:\Users\sugat\MusePlus\analysis\` (sessions_extracted.csv, progress_dashboard.png, findings.md)

#### Key patterns found
- **deepFraction is bimodal:** sessions produce either 0.000 or 0.66–0.93. No middle ground.
- **4 of 8 zero-deep sessions were instrumentation failures, not meditation failures:**
  - B95 (2026-05-13): kEnterSustained=20 (10s required); session max run was 2.5s → gate never fired
  - B100 (2026-05-16): calibrationIndexMean≈0 → no theta/alpha baseline established
  - B103 (2026-05-17): BLE dropout 34.2s at t=33.7min killed session (packetGapMax=34.17s)
  - B87 (2026-05-10): same build produced 0.847 earlier that day; cause unknown
- **calibrationIndexMean predicts outcome** (r²=0.84, n=8): sessions with cal > −0.20 produced deepFraction=0 in 3/3 cases; cal < −0.20 → deepFraction 0.66–0.93. Treat as a signal, not a hard gate (sample too small for validated threshold).
- **physiologicalScore=20 was not a bug** — the relative rmssdScore formula scored 0 because calRmssd=97.3ms > sessRmssd=80.7ms. The arousal/anticipation spike at calibration start elevated RMSSD; relaxation during session normalized it downward. The formula interpreted this as "no HRV improvement" despite 80.7ms being elite in absolute terms.
- **betaZScore likely 0 by nil** — calibrationBetaMean was captured in-memory but not exported to NDJSON footer, so it cannot be verified retroactively. betaZScore has contributed 0 pts to every physiologicalScore ever recorded.
- **Kalman freeze already exists** for frontal contact loss (DepthGate.swift:144). BLE dropout is handled differently (no packets = gate stops updating = last state persists implicitly). My initial recommendation to "add Kalman freeze on BLE dropout" was wrong — it already works.
- **qualityScore contact component uses frontalGoodFraction** (AF7/AF8), not temporal sensors (TP9/TP10). TP9/TP10 noise does NOT penalize qualityScore. Earlier claim that "TP9/TP10 killing quality score" was factually wrong.
- **kEnterSustained is already tunable**: `UserDefaults.standard.set(X, forKey: "kEnterSustainedWindows")` via debugger, range 6–24. No build needed.

### Changes

#### 1. physiologicalScore: absolute RMSSD scoring (`SessionRecorder.swift:computePhysiologicalScore`)
- **Old:** `response = (sessRmssd - calRmssd) / calRmssd` — relative improvement formula. Scored 0 when calRmssd > sessRmssd.
- **New:** Absolute thresholds from Shaffer & Ginsberg (2017): <40ms=0-10pts, 40-65ms=10-25pts, 65-100ms=25-30pts, >100ms=30pts.
- **Effect on B107 session:** rmssdScore goes from 0 → ~27 (sessRmssd=80.7ms). physiologicalScore goes from 20 → ~47 (assuming betaZScore still 0 pending investigation).
- **Invariant:** `calibrationRmssd` field kept in NDJSONFooter for historical comparison; just no longer drives the score.

#### 2. Export calibration beta to NDJSON footer (`SessionRecorder.swift:NDJSONFooter + appendFooter`)
- Added `calibrationBetaMean: Float?`, `calibrationBetaStd: Float?`, `calibrationIndexMean: Float?` to NDJSONFooter.
- Populated from `rec.calibrationBetaMean`, `rec.calibrationBetaStd`, `rec.calibrationIndexMean`.
- **Why:** calibrationBetaMean was captured in-memory (B107) but never written to JSON. betaZScore inputs have been unverifiable for every session since B107. `TrendRecord` in TrendsView already had the field parsed — it was always nil because the footer lacked it.
- **calibrationIndexMean export:** was in NDJSONHeader only. Now also in footer → TrendsView can chart it across sessions (key predictor metric).

#### 3. betaZScore diagnostic telemetry (`App.swift`)
- Added `Telemetry.recording.notice` after `attachCalibrationBeta` call.
- Logs whether `calibrationBetaMean` and `calibrationBetaStd` are nil or populated at calibration end.
- **Action on next session:** Check Console (category `Telemetry.recording`) after calibration fires. If nil → scorer.calibrationBetaMean is not being set; track down in DepthScore/EEGWindowBuffer. If non-nil → betaZScore actually computed; cross-check with physiologicalScore.

#### 4. TrendsView: 3 new chart sections (`TrendsView.swift`)
- **MI/Depth Correlation (r):** charts meditationIndexCorrelation over time. r < 0.4 = EEG/depth mismatch → calibration drift. Field existed in TrendSession but was never displayed.
- **Calibration Baseline (ECDF Index):** charts calibrationIndexMean over time. Includes dashed reference line at −0.20 (empirical threshold from 8-session dataset — labeled as signal, not gate). Critical for monitoring pre-session brain state quality.
- **Beta Suppression:** charts `calibrationBetaMean - mainBetaMean` per session. Positive = beta decreased during session (expected during deep state). Exposes whether betaZScore ever had real inputs.
- All three sections are conditional (`contains(where:)`) — hidden until data accumulates.

---

## B108 Validation Checklist

1. Console after calibration: `B108 calBeta mean=X.XXX std=X.XXX` (not nil). If nil, investigate `scorer.calibrationBetaMean` population.
2. Session end → `physiologicalScore` in JSON > 20 for sessions with RMSSD > 65ms.
3. Session JSON footer contains `calibrationBetaMean`, `calibrationBetaStd`, `calibrationIndexMean` fields.
4. TrendsView shows "Calibration Baseline" section after first B108 session.
5. TrendsView shows "MI/Depth Correlation" section (data already exists from B97+ sessions).

---

## B108 Architecture Invariants

**B108+:**
- `computePhysiologicalScore` rmssdScore uses absolute thresholds, not relative-to-calibration. `calibrationRmssd` retained in footer for historical data but no longer drives score.
- `NDJSONFooter` exports `calibrationBetaMean`, `calibrationBetaStd`, `calibrationIndexMean` — these are now verifiable from JSON without Console access.
- betaZScore diagnostic telemetry fires at every calibration end — never remove without replacing with equivalent observability.

---

## B97–B107 Changes (reconstructed from memory — not in original STATUS.md)

### B97 (TF 101, 2026-05-14)
- `EndGongPlayer.bundleURL()` subdirectory lookup fix — `bowl_success.mp3` in bundle but root-only lookup fell through to synthesized WAV. Lookup now: m4a → mp3 → wav at root then Sounds/ subdirectory.
- `NDJSONFooter` biomarkers fix: `qualityScore`, `timeOfDay`, `rmssdDepthDelta`, `meditationIndexCorrelation` were nil in footer for all B96 sessions — biomarker computation moved BEFORE `appendFooter()`.
- `frontalGoodFrac` for qualityScore fixed to use `mainSamples` not `rec.samples` (warmup noise excluded).
- `pendingGongEvents` flush moved AFTER `openNDJSONHandle()` — now writes to NDJSON.
- SwiftUI type-checker fix: `SessionSummarySheet.body` 160-line body causing type-checker timeout — extracted 3 `@ViewBuilder private var` sections.
- **Session data:** Best session to date — 2026-05-15, deepFraction=0.931, Q=91, 58.6 min.

### B99 (TF 103)
- Main-phase band power means added to SessionRecord: `mainAlphaMean`, `mainThetaMean`, `mainBetaMean`.
- `rmssdDepthDelta` wired in (RMSSD at ecdfDisplay ≥ 0.50 vs < 0.25).
- `warmupFAAMean` capture (warmup phase FAA, ≥30 valid samples).

### B100 (TF 104)
- Warmup FAA tracking improvements.
- `calibrationIndexMean` capture refinements.
- **Session data (2026-05-16):** deepFraction=0, Q=45. calibrationIndexMean=−0.010 (near zero) → confirmed calibration oracle pattern.

### B103 (TF 106, 2026-05-15)
- Spotify depth-responsive volume (6 bugs fixed):
  - Volume map: no session→no-op, cal end→60%, enter deep→25%, chime→15% debounced, exit deep→60%, session end→preSessionVol.
  - 403 detection: `volumeManagementEnabled=false` on free tier.
  - `duckForChime` WorkItem reads `targetVol` at fire time (not schedule time).
- **Session data (2026-05-17):** deepFraction=0, Q=43. BLE dropout: packetGapMax=34.17s at t=33.7min, 2 reconnects. Session ended mid-session — zero deep was from BLE failure, not meditation.

### B107 (TF 112, 2026-05-17)
- HRV pipeline: RMSSD, SDNN, SD1, SD2, DFA α1 computed at session end via `attachHRVScalars()`.
- `calibrationRmssd`: RMSSD during calibration window captured for physiologicalScore baseline.
- `physiologicalScore` (0-100): betaZScore (0-50) + rmssdScore (0-30) + coherenceScore (0-20).
- `calibrationBetaMean`/`Std` captured via `attachCalibrationBeta()` at calibration end.
- BLE resilience improvements: B103 had 2 reconnects and 34s gap. B107 session had 0 reconnects, 0 disconnects.
- Adaptive Kalman qD from calibration ECDF variance (App.swift).
- TrendsView expansion: RMSSD, DFA α1, physiologicalScore sections added.
- **Session data (2026-05-18):** deepFraction=0.836, Q=79, RMSSD=80.7ms, DFA α1=0.665, physiologicalScore=20 (rmssdScore=0 — fixed in B108).

---

## Pending (B109+)

1. **Verify betaZScore pipeline** — after one B108 session, check Console log. If `calibrationBetaMean` is nil at calibration end, find and fix in `scorer.calibrationBetaMean` population path.
2. **calibrationIndexMean as soft gate** — display value at calibration end in session HUD. Do not add hard go/no-go until n≥30 sessions validate the −0.20 threshold. Currently r²=0.84 with n=8 (one outlier: B87 S11, cal≈0, deep=0.847 in 15-min session).
3. **kEnterSustained empirical tuning** — try `UserDefaults.standard.set(10, forKey: "kEnterSustainedWindows")` for 3 sessions. No code change needed. Current default=20 (10s) was confirmed too tight in B95.
4. **Per-sensor contact extraction** — re-extract `diagnostics.contactStateChanges` dict per session to get real TP9/TP10 vs AF7/AF8 split. Run script in `analysis/` against raw JSON files.
5. **Phase-continuous iTPF binaural ramp** (backlog since B94).
6. **EEGDenoiser live-signal wire-in** (gated by `eegDenoiseLiveSignal` UserDefault).
7. **TrendsView time-of-day stratification** — filter already implemented; labels need UTC→local time correction in session tagging (current `timeOfDay` field uses UTC hour, not local ET).

---

## B96 Changes

### Session-end gong overhaul
- Root cause of buzzing: synthesized bowl_success.wav loses 432 Hz fundamental on iPhone speaker (bass rolloff) → 1190+2334 Hz partials sound metallic. Real recording eliminates synthesis entirely.
- `bowl_success.mp3` bundled from `soundscape/universfield-single-church-bell-2-352062.mp3`.
- `EndGongPlayer.bundleURL()` now checks `.m4a → .mp3 → .wav` in that order — real recording preferred over synthesis.
- `EndGongPlayer.prepareAudioSession()` called synchronously before `asyncAfter` in `endSessionGracefully` — eliminates AVAudioEngineConfigurationChange mid-fade (was called at t=+1.5s inside asyncAfter).
- `BowlAudioGenerator.kBowlAudioVersion = "B96"` — forces WAV regen if MP3 missing.

### alphaPowerRatio wire-in
- `EEGWindowBuffer.latestAlphaPowerRatio: Float` — updated after each `denoiser.denoise(window:)` call (was 0.5 hardcoded).
- `DepthScore` uses `EEGWindowBuffer.shared.latestAlphaPowerRatio` in both `DepthResult` constructions — Kalman `rMeasure` now adapts to actual denoiser signal quality.
- Session 2026-05-13 measured mean alphaPowerRatio 0.6503 vs hardcoded 0.5 — Kalman was under-trusting the signal.

### Gong telemetry buffer (data loss fix)
- Root cause: `appendGongLifecycle` had `guard isRecording else { return }` — NDJSON closed by `endSession()` at t=0, gong fires at t=+1.5s → gong events silently dropped.
- Fix: `pendingGongEvents` buffer captures post-session events. Flushed to os_log at close; re-flushed into next session NDJSON at `startSession()`.

### kEnterSustained UserDefault
- `kEnterSustained` now reads `UserDefaults.standard.integer(forKey: "kEnterSustainedWindows")` at init. Valid range 6–24 (3s–12s). Default 20 (10s) if unset or out of range.
- Session 2026-05-13: longest run above threshold was 5 windows (2.5s) — deep state unreachable at 20-window requirement. UserDefault allows tuning down to 6 without code deploy.

### HR artifact rejection
- `filteredHeartRate()` — 5-sample rolling buffer, median filter, reject if |raw - median| > 35 BPM.
- Session 2026-05-13 artifacts: 30.2 BPM and 192 BPM (sensor dropout, not physiology). Both would now be rejected.
- `heartRateBuffer.removeAll()` on session start — no carry-over between sessions.

### Trajectory coaching (no-deep-state branch)
- Classifies session ECDF shape: two-attempt (early + late peaks with valley), late-peak, flat-low.
- Fixed negative-gap bug: peak at/above threshold showed "−Xs from threshold" — now shows "Xs held, 10s needed".
- Flat-low coaching suggests calibration reconsideration for users with shallow profiles.

### RMSSD/depth biomarker
- `rmssdDepthDelta`: RMSSD at ecdfDisplay ≥ 0.50 vs < 0.25. Non-nil when ≥5 samples each bucket.
- Shows in Biomarkers section: "RMSSD high/low depth: 42 / 38 ms ↑" — positive delta = parasympathetic activation tracks depth signal.

### meditationIndex/ECDF correlation
- Pearson r between `meditationIndexCorrected` and `ecdfDisplay` (main phase, ≥20 samples).
- r < 0.4 = signals uncorrelated → possible calibration drift → shown in orange.
- Displayed in Biomarkers: "MI/Depth Correlation: r = 0.62 (moderate)".

### NSFileCoordinator (iCloud conflict prevention)
- `SessionRecorder.save()` wraps `data.write()` in `NSFileCoordinator.coordinate(writingItemAt:options:.forReplacing)`.
- `CrashRecovery` recovery write wrapped identically.
- Signals iCloud daemon (ubiquityd) to pause syncing during write — prevents "session (1).json" conflict copies.

### timeOfDay session tagging
- `SessionRecord.timeOfDay: String?` — "early-morning" (<6), "morning" (6-12), "afternoon" (12-17), "evening" (17-21), "night" (≥21).
- Enables depth stratification by time-of-day in future TrendsView filters.

---

## B96 Validation Checklist

**Gong:**
1. End session → ~1.5s fade → church bell chime (not synthesized bowl). Clean ring, no buzzing.
2. `EndGongPlayer` logs show source "bundle" not "generated" (check Console: category "Telemetry.audio").
3. `bowl_success.wav` regenerated with vB96 stamp (logs: "wrote bowl_success.wav vB96").

**alphaPowerRatio:**
4. Session NDJSON shows `alphaPowerRatio` values ≠ 0.5 (varies 0.3–0.9 with signal quality).

**Gong telemetry:**
5. Gong lifecycle events (prepare/play/complete) appear in os_log after session end — not silently dropped.

**HR filter:**
6. Heart rate display does not show values < 30 or > 150 BPM during normal meditation.

**Correlation:**
7. After session: Biomarkers section shows "MI/Depth Correlation: r = X.XX (weak/moderate/strong)".
8. r < 0.4 shown in orange; r ≥ 0.4 in primary color.

**NSFileCoordinator:**
9. No "session (1).json" conflict copies after sessions where iCloud sync is active.

---

## B95 Changes

### Deep-state volume bounce fix
- Root cause: `applyProximityDuck()` called `setProximityGain(1.0)` on every 0.5s update while `inDeepState=true` — completely replaced deep-state gain with approach-zone gain. Fixed: `guard !inDeepState else { return }` (no explicit setProximityGain).
- `SoundscapePlayer.deepStateGain: Float` — 0.15 while in deep, 1.0 otherwise. Gain composition: `min(proximityGain, deepStateGain)` everywhere (not multiply — prevents 0.0225 compound duck).
- `SoundscapePlayer.setDeepStateGain(_ target:, fadeDuration:)` — fades deepStateGain with `deepStateGeneration` counter to cancel stale steps on re-entry mid-fade. Entry: fade to 0.15 over 2.0s. Exit: fade to 1.0 over 3.0s (the rise IS the exit signal).
- `SoundscapePlayer.resetDeepStateGain()` — snaps to 1.0, clears isDucked, cancels in-flight steps.
- Entry block: removed 1.5s asyncAfter delay (was workaround for old isDucked bug); now fires immediately.

### fade() smart isDucked logic (prevents exit signal suppression)
- `isActuallyDucking = min(multiplier, deepStateGain) < capturedEffective - 0.02` — chime at exit (target 0.18 > deepStateGain 0.15) is not actually ducking; isDucked stays false, setDeepStateGain rise flows unimpeded.
- `guard isActuallyDucking else { applyProximityGain(); return }` — skips all volume steps on non-ducking path; eliminates concurrent writes fighting setDeepStateGain during exit chime.
- Captured `startVols` dictionary for true linear interpolation (eliminates non-monotonic path from live-`cur` formula).
- `fadeGeneration` counter cancels stale fade steps when new fade starts.
- `currentDuckMultiplier` tracks last duck target for new/resumed layers.

### Crash data preservation
- `SessionRecorder.attachEnterThreshold()` now writes `{_type:"threshold", time:…, enterThreshold:…}` record to NDJSON immediately — survives crash.
- `synthesiseRecord()` parses `"threshold"` type, reconstructs `enterThresholdAtSession`.
- Crash synthesis computes `durationSec`, `deepFraction`, `qualityScore` from available samples (uses `lastTime` not fabricated endDate for duration).

### 7 pre-existing audio bugs fixed
1. `unduckTimer` removed — was declared but never assigned; `cancel()` was always a no-op.
2. `startLayer()`: new layer during chime now starts at duck level (`currentDuckMultiplier × deepStateGain`) not proximity level.
3. `resumeActiveLayers()`: BT reconnect mid-chime now restores duck level explicitly (previously `applyProximityGain()` was blocked by `isDucked=true` → audible surge).
4. `resetDeepStateGain()`: now clears `isDucked` and bumps `fadeGeneration` — prevents stuck-at-duck-level on session reset.
5. `deepeningRing` off-by-one: was reading `ring[(head+1)%N]` (second-oldest) — measured 29.5s window instead of 30s. Now reads `ring[head]` before overwrite.
6. `setVolume()` and `stopAll()` updated to respect `deepStateGain` in gain composition.
7. `startVols` capture in fade() — true linear interpolation, immune to any concurrent write.

---

## B95 Validation Checklist

**Volume system:**
1. Enter deep state with soundscape active → volume fades smoothly to ~15% over 2s; stays down
2. No bounce: volume does not snap back to full while in deep state
3. Exit deep state → volume rises 0.15→1.0 over 3s (the rise itself is the exit signal)
4. Re-enter during exit fade → volume falls back to 0.15, rise cancels
5. BT headphones disconnect/reconnect mid-chime → volume at duck level after reconnect (no surge)
6. New layer activated during chime → starts at same duck level as existing layers

**Crash recovery:**
7. Kill app mid-session while in deep state → on relaunch, JSON synthesised with correct `enterThresholdAtSession`, `durationSec`, `deepFraction`

**Deepening cue:**
8. Sustained 0.08+ ECDF rise over 30s in deep state triggers deepening chime (was off by one sample)

---

## B94 Changes

### Kalman depth filter (Task 2–3)
- `KalmanDepth.swift` — new 2-state Kalman (depth + velocity), `qD=2.16e-3`, `qV=1e-4`, `rBase=0.005`, `rNeutralQuality=0.6`, innovation clamped ±0.3, depth clamped [0,1].
- `DepthGate.smoothedDisplay` now uses Kalman output (was raw EMA). Kalman frozen during contact loss — more honest than artificial decay.
- `duckDisplay` = separate slower EMA (α=0.095, τ≈5s) used **only** for proximity duck gain — prevents audible volume pumping. Empirical: 76% fewer approach-zone threshold crossings vs raw smoothedDisplay.

### End-of-session gong fix (Task 4)
- Root cause: `stopAll(fadeSeconds:4.0)` + immediate `playSuccess()` → full-volume overlap at t=0 → DAC clip → buzzing.
- Fix: `stopAll(fadeSeconds:2.0)`, gong deferred 1.5s (fires when soundscape ≈25% volume). `recordEvent` called synchronously before asyncAfter (endSession() closes NDJSON file — writing after close was a race).

### FAA flow state (Task 5)
- `DepthGate.inFlowState` — true when deep AND `smoothedFaa > faaBaseline + 0.25` sustained 10 windows (5s).
- Baseline locked at calibration end. Population median −0.092; margin 0.25 ≈ top 25% of session FAA distribution.
- Cooldown 120s. Exit: 3 consecutive samples below `baseline + 0.075` (1.5s hysteresis prevents noise collapse).
- `ChimeEngine.playFlow()` — 444 Hz bowl (distinct from 528 Hz enter-deep, 432 Hz gong).

### iTPF adaptive binaural (Task 6)
- `SoundscapePlayer.setAdaptiveBinauralIfActive(hz:)` — sets `customBinauralHz` from iTPF on deep state entry. Valid range 4–9 Hz; ignores if binaural inactive or change < 0.3 Hz.
- Effect deferred to next 120s buffer loop — no restart, no audible gap.
- Called from App.swift `wasDeep` pattern AFTER `updateAdaptiveDepth` to prevent immediate overwrite by `iTPF - 2.0` formula.

### Session quality score (Task 7)
- `SessionRecord.qualityScore: Int?` — composite 0–100: deep fraction (40pts, target 70%) + ECDF smoothness (25pts, std/0.25) + contact quality (35pts, frontalGoodFraction).
- Computed in `endSession()` using main-phase samples only.
- `SessionSummarySheet` shows "Session Quality" section: ring gauge (green ≥80, orange ≥60, red <60) + label + deep/contact pct.

### Early session forecast banner (Task 8)
- `SessionForecast` enum (strong/building/slow) with label, SF symbol, color.
- 60s after first calibration: computes mean of last 60s ECDF values → strong (>0.52) / building (>0.38) / slow.
- Banner shown at top of session HUD for 15s then auto-dismisses. Resets on session start.

### TrendsView (Task 9)
- `TrendsView.swift` — reads last 30 `session_*.json` files asynchronously from documentDirectory.
- Swift Charts: deep fraction (area+line, green), quality score (line, blue), session duration (bar, indigo).
- Trend arrow: compares last 7 vs prior 7 sessions (±2pp threshold).
- "Trends" toolbar button in `SessionSummarySheet` opens TrendsView in sheet.

---

## B94 Validation Checklist

**Audio:**
1. End session manually → ~1.5s silence → clean gong, no buzzing
2. End session via timer → same clean gong behavior
3. `buildTag` in NDJSON header shows `"B94"`; `bowl_success.wav` regenerated on first launch (check logs: `BowlAudioGenerator: wrote bowl_success.wav vB94`)

**Proximity duck (requires active soundscape):**
4. Approach threshold with soundscape active → gradual smooth volume reduction, no pumping artifacts
5. At threshold entry chime, soundscape restores to full volume

**Flow state:**
6. After sustained deep state, flow chime (444 Hz, softer/distinct from enter chime) fires when FAA shifts positive for 5s
7. Flow chime does not fire when not in deep state

**iTPF binaural:**
8. Session with binaural active → at deep state entry, binaural frequency shifts toward iTPF value on next buffer cycle (≤120s latency)

**Quality score:**
9. After session: `SessionSummarySheet` shows "Session Quality" ring gauge with score and label
10. Sessions without qualityScore (pre-B94 JSON) show no quality section (nil guard works)

**Forecast banner:**
11. 60s after calibration: forecast banner (strong/building/slow) appears at top of session HUD
12. Banner disappears after 15s without user interaction
13. No banner if session ends before 60s post-calibration

**Trends:**
14. "Trends" button in SessionSummarySheet toolbar opens TrendsView
15. TrendsView loads last 30 sessions asynchronously (no main-thread stall)
16. Deep fraction chart shows correct values; B94 sessions show quality score chart

---

## B92 Changes

### Drone race condition (complete fix)
- Root cause: B90 fixed `engine.stop()` at fade completion but ordering was still wrong — `playSuccess()` fired BEFORE `stopAll()`. `configureAudioSession()` inside playSuccess triggered `AVAudioEngineConfigurationChange` ~0.5s later while `activeLayers` still populated → `resumeActiveLayers()` restarted nodes.
- Fix 1: `SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)` now called BEFORE `EndGongPlayer.shared.playSuccess()` in `endSessionGracefully`.
- Fix 2: `isStopping` flag added to `SoundscapePlayer`. Set true on `stopAll()` entry; `resumeActiveLayers()` returns early when true; cleared at fade completion and in `activate()`.
- Fix 3: `guard !activeLayers.isEmpty` in `stopAll()` now still calls `engine.stop()` even when no soundscape was active.

### BowlAudioGenerator — fix buzzing/clipping
- Root cause: normalization happened BEFORE reverb. Post-reverb peak = `peakAmplitude + reverbMix * peakAmplitude` → hard clip → distortion harmonics → buzzing on speaker.
- Fix: normalization moved to AFTER reverb. Tuned: `peakAmplitude` 0.9→0.65, `reverbMix` 0.25→0.12, `baseDecay` 0.4→0.6 (cleaner decay).
- Version key `"B92"` in UserDefaults forces regeneration of cached WAV files on first launch.

### Proximity approach duck (new feature)
- Gap: approach zone (0→threshold) was completely silent. No feedback loop before threshold.
- Implementation: `DepthGate.applyProximityDuck()` called every 0.5s update. Maps `smoothedDisplay` [0.30 → enterThresholdEcdf] to `SoundscapePlayer.setProximityGain()` [1.0 → 0.15].
- Effect: soundscape silently fades to 15% as user approaches threshold. No new tone — silence is the signal.
- Chime duck takes precedence (checked via `isDucked`). Contact loss and deep-state entry restore gain to 1.0.

### Warmup ECDF contamination fix
- Fix: `PersonalZDistribution.ingestSession()` now filters `s.phase == "main"` only. Warmup samples (first 300s) no longer inflate the distribution.

### Post-session depth trace (new feature)
- `SessionSummarySheet` now shows `DepthTraceChart`: ecdfDisplay over session time (minutes), orange dashed threshold line, grey calibration boundary at 5 min.
- Data was already stored per sample (`ecdfDisplay: Float?`). No new capture needed. Downsampled to ≤300 points for render performance.
- `enterThresholdAtSession: Float?` added to `SessionRecord` — populated via `attachEnterThreshold(gate.enterThresholdEcdf)` before `endSession()`.

### Coaching line — near-miss case
- When no deep state and peak ecdfDisplay ≥ 88% of threshold: "Peak depth X% — Y points from Z% threshold. The approach is there. You arrived without crossing. Less monitoring of state, more surrender to the breath."

### BuildTag fix
- `SessionRecorder.static let currentBuildTag = "B92"`. Both stale `"B87"` literals in SessionRecorder + `"B83"` in App.swift replaced.

---

## B92 Validation Checklist

**Audio:**
1. Session-end gong sounds clean (bowl ring, no buzzing). `bowl_success.wav` regenerated on first B92 launch.
2. No drone after session ends. Soundscape fades to silence and stays silent.
3. After session ends, start new soundscape — plays normally (engine restarts, `isStopping` cleared).

**Proximity duck (requires active soundscape):**
4. Start session with soundscape active. As calibration completes and depth rises toward threshold, soundscape volume gradually lowers.
5. At threshold: soundscape near-silent. Entry chime fires. After chime, soundscape restores to full volume.
6. No soundscape active: no effect (proximity duck silently no-ops).

**Session summary:**
7. After session: `SessionSummarySheet` shows "Depth Trace" section with chart.
8. Orange dashed line at correct threshold (55% for first session, higher for experienced users).
9. If no deep state but peak ≥ 88% of threshold: Insight shows "Peak depth X% — Y points from Z% threshold..."
10. `session_*.json` contains `enterThresholdAtSession` field.

**ECDF:**
11. After session, `PersonalZDistribution` updated using main-phase samples only (verify no warmup depthZ spikes in next session's threshold).

**Telemetry:**
12. `buildTag` in JSON and NDJSON header shows `"B92"` (not `"B87"` or `"B83"`).

---

## B86–B90 Changes (cumulative since B83)

### B87 — Timer unification
- `MeditationTimer` deleted entirely. `SessionTimer.shared` is the single timer.
- `BottomButton` touch targets fixed (`.padding(.vertical,16)` replaces greedy `maxHeight:.infinity`).
- Fit-event rate metric corrected: was counting HSI-tier flips, now counts `allGood→bad` transitions.

### B88 — Four-fix commit
- `DepthGate.contactsGood` → `frontalContactGood` (clarity rename; behavior unchanged since B77.1).
- Adaptive `enterThresholdEcdf` by `PersonalZDistribution.sessionCount`:
  - n=0: enter=0.55, exit=0.40 (cold start)
  - n<5: 0.60/0.45
  - n<20: 0.65/0.48
  - n≥20: 0.70/0.50
- Spotify row in `SoundscapeSheet` (shows when `SpotifyManager.isConnected`).
- `SessionRecord` stored scalars: `durationSec`, `summarySampleCount`, `deepFraction` (Codable, populated at `endSession()`).

### B89 — Layout fix (correct)
- Root cause: B86 GeometryReader inside VStack splits remaining space 50/50 with `maxHeight:.infinity` BottomButton. Band chart invisible, buttons 40% of screen.
- Fix: `ScrollView(.vertical).frame(maxHeight:.infinity)` between ElementsStripView and BottomButton HStack. No GeometryReader. BandChart inside scroll — reachable on all iPhone sizes.

### B90 — Gong + drone partial fix + chime preview
- `EndGongPlayer.gongVolumeFloor = 0.85`. `resolvedVolume()` returns `max(0.85, userSetting)`.
- `SoundscapePlayer.stopAll()`: `engine.stop()` at fade completion (partial drone fix — B92 completes it).
- Chime preview: orange "0% — drag slider to hear preview" label. Session End preview calls `EndGongPlayer.shared.playSuccess()`.
- Anchor Tone label: "7 Hz θ binaural · headphones only".

---

## Architecture Invariants

**Carryover (B80+):**
- `handleIsGood` 5s rate limit — NEVER REMOVE.
- Contact chimes gated behind `depth.isCalibrated`.
- Beta cue: additive `bm + 1.5 * bs`.
- AVAudioEngine stereo format explicit on all `engine.connect()`.
- `SessionRecorder` serial DispatchQueue (single-writer).
- `SessionRecorder` file protection `.completeUnlessOpen`.
- `MuseClient.registerAllListeners` idempotent reconnect path.

**B88+:**
- `DepthGate.thresholdConfigured` flag — adaptive threshold set ONCE per session. Reset in `reset()`.
- `SessionRecord.durationSec/summarySampleCount/deepFraction` stored properties — Codable synthesis includes them.

**B90+:**
- `EndGongPlayer.gongVolumeFloor = 0.85` — gong always ≥ 85% regardless of `chimeVolume` UserDefault.

**B92+:**
- `SoundscapePlayer.stopAll()` called BEFORE `EndGongPlayer.playSuccess()` in `endSessionGracefully` — ordering is load-bearing.
- `SoundscapePlayer.isStopping` — blocks `resumeActiveLayers()` during session-end fade. Never remove.
- `BowlAudioGenerator.kBowlAudioVersion = "B94"` — bump when synthesis params change to force WAV regen.
- `SessionRecord.enterThresholdAtSession` stored at session end — used by depth trace chart.
- PersonalZDistribution ingests main-phase samples only — warmup excluded.

**B94+:**
- `DepthGate.smoothedDisplay` is Kalman-filtered (not EMA). `duckDisplay` (EMA α=0.095) used exclusively for proximity duck gain.
- `DepthGate.inFlowState` — FAA flow detection, requires `inDeepState`. Reset on deep-state exit and session reset.
- `SoundscapePlayer.setAdaptiveBinauralIfActive()` called from App.swift AFTER `updateAdaptiveDepth` — call order is load-bearing.
- `SessionRecord.qualityScore: Int?` — populated at endSession(), nil for pre-B94 sessions.
- `recordEvent(kind:"session-end-success")` called synchronously before asyncAfter in endSessionGracefully — NDJSON file closes synchronously; event must precede closure.

**B95+:**
- `SoundscapePlayer.deepStateGain` — 0.15 in deep state, 1.0 otherwise. Gain = `min(proximityGain, deepStateGain)`. Never multiply.
- `SoundscapePlayer.setDeepStateGain()` has `deepStateGeneration` counter — re-entry mid-exit-fade cancels fade-up immediately.
- `SoundscapePlayer.fade()` isActuallyDucking guard — returns early when chime target ≥ deepStateGain floor (exit case). Prevents exit signal suppression.
- `SoundscapePlayer.fadeGeneration` — cancels stale fade steps on new fade call. Never remove.
- `SoundscapePlayer.currentDuckMultiplier` — tracks duck level for new/resumed layers during active chime.
- `DepthGate.applyProximityDuck()` guard `!inDeepState` — never writes proximityGain while in deep state. Load-bearing.
- `SessionRecorder.attachEnterThreshold()` writes NDJSON threshold record — must be called before session end for crash recovery.
- `deepeningRing`: read `ring[head]` BEFORE overwriting (not `ring[(head+1)%N]`). Load-bearing for correct 30s window.

**B96+:**
- `EndGongPlayer.bundleURL()` tries `.m4a → .mp3 → .wav` — real recording preferred over synthesis.
- `EndGongPlayer.prepareAudioSession()` called synchronously before asyncAfter in endSessionGracefully — ordering is load-bearing. AVAudioSession must be configured before the fade completes.
- `EEGWindowBuffer.latestAlphaPowerRatio` — updated after each denoiser.denoise(); consumed by DepthScore. Never bypass.
- `SessionRecorder.pendingGongEvents` — post-session gong lifecycle events buffer. Flushed at next startSession(). Never remove.
- `kEnterSustained` reads UserDefault at init (not each call) — value is constant per app launch.
- `heartRateBuffer.removeAll()` on session start — must precede startSession() call. Prevents cross-session contamination.
- `SessionRecorder.save()` + `CrashRecovery` write wrapped in `NSFileCoordinator.coordinate(writingItemAt:options:.forReplacing)` — prevents iCloud conflict copies.

---

## Pending (B97+)

1. **Phase-continuous iTPF binaural ramp** — smooth ramp requires short-buffer scheduling (120s pre-gen deferred in B94).
2. **EEGDenoiser live-signal wire-in** — replace raw EEG with cleaned signal in MuseClient.handleEEG. Gated by `eegDenoiseLiveSignal` UserDefault.
3. **MainThreadStall blocking-stack** — MetricKit MXCallStackTree deferred.
4. **fNIRS Gate 13** — HbO/HbR from Optics1-6 (backlog).
5. **TrendsView time-of-day stratification** — filter by `timeOfDay` bucket (field now captured in B96).
6. **meditationIndexCorrelation TrendsView chart** — per-session r values already stored, not yet charted.

---

## How to Resume

1. Read STATUS.md (this file) — canonical.
2. `gh run list --limit 5` — verify CI green.
3. Install TestFlight build and run B92 Validation Checklist above.
4. Run B94 Validation Checklist above on physical device.
5. Hard rule: never push without explicit "go" per `MusePlus/CLAUDE.md`.
