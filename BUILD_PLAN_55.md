# BUILD_PLAN_55 — SDK 8.0.5 Migration + Athena Foundations + fNIRS Integration

**Date drafted:** 2026-05-04
**Current TestFlight build:** 54 (binary = "Build 51 features" per BUILD_PLAN_51.md)
**Hardware target:** Muse S Athena (MS-03). See `docs/ATHENA_SPECS.md` for canonical spec.
**SDK target:** 8.0.5 (migration from 7.x required before any Athena work).
**This plan delivers:** TestFlight build 55 (next push) — two sequenced sub-builds:
- **Build 55a** — SDK migration + 8-channel EEG + Optics PPG + IRASA aperiodic exponent + Gaussian iTPF + complete SessionRecorder schema
- **Build 55b** — Full fNIRS pipeline (Beer-Lambert HbO/HbR) + MeditationView fNIRS bar

**User context:** Decades-experienced practitioner. Pillar 1 entry training is dropped. This plan is advanced foundations only.

**Pillar mapping:** This is a **foundations** build — does not advance Pillars 1/2/3 directly, but provides primitives all subsequent builds depend on:
- IRASA exponent feeds Pillar 2 drift early-warning (build 60) and Pillar 3 retrospective reports (build 67)
- iTPF feeds Pillar 1 personalized binaural targeting (build 56) and adaptive audio bandit (build 61)
- fNIRS HbO trajectory feeds Pillar 3 absorption transfer tracking (builds 64–67)
- SessionRecorder fields feed every Pillar 3 feature (builds 64–67)

---

## GOALS — five deliverables

### Goal A — SDK 8.0.5 migration + Athena hardware detection

Replace SDK 7.x framework with 8.0.5. Detect Athena (`IXNMuseModelMs03`) and branch preset/pipeline config. Preserve legacy Muse S 2019 path for users with old hardware. Build must compile cleanly before any logic changes proceed.

**What we ship:** No new features — just working build with new SDK, Athena detection, preset 1041 for Athena, 8-channel EEG allocation, Optics subscription, legacy PPG path preserved.

**LOC:** ~80 modifications across `MuseClient.swift`, `project.yml`, framework swap.

---

### Goal B — IRASA aperiodic exponent (1/f slope, χ)

Measure the aperiodic exponent χ in log10(power) vs log10(frequency) using IRASA (Irregular-Resampling Auto-Spectral Analysis, Wen & Liu 2016). IRASA separates periodic from aperiodic components by resampling the signal at non-integer factors h — the aperiodic component is invariant to resampling, periodic components alias out in the geometric mean.

- Steeper exponent (more negative, e.g. −1.8) → cortical inhibition, deep absorption, sleep onset
- Flatter exponent (e.g. −0.8) → cortical arousal, alert task engagement
- Primary algorithm: IRASA geometric mean over h ∈ [1.1, 1.95] step 0.05 (19 factors)
- Backup: specparam-2.0 nonlinear knee fit if IRASA fails on a session (R² < 0.85 on >50% of 2s windows)
- References: Wen X, Liu Y. 2016. *Separating fractal and oscillatory components in the power spectrum of neurophysiological signal.* Brain Topogr 29:13–26. Donoghue T et al. 2020. Nat Neurosci 23:1655–1665.

**What we ship:**
- `Pipeline/AperiodicSlope.swift` — vDSP-accelerated IRASA. Inputs: 8-channel PSD array from existing FFT. Outputs per-channel (χ, offset, R²). Mean χ across canonical 4 channels (EEG1-4) for depth metrics.
- Surface as header chip in `MeditationView`: `χ −1.42` with color (red >−1.0 = aroused; green <−1.5 = absorbed).
- Recorded per-sample in SessionRecorder.

**Algorithm skeleton (vDSP-accelerated IRASA):**

```swift
// Inputs: psd[bin] = power per bin, Fs = sample rate (256Hz for Athena)
// h_factors: stride(from: 1.1, through: 1.95, by: 0.05) — 19 values
// Output: aperiodic exponent χ (negative), offset, R²
func fitIRASA(psd: [Float], binResolutionHz: Float, hFactors: [Float]) -> (chi: Float, offset: Float, r2: Float) {
    // For each h, upsample psd by h and downsample by h (geometric mean cancels periodic)
    // resampledPSD[h] = geometricMean(upsample(psd, h), downsample(psd, h))
    // fractalPSD = geometricMean over all h of resampledPSD[h] (vDSP.geometricMean)
    // Then OLS on (log10(f), log10(fractalPSD)) over 1-40 Hz
    let lo = Int(1.0 / binResolutionHz), hi = Int(40.0 / binResolutionHz)
    var fractalPower = [Float](repeating: 0, count: psd.count)
    // ... resampling loop using vDSP ...
    var xs: [Float] = [], ys: [Float] = []
    for i in lo...hi where fractalPower[i] > 0 {
        xs.append(log10(Float(i) * binResolutionHz))
        ys.append(log10(fractalPower[i]))
    }
    let n = Float(xs.count)
    let mx = xs.reduce(0,+) / n, my = ys.reduce(0,+) / n
    let num = zip(xs, ys).map { ($0-mx)*($1-my) }.reduce(0,+)
    let den = xs.map { ($0-mx)*($0-mx) }.reduce(0,+)
    let chi = num / den
    let offset = my - chi * mx
    let predicted = xs.map { offset + chi * $0 }
    let ssRes = zip(ys, predicted).map { ($0-$1)*($0-$1) }.reduce(0,+)
    let ssTot = ys.map { ($0-my)*($0-my) }.reduce(0,+)
    let r2 = 1 - ssRes / ssTot
    return (chi, offset, r2)
}
```

**Quality gate:** discard χ estimates with R² < 0.85. Show stale value with dimmed color until next valid fit (2s window).

**LOC:** ~150 in new `Pipeline/AperiodicSlope.swift` + ~40 in `EEGPipeline.swift` + ~30 in `MeditationView`. Total ~220 LOC.

---

### Goal C — iTPF tracker with Gaussian fit + Kalman cross-session

Each user's true theta peak varies 5.5–7.5 Hz. Targeting binaural beats at *their* peak entrains 3–5× harder than fixed 6 Hz (Mierau et al. 2017). Use Gaussian fit (not argmax) per Corcoran 2018 and Cesnaite 2023 — argmax is noise-sensitive in narrow-band spectra.

- References: Klimesch W. 1999. Brain Res Rev 29:169–195. Mierau A et al. 2017. Neuroscience 360:146–154. Corcoran AW et al. 2018. NeuroImage 174:245–263. Cesnaite E et al. 2023. J Neurosci 43:4143–4158.

**What we ship:**
- `Pipeline/iTPFTracker.swift` — Gaussian fit on theta band PSD (4–8 Hz) per frontal channel (EEG2/AF7, EEG3/AF8). Cross-session aggregation via Kalman filter: state = [iTPF, dITPF/dt], adaptive process noise from session-to-session variance.
- Within-session: Kalman update every 2s. Cross-session: state persisted in UserDefaults, updated at session end.
- `SoundscapePlayer.adaptiveBinauralFor(depthScore:)` extended: when `depthScore > 0.45` AND iTPF reliable (≥3 prior sessions, ≥10 min clean frontal data), use `iTPFFrontalMean` as theta beat freq instead of fixed 6 Hz.
- Display in SettingsSheet (developer view): "Your θ peak: 6.32 Hz (last 12 sessions)"

**Reliability gate:** require ≥10 min clean (artifactSuppressed=false) frontal data across ≥3 sessions. Until then, fixed 6 Hz.

**LOC:** ~150 in `Pipeline/iTPFTracker.swift` + ~30 in `SoundscapePlayer` + ~20 in `SettingsSheet`. Total ~200 LOC.

---

### Goal D — Complete SessionRecorder schema (55a fields)

All Optional with `decodeIfPresent` for back-compat with build 54 JSONs.

**Schema additions to `SessionSample`:**

```swift
struct SessionSample: Codable {
    // existing (unchanged)
    let time:   Double
    let alpha:  Float
    let theta:  Float
    let beta:   Float
    let delta:  Float
    let gamma:  Float
    let depth:  Float
    let inDeep: Bool
    // build 55a additions
    var eegBandPowers8ch: [BandPowers]?      // 8-element array (EEG1-4, AUX1-4); nil for legacy Muse S
    let heartRateBPM: Float?                  // Optics-derived on Athena; legacy PPG on Muse S 2019; nil if locked
    let faa: Float?                           // af8α - af7α (EEG3-EEG2); nil if either artifactSuppressed
    let aperiodicSlopeMean: Float?            // mean χ across canonical 4 channels; nil if R² < 0.85
    let iTPFFrontal: Float?                   // current Kalman-filtered frontal theta peak Hz
    // build 55b additions (placeholder — nil until 55b)
    let hboL: Float?                          // prefrontal HbO left (µM); nil in 55a
    let hboR: Float?                          // prefrontal HbO right (µM); nil in 55a
    let hbrL: Float?                          // prefrontal HbR left (µM); nil in 55a
    let hbrR: Float?                          // prefrontal HbR right (µM); nil in 55a
}
```

**New top-level fields in `SessionRecord`:**

```swift
struct SessionRecord: Codable {
    // existing (unchanged)
    let id: String
    let startDate: Date
    var endDate: Date?
    var samples: [SessionSample]
    var episodes: [DeepEpisode]
    var fitEvents: [Double]
    // build 55a additions
    var preSessionBaseline: BaselineCapture?
    var soundscapeEvents: [SoundscapeEvent]
    var endingSelfRating: Int?               // 0-10, placeholder for build 64
    var deviceModel: String?                 // "Ms03" or "MuseS2019"
    var sdkVersion: String?                  // "8.0.5"
}

struct BaselineCapture: Codable {
    let startDate: Date
    let durationSeconds: Double
    let eyesOpenAlpha: Float
    let eyesClosedAlpha: Float
    let eyesClosedTheta: Float
    let bermanRatio: Float?                  // closed-α / open-α; >1 good occipital alpha (Berger 1929)
    let restingBPM: Float?                   // Optics-derived on Athena
    let aperiodicSlopeMean: Float?           // resting χ
    let iTPFFrontal: Float?                  // resting frontal theta peak
}

struct SoundscapeEvent: Codable {
    let time: Double
    enum Kind: String, Codable {
        case soundscapeStart, soundscapeStop, binauralChange, chime, timerEnd
    }
    let kind: Kind
    let detail: String?                      // e.g. "brook -> rain" or "depth gate enter"
}
```

**LOC:** ~120 in `SessionRecorder.swift` + ~40 hooks across MuseClient/SoundscapePlayer. Total ~160 LOC.

---

### Goal E — fNIRS pipeline: Beer-Lambert HbO/HbR (Build 55b)

Subscribe to `IXNMuseDataPacketTypeOptics`, decode 16 channels per `IXNOptics` enum mapping, compute HbO/HbR via modified Beer-Lambert law, populate SessionRecorder Optics fields, display fNIRS bar in MeditationView.

**What we ship:**
- `Pipeline/OpticsPipeline.swift` — full fNIRS pipeline
- SessionRecord Optics fields populated (hboL/hboR/hbrL/hbrR per region)
- MeditationView fNIRS bar showing HbO trajectory

**LOC:** ~300 in `Pipeline/OpticsPipeline.swift` + ~40 SessionRecorder populate + ~60 MeditationView. Total ~400 LOC.

---

## TOTAL LOC ESTIMATE

| Goal | New | Modified | Total |
|------|-----|----------|-------|
| A — SDK migration + Athena detection | 0 | 80 | 80 |
| B — IRASA aperiodic exponent | 150 | 70 | 220 |
| C — iTPF Gaussian + Kalman | 150 | 50 | 200 |
| D — SessionRecorder schema | 120 | 40 | 160 |
| E — fNIRS Beer-Lambert (55b) | 300 | 100 | 400 |
| **Total** | **720** | **340** | **~1060** |

Spread across ~12 files. Two working sessions (55a ≈ 7h, 55b ≈ 5h).

---

## PHASE 0 — Pre-flight

### Phase 0.1 — Compile-time risks (grep before commit)

| Risk | Expected value | File |
|------|----------------|------|
| Muse model enum case | `IXNMuseModelMs03` (uppercase Ms03, not ms03) | MuseClient.swift |
| Preset enum case | `.preset1041` (verify case against `IXNMusePreset.h` — may be `Preset1041`) | MuseClient.swift |
| Optics enum cases | `.OPTICS1` through `.OPTICS16` (all-caps acronym preserved) | OpticsPipeline.swift |
| EEG aux channel enum | `.AUX1` through `.AUX4` (uppercase, not aux1) | MuseClient.swift |
| PPG enum NOT used on Athena | `IXNPpg` enum: confirm absent from Athena subscription path | MuseClient.swift |
| Beer-Lambert extinction matrix | Cope & Delpy 1988 published values only — NOT estimated | OpticsPipeline.swift |
| `BandPowers` init order intact | `delta,theta,alpha,beta,gamma,deltaPeak,...` | EEGPipeline.swift |
| New `SessionSample` fields | All `Optional` (`Float?` not `Float`) for JSON back-compat | SessionRecorder.swift |
| Thermistor paths | Remove any `THERMISTOR` or body-temp subscription on Athena branch | MuseClient.swift |

### Phase 0.2 — JSON back-compat check

Build 54 export JSONs must decode against new schema. All new fields use `decodeIfPresent`. **Test:** load a real build 54 JSON in unit test, decode against new schema, assert no crash, assert existing fields match.

### Phase 0.3 — Framework swap verification

After replacing `Frameworks/Muse.framework`:
1. Clean build folder in Xcode
2. `xcodegen generate` from project root
3. Build without running — assert zero errors before touching logic

---

## PHASE 1 — Build 55a: Implementation order

### Phase A1 — SDK framework swap + build verification (~1 hr)

1. Extract `libmuse_ios_8.0.5.tar.gz` from `OneDrive/CLAUDE RELATED/MUSE SDK/Muse SDK _ RDK-20260428T132319Z-3-001/Muse SDK _ RDK/Muse SDK/Muse SDK 8.0.5/`
2. Replace `Frameworks/Muse.framework` with extracted 8.0.5 framework
3. Update `project.yml` framework reference if hash/path changed
4. `xcodegen generate`
5. Clean build — assert zero compile errors before any logic changes
6. Commit checkpoint: `feat(sdk): bump Muse.framework to 8.0.5, verify compile`

### Phase A2 — Athena detection + preset selection in MuseClient.swift (~45 min)

- On `museDidConnect(_:)`: read `muse.getConfiguration().getModel()`
- Branch on `IXNMuseModelMs03`:
  - Set preset 1041 via `muse.setPreset(.preset1041)`
  - Subscribe to `IXNMuseDataPacketTypeOptics`
  - Skip `IXNPpg` subscription (legacy only)
  - Log: `"Athena detected — preset 1041, Optics subscribed"`
- Else (legacy Muse S 2019):
  - Set original preset (preserve existing code path)
  - Subscribe to `IXNMuseDataPacketTypePpg`
  - Log: `"Legacy MuseS — legacy preset, PPG subscribed"`
- Store `deviceModel` on current session record (`"Ms03"` or `"MuseS2019"`)

### Phase A3 — 8-channel EEG pipeline extension in EEGPipeline.swift (~45 min)

- Allocate 8 FFT processors (was 4) — guard on Athena-detected flag
- Channel index loop: `0..<8` when Athena, `0..<4` when legacy
- Canonical 4-channel metrics (depth, FAA, HSI display): always use EEG1-4 (indices 0–3)
- Aux channels (AUX1-4, indices 4–7): compute band powers, log to SessionSample.eegBandPowers8ch
- On first Athena connection: log channels 4–7 raw µV for first 1s, assert non-zero, non-NaN (manual smoke test)

### Phase A4 — Replace PPG with Optics-derived heart rate (~45 min)

- In Athena branch: subscribe handler for `IXNMuseDataPacketTypeOptics`
- Read IR channel (OPTICS7, 850nm left inner) and Red channel (OPTICS9, 660nm left outer) — or whichever pair has highest SNR in first 5s
- Derive heart rate: autocorrelation of bandpass-filtered (0.5–4 Hz) IR signal over 10s window → peak lag = RR interval → BPM
- Quality gate: require autocorrelation peak R > 0.5; else `heartRateBPM = nil`
- Legacy Muse S 2019 path: `getPpgChannelValue(.AMBIENT)` unchanged
- Note in code comment: `// Full Beer-Lambert HbO/HbR deferred to Phase B1 (Build 55b)`

### Phase A5 — IRASA aperiodic exponent in Pipeline/AperiodicSlope.swift (~1.5 hr)

- New file: `Pipeline/AperiodicSlope.swift`
- vDSP-accelerated IRASA: geometric mean of resampled spectra over 19 h-factors (1.1–1.95, step 0.05)
- Output per channel: (χ, offset, R²)
- Mean χ across canonical EEG1-4 → `aperiodicSlopeMean` in SessionSample
- Backup: if IRASA R² < 0.85 on >50% of windows in a session, fall back to specparam-2.0 nonlinear knee fit
- Call from `EEGPipeline.swift` after each FFT update (every 2s)
- Unit test in `MusePlusTests/`: 1/f^χ synthetic noise → recovered χ within ±0.1 at 95% CI over 100 trials

### Phase A6 — Gaussian iTPF + Kalman tracker in Pipeline/iTPFTracker.swift (~1.5 hr)

- New file: `Pipeline/iTPFTracker.swift`
- Gaussian fit on theta band PSD (4–8 Hz): fit µ (peak), σ (width), A (amplitude)
- Input: 2s FFT from EEGPipeline for EEG2 (AF7) + EEG3 (AF8) — frontal only
- Kalman filter: state = [iTPF, velocity], process noise adapted from session-to-session variance
- Cross-session persistence: UserDefaults keys `"iTPF.EEG2"`, `"iTPF.EEG3"`, `"iTPF.kalman.P"`, `"iTPF.weight"` — write at session end
- Reliability gate: ≥10 min clean frontal data × ≥3 prior sessions → `iTPFReliable = true`
- SoundscapePlayer hook: when reliable, `adaptiveBinauralFor(depthScore:)` uses iTPFFrontalMean
- Unit test: Gaussian peak at 6.32 Hz, σ=0.5 Hz, on top of 1/f background → recovered peak within ±0.05 Hz

### Phase A7 — SessionRecorder schema migration (~1 hr)

- All new fields added per Goal D schema above
- `decodeIfPresent` for every new field
- `preSessionBaseline` struct implemented
- `soundscapeEvents` array populated from SoundscapePlayer hooks
- Omit BaselineView UI for 55a (user is experienced — baseline capture is optional infrastructure; add as SettingsSheet developer option first, promote to flow in 56)
- Unit test: load real build 54 export JSON → decode → assert no crash → assert existing fields preserved

---

## PHASE 1 (continued) — Build 55b: Implementation order

### Phase B1 — OpticsPipeline.swift + channel mapping (~1.5 hr)

- New file: `Pipeline/OpticsPipeline.swift`
- Subscribe handler for `IXNMuseDataPacketTypeOptics` (already subscribed in A2)
- Decode all 16 channels using `IXNOptics` enum per `ATHENA_SPECS.md` mapping:

```
730nm (HbR sensitive):  OPTICS1 (L outer), OPTICS2 (R outer), OPTICS5 (L inner), OPTICS6 (R inner)
850nm (HbO sensitive):  OPTICS3 (L outer), OPTICS4 (R outer), OPTICS7 (L inner), OPTICS8 (R inner)
Red 660nm:              OPTICS9 (L outer), OPTICS10 (R outer), OPTICS13 (L inner), OPTICS14 (R inner)
Ambient:                OPTICS11 (L outer), OPTICS12 (R outer), OPTICS15 (L inner), OPTICS16 (R inner)
```

- Log first Optics packet on Athena connect: assert 16 channels, no NaN (AS-3)
- Maintain 10s rolling buffer per channel at 64 Hz = 640 samples each
- Build baseline (first 60s) for ΔOD computation

### Phase B2 — Modified Beer-Lambert HbO/HbR computation (~2 hr)

Per channel pair (730nm + 850nm at same anatomical location):

```
ΔOD(730) = -log10(I_730(t) / I_730_baseline)
ΔOD(850) = -log10(I_850(t) / I_850_baseline)

[ΔHbO]   =  E^{-1}  ×  [ΔOD_730]
[ΔHbR]              ×  [ΔOD_850]

E = extinction coefficient matrix (Cope & Delpy 1988):
    ε_HbO_730 = 0.320  (mM^-1 cm^-1)
    ε_HbR_730 = 1.336
    ε_HbO_850 = 1.027
    ε_HbR_850 = 0.428
(multiply by DPF × d to get concentration — DPF = 6.0 typical adult prefrontal, d = source-detector sep ~3cm)
```

- Compute E^-1 at init (det = ε_HbO_730×ε_HbR_850 - ε_HbR_730×ε_HbO_850)
- Bandpass 0.01–0.5 Hz (remove DC drift). Mayer wave at ~0.1 Hz: DO NOT aggressively notch — preserve for future HRV-fNIRS coupling (build 62). Add code comment: `// Mayer wave (~0.1 Hz) preserved intentionally — see T2-HRV-fNIRS tracking in build 62`
- Output per region (4 regions: L-outer, L-inner, R-outer, R-inner): HbO + HbR in µM
- Aggregate to 4-element summary for SessionSample: `hboL` = mean(L-inner + L-outer), `hboR`, `hbrL`, `hbrR`

### Phase B3 — SessionRecorder Optics fields populate (~30 min)

- Populate `hboL`, `hboR`, `hbrL`, `hbrR` in each SessionSample from OpticsPipeline output
- These were placeholder-nil in 55a; build 55b makes them live
- Assert back-compat: old 55a JSONs still decode (fields remain Optional)

### Phase B4 — MeditationView fNIRS bar (~45 min)

- Add collapsible fNIRS panel at bottom of MeditationView (collapsed by default; developer tap to expand)
- Show HbO trajectory over session: SwiftUI Chart, left (blue) and right (red) prefrontal HbO in µM
- Note in view comment: `// Prefrontal HbO drops in absorbed states per Brewer 2011 fMRI analog — decreasing trace = deepening absorption`
- Promote to always-visible in build 56 once validated on real device

---

## PHASE 2 — Git commits

### Build 55a commit

```bash
git add MusePlus/MuseClient.swift
git add MusePlus/Pipeline/EEGPipeline.swift
git add MusePlus/Pipeline/AperiodicSlope.swift
git add MusePlus/Pipeline/iTPFTracker.swift
git add MusePlus/SessionRecorder.swift
git add MusePlus/Audio/SoundscapePlayer.swift
git add Frameworks/Muse.framework
git add project.yml
git add MusePlusTests/AperiodicSlopeTests.swift
git add MusePlusTests/iTPFTrackerTests.swift
git add MusePlusTests/SessionRecorderMigrationTests.swift
git add STATUS.md
git add JOURNAL_MusePlus.md
git add BUILD_PLAN_55.md
```

```bash
git commit -m "feat(build55a): SDK 8.0.5 + Athena foundations — IRASA exponent, Gaussian iTPF, 8ch EEG, Optics PPG, SessionRecorder v2

SDK migration:
- Muse.framework 7.x → 8.0.5 (Athena support)
- Athena detection: IXNMuseModelMs03 → preset 1041 (8 CH EEG @ 256Hz/14-bit + 16 Optics @ 64Hz)
- Legacy Muse S 2019 path preserved unchanged

Biomarkers (Athena 8-channel):
- AperiodicSlope.swift: IRASA geometric mean (h 1.1-1.95, 19 factors), vDSP-accelerated, R2 quality gate
  Backup: specparam-2.0 knee fit on session failure. Wen & Liu 2016.
- iTPFTracker.swift: Gaussian fit on theta PSD (Corcoran 2018), Kalman cross-session aggregation,
  UserDefaults persistence. Klimesch 1999 / Cesnaite 2023.
- SoundscapePlayer adaptive binaural uses iTPF when reliable (>=3 sessions, >=10 min clean data)

Hardware:
- PPG → Optics-derived HR on Athena (IXNMuseDataPacketTypeOptics, autocorrelation method)
- 8-channel FFT allocation (EEG1-4 canonical + AUX1-4). Depth/FAA use EEG1-4 only.
- Thermistor paths removed on Athena branch (not present on MS-03)

SessionRecorder v2 (all new fields Optional, decodeIfPresent, build 54 back-compat):
- SessionSample: eegBandPowers8ch, heartRateBPM (Optics), faa, aperiodicSlopeMean, iTPFFrontal,
  hboL/hboR/hbrL/hbrR placeholders (nil — live in 55b)
- SessionRecord: preSessionBaseline, soundscapeEvents, endingSelfRating, deviceModel, sdkVersion

Foundations build — powers builds 56-67 (binaural targeting, drift warning, transfer tracking)"
```

### Build 55b commit

```bash
git add MusePlus/Pipeline/OpticsPipeline.swift
git add MusePlus/Pipeline/EEGPipeline.swift   # Optics integration hooks
git add MusePlus/SessionRecorder.swift          # hbo/hbr populate
git add MusePlus/Views/MeditationView.swift    # fNIRS bar
git add MusePlusTests/OpticsPipelineTests.swift
git add STATUS.md
git add JOURNAL_MusePlus.md
```

```bash
git commit -m "feat(build55b): fNIRS Beer-Lambert pipeline — HbO/HbR, MeditationView trajectory bar

fNIRS pipeline (OpticsPipeline.swift):
- Subscribe IXNMuseDataPacketTypeOptics, decode 16 channels (730nm/850nm/Red/Ambient × L/R × inner/outer)
- Modified Beer-Lambert: Cope & Delpy 1988 extinction coefficients, DPF=6.0, d=3cm
- ΔOD from 60s baseline, bandpass 0.01-0.5 Hz (Mayer wave at 0.1 Hz preserved for future HRV-fNIRS)
- Output: HbO + HbR per region (L-inner, L-outer, R-inner, R-outer) in µM

SessionRecorder: hboL/hboR/hbrL/hbrR now live (was nil in 55a)
MeditationView: fNIRS bar — HbO trajectory (collapsed dev panel; promote in 56)
Tests: Beer-Lambert sanity (synthetic 850nm + 1µM HbO → recovered within 5%)"
```

---

## PHASE 3 — CI pipeline

Same as builds 51/53/54: `github.run_number` becomes `55` on push. `xcodebuild archive` → `altool` upload. Same provisioning profile, same secrets. No CI changes needed.

---

## PHASE 4 — Acceptance gates (on real Athena device)

| Gate | Test | Pass criterion |
|------|------|----------------|
| AS-1 | `getMuseModel()` on Athena connection | Returns `.Ms03` — log confirms |
| AS-2 | Preset 1041 set | Verify via `muse.getConfiguration()` after `setPreset` — log confirms |
| AS-3 | First Optics packet | 16 channels received, no NaN, log shows OPTICS1-16 all present |
| AS-4 | IRASA χ update rate + quality | χ updates every 2s; R² > 0.85 in ≥80% of 2s windows over 5 min session |
| AS-5 | Gaussian iTPF range | iTPF identifies frontal theta peak within Klimesch 1999 expected range (5.5–7.5 Hz) |
| AS-6 | HbO trajectory direction | Eyes-closed rest: prefrontal HbO shows expected post-task decrease pattern (Brewer 2011) |
| AS-7 | 8-channel HSI contact quality | All 4 canonical channels (EEG1-4) report ≥ "Good" within 30s of headband-on |
| AS-8 | BLE jitter measurement | 95th-percentile packet jitter < 30 ms over 5 min recording. Input to T2-#7 wired decision. |
| AS-9 | JSON back-compat | Build 54 exports decode against 55 schema without crash; all legacy fields preserved |
| AS-10 | DepthGate regression | Identical replay of build 54 session → DepthGate state transitions match build 54 logged behavior |
| AS-11 | Synthetic tests pass | All MusePlusTests/ pass: IRASA ±0.1, Gaussian iTPF ±0.05 Hz, Beer-Lambert ±5% |
| AS-12 | Battery drain at preset 1041 | < 8% over 1 hour (per Athena published spec) |

---

## QUALITY GATES (synthetic, pre-device)

| Test | Method | Pass criterion |
|------|--------|----------------|
| IRASA recovery | Synthesize 1/f^χ noise for χ ∈ {0.8, 1.2, 1.5, 1.8, 2.0}; run IRASA; compare | Recovered χ within ±0.1 at 95% CI across 100 trials per χ |
| Gaussian iTPF recovery | Gaussian peak at 6.32 Hz, σ=0.5 Hz, on 1/f background | Recovered peak within ±0.05 Hz |
| Beer-Lambert sanity | Synthetic 850nm with HbO 1 µM increase (Cope & Delpy extinction coeffs) | Recovered ΔHbO within ±5% |
| Build 54 JSON round-trip | Load real user export JSON; decode against 55 schema | No crash; existing fields match original values exactly |
| 8-channel smoke | Log 1s of EEG5-8 (AUX1-4) on first Athena connect | All 4 channels non-zero, non-NaN |

---

## KNOWN LIMITATIONS (explicit, not blockers)

| Issue | Impact | Future fix |
|-------|--------|------------|
| AUX1-4 (channels 5-8) have no HSI | Contact quality of aux channels unknown until DRL/REF parsed | Parse DRL/REF in build 57; use signal variance as proxy until then |
| THERMISTOR removed on Athena | Drop all body-temp paths from Athena branch | Remove dead code in Phase A2; no future fix needed |
| Muse S 2019 backwards compatibility | Legacy path must stay — some users have old hardware | Preserve legacy preset + PPG path indefinitely in else-branch |
| BLE 5.3 jitter empirically unknown | Phase-lock (T2-#7) decision deferred until AS-8 on real device | Measure AS-8; if >30 ms median, USB-C wired-only for T2-#7 |
| IRASA ignores knee parameter | Acceptable for 1–40 Hz (knee < 1 Hz on Muse) | Add knee fit if extending to 0.5–50 Hz |
| iTPF unreliable for low-theta-power users | Falls back to 6 Hz fixed; no harm | Add manual iTPF set in advanced SettingsSheet |
| Beer-Lambert DPF fixed at 6.0 | DPF varies ±1 across individuals | Age-dependent DPF formula (Duncan 1996) in build 58 |
| fNIRS bar hidden (developer-only) in 55b | Users can't see HbO trajectory | Promote to always-visible in build 56 post-validation |

---

## COMPILE-TIME RISK REFERENCE

| Risk | Expected | File |
|------|----------|------|
| Muse model enum | `IXNMuseModelMs03` (uppercase Ms03) | MuseClient.swift |
| Preset enum case | `.preset1041` (verify against IXNMusePreset.h — may be camelCase) | MuseClient.swift |
| Optics enum cases | `.OPTICS1` through `.OPTICS16` (all-caps) | OpticsPipeline.swift |
| EEG aux channels | `.AUX1` through `.AUX4` (uppercase) | MuseClient.swift, EEGPipeline.swift |
| Beer-Lambert extinction matrix | Cope & Delpy 1988 published values only | OpticsPipeline.swift |
| Legacy PPG enum | `IXNPpg` enum NOT subscribed on Athena branch | MuseClient.swift |
| Thermistor paths | No THERMISTOR subscription on Athena branch | MuseClient.swift |

---

## QUICK REFERENCE

| Item | Value |
|------|-------|
| Plan target Apple build | 55 (55a + 55b sequential) |
| Hardware target | Muse S Athena (MS-03), SDK 8.0.5 |
| Estimated sessions | 2 (55a ≈ 7h, 55b ≈ 5h) |
| Estimated LOC | ~1060 |
| New files | 3 (AperiodicSlope.swift, iTPFTracker.swift, OpticsPipeline.swift) + 3 test files |
| Modified files | 6 (MuseClient, EEGPipeline, SoundscapePlayer, SessionRecorder, MeditationView, project.yml) |
| Compile risks | 7 (see Phase 0.1) |
| Acceptance gates | 12 (AS-1 through AS-12) |
| Quality gates | 5 synthetic tests |
| Known limitations | 8 (explicit, non-blocking) |
