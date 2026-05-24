# MusePlus — Continuation Prompt

**Read STATUS.md first. Then read this.**

---

## Current State (2026-05-24)

**B126 pushed to origin/main** — 8 commits, CI pending as of 2026-05-24 ~06:00 ET.  
Last confirmed green: B125 (CI run 26341344481).  
**Last session data:** B121 (2026-05-23_0538) — physiologicalScore=97, deepFraction=0 (ecdfMax=0.944, never sustained 10s, gate correct).

---

## What B126 Shipped (commits 519b8bd → f311a01)

### Phase A — EnterSustainedShaping
- `EnterSustainedShaping.swift` (NEW): default 12 windows (6s), range [4,20]; `recordSession(deepFraction:)` adjusts on 3-streak
- `DepthGate.kEnterSustained` now instance var, re-read at `reset()` from UserDefaults
- `SessionRecord` + `NDJSONFooter`: `enterSustainedAtSession: Int?`
- `App.swift`: `attachEnterSustained()` + `recordSession()` at all 3 session-end paths (nil-guarded)

### Phase B — Alpha-theta crossover
- `DepthResult.alphaTheta: Float` — (AF7+AF8 theta) / (AF7+AF8 alpha); >1.0 = theta-dominant
- Crossover accumulators in `DepthGate`: `alphaThetaCrossoverCount`, `alphaThetaCrossoverFirstTimeSec`
- `SessionRecord` + `NDJSONFooter`: `alphaThetaMean`, `alphaThetaCrossoverCount`, `alphaThetaCrossoverFirstTime`

### Phase C — Continuous ECDF→reverb sonification
- `AVAudioUnitReverb` (mediumHall) wired after mainMixerNode; `wetDryMix` driven by `applyContinuousSonification()`
- Linear map: 0 at display ≤ 0.30, full at enterThreshold; replaces binary proximity duck
- `SoundscapePlayer`: `setAmbientPresence(_:fadeDuration:)`, `enterSilenceGap(durationSec:postGapTarget:)`, `setDeepStateGainAbsolute(_:fadeDuration:)`

### Phase D — Deep state maintenance
- Entry: `setDeepStateGain(0.20, fadeDuration: 30.0)`; silence gap scheduler fires every 120s (8-12s random gap); 60s chime blackout after entry
- `kDeepInitialFadeSec=30`, `kDeepInitialFadeTarget=0.20`, `kDeepExitFadeSec=5.0`, `kSilenceGapEverySec=120`, `kSilenceGapMinSec=8`, `kSilenceGapMaxSec=12`, `kFirstChimeBlackoutSec=60`

### Phase E — BOCPD drift alert
- `BayesianChangepointDetector.swift` (NEW): logit-transform, NIG conjugate prior, hazardRate=1/250, maxRunLength=7200
- `BayesianChangepointDetectorTests.swift` (NEW): 3 tests
- Fires `onDriftAlert` when posterior>0.75 AND derivative<-0.05 (10-sample lookback) AND cooldown 90s AND outside silence gap recovery window
- `SessionRecorder`: `NDJSONDriftAlert` + `appendDriftAlert()`
- `App.swift`: `onDriftAlert` → `appendDriftAlert` + `UIImpactFeedbackGenerator(.soft, 0.4)` on main thread

### Phase F — SessionNarrative TDD
- `SessionNarrative.swift` (NEW): pure-Swift deterministic struct, 6 dimensions (calibration, gate, signal, physiology, crossover, insight)
- `SessionNarrativeTests.swift` (NEW): 6 tests

### Phase G — SessionSummarySheet UI
- `narrativeSection`: `Section("What happened")` + `ForEach(id: \.offset)` in List
- `gateRequirementSection`: "X seconds of sustained focus required"

### Phase H — STATUS.md + CFBundleVersion bump

### Audit fixes (f311a01) — 8 issues, all fixed
| # | File | Fix |
|---|------|-----|
| 1 CRITICAL | `SessionNarrativeTests:8` | `enterSustainedAtSession: 3→6` (3×0.5=1.5s ≠ "3 seconds"; 6×0.5=3.0s ✓) |
| 2 HIGH | `DepthGate.applyContinuousSonification` | `setAmbientPresence` → `DispatchQueue.main.async` |
| 3 HIGH | `DepthGate` silence gap scheduler | `enterSilenceGap` → `DispatchQueue.main.async`; `lastSilenceGapAt` stays on pipeline thread |
| 4 HIGH | `App.swift` ×3 | `recordSession(?? 0)` → `if let deepF` guard |
| 5 MEDIUM | `DepthGate` BOCPD | Gate behind `silenceGapRecoveryEnd = lastSilenceGapAt + kSilenceGapMaxSec + 3.5s` |
| 6 MEDIUM | `App.swift narrativeSection` | Bare VStack → `Section("What happened")` |
| 7 MEDIUM | `App.swift narrativeSection` | `id: \.self` → `id: \.offset` |
| 8 MEDIUM | `BayesianChangepointDetector` | `reserveCapacity(n+1)` on 4 NIG arrays |

---

## B126 Validation Checklist (first session)

- [ ] NDJSON footer: `enterSustainedAtSession` present + equals `EnterSustainedShaping.currentWindows()` at session start
- [ ] NDJSON footer: `alphaThetaMean`, `alphaThetaCrossoverCount`, `alphaThetaCrossoverFirstTime` present
- [ ] Reverb audible during approach (not binary duck) — continuous gradient as ecdfDisplay rises
- [ ] Deep state entry: volume fades slowly over ~30s (not instant)
- [ ] Silence gap fires ~2min into deep state (audible dip, then restore to 0.20)
- [ ] No deepening chime in first 60s after deep state entry
- [ ] If deep state exits early: NDJSON stream contains `{"_type":"driftAlert",...}`
- [ ] Session summary: "What happened" Section shows plain-English lines
- [ ] Session summary: gate line shows "X seconds" in human language (no raw field names)

---

## Architecture Invariants (cumulative — all must be preserved)

**B126+:**
- `EnterSustainedShaping.recordSession()` only with non-nil `deepFraction` — never `?? 0` default
- ALL `SoundscapePlayer` mutations from `DepthGate` → `DispatchQueue.main.async`
- `lastSilenceGapAt = now` on pipeline thread BEFORE the async dispatch
- BOCPD drift alert gated: posterior>0.75 AND derivative<-0.05 AND cooldown 90s AND `now >= silenceGapRecoveryEnd`
- `narrativeSection`: `Section("What happened")` + `ForEach(id: \.offset)` — never revert
- `BayesianChangepointDetector.observe()`: `reserveCapacity(n+1)` on 4 NIG arrays
- `kEnterSustained` re-read at `reset()` — each session picks up updated UserDefault
- `SessionNarrative` pure-Swift deterministic — no Date, no AVAudio, no Muse SDK

**B122+:**
- `calBetaStd >= 0` guard (NOT `> 0`) in both betaZRaw and betaZScore
- `ecdfMax`/`ecdfP90` scoped to `phase == "main"` only
- `pendingGateEvents` flush in `startSession()` AFTER `openNDJSONHandle()`
- `FAABarView` color gate: `clamped < 0` → green
- `metricDefinitions.faa` = r=-0.43 (n=16, p≈0.10) — NOT r=-0.76

**B120+:**
- `attachCalibrationBeta()` guards on `current != nil` (NOT `isRecording`) — race-safe
- `.completeFileProtectionUnlessOpen` for all file writes
- `synthesiseRecord()` decodes full NDJSONFooter — add new footer fields here too

**B118+:**
- buildTag dynamic from `CFBundleVersion` — never hardcode
- All coaching events through `recordCoach()`

**B109+:**
- `attachCalibrationBeta` MUST be called AFTER `startSession`
- `recordingStartedAt` must not be nil before `buildDiagnostics`
- All 3 session-end paths carry full HRV attachment block

**Always:**
- `handleIsGood` 5s rate limit — NEVER REMOVE
- `SoundscapePlayer.stopAll()` BEFORE `EndGongPlayer.playSuccess()` — ordering load-bearing
- Gain = `min(proximityGain, deepStateGain)` everywhere — never multiply
- `DepthGate.applyProximityDuck()` guard `!inDeepState` — load-bearing
- `pendingGongEvents` + `pendingGateEvents` buffers — never remove

---

## FAA Empirical Facts (definitive, n=16)

- `faa = af8Alpha - af7Alpha`
- r(FAA, depthZ)=-0.43, r(FAA, deepFraction)=-0.48, p≈0.10 — direction consistent, NOT significant
- **Positive FAA → zero depth (no exceptions, n=16)** — load-bearing signal
- **Negative FAA → necessary but not sufficient**
- For Sugato: negative = right-frontal dominant = green
- NEVER restore r=-0.76

---

## Score Decomposition (reference)

`physiologicalScore = betaZScore(0–50) + rmssdScore(0–30) + coherenceScore(0–20)`

| Component | Formula |
|-----------|---------|
| betaZScore | `(calBeta - sessBeta) / max(calBetaStd, 0.10) / 2.0 × 50.0` clamped 0–50 |
| betaZRaw | same, unclamped |
| rmssdScore | `<40ms→0-10, 40-65ms→10-25, 65-100ms→25-30, ≥100ms→30` |
| coherenceScore | `frontalGoodFrac × 20.0` |

B121: betaZ=50 (bz=5.125 ceiling), rmssd=27, coherence=20 → total=97.

---

## DepthGate Entry Logic (reference)

```
enterThresholdEcdf: n=0→0.55, n<5→0.60, n<20→0.65, n≥20→0.70
exitThresholdEcdf:  n=0→0.40, n<5→0.45, n<20→0.48, n≥20→0.50
kEnterSustained:    B126 default 12 windows × 0.5s = 6s (adaptive, range [4,20])
```

At n=16 sessions (Sugato current): threshold=0.65. B126 gate default now 6s (was 10s in B125).

---

## Top Next Candidate (B127) — do NOT build until B126 CI green + one validated session

**Binaural beats theta entrainment** — real-time binaural beat generator layered under reverb sonification.

- Carrier ~200 Hz, beat = user's dominant theta peak (4–8 Hz) from FFT or fixed 5.5 Hz default
- `SoundscapePlayer`: `setBinauralBeat(frequency: Float)` + stereo sine-wave generator (left: carrier, right: carrier + beat)
- `DepthGate`: call `setBinauralBeat` at deep state entry with dominant theta freq
- UserDefaults: `binauralBeatEnabled: Bool`, `binauralBeatHz: Float`
- ~200 lines, no hardware change, works on Muse S
- Neuroscience basis: theta binaural entrainment (4.5–6 Hz) directly stimulates occipital theta even without Oz electrode — highest-impact single remaining software feature

### B127 Deferred list (from B118)
- State-contingent coaching triggers (C1) — EEG-state-driven, not 360/600/900s timers
- Differential diagnosis per induction-stall (C2) — highArousal vs overEfforting vs drowsy
- Positive anchoring at ecdfDisplay ≥ 0.80 sustained ≥3 samples (C3)
- Ectopic-RR filter (F8) — needs offline validation first
- Phase-continuous iTPF binaural ramp (backlog B94)

---

## Key Files

| File | Purpose |
|------|---------|
| `STATUS.md` | Canonical build state — READ FIRST |
| `MusePlus/App.swift` | Session management, gate events, FAABarView, all 3 session-end paths |
| `MusePlus/SessionRecorder.swift` | Score, NDJSON footer, denoise accumulators, gateEvent, driftAlert |
| `MusePlus/Audio/DepthGate.swift` | Gate logic, deep state maintenance, BOCPD, alpha-theta, silence gap |
| `MusePlus/Audio/SoundscapePlayer.swift` | Gain composition, reverb, silence gap, binaural |
| `MusePlus/Audio/EnterSustainedShaping.swift` | Adaptive gate shaping, UserDefaults, streak counters |
| `MusePlus/Pipeline/BayesianChangepointDetector.swift` | BOCPD NIG conjugate, logit-transform, Accelerate |
| `MusePlus/SessionNarrative.swift` | Plain-English session summary, 6 dimensions |
| `MusePlus/TrendsView.swift` | Cross-session charts |
| `MusePlus/Pipeline/DepthScore.swift` | meditationIndex, FAA, betaZRaw, calibration |
| `MusePlus/Pipeline/HRVPipeline.swift` | RMSSD, SDNN, SD1, SD2, DFA α1 |
| `MusePlusTests/SessionNarrativeTests.swift` | 6 narrative tests (all pass after f311a01) |
| `MusePlusTests/BayesianChangepointDetectorTests.swift` | 3 BOCPD tests |
| `analysis/` | Python session analysis scripts |
| `G:\My Drive\session_*.json` | Session JSON (Google Drive desktop sync) |

---

## Diagnostic Commands

```bash
gh run list --limit 5            # CI status
gh run view <id>                 # run details
```

Console filter: category `Telemetry.recording` — calibration beta, score computation, gate events, drift alerts.
