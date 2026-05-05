# BUILD_PLAN_55 — Foundations: Tier 1 biomarkers + complete SessionRecorder

**Date drafted:** 2026-05-05
**Current TestFlight build:** 54 (binary = "Build 51 features" per BUILD_PLAN_51.md)
**This plan delivers:** TestFlight build 55 (next push) — Tier 1 #3 (1/f aperiodic slope) + Tier 1 #5 (iTPF) + complete SessionRecorder fields per STATUS pending list.

**Pillar mapping:** This is a **foundations** build — does not advance any of the 3 trainer pillars by itself, but provides primitives all subsequent pillar builds depend on. Specifically:
- 1/f slope feeds Pillar 2 drift early-warning (build 60) and Pillar 3 retrospective reports (build 67)
- iTPF feeds Pillar 1 personalized binaural targeting (build 56) and the adaptive audio bandit (build 61)
- SessionRecorder fields feed every Pillar 3 transfer-tracking feature (builds 64–67)

---

## GOALS — three deliverables

### Goal A — Aperiodic exponent (1/f slope, FOOOF/SpecParam-lite)

Measure the slope of log10(power) vs log10(frequency) over 1–40 Hz on each session.

- Steeper slope (more negative, e.g. −1.8) → cortical inhibition, deep absorption, sleep onset
- Flatter slope (e.g. −0.8) → cortical arousal, alert task engagement
- Reference: Donoghue, Haller, Peterson et al. 2020. *Parameterizing neural power spectra into periodic and aperiodic components.* Nat Neurosci 23:1655–1665.

**What we ship:**
- `Pipeline/AperiodicSlope.swift` — fits a single slope + offset to log-log PSD on 1–40 Hz, excluding canonical band peaks (ignore bins within ±1 Hz of α and θ peaks identified by existing `peakFreq`).
- Per-channel slope (4 values: TP9, AF7, AF8, TP10), plus mean across 4.
- Surface as a header chip in `MeditationView`: `1/f −1.42` with color (red >−1.0 = aroused; green <−1.5 = absorbed).
- Recorded per-sample in SessionRecorder.

**Algorithm (no external dependencies):**

```swift
// Inputs: psd[bin] = power per bin from existing FFT (mag2, normalized).
// Output: slope (negative Float) and offset.
// Method: linear regression on (log10(f), log10(psd)) over 1-40Hz, mask band peaks.

func fitAperiodicSlope(psd: [Float], binResolutionHz: Float, peakBins: [Int]) -> (slope: Float, offset: Float, r2: Float) {
    let lo = Int(1.0 / binResolutionHz), hi = Int(40.0 / binResolutionHz)
    var xs: [Float] = [], ys: [Float] = []
    let mask = Set(peakBins.flatMap { ($0-1)...($0+1) })  // ±1 Hz exclusion zones
    for i in lo...hi where !mask.contains(i) && psd[i] > 0 {
        xs.append(log10(Float(i) * binResolutionHz))
        ys.append(log10(psd[i]))
    }
    // Standard OLS
    let n = Float(xs.count)
    let mx = xs.reduce(0,+) / n, my = ys.reduce(0,+) / n
    let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0,+)
    let den = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0,+)
    let slope = num / den
    let offset = my - slope * mx
    let predicted = xs.map { offset + slope * $0 }
    let ssRes = zip(ys, predicted).map { ($0 - $1) * ($0 - $1) }.reduce(0,+)
    let ssTot = ys.map { ($0 - my) * ($0 - my) }.reduce(0,+)
    let r2 = 1 - ssRes / ssTot
    return (slope, offset, r2)
}
```

**Quality gate:** discard slope estimates with `r2 < 0.85`. Show stale value with dimmed color until next valid fit.

**LOC:** ~100 in new file + ~40 modifications in `EEGPipeline.swift` to call it + ~30 in `MeditationView` for chip. Total ~170 LOC.

---

### Goal B — Individualized Theta Peak Frequency (iTPF)

Each user's true theta peak varies between 5.5 and 7.5 Hz. Targeting binaural beats at *their* peak entrains 3-5× harder than fixed 6 Hz (Mierau et al. 2017).

- Reference: Klimesch W. 1999. *EEG alpha and theta oscillations reflect cognitive and memory performance: a review and analysis.* Brain Res Rev 29:169–195.
- Reference: Mierau A, Klimesch W, Lefebvre J. 2017. *State-dependent alpha peak frequency shifts: experimental evidence, potential mechanisms and functional implications.* Neuroscience 360:146–154.

**What we ship:**
- `Pipeline/iTPFTracker.swift` — accepts a stream of `thetaPeak` Hz (already produced by EEGPipeline `peakFreq(4, 8)`), maintains:
  - Within-session EMA (α=0.05, slow)
  - Cross-session weighted mean (persisted in UserDefaults under key `iTPF.<channel>`, written at session end with weight = `samples_count`)
  - Frontal (AF7, AF8) only — temporal channels (TP9/TP10) too noisy at frontal-theta band for stable peak.
- `SoundscapePlayer.adaptiveBinauralFor(depthScore:)` extended: when `depthScore > 0.45` AND iTPF is reliable (≥3 prior sessions), use `iTPFFrontalMean` as theta beat freq instead of fixed 6 Hz.
- Display in SettingsSheet (developer view): "Your θ peak: 6.32 Hz (last 12 sessions)"

**Reliability gate:** require ≥10 minutes of clean (artifactSuppressed=false) frontal data accumulated across ≥3 sessions before treating cross-session iTPF as valid. Until then, fall back to fixed 6 Hz.

**LOC:** ~120 in new file + ~30 in SoundscapePlayer + ~20 in SettingsSheet. Total ~170 LOC.

---

### Goal C — Complete SessionRecorder fields

Per STATUS.md pending: add `heartRate`, `faa`, `soundscapeEvents`, `preSessionBaseline`. Plus add fields needed for builds 60–67: `aperiodicSlope`, `iTPFEstimate`, `intentionMode` (placeholder for build 56).

**Schema additions to `SessionSample`:**

```swift
struct SessionSample: Codable {
    // existing
    let time:   Double
    let alpha:  Float
    let theta:  Float
    let beta:   Float
    let delta:  Float
    let gamma:  Float
    let depth:  Float
    let inDeep: Bool
    // build 55 additions
    let heartRateBPM: Float?      // from MuseClient PPG; nil if not yet locked
    let faa: Float?               // af8α - af7α; nil if either electrode artifactSuppressed
    let aperiodicSlopeMean: Float?  // mean across 4 channels; nil if r2 < 0.85
    let iTPFFrontal: Float?       // current within-session EMA of frontal theta peak
}
```

**New top-level fields in `SessionRecord`:**

```swift
struct SessionRecord: Codable {
    // existing
    let id: String
    let startDate: Date
    var endDate: Date?
    var samples: [SessionSample]
    var episodes: [DeepEpisode]
    var fitEvents: [Double]
    // build 55 additions
    var preSessionBaseline: BaselineCapture?  // 90s capture; nil if user skipped
    var soundscapeEvents: [SoundscapeEvent]
    var endingSelfRating: Int?  // 0-10, captured in 1-question post-session sheet (placeholder for build 64)
}

struct BaselineCapture: Codable {
    let startDate: Date
    let durationSeconds: Double
    let eyesOpenAlpha: Float
    let eyesClosedAlpha: Float
    let eyesClosedTheta: Float
    let bermanRatio: Float?  // (closed-α / open-α); >1 = good occipital alpha (Berger 1929)
    let restingBPM: Float?
    let aperiodicSlopeMean: Float?
}

struct SoundscapeEvent: Codable {
    let time: Double
    enum Kind: String, Codable {
        case soundscapeStart, soundscapeStop, binauralChange, chime, timerEnd
    }
    let kind: Kind
    let detail: String?  // e.g. "brook -> rain" or "depth gate enter"
}
```

**Pre-session baseline capture flow:**

- New `BaselineView` shown after device connects, before MeditationView is reachable.
- 30s eyes-open + 60s eyes-closed prompts (visual cues on screen + audio "open eyes" / "close eyes" voice or chime).
- Records `BaselineCapture` to current SessionRecord.
- User can skip → `preSessionBaseline = nil`.

**LOC:** ~90 SessionRecorder + ~180 BaselineView + ~40 hooks across MuseClient/SoundscapePlayer to emit events. Total ~310 LOC.

---

## TOTAL LOC ESTIMATE

| Goal | New | Modified | Total |
|------|-----|----------|-------|
| A — 1/f slope | 100 | 70 | 170 |
| B — iTPF tracker | 120 | 50 | 170 |
| C — SessionRecorder + baseline | 270 | 40 | 310 |
| **Total** | **490** | **160** | **~650** |

Spread across ~8 files. Single working session reasonable.

---

## PHASE 0 — Pre-flight

### 0.1 — Compile-time risks (grep before commit)

| Risk | Expected | File |
|------|----------|------|
| `BandPowers` init order intact | `delta,theta,alpha,beta,gamma,deltaPeak,...` | EEGPipeline.swift |
| New `SessionSample` fields are Optional Float | `Float?` not `Float` (back-compat with existing JSON) | SessionRecorder.swift |
| Codable for new structs | All new fields conform | SessionRecorder.swift |
| iTPF UserDefaults keys | `"iTPF.AF7"`, `"iTPF.AF8"`, `"iTPF.weight.AF7"`, `"iTPF.weight.AF8"` | iTPFTracker.swift |
| AperiodicSlope handles `psd[i] == 0` | Skip log10(0) → -inf | AperiodicSlope.swift |

### 0.2 — JSON back-compat check

Existing build 54 JSON files in users' Files app must still decode after schema change. Add `decodeIfPresent` for all new fields. **Test:** load a real build 54 export JSON file in unit test, decode against new schema, assert no crash.

### 0.3 — Quality gate testing

Run aperiodic slope fit on synthetic 1/f^1.5 noise → assert slope ≈ −1.5 ± 0.1 with r²>0.95. Run on white noise → assert slope ≈ 0 ± 0.1. Sanity check before shipping.

---

## PHASE 1 — Implementation order (recommended)

1. **AperiodicSlope.swift** standalone + unit test. Synthetic-signal validation. ~1 hr.
2. **EEGPipeline integration** — call `fitAperiodicSlope` after each FFT, append to per-sample output. ~30 min.
3. **iTPFTracker.swift** standalone + persistence. ~1 hr.
4. **SoundscapePlayer integration** — adaptive binaural reads iTPF when reliable. ~30 min.
5. **SessionSample + SessionRecord schema migration** + JSON decode-tolerant. ~45 min.
6. **BaselineView + onboarding flow injection.** ~1.5 hr.
7. **MeditationView header chip** for 1/f slope display. ~30 min.
8. **SettingsSheet developer info** for iTPF estimate. ~20 min.

Total: ~6.5 hours active work. Plan 1 working session.

---

## PHASE 2 — Git commit (when complete)

```bash
git add MusePlus/Pipeline/AperiodicSlope.swift
git add MusePlus/Pipeline/iTPFTracker.swift
git add MusePlus/Pipeline/EEGPipeline.swift
git add MusePlus/Audio/SoundscapePlayer.swift
git add MusePlus/SessionRecorder.swift
git add MusePlus/Views/BaselineView.swift
git add MusePlus/App.swift
git add docs/BUILD_55_TEST_RESULTS.md  # synthetic-signal validation log
git add STATUS.md
git add JOURNAL_MusePlus.md
git add BUILD_PLAN_55.md  # commit the plan itself this time
```

```bash
git commit -m "feat(build55): foundations — 1/f aperiodic slope, iTPF tracker, complete SessionRecorder fields, pre-session baseline view

Tier 1 biomarkers (Donoghue 2020 + Klimesch 1999 + Mierau 2017):
- AperiodicSlope.swift: log-log linear fit on 1-40Hz PSD, band-peak masking, r2 quality gate
- iTPFTracker.swift: within-session EMA + cross-session weighted mean per frontal channel, persisted in UserDefaults
- SoundscapePlayer adaptive binaural now uses iTPF when reliable (>=3 prior sessions, >=10 min clean data)

SessionRecorder schema completion (per STATUS.md pending list):
- SessionSample adds heartRateBPM, faa, aperiodicSlopeMean, iTPFFrontal (all Optional, JSON back-compat)
- SessionRecord adds preSessionBaseline, soundscapeEvents, endingSelfRating
- BaselineCapture struct: 30s eyes-open + 60s eyes-closed, computes Berger ratio
- SoundscapeEvent struct: enumerated event log

UI:
- BaselineView: post-connect, pre-session capture flow with chime cues
- MeditationView header: 1/f slope chip with color coding (red>-1, green<-1.5)
- SettingsSheet: shows iTPF estimate per channel + sample count

Foundations build — does not advance pillar 1/2/3 directly but provides primitives builds 56-67 depend on."
```

---

## PHASE 3 — CI pipeline

Same as build 51/53/54: `github.run_number` will become `55` on this push. xcodebuild archive → upload via altool. Same provisioning profile, same secrets. No CI changes.

---

## PHASE 4 — On-device acceptance gates

| Gate | Test | Pass criterion |
|------|------|----------------|
| AS-1 | Connect Muse, sit 60s, observe 1/f chip | Updates every ~2s; r²≥0.85 ≥80% of the time |
| AS-2 | Synthetic eyes-closed (close eyes, relax 30s) | Slope steepens by ≥0.2 vs eyes-open baseline |
| AS-3 | Pre-session baseline flow runs without crash | 90s capture completes; BaselineCapture stored in SessionRecord |
| AS-4 | Berger ratio sanity | Eyes-closed α / eyes-open α ≥ 1.3 in healthy users (occipital alpha block) |
| AS-5 | iTPF persistence across app restarts | Kill app, reopen — UserDefaults `iTPF.AF7` survives |
| AS-6 | Adaptive binaural changes after 3 sessions | Frequency drifts from 6 Hz toward user's iTPF (visible in dev settings) |
| AS-7 | JSON export round-trip | Old build 54 exports still load; new build 55 exports include new fields |
| AS-8 | Regression: build 54 features all still work | DepthGate, soundscapes, chimes, timer, signal quality, heart rate — all unchanged |

---

## KNOWN LIMITATIONS (not blockers)

| Issue | Impact | Future fix |
|-------|--------|-----------|
| Aperiodic fit ignores knee parameter (full SpecParam has it) | Acceptable for 1-40Hz on Muse S — knee is below 1Hz anyway | Add knee fit if extending to 0.5-50Hz |
| iTPF unreliable for very low-power theta users | Falls back to 6 Hz fixed; no harm | Add user-prompted manual iTPF set in advanced settings |
| Berger ratio interpretation assumes non-impaired occipital alpha (clinical caveat) | Some users (~5%) lack strong α blocking response | Surface to user only if ratio looks anomalous; do not gate behavior |
| BaselineView interrupts immediate-meditation users who want fast start | Add "skip" button + remember preference | Already specified — `preSessionBaseline = nil` valid path |

---

## QUICK REFERENCE

| Item | Value |
|------|-------|
| Plan target Apple build | 55 (whichever run_number that lands on) |
| Estimated session count | 1 |
| Estimated LOC | ~650 |
| New files | 4 (AperiodicSlope, iTPFTracker, BaselineView, BUILD_55_TEST_RESULTS) |
| Modified files | 5 (EEGPipeline, SoundscapePlayer, SessionRecorder, MeditationView in App.swift, SettingsSheet in App.swift) |
| Compile risks | 5 (see Phase 0.1) |
| Acceptance gates | 8 (see Phase 4) |
