# MusePlus — STATUS

**Last updated:** 2026-05-07 (B77 ready to push)

## Build State

| Build | Feature | TestFlight | Notes |
|-------|---------|-----------|-------|
| 40–54 | Foundation → signal quality → audio | ✅ Historical | See journal |
| 55–64 | Feature dev (never device-tested) | ⚠️ Intermediate | Superseded by 65 |
| 65 | Full feature set | ✅ Uploaded | BROKEN — calibration stuck |
| 66 | Calibration root-cause fixes | ✅ Uploaded | First working build |
| 67–73 | Incremental features | ✅ Uploaded | See journal |
| **74** | Soundscape overhaul + HRV + Ad Hoc CI | ✅ TestFlight | Last stable before depth fixes |
| 75 | Depth scoring overhaul (calibration discard, MAD baseline) | ✅ TestFlight | Saturation persisted — sigmoid display crushed all dynamic range |
| 76 | Stored calibration metadata for analysis | ✅ TestFlight | Same display saturation as B75; data analysis confirmed root cause |
| **77** | ECDF display + aperiodic correction + SDK Elements + tap-to-mark + going-deeper chime | ⚙️ **Building** | **Comprehensive overhaul — see B77 section below** |

---

## What Build 75 Changed (over Build 74)

### Depth Scoring — Root Cause Fix

**Problem confirmed by data analysis of 5 real sessions:**
- 86.5% of meditation-phase z-scores positive → score never below 0.5
- 38% of samples saturating at sigmoid(3) = 0.9526 → gauge stuck at 80–90
- Root cause: 60s calibration window captured headband-adjustment transient (elevated beta, suppressed alpha/theta). Meditation state always above calibration baseline → z always positive.
- Secondary finding: session JSON files do NOT contain calibration-phase data (recording starts 300s post-calibration). All prior analysis of "calibration baseline" was actually early meditation phase.

**Fixes in `DepthScore.swift`:**
1. **Discard first 30s of calibration** — `progress >= 0.5` time-based gate. Only settled last 30s used for baseline. `calibrationAllSamples` kept as fallback for sub-1Hz delivery.
2. **MAD-based robust baseline** — Median + MAD×1.4826. Resistant to artifact outliers.
3. **Upper z-clip removed** — was `clamp(z, -3, 3)`, now `max(-3.0, z)`. The +3 clip was saturating 38% of samples at sigmoid(3)=0.9526 with no resolution.

### Contact Gate Fix (`DepthGate.swift`)
- Before: bad contact → immediate 0.92 decay → gauge snapped on every TP9/TP10 flicker.
- After: 30s hold (60 windows), then α=0.97 slow decay. Bad contact = unknown, not declining.
- `contactLossWindows` counter reset on `reset()` and on contact restored.

### Display & UX (`App.swift`)
- `displayScore = max(0, (score - 0.5) * 2.0)` — remaps [0.5, 1.0] → [0, 100%].
- `gdt = (enterThreshold - 0.5) * 2` — gate display threshold. All labels/colors are fractions of gdt; adapts when enterThreshold personalises.
- `stateText`, `gaugeColor`, `trainingHint` all gate-aware (thresholds at 0.15×, 0.50×, 0.75×, 0.80× gdt).
- Calibration countdown uses `DepthScore.calibrationDuration` (not hardcoded 60).
- **ConnectView gear button** — Settings/Sessions accessible without headband connected.

### Session Metadata (`SessionRecorder.swift`)
- `SessionRecord` stores `calibrationIndexMean?` and `calibrationIndexStd?` — enables offline calibration analysis. Nil in pre-Build 75 sessions (backward compatible).
- `startSession(calibrationIndexMean:calibrationIndexStd:)` — values captured at calibration-complete time, stored before the 300s delay fires.

### Settings Diagnostics (`App.swift`)
- "Cal. Baseline Mean" + "Cal. Baseline Std" rows in Depth section (post-calibration).
- "Display %" row shows `(smoothedScore - 0.5) * 200` as percentage.
- Adaptive Deep Threshold shown as display-scale % ("30% display depth") not raw sigmoid.

### Info.plist
- `UIFileSharingEnabled = YES` — enables iTunes bulk export of MuseSessions/ folder.

---

## Build 75 Validation Checklist

Run one full session after TestFlight install:

- [ ] Gauge starts at 0% after calibration — does NOT jump to 80+ immediately
- [ ] Score dips below 50% during unsettled periods
- [ ] Settings → Depth: "Cal. Baseline Mean" and "Cal. Baseline Std" visible
  - Std 0.10–0.35 = normal; < 0.10 = suspiciously stable; > 0.40 = recalibrate
- [ ] Calibration countdown reads "60s" to "0s" correctly
- [ ] Contact flicker: gauge holds ~30s before slow decay (no snap to 50%)
- [ ] Gear icon visible on connect screen (no headband needed)

---

## Pending

| Item | Priority | Notes |
|------|----------|-------|
| Display remap tuning | Medium | After B75 session data: check if p50 displayScore ≈ 30–50%. May need denominator adjustment in `(score - 0.5) / X`. |
| Phase A2: Athena model detection | High | Task #13 in progress. Preset branch logic. |
| baselineStd floor 0.10 validation | Medium | Provisional. Check calibrationIndexStd in Settings after a few B75 sessions. |
| fNIRS OpticsPipeline (Gate 13) | Low | HbO/HbR from Athena Optics1-6. SessionSample placeholders exist. |

---

## Architecture Invariants (never break without understanding)

- `handleIsGood` rate-limited to 5s — prevents calibration-stuck bug
- Contact chimes gated behind `depth.isCalibrated`
- Beta cue: additive threshold `bm + 1.5 * bs` (NOT multiplicative — wrong in log domain)
- Binaural fade: baked into `fillBinaural` amplitude, NOT node volume
- Athena preset: `preset1041` for MS-03, `preset21` for legacy
- AVAudioEngine stereo format explicit on all `engine.connect()` calls
- `asyncAfter(0.5s)` in `AVAudioEngineConfigurationChange` handler
- `calibrationAllSamples` fallback in `finalizeBaseline()` — do not remove

---

## Key Files

| File | Purpose |
|------|---------|
| `MusePlus/App.swift` | Root view, Probe, all UI, DepthGaugeView, SettingsSheet |
| `MusePlus/Muse/MuseClient.swift` | BLE + SDK wrapper |
| `MusePlus/Pipeline/DepthScore.swift` | Calibration (discard first 30s), MAD baseline, z-score |
| `MusePlus/Audio/DepthGate.swift` | State machine, hold-then-decay contact logic |
| `MusePlus/Pipeline/HRVPipeline.swift` | RMSSD + LF/HF (Athena Optics7/8) |
| `MusePlus/Audio/SoundscapePlayer.swift` | DSP rain/ocean/wind + binaural fade |
| `MusePlus/SessionRecorder.swift` | JSON recording + calibration metadata |
| `STATUS.md` | This file — read first every session |

---

## How to Resume

```
1. Read STATUS.md (this file)
2. gh run list --limit 5        ← verify CI clean
3. If B75 not validated: run session, check validation checklist above
4. Next feature: Phase A2 Athena model detection (task #13)
```
