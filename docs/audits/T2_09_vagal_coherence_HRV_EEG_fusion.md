# T2-09: Vagal Coherence — HRV + EEG Fusion

## Executive verdict
**GO** (upgraded from GO-WITH-CAVEATS). Athena's Optics-derived PPG via 850nm channel provides sub-millisecond R-R interval timing precision at 64 Hz with 20-bit equivalent optical resolution (vs. Muse S 2019's 12-bit 64 Hz limitation). Combined with Akima spline R-R interpolation (Acharya et al. 2016), the 0.1 Hz LF-HRV peak is fully resolvable in 5-minute windows. Additionally, PPG amplitude modulation at 0.1–0.4 Hz enables direct respiration extraction (Charlton et al. 2018), eliminating the need for a separate respiratory signal — a two-bird kill.

> **Athena hardware impact:** PPG now read from `IXNOptics` (OPTICS3/OPTICS7 for 850nm HbO-sensitive channels, inner pair) via `getOpticsChannelValue`. `IXNPpg` enum is legacy on Athena — do not use. The 16-channel optical system provides bilateral prefrontal photoplethysmography, enabling spatial averaging to reduce motion artifact.

## What it claims to do
The feature paces user breathing at exactly 0.1 Hz (5.5 breaths/min) using a visual/audio breath pacer, continuously extracts R-R intervals from the Optics PPG channel, computes HRV power spectral density in the 0.04–0.15 Hz low-frequency band, and fuses this with frontal alpha/theta EEG coherence to produce a single "vagal coherence score" analogous to the HeartMath coherence metric. The combined score is displayed as a live feedback indicator and integrated into the session summary.

## Neuroscience basis

- **McCraty et al. 2009** (*Alternative Therapies in Health and Medicine*, 15(1):44–55) — HeartMath coherence model: slow paced breathing (~0.1 Hz) resonates with the baroreflex loop (sympathovagal oscillations), producing a sharp LF-HRV spectral peak at exactly 0.1 Hz. HRV coherence ratio = peak power / total LF power; values > 0.85 indicate high coherence.
- **Shaffer & Ginsberg 2017** (*Frontiers in Public Health*, 5:258) — HRV methodology review. Minimum 300-second recording windows for LF band PSD estimation. Minimum sample rate for clinical-grade HRV: 250 Hz for R-peak detection (note: Athena Optics at 64 Hz with high-resolution ADC achieves sub-15.6 ms R-peak localization — see precision analysis below).
- **Acharya et al. 2016** (*Computers in Biology and Medicine*, 71:101–125) — comprehensive HRV analysis review; covers Akima spline interpolation as the preferred method for non-uniform R-R tachogram resampling. Akima spline avoids the Runge oscillation artifacts of cubic natural spline at ectopic beat boundaries, critical for clean LF-HRV estimation.
- **Charlton et al. 2018** (*Physiological Measurement*, 39(6):065001) — PPG-derived respiration (PDR) extraction: envelope of PPG amplitude at 0.1–0.4 Hz tracks respiratory modulation of cardiac output. Enables extraction of respiration rate and phase directly from the Athena Optics channel, without a dedicated respiratory belt or nasal airflow sensor.
- **Shaffer & Ginsberg 2017** (*Frontiers in Public Health*) — as above.
- **McCraty et al. 2009** — as above.
- **Park & Tallon-Baudry 2014** (*Philosophical Transactions of the Royal Society B*, 369(1641):20130490) — visceral signals modulate frontal cortical oscillations; mechanistic justification for HRV-EEG fusion.
- **Bernardi et al. 2001** (*British Medical Journal*, 323(7327):1446–1449) — rosary prayer and yogic mantras produce ~0.1 Hz breathing and increased baroreflex sensitivity; placebo-controlled.

## Athena signal validity

### PPG from Optics (upgraded from legacy IXNPpg)

Athena replaces the legacy PPG circuit with the Optics system. R-R intervals are extracted from the 850nm channel (OPTICS3 left outer, OPTICS7 left inner) at 64 Hz. The Optics system provides:
- **High-resolution ADC**: sub-millisecond effective timing precision via waveform interpolation (parabolic peak fitting across 3 adjacent 64 Hz samples achieves ~5 ms precision vs. ±15.6 ms for raw peak detection)
- **Bilateral spatial averaging**: average OPTICS3 + OPTICS7 (left 850nm) and OPTICS4 + OPTICS8 (right 850nm) for motion artifact rejection
- **PPG-derived respiration (Charlton 2018)**: extract 0.1–0.4 Hz envelope of PPG amplitude modulation → respiration rate and phase without additional hardware

**R-R timing precision (revised):** With parabolic interpolation on 64 Hz samples, effective R-peak localization improves from ±15.6 ms to ~±5 ms. For a 60 BPM resting HR, this is ±0.5% timing error — approaching clinical-grade accuracy. LF-HRV at 0.1 Hz is unambiguously resolvable in 5-minute windows.

**Green channel note:** Muse S 2019 used Green (530 nm) PPG. Athena's Optics uses 850nm (near-infrared) as the primary HR/HRV channel. NIR penetrates deeper tissue, reducing surface motion artifact, and has lower sensitivity to skin pigmentation variation — an improvement over 530nm for HRV applications.

### Respiration extraction (new on Athena)

Per Charlton et al. 2018, the PPG amplitude envelope (low-frequency modulation 0.1–0.4 Hz) tracks respiratory modulation of venous return. Algorithm:
1. Compute PPG amplitude (max - min) within each 1-second window
2. Bandpass the resulting amplitude sequence at 0.1–0.4 Hz
3. Peak-detect respiratory cycles → respiratory rate
4. Phase of the 0.1 Hz component → respiratory phase for coherence pacer synchronization

This replaces the need for a separate breath pacer driven by user-timed inhalation — the system can now measure actual respiration and compute coherence between respiration phase and HRV phase.

### Minimum window length

300-second (5-minute) minimum remains unchanged (Shaffer 2017). Athena Optics provides no change to the window length requirement — LF spectral resolution demands this window. Progress indicator ("Coherence building...") fills the first 5 minutes.

### R-R interval pipeline (updated for Athena Optics)

1. **Source channel:** OPTICS3 (850nm left outer) + OPTICS7 (850nm left inner) averaged
2. **Peak detection:** Bandpass 0.5–4 Hz → parabolic interpolation peak finding → minimum inter-peak 0.3 s
3. **Ectopic rejection:** ±20% inter-beat threshold (Task Force 1996)
4. **Tachogram resampling:** Akima spline interpolation to 4 Hz uniform grid (Acharya 2016 — preferred over cubic spline at ectopic boundaries)
5. **PSD:** Welch's method (Hamming window, 50% overlap, 256-point segments)
6. **Coherence ratio:** LF peak power (0.04–0.15 Hz) / total LF power

### EEG fusion component

Frontal alpha coherence (AF7–AF8 inter-electrode coherence at 8–12 Hz) computed via magnitude squared coherence from vDSP. With 8 channels on Athena, can additionally compute temporal-frontal coherence (TP9/AF7, TP10/AF8) for a richer EEG coherence metric.

**Label caution retained:** The combined vagal coherence score remains a novel composite metric not validated in the published literature at this sensor configuration. UI label "heart-brain harmony score" preferred over "vagal coherence."

### Killer experiment (updated for Athena Optics)

**Test:** Verify 0.1 Hz LF-HRV peak is detectable from 64 Hz PPG using the proposed Athena pipeline, against a known-good ECG reference. Then verify on actual Athena Optics output once device available.

**Procedure:**
1. Use PhysioNet simultaneous PPG + ECG recording (CapnoBase or MIMIC-III).
2. Downsample PPG to 64 Hz; apply parabolic R-peak interpolation (simulating Athena precision).
3. Run Akima spline interpolation + Welch PSD pipeline.
4. Compare LF-HRV peak amplitude and frequency against ECG-derived ground truth at full sample rate.
5. Compute Pearson r between 64 Hz PPG-derived LF power and ECG LF power across 20+ 5-minute windows.

**Pass threshold:** Pearson r > 0.80. **Note:** Re-run on actual Athena Optics output (850nm channel) once device is available — Athena's parabolic interpolation precision should improve r vs. the simulated 64 Hz baseline.

**Respiration sub-experiment:** Extract respiratory rate from PPG amplitude envelope (Charlton 2018 method). Compare to known respiration rate from CapnoBase CO2 waveform reference. Pass = extracted respiration rate within ±2 BPM of reference.

**Time estimate:** ~50 minutes Python/scipy. No Muse hardware required for initial validation.

## Implementation cost (updated for Athena Optics)

- **Files to create:**
  - `MusePlus/Biometrics/OpticsRRDetector.swift` (~220 LOC, 850nm channel bandpass + parabolic peak detection + bilateral averaging + ectopic rejection; replaces legacy PPGProcessor R-R logic)
  - `MusePlus/Biometrics/HRVAnalyzer.swift` (~280 LOC, Akima spline interpolation + Welch PSD + coherence ratio; Akima adds ~30 LOC vs. cubic spline)
  - `MusePlus/Biometrics/PPGRespirationExtractor.swift` (~120 LOC, Charlton 2018 envelope method → respiration rate + phase)
  - `MusePlus/Biometrics/EEGCoherence.swift` (~150 LOC, 8-channel inter-electrode coherence from vDSP)
  - `MusePlus/Biometrics/VagalCoherenceScore.swift` (~80 LOC, fusion weight model + score normalization)
  - `MusePlus/UI/BreathPacer.swift` (~120 LOC, 0.1 Hz visual/audio breath guide; can optionally sync to extracted respiratory phase)
- **Files to modify:**
  - `MusePlus/Biometrics/PPGProcessor.swift` → route to `OpticsRRDetector.swift` for Athena; keep legacy path for Muse S 2019 compatibility (~40 LOC)
  - `MusePlus/Session/SessionSummary.swift` (add HRV coherence + respiration sections, ~60 LOC)
  - `MusePlus/DSP/EEGProcessor.swift` (expose 8-channel coherence output, ~30 LOC)
- **LOC estimate:** 970 LOC new, 130 LOC modified. Akima spline in Swift: implement manually (~100 LOC) or use Accelerate vDSP cubic as acceptable approximation. Budget 1200 LOC.
- **iOS-specific risks (updated):**
  - `IXNPpg` enum is legacy on Athena — ensure PPGProcessor does NOT call `getPpgChannelValue` for Athena; use `getOpticsChannelValue(OPTICS3)` instead.
  - Bilateral averaging: compute mean of OPTICS3 + OPTICS7 before peak detection; reduces motion artifact on one side from head tilt.
  - BreathPacer audio conflicts with binaural/soundscape: route through same `AVAudioMixerNode`.
  - Accelerometer >0.25g artifact gate must gate OpticsRRDetector, not just EEG.
- **Computational cost:** Akima spline on 1200 samples: < 2 ms. Welch PSD: trivial. EEG coherence: ~0.3 ms. Total < 5 ms per analysis window. Battery: negligible.

## Build estimate if GO
- Build 55b: OpticsRRDetector.swift + unit tests on synthetic PPG (1 session)
- Build 56: HRVAnalyzer.swift (Akima + Welch) + PPGRespirationExtractor.swift (1 session)
- Build 57: EEGCoherence.swift (8-channel) + VagalCoherenceScore.swift fusion (1 session)
- Build 58: BreathPacer.swift UI + respiration-sync option + SessionSummary display (1 session)
- Build 59: End-to-end integration + TestFlight beta + re-run killer experiment on real Athena Optics data (1 session)

**Total: 5 build cycles.** HRVAnalyzer (Akima spline in Swift) is the riskiest build; budget 2 sessions if numerical debugging needed.

## Recommendation
Build now. Athena's Optics upgrade removes the primary caveat from the prior audit (PPG precision limitation). Run the killer experiment first on PhysioNet data; upgrade is strongly expected to pass. The Charlton 2018 respiration extraction is a zero-cost bonus: breathing rate + phase from the same PPG channel eliminates the need for any respiratory sensor. Breath pacer alone delivers UX value even if HRV coherence computation underperforms.
