# MusePlus — Continuation Prompt

**Read STATUS.md first. Then read this.**

---

## Current State (as of 2026-05-19)

**B109 = TF build 116** — CI run 26092291419, green. Uploaded to TestFlight.
**B108 = TF build 115** — first session run 2026-05-19_0340.json. Confirmed several bugs (see below).

---

## What Was Just Fixed (B109)

### Fix 1 — calibrationBetaMean always nil (ROOT BUG — affects every session since B107)
- `attachCalibrationBeta` was called BEFORE `startSession` in the calibration-end block (App.swift ~line 841)
- `isRecording=false` at that point → guard blocked → value never stored → betaZScore=0 every session
- **Fix:** moved `attachCalibrationBeta` + telemetry log to AFTER `startSession`
- **Effect:** betaZScore will be non-zero for the first time in B109+. physiologicalScore was artificially suppressed every session since B107.

### Fix 2 — fitsPerMin=0 in diagnostics (non-grace disconnect path)
- `recordingStartedAt = nil` at line 374 BEFORE `buildDiagnostics` at line 382 → `sessionMin=0` → `fitsPerMin=0/0=0`
- Also: endReason in `buildDiagnostics` was wrong ("disconnect-grace-expired" → should be "disconnect")
- **Fix:** moved `recordingStartedAt = nil` to AFTER the attach block; fixed endReason string

### Fix 3 — performFinalDisconnect had NO diagnostics at all
- `performFinalDisconnect` (grace-expired path) went directly to `endSession` with zero attachment calls
- No `buildDiagnostics`, no `attachEventStream`, no HRV block → grace-expired sessions had skeletal JSON
- **Fix:** added full attachment block before `endSession` (same as graceful-end path)
- Same `recordingStartedAt` ordering fix applied here too

### Fix 4 — HRV scalars missing from all non-graceful session ends
- `attachEnterThreshold`, `attachHRVScalars`, `attachCalibrationRmssd`, `attachDFAAlpha1` were ONLY called in the graceful-end path (lines 1150-1168)
- Disconnect and grace-expired paths had nil dfaAlpha1, sdnn, sd1, sd2 in every session
- **Fix:** added full HRV block to both non-graceful paths

### Fix 5 — scoreComponents not exported (betaZScore/rmssdScore/coherenceScore)
- `computePhysiologicalScore` returned a single `Int` (total score only)
- Sub-components (betaZ 0-50, rmssd 0-30, coherence 0-20) were local Float vars — unverifiable post-hoc
- **Fix:** return type → `(total: Int, betaZ: Int, rmssd: Int, coherence: Int)`
- Added `betaZScore`, `rmssdScore`, `coherenceScore` to SessionRecord + NDJSONFooter
- Now auditable from JSON without Console access

---

## B109 Validation Checklist (first session on TF 116)

1. **Console after calibration:** `B109 calBeta mean=X.XXX std=X.XXX` — MUST be non-nil. If nil: `scorer.calibrationBetaMean` not being set in DepthScore — investigate.
2. **NDJSON footer** contains `betaZScore`, `rmssdScore`, `coherenceScore` as separate integer fields.
3. `physiologicalScore` ≈ betaZScore + rmssdScore + coherenceScore (within 1pt rounding).
4. `betaZScore` > 0 (any non-zero confirms Fix 1 worked).
5. **If session ends via disconnect:** `dfaAlpha1`, `sdnn`, `sd1`, `sd2` non-nil in NDJSON footer.
6. `fitsPerMin` > 0 in diagnostics block (for any session with fit events).

---

## B108 Validation Results (session_2026-05-19_0340.json)

| Check | Result |
|-------|--------|
| buildTag = "B108" | ✅ confirmed |
| calibrationBetaMean in JSON | ❌ MISSING — confirmed Fix 1 root cause |
| physiologicalScore > 20 | ✅ score=47 (betaZ=0 + rmssd=27 + coherence=20) |
| NDJSON calibration fields | ✅ calibrationIndexMean, calibrationBetaMean (but nil — ordering bug) |
| deepFraction > 0 | ❌ 0 — gate correct, signal oscillatory (max run=12 windows, need 20) |
| Signal quality | ✅ frontalGoodFrac=1.0, calibrationIndexMean=-0.688 |
| endReason | disconnect-grace-expired (one 3.06s gap at t=2358.9s) |
| meditationIndexCorrelation | 0.928 (strong signal coherence) |

**deepFraction=0 is NOT a bug.** ecdfDisplay max=0.9545 but longest consecutive run at 0.65 = 12 windows (6s). Gate requires 20 consecutive (10s). All 4 historical deep sessions had lr@0.65 ≥ 39. Signal was oscillatory this session — gate worked correctly.

---

## Known Data Patterns (20 sessions, 2026-05-02 → 2026-05-19)

- **deepFraction is bimodal:** sessions produce 0.000 or 0.66–0.93. No middle ground.
- **calibrationIndexMean < −0.20** predicts deep state (r²=0.84, n=8, treat as signal not gate)
- **betaZScore was 0 in ALL sessions since B107** — ordering bug. B109 is the first build where it can be non-zero.
- **TP9/TP10 noise does NOT penalize qualityScore** — contact component uses frontalGoodFraction (AF7/AF8). Never claim otherwise.
- **kEnterSustained is UserDefault-tunable** without code deploy: `UserDefaults.standard.set(12, forKey: "kEnterSustainedWindows")` via debugger. Range 6–24, default 20.
- **Kalman freeze on frontal contact loss already exists** (DepthGate.swift:144). Do NOT add it — it's there.

---

## Architecture Invariants (cumulative)

**Always (all builds):**
- `handleIsGood` 5s rate limit — NEVER REMOVE
- Contact chimes gated behind `depth.isCalibrated`
- AVAudioEngine stereo format explicit on all `engine.connect()`
- `SessionRecorder` serial DispatchQueue + file protection `.completeUnlessOpen`
- `SoundscapePlayer.stopAll()` BEFORE `EndGongPlayer.playSuccess()` — ordering load-bearing
- `SoundscapePlayer.isStopping` — blocks `resumeActiveLayers()` during fade
- `PersonalZDistribution.ingestSession()` filters `phase == "main"` only
- Gain = `min(proximityGain, deepStateGain)` everywhere — never multiply
- `DepthGate.applyProximityDuck()` guard `!inDeepState` — load-bearing
- `EndGongPlayer.bundleURL()` tries .m4a → .mp3 → .wav at root then Sounds/ — ordering load-bearing
- `pendingGongEvents` buffer — never remove
- `SessionRecorder.save()` wrapped in `NSFileCoordinator.coordinate(.forReplacing)`
- On `.disconnected` while recording: enter 30s grace — do NOT immediately endSession

**B108+:**
- `computePhysiologicalScore` uses absolute RMSSD thresholds (Shaffer & Ginsberg 2017). `calibrationRmssd` retained for historical data but no longer drives score.
- `NDJSONFooter` exports `calibrationBetaMean`, `calibrationBetaStd`, `calibrationIndexMean`
- betaZScore telemetry fires at every calibration end — never remove

**B109+:**
- `attachCalibrationBeta` MUST be called AFTER `startSession`. The `isRecording` guard depends on this order. Moving it back before `startSession` silently zeros betaZScore forever.
- `recordingStartedAt` must NOT be nil when `buildDiagnostics` runs. Clear it only after the full attachment block.
- All three session-end paths (graceful, non-grace disconnect, grace-expired) now carry the full HRV attachment block. Never remove from any path.
- `computePhysiologicalScore` returns a 4-tuple. Call site must populate all four SessionRecord fields: `physiologicalScore`, `betaZScore`, `rmssdScore`, `coherenceScore`.

---

## Score Decomposition (reference)

`physiologicalScore = betaZScore(0–50) + rmssdScore(0–30) + coherenceScore(0–20)`

| Component | Formula | Range | Notes |
|-----------|---------|-------|-------|
| betaZScore | `(calBeta - sessBeta) / max(calBetaStd, 0.10) / 2.0 * 50.0` clamped 0–50 | 0–50 | Nil if calibrationBetaMean missing → 0pts |
| rmssdScore | `<40ms → 0-10pts, 40-65ms → 10-25pts, 65-100ms → 25-30pts, >100ms → 30pts` | 0–30 | B108 absolute thresholds |
| coherenceScore | `frontalGoodFrac * 20.0` | 0–20 | frontalGoodFrac = AF7+AF8 contact fraction |

**B108 session decomposition (confirmed from data):**
- betaZScore = 0 (ordering bug — calibrationBetaMean nil)
- rmssdScore ≈ 27 (rmssd=75.76ms → 25 + (75.76-65)/35 × 5 = 26.5 → Int = 27)
- coherenceScore = 20 (frontalGoodFrac=1.000)
- Total = 47 ✅ (matches JSON)

---

## DepthGate Entry Logic (reference)

```
enterThresholdEcdf: n=0→0.55, n<5→0.60, n<20→0.65, n≥20→0.70
kEnterSustained: default 20 windows (10s at 0.5s windows)
Entry condition: smoothedDisplay(Kalman) ≥ enterThresholdEcdf for kEnterSustained consecutive windows
```

B108 had n=19 prior sessions → threshold=0.65. Longest raw run at 0.65 = 12 windows (6s). Kalman adds ~1-3 window lag at high qD → gate could not fire.

---

## Key Files

| File | Purpose |
|------|---------|
| `STATUS.md` | Canonical build state — READ FIRST |
| `MusePlus/App.swift` | Session management, calibration, disconnect paths |
| `MusePlus/SessionRecorder.swift` | Score computation, NDJSON footer, HRV pipeline |
| `MusePlus/TrendsView.swift` | Cross-session charts (7 sections as of B108) |
| `MusePlus/Audio/DepthGate.swift` | kEnterSustained, Kalman, enter/exit logic |
| `MusePlus/Audio/KalmanDepth.swift` | 2D Kalman state (depth, velocity), adaptive qD |
| `MusePlus/Pipeline/DepthScore.swift` | calibrationBetaMean/Std storage — set at calibration end |
| `MusePlus/Pipeline/HRVPipeline.swift` | RMSSD, SDNN, SD1, SD2, DFA α1 |
| `analysis/` | Python scripts + session data analysis artifacts |
| `G:\My Drive\session_*.json` | Session JSON files (Google Drive desktop sync) |

---

## Diagnostic Commands

```bash
gh run list --limit 5            # CI status
gh run view <id> --log 2>&1 | grep -iE "(error:|succeed|fail|upload)" | head -20
```

Session JSON on device: Files → MusePlus → MuseSessions → export.
Console filter: category `Telemetry.recording` — see calibration beta log + score computation.
