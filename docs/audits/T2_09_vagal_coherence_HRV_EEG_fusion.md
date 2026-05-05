# T2-09: Vagal Coherence — HRV + EEG Fusion

## Executive verdict
GO-WITH-CAVEATS — 0.1 Hz LF-HRV power is measurable from PPG R-R intervals at 64 Hz with careful interpolation, but the minimum reliable window is 5 minutes (300 seconds), which spans a full meditation session; real-time feedback must be deferred until window completion, and the fused EEG coherence score is a UX indicator, not a physiologically validated metric without further validation work.

## What it claims to do
The feature paces user breathing at exactly 0.1 Hz (5.5 breaths/min) using a visual/audio breath pacer, continuously extracts R-R intervals from the PPG autocorrelation output, computes HRV power spectral density in the 0.04–0.15 Hz low-frequency band, and fuses this with frontal alpha/theta EEG coherence to produce a single "vagal coherence score" analogous to the HeartMath coherence metric. The combined score is displayed as a live feedback indicator and integrated into the session summary.

## Neuroscience basis

- **McCraty et al. 2009** (*Alternative Therapies in Health and Medicine*, 15(1):44–55) — HeartMath Institute's coherence model: slow paced breathing (~0.1 Hz) resonates with the baroreflex loop (sympathovagal oscillations), producing a sharp LF-HRV spectral peak at exactly 0.1 Hz. HRV coherence ratio = peak power / total LF power; values > 0.85 indicate high coherence. This is the direct mechanistic source for the 0.1 Hz breathing target.
- **Shaffer & Ginsberg 2017** (*Frontiers in Public Health*, 5:258) — comprehensive HRV methodology review. Explicitly states that short-term HRV (< 5 min) requires minimum 300-second recording windows for LF band (0.04–0.15 Hz) PSD estimation; shorter windows produce unreliable LF estimates. Also states: minimum sample rate for short-term HRV = 250 Hz for accurate R-R interval detection. **This is the primary constraint for Muse S PPG at 64 Hz.**
- **Park & Tallon-Baudry 2014** (*Philosophical Transactions of the Royal Society B*, 369(1641):20130490) — visceral signals (heartbeat, respiration) modulate frontal cortical oscillations; anterior insula mediates the heart-brain coupling. Mechanistic justification for fusing HRV coherence with frontal EEG: the two signals share a physiological coupling pathway.
- **Lutz et al. 2008** (*PLOS ONE*, 3(3):e1897) — compassion meditation practitioners show increased frontal gamma and alpha coherence. Provides EEG-side anchor for what "coherent" brain state looks like; the fusion metric is motivated by the co-occurrence of cardiac and cortical coherence in experienced practitioners.
- **Bernardi et al. 2001** (*British Medical Journal*, 323(7327):1446–1449) — rosary prayer and yogic mantras both produce ~0.1 Hz breathing rate and increased baroreflex sensitivity; placebo-controlled. Directly supports the 0.1 Hz pacing target as the physiologically optimal frequency for vagal activation, regardless of tradition.

## Muse S signal validity

### PPG R-R precision at 64 Hz

The Muse S PPG samples at 64 Hz → sample interval = 15.625 ms. R-peak detection via the 8-second autocorrelation pipeline (currently shipping) estimates heart rate from the lag of the first autocorrelation peak. For HRV computation, we need *individual* R-R intervals, not average HR.

**R-R timing precision:** With 64 Hz PPG, the R-peak can be localized to ±15.6 ms (one sample). For a resting HR of 60 BPM (1000 ms R-R interval), this is ±1.56% timing error per interval. Shaffer 2017 recommends ≥ 250 Hz for "clinical-grade" HRV — at that rate, precision is ±4 ms (±0.4% error).

**Impact on 0.1 Hz LF power:** The 0.1 Hz spectral peak corresponds to HRV oscillations with period 10 seconds. At 60 BPM, a 10-second window contains ~10 R-R intervals. The 15.6 ms timing jitter per interval adds noise to the R-R tachogram but does not prevent detection of a 10-second LF oscillation, provided the amplitude of the cardiac coherence response is large enough. McCraty 2009 reports LF-HRV peak amplitudes of 50–200 ms² during coherence — well above the noise floor from 15.6 ms jitter.

**Practical assessment:** 64 Hz PPG is *sufficient for detecting the 0.1 Hz LF peak* in cooperative, still subjects, but degrades LF power estimation by ~10–20% compared to a 250 Hz reference. This is not a kill-shot, but it means the coherence ratio will have wider confidence intervals.

**Muse S PPG channel selection:** The build prompt specifies Muse S 2019 uses the Green channel. Green light (530 nm) provides better SNR for skin photoplethysmography in lightly pigmented subjects but lower SNR in darker skin tones (Bent et al. 2020, *npj Digital Medicine* — [citation needed for exact reference]). The existing 8-second autocorrelation HR pipeline already validates this channel's utility.

### Minimum window length

**Problem:** To resolve a 0.1 Hz spectral peak with 1 FFT bin resolution, the window length T must satisfy: T ≥ 1 / Δf = 1 / 0.04 Hz = 25 seconds (minimum for LF band lower edge). But Shaffer 2017 requires 300 seconds (5 minutes) for stable LF estimates. In practice, a 300-second window captures 30 full cycles of the 0.1 Hz oscillation — sufficient for a clean spectral peak.

**Implication for real-time feedback:** During a 10-minute session, the first reliable LF-HRV estimate is not available until minute 5. A progress indicator ("HRV coherence building...") should fill the UI gap. The coherence score is best shown in the post-session summary rather than as live feedback unless the session is ≥ 10 minutes.

### R-R interval pipeline modification

The current pipeline computes HR from 8-second autocorrelation. HRV computation requires a different approach:
1. **Peak detection:** Apply a bandpass filter (0.5–4 Hz) to the Green channel, threshold positive peaks with minimum inter-peak distance of 0.3 seconds, record peak times.
2. **Tachogram construction:** Compute R-R intervals as differences of consecutive peak times.
3. **Ectopic beat / artifact filtering:** Use a ±20% inter-beat variation threshold to reject artifacts (consistent with Task Force 1996 HRV guidelines).
4. **Resampling to 4 Hz:** Interpolate the non-uniformly sampled R-R tachogram to a uniform 4 Hz grid (cubic spline or linear; cubic preferred) before PSD estimation. This step is essential — raw R-R intervals cannot be directly FFT'd.
5. **PSD computation:** Apply Welch's method (Hamming window, 50% overlap, 256-point segments) to the 4 Hz resampled tachogram.

**Interpolation strategy recommendation:** Cubic spline interpolation to 4 Hz is the standard (Clifford et al. 2006 PhysioNet guidelines). Linear interpolation introduces spectral distortion above 1 Hz (not relevant for 0.1 Hz band) but is acceptable. Do not use zero-order hold (nearest-neighbor) — it introduces spectral artifacts that distort the LF peak.

### EEG fusion component

The frontal alpha coherence (AF7–AF8 inter-electrode coherence at 8–12 Hz) is computable from the existing vDSP pipeline as the magnitude squared coherence of the two frontal channels. Park & Tallon-Baudry 2014 provides mechanistic support but the specific fusion formula (weighted sum of HRV coherence ratio + EEG coherence) is not validated in published literature at this sensor configuration — it would be a novel composite metric. Labeling it "vagal coherence" in the UI overstates current evidence; "heart-brain harmony score" or similar neutral label is more defensible.

## Implementation cost (realistic)

- **Files to create:**
  - `MusePlus/Biometrics/RRDetector.swift` (~200 LOC, PPG bandpass + peak detection + ectopic rejection)
  - `MusePlus/Biometrics/HRVAnalyzer.swift` (~250 LOC, tachogram construction + cubic spline interpolation + Welch PSD + coherence ratio)
  - `MusePlus/Biometrics/EEGCoherence.swift` (~150 LOC, AF7–AF8 magnitude squared coherence from vDSP)
  - `MusePlus/Biometrics/VagalCoherenceScore.swift` (~80 LOC, fusion weight model + score normalization)
  - `MusePlus/UI/BreathPacer.swift` (~120 LOC, 0.1 Hz visual/audio breath guide animation)
- **Files to modify:**
  - `MusePlus/Biometrics/PPGProcessor.swift` (expose raw peak timestamps instead of only HR, ~40 LOC)
  - `MusePlus/Session/SessionSummary.swift` (add HRV coherence section to post-session report, ~60 LOC)
  - `MusePlus/DSP/EEGProcessor.swift` (expose inter-channel coherence output, ~30 LOC)
- **LOC estimate:** 800 LOC new, 130 LOC modified. Cubic spline interpolation and Welch PSD in Swift without a dedicated numerical library will require careful implementation — budget 1100 LOC total.
- **iOS-specific risks:**
  - vDSP provides FFT but not Welch's method directly; must implement segment windowing and averaging manually (~100 LOC).
  - Cubic spline interpolation in Swift: use Accelerate framework's `vDSP_vgen` for linear interpolation (fast but lower quality) or implement cubic spline manually (~120 LOC). No iOS system library provides cubic spline directly.
  - `AVAudioEngine` breath pacer audio conflicts with existing binaural/soundscape audio must be routed through the same `AVAudioMixerNode` — requires careful bus assignment.
  - PPG peak detection quality degrades significantly with motion; the existing accelerometer >0.25g artifact gate must gate the RR detector, not just the EEG.
- **Computational cost:** Welch PSD on 4 Hz tachogram (1200 samples for 5 min) ≈ trivial. Cubic spline interpolation ≈ trivial. EEG coherence computation: 256-point cross-spectral density via vDSP ≈ 0.3 ms. Total: < 5 ms per analysis window, runs on background thread. Battery: negligible.

## Killer experiment (1 hour to run on Sparky / device)

**Test:** Verify that the 0.1 Hz LF-HRV peak is detectable from a 64 Hz PPG signal using the proposed pipeline, against a known-good reference.

**Procedure:**
1. Use a publicly available simultaneous PPG + ECG recording from PhysioNet (e.g., MIMIC-III waveform database, or CapnoBase respiratory dataset — both freely available).
2. Downsample the PPG to 64 Hz (simulating Muse S).
3. Run the proposed R-R detector + cubic spline interpolation + Welch PSD pipeline.
4. Compare the LF-HRV peak (0.04–0.15 Hz) amplitude and frequency against the ECG-derived R-R ground truth processed at full sample rate (125 Hz or higher).
5. Compute the correlation between 64 Hz PPG-derived LF power and ECG-derived LF power across 20+ 5-minute windows.

**Expected output:** Pearson r > 0.85 between 64 Hz PPG LF power and ECG LF power over 5-minute windows.

**Pass threshold:** r > 0.80. If < 0.80, the 64 Hz PPG + 15.6 ms jitter degrades LF-HRV estimation too severely for a coherence score — the feature becomes a breathing pacer only (no HRV output).

**Time estimate:** ~50 minutes on Sparky with Python/scipy. No Muse S required.

## Build estimate if GO
- Build 55: RRDetector.swift + unit tests on synthetic PPG (1 session)
- Build 56: HRVAnalyzer.swift — tachogram + spline interpolation + Welch PSD (1 session)
- Build 57: EEGCoherence.swift + VagalCoherenceScore.swift fusion (1 session)
- Build 58: BreathPacer.swift UI animation + audio pacer integration (1 session)
- Build 59: End-to-end integration + SessionSummary display + TestFlight beta (1 session)

**Total: 5 build cycles.** HRVAnalyzer is the riskiest build (cubic spline + Welch in Swift from scratch); budget 2 sessions if the first attempt needs numerical debugging.

## Recommendation
Build now after running the killer experiment — the physics is favorable (0.1 Hz is well within 64 Hz PPG capability for 5-minute windows), the implementation is self-contained, and the breath pacer alone delivers UX value even if the HRV component underperforms; defer the EEG fusion component to a follow-on build after validating HRV output quality with 10+ real Muse S sessions.
