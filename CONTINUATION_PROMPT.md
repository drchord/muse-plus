# MusePlus — Continuation Prompt

**Read STATUS.md first. Then read this.**

---

## Current State (2026-05-25)

**B127 pushed to origin/main** — CI run 26408036846, in progress as of 2026-05-25 ~11:00 ET.  
Last confirmed green: B126 (CI run 26358648681).  
**B126 validated:** Two sessions this morning — S1 deepFraction=0.954 (best ever), S2 deepFraction=0.890.

---

## What B127 Shipped

### Root Cause Fixed: Binaural Dead-Write

Pre-B127: `startNode(buffer, options:.loops)` creates an infinite looping buffer with no completion callback. ALL `customBinauralHz` writes during a session were dead — frequency never changed until layer restarted. `updateAdaptiveDepth`'s `iTPF - 2.0` tier formula also pushed the beat to ~3.78 Hz (delta range) for typical iTPF=5.78 Hz. Neither bug was audible as a crash; both silently sabotaged the entrainment effect.

### Option C — AVAudioSourceNode (backbone)

`SoundscapePlayer.makeBinauralSourceNode(format:)` creates an `AVAudioSourceNode` with two phase accumulators (`phaseL`, `phaseR`). On each ~23ms render frame it reads `_binauralBeatHz` (Double) and `_binauralAmp` (Float) — both written only from the main thread. ARM64 aligned 64/32-bit stores are single-instruction; no lock needed. Phase is continuous across frequency changes — no click, no gap.

Engine graph: `AVAudioSourceNode → binauralEQ(AVAudioUnitEQ) → mainMixerNode → ambientReverb → output`

The source node starts at `volume = 0` in `init()`. `activate(.binaural)` calls `ensureRunning()` then sets volume. `deactivate(.binaural)` sets volume to 0. No `startNode(buffer:options:.loops)` is ever called for binaural.

`customBinauralHz` is now a computed property: setter writes both `_customBinauralHz` and `_binauralBeatHz`. `binauralFadeLevel.didSet` writes `_binauralAmp`. All downstream consumers of `customBinauralHz` (updateAdaptiveDepth, setAdaptiveBinauralIfActive, binauralPreset.didSet) automatically propagate to the render callback.

### Option A — Session-start priming (App.swift, line ~1063)

At `SessionRecorder.shared.startSession()` (calibration end), if `pipeline.iTPFTracker.isReliable` (sessionCount ≥ 3 AND cleanMinutes ≥ 10), `customBinauralHz` is set from `iTPFTracker.currentEstimate`. For today's data: starts at ~5.78 Hz instead of 6.0 Hz preset. Falls back silently if not reliable. Once live iTPF arrives (via `updateAdaptiveDepth` every 0.5s), it overrides the primed value within the hysteresis band.

### Option B — Deep-entry live update

`setAdaptiveBinauralIfActive(hz: Double(iTPF))` already fires at deep entry (App.swift line 903-904). With Option C as transport, the write is now live on next audio frame. Comment on the function corrected from "≤120s latency" to "~23ms". No call-site change needed.

### Bug Fixes

| Bug | Fix |
|-----|-----|
| `updateAdaptiveDepth` `iTPF - 2.0` → delta range | Now: `max(4.0, min(8.0, rawHz))` with 0.10 Hz hysteresis. Returns early if iTPF nil. |
| `activate(.binaural)` missing `ensureRunning()` | Found in pre-push audit: engine stopped after `stopAll()`. Fixed. |
| `alphaThetaMean` description wrong | "log10 µV² difference" → "linear theta/alpha ratio >1.0 = theta-dominant" |
| `alphaThetaCrossoverCount` description wrong | "alphaTheta < 0" → "theta/alpha ratio > 1.0" |

---

## B127 Validation Checklist (first session on B127 TestFlight)

- [ ] Binaural starts at ~5.78 Hz (not 6.0 Hz) if ITPFTracker.isReliable — listen for slightly slower beat than before
- [ ] No click or gap at deep state entry — frequency update is seamless
- [ ] `customBinauralHz` in Telemetry/logs tracks iTPF drift (≥0.10 Hz changes)
- [ ] `binauralFadeLevel` still decrements after successful sessions; amplitude fades correctly
- [ ] Binaural survives BT route change (engine restart): volume restored correctly by `resumeActiveLayers()`
- [ ] `alphaThetaMean` description in NDJSON footer `metricDefinitions` reflects corrected text

---

## Architecture Invariants (cumulative — all must be preserved)

**B127+:**
- Binaural = `AVAudioSourceNode` + phase accumulators. No pre-generated buffer for binaural.
- `customBinauralHz` setter ALWAYS writes `_binauralBeatHz`. Never assign `_binauralBeatHz` directly from outside `SoundscapePlayer`.
- `_binauralBeatHz` / `_binauralAmp`: main-thread writes only. Audio render reads without lock (ARM64 safe).
- `activate(.binaural)` calls `ensureRunning()` before volume set.
- `startLayer()` guards `layer != .binaural`.
- `updateAdaptiveDepth`: returns early if `iTPF == nil`. [4,8] Hz theta only. No `10.0` alpha tier.

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

## B126 Session Data (2026-05-25, validated)

| Session | Score | deepFraction | rmssd | alphaThetaCrossoverCount | iTPF median |
|---------|-------|-------------|-------|--------------------------|-------------|
| S1 (0406, 61min) | 96 | **0.954** (best ever) | 72.1ms | 143 | 5.78 Hz |
| S2 (0622, 30min) | 95 | 0.890 | 66.9ms | 5 | 5.63 Hz |

S1: theta broke through alpha at t=0.53s, held for 51.2 min continuous deep. EnterSustainedShaping adaptive gate worked (gate had dropped from 12→6 windows after May 20/21/23 zero-deep streak).

S2: back-to-back session, alpha-dominant state (brain residual from S1). alphaThetaMean=4.303 with crossoverCount=5 is mathematically anomalous — potential back-to-back session reset issue. `enterSustainedAtSession=None` in S2 footer also anomalous. Both flagged for investigation if it recurs.

---

## Score Decomposition (reference)

`physiologicalScore = betaZScore(0–50) + rmssdScore(0–30) + coherenceScore(0–20)`

| Component | Formula |
|-----------|---------|
| betaZScore | `(calBeta - sessBeta) / max(calBetaStd, 0.10) / 2.0 × 50.0` clamped 0–50 |
| betaZRaw | same, unclamped |
| rmssdScore | `<40ms→0-10, 40-65ms→10-25, 65-100ms→25-30, ≥100ms→30` |
| coherenceScore | `frontalGoodFrac × 20.0` |

---

## DepthGate Entry Logic (reference)

```
enterThresholdEcdf: n=0→0.55, n<5→0.60, n<20→0.65, n≥20→0.70
exitThresholdEcdf:  n=0→0.40, n<5→0.45, n<20→0.48, n≥20→0.50
kEnterSustained:    B127 current ~6 windows × 0.5s = 3s (adapted down from 12 after May 20/21/23 zero-deep streak)
```

---

## Top Next (B128) — do NOT build until B127 CI green + one validated session

1. **State-contingent coaching (C1/C2)** — replace 360/600/900s timers with EEG-state-driven triggers + differential diagnosis. Foundation (C5 NDJSONCoach) already in B118.
2. **Positive anchoring (C3)** — soft tone when ecdfDisplay ≥ 0.80 sustained ≥3 samples.
3. **Ectopic-RR filter (F8)** — needs offline validation against historical sessions.
4. **TrendsView time-of-day stratification** — `timeOfDay` field captured since B96; UTC→local needed.

---

## Key Files

| File | Purpose |
|------|---------|
| `STATUS.md` | Canonical build state — READ FIRST |
| `MusePlus/App.swift` | Session management, Option A priming (~line 1063), deep-entry Option B (~line 903) |
| `MusePlus/Audio/SoundscapePlayer.swift` | AVAudioSourceNode binaural, gain composition, reverb |
| `MusePlus/SessionRecorder.swift` | Score, NDJSON footer, metricDefinitions |
| `MusePlus/Audio/DepthGate.swift` | Gate logic, BOCPD, alpha-theta, silence gap |
| `MusePlus/Audio/EnterSustainedShaping.swift` | Adaptive gate shaping |
| `MusePlus/Pipeline/ITPFTracker.swift` | Kalman cross-session theta peak tracker |
| `MusePlus/Pipeline/EEGPipeline.swift` | `iTPFTracker` instance (line 35), onITPFUpdate callback |
| `MusePlus/Pipeline/BayesianChangepointDetector.swift` | BOCPD NIG conjugate |
| `MusePlus/SessionNarrative.swift` | Plain-English session summary |
| `MusePlus/TrendsView.swift` | Cross-session charts |
| `analysis/` | Python session analysis scripts |
| `G:\My Drive\session_*.json` | Session JSON (Google Drive desktop sync) |

---

## Diagnostic Commands

```bash
gh run list --limit 5            # CI status
gh run view <id>                 # run details
```

Console filter: category `Telemetry.recording` — calibration beta, score computation, gate events, drift alerts, iTPF updates.
