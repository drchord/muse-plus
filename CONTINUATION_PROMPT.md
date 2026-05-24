# MusePlus — Continuation Prompt

**Read STATUS.md first. Then read this.**

---

## Current State (as of 2026-05-23)

**B125 = CI run 26341344481, green** — all B122 code review fixes committed and live in TestFlight.  
**B121 session (2026-05-23_0538):** physiologicalScore=97/100. deepFraction=0 (gate correct — ecdfMax=0.944 never sustained 10s).

---

## What B122→B125 Shipped

### 9 new NDJSONFooter fields (SessionRecorder.swift)

| Field | Type | Why it was added |
|-------|------|-----------------|
| `betaZRaw` | Float? | bz=5.125 in B121 was clamped to score=50. Unclamped value preserves longitudinal magnitude. |
| `signalQualityMeanSpikes` | Float? | B121 had 33.3 spikes/frame (5.6×). Was NDJSON-only, invisible in JSON. |
| `signalQualityAlphaPowerRatio` | Float? | Denoiser confidence per session. B121=0.744, better than B120=0.699 despite more spikes. |
| `potatoFlaggedPct` | Float? | Riemannian Potato verdict fraction. |
| `alphaRelMean` | Float? | Calibration-independent. B121 grew 0.337→0.389 (+15.6%) — temporal deepening arc. |
| `thetaRelMean` | Float? | Same. |
| `betaRelMean` | Float? | Same. |
| `ecdfMax` | Float? | Main-phase peak. B121 reached 0.944 — gate never fired but threshold was approached. |
| `ecdfP90` | Float? | Main-phase 90th percentile. |

### NDJSONGateEvent
`_type: "gateEvent"` record in NDJSON stream. Fields: `time`, `path` ("cleared"/"timeout"), `tp9Tier`, `tp10Tier`.  
- Pre-session gate events buffered in `pendingGateEvents`, flushed at `startSession()` with `time=-1.0`.  
- `appendGateEvent()` called from App.swift at gate timeout and gate clear.

### FAABarView fix (App.swift)
- Color direction: `clamped < 0` → green (was `clamped >= 0` → green — Davidson convention, wrong for Sugato).
- Labels: "approach"/"withdrawal" → "left-frontal"/"right-frontal".
- Now consistent with `WarmupFAAReadiness` (faa≤-0.08 → green).

### DepthScore.swift FAA comment
- r=-0.76 (n=8, overstated early sessions) → r=-0.43 (n=16, p≈0.10, NOT significant).
- "Positive FAA reliably predicts zero depth — no exceptions in 16 sessions."
- "Negative FAA necessary but not sufficient."

### Code review fixes (B125)
1. `calBetaStd > 0` → `>= 0` (lines 694 + 1138). `max(calBetaStd, 0.10)` is the safety floor. Strict `> 0` caused betaZRaw=nil while betaZScore was set via else-branch — silent inconsistency.
2. `ecdfVals` → `mainEcdfVals` (CI error fix: redeclaration in same scope).
3. ecdf computation scoped to `phase == "main"` — warmup spikes excluded from ecdfMax/ecdfP90.
4. appendGateEvent comment: documents internal access is intentional.
5. ecdf comment: corrected to adaptive threshold table (0.55→0.70 by session count), kEnterSustained=default 20 (tunable).

---

## B122 Validation Checklist (first session on B125)

1. Footer `betaZRaw` non-nil — expected 2.0–6.0 for Sugato.
2. Footer `signalQualityMeanSpikes`, `signalQualityAlphaPowerRatio`, `potatoFlaggedPct` non-nil.
3. Footer `alphaRelMean`, `thetaRelMean`, `betaRelMean` non-nil.
4. Footer `ecdfMax`, `ecdfP90` non-nil and in [0, 1].
5. NDJSON stream has `{"_type":"gateEvent","path":"cleared",...}` near session start.
6. `FAABarView` green when FAA < 0 — verify in live session UI.
7. Footer `metricDefinitions.faa` cites r=-0.43 (not r=-0.76).

---

## FAA Empirical Facts (definitive, n=16 sessions)

- `faa = af8Alpha - af7Alpha` (right minus left, log10 µV²)
- r(FAA, depthZ) = -0.43, r(FAA, deepFraction) = -0.48, p≈0.10 — direction consistent, NOT significant
- **Positive FAA → zero depth (no exceptions, n=16)** — this is the load-bearing signal
- **Negative FAA → necessary but not sufficient** — many negative-FAA sessions still missed depth
- For Sugato: negative FAA = right-frontal dominant = green indicator
- **NEVER restore r=-0.76** — that was n=8 early sessions, overstated

---

## Architecture Invariants (cumulative — all must be preserved)

**Always:**
- `handleIsGood` 5s rate limit — NEVER REMOVE
- Contact chimes gated behind `depth.isCalibrated`
- AVAudioEngine stereo format explicit on all `engine.connect()`
- `SessionRecorder` serial DispatchQueue + file protection `.completeFileProtectionUnlessOpen`
- `SoundscapePlayer.stopAll()` BEFORE `EndGongPlayer.playSuccess()` — ordering load-bearing
- `SoundscapePlayer.isStopping` — blocks `resumeActiveLayers()` during fade
- `PersonalZDistribution.ingestSession()` filters `phase == "main"` only
- Gain = `min(proximityGain, deepStateGain)` everywhere — never multiply
- `DepthGate.applyProximityDuck()` guard `!inDeepState` — load-bearing
- `EndGongPlayer.bundleURL()` tries .m4a → .mp3 → .wav at root then Sounds/ — ordering load-bearing
- `pendingGongEvents` + `pendingGateEvents` buffers — never remove either
- `SessionRecorder.save()` wrapped in `NSFileCoordinator.coordinate(.forReplacing)`
- On `.disconnected` while recording: enter 30s grace — do NOT immediately endSession

**B122+:**
- `calBetaStd >= 0` guard (NOT `> 0`) in BOTH betaZRaw (line ~694) and betaZScore (line ~1138)
- `ecdfMax`/`ecdfP90` scoped to `phase == "main"` only
- `appendDenoiseStats` accumulates ONLY when `bypassReason == nil`
- `pendingGateEvents` flush in `startSession()` AFTER `openNDJSONHandle()`
- `FAABarView` color gate: `clamped < 0` → green (matches WarmupFAAReadiness)
- `metricDefinitions.faa` = r=-0.43 (n=16, p≈0.10) — NOT r=-0.76

**B120+:**
- `attachCalibrationBeta()` guard checks `current != nil` (NOT `isRecording`) — race-condition-safe
- `SessionRecorder.save()` + `CrashRecovery`: `.completeFileProtectionUnlessOpen`
- `synthesiseRecord()` decodes full NDJSONFooter — if you add a footer field, add it to synthesiseRecord() too

**B118+:**
- buildTag dynamic from `CFBundleVersion` — never hardcode
- All coaching events through `recordCoach()` — A/B analysis requires this
- `metricDefinitions` is authoritative; formula changes need same-commit dict update
- `calibrationBetaAttached: false` in footer = betaZScore void for that session

**B109+:**
- `attachCalibrationBeta` MUST be called AFTER `startSession`
- `recordingStartedAt` must not be nil before `buildDiagnostics`
- All three session-end paths carry the full HRV attachment block

---

## Score Decomposition (reference)

`physiologicalScore = betaZScore(0–50) + rmssdScore(0–30) + coherenceScore(0–20)`

| Component | Formula | Range |
|-----------|---------|-------|
| betaZScore | `(calBeta - sessBeta) / max(calBetaStd, 0.10) / 2.0 * 50.0` clamped 0–50 | 0–50 |
| betaZRaw | same without clamping — betaZRaw > 2.0 means score was at ceiling | unclamped |
| rmssdScore | `<40ms→0-10, 40-65ms→10-25, 65-100ms→25-30, ≥100ms→30` | 0–30 |
| coherenceScore | `frontalGoodFrac × 20.0` | 0–20 |

B121 decomposition: betaZ=50 (bz=5.125 at ceiling), rmssd=27, coherence=20 → total=97.

---

## DepthGate Entry Logic (reference)

```
enterThresholdEcdf: n=0→0.55, n<5→0.60, n<20→0.65, n≥20→0.70
exitThresholdEcdf:  n=0→0.40, n<5→0.45, n<20→0.48, n≥20→0.50
kEnterSustained: default 20 windows × 0.5s = 10s (tunable 6–24 via UserDefaults key "kEnterSustainedWindows")
Entry: smoothedDisplay(Kalman) ≥ enterThresholdEcdf for kEnterSustained consecutive windows
```

At n=16 sessions (Sugato current): threshold=0.65. B121 ecdfMax=0.944 but never sustained 10s → deepFraction=0 (gate correct).

---

## B123 Candidates (do NOT implement without new session data)

- Scope denoise accumulators to main vs warmup phase separately (currently mixed)
- State-contingent coaching triggers (C1 from B118 deferred list) — build on NDJSONCoach log
- Differential diagnosis per induction-stall (C2)
- Positive anchoring at ecdfDisplay ≥ 0.80 (C3)
- ectopic-RR filter (F8) — offline validation first
- ecdfMax/ecdfP90 comment: clarify p90 index formula is conservative (`floor(n×0.90)-1`)

---

## Key Files

| File | Purpose |
|------|---------|
| `STATUS.md` | Canonical build state — READ FIRST |
| `MusePlus/App.swift` | Session management, gate events, FAABarView, disconnect paths |
| `MusePlus/SessionRecorder.swift` | Score computation, NDJSON footer, denoise accumulators, gateEvent |
| `MusePlus/TrendsView.swift` | Cross-session charts |
| `MusePlus/Audio/DepthGate.swift` | kEnterSustained (default 20, tunable), adaptive threshold, Kalman |
| `MusePlus/Audio/KalmanDepth.swift` | 2D Kalman state (depth, velocity), adaptive qD |
| `MusePlus/Pipeline/DepthScore.swift` | meditationIndex, FAA, betaZRaw formula, calibration storage |
| `MusePlus/Pipeline/HRVPipeline.swift` | RMSSD, SDNN, SD1, SD2, DFA α1 |
| `MusePlus/Audio/EEGDenoiser.swift` | Spike removal, Riemannian Potato, bypassReason |
| `analysis/` | Python scripts + session data analysis artifacts |
| `G:\My Drive\session_*.json` | Session JSON (Google Drive desktop sync) |

---

## Diagnostic Commands

```bash
gh run list --limit 5            # CI status
gh run view <id> 2>&1            # run details
```

Session JSON on device: Files → MusePlus → MuseSessions → export.  
Console filter: category `Telemetry.recording` — calibration beta, score computation, gate events.
