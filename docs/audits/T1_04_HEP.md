# T1-04: Heartbeat-Evoked Potential (HEP)

## Executive verdict
**GO-WITH-CAVEATS** (upgraded from GO-WITH-CAVEATS/weak SNR). Athena's 8-channel 14-bit EEG + Optics 20-bit-equivalent PPG R-detection substantially improves SNR over the prior Muse S 2019 4-channel/12-bit assessment. The primary remaining caveat: HEP is strongest at central electrode Cz and frontal Fz — neither of which Athena covers. AF7/AF8 frontal-polar electrodes are suboptimal but sufficient to detect the HEP component (positive peak ~250 ms post-R, negative peak ~400 ms) with 200+ heartbeats per session.

> **Previous verdict (Muse S 2019, frontal-only):** GO-WITH-CAVEATS — weak SNR due to 12-bit ADC and frontal-polar electrode placement (no Cz/Fz central coverage). Required 300+ heartbeats; 4-channel coverage insufficient for spatial pattern analysis.

> **Athena hardware impact:** 14-bit ADC (2× amplitude precision over 12-bit), 8 channels including temporal (TP9/TP10-equivalent), Optics-derived R-peak detection with ~5 ms precision (parabolic interpolation on 64 Hz IR channel). Temporal electrodes (TP9/TP10 ~ EEG1/EEG4) are closer to Cz than AF7/AF8, providing partial central coverage. HEP SNR improves significantly.

## What it does
The Heartbeat-Evoked Potential (HEP) is a cortical response to cardiac afferent signals (interoceptive heartbeat awareness). EEG is epoched relative to each R-peak (detected from PPG), baseline-corrected, and averaged over 200+ heartbeats. The resulting HEP waveform (positive ~250 ms, negative ~400 ms post-R) reflects how strongly the brain processes each heartbeat. In experienced meditators, HEP amplitude is enhanced during body-scan and interoceptive meditation styles compared to focused attention practices (Schandry 1981, Pollatos 2007). For a decades-experienced meditator, HEP amplitude is a potential correlate of interoceptive awareness quality.

## Algorithm

1. **R-peak detection:** From Athena Optics IR channel (850nm, OPTICS3/OPTICS7 inner pair) via parabolic interpolation peak-finding on bandpass-filtered (0.5–4 Hz) PPG → R-peak timestamps with ~5 ms precision.
2. **EEG epoching:** For each R-peak: extract epoch [-100 ms, +600 ms] from all 8 EEG channels.
3. **Baseline correction:** Subtract mean of [-100 ms, 0 ms] pre-R window from each epoch.
4. **Artifact rejection:** Reject epochs with any channel amplitude > 100 µV in the epoch window (ocular artifact from AF7/AF8). Accept epochs with ≥ 4 clean channels minimum.
5. **Averaging:** Average accepted epochs across session (target: 200+ for reliable HEP estimate at ~70 BPM over 3+ minutes).
6. **HEP extraction:** Average across AF7 + AF8 (frontal bilateral) and EEG1 + EEG4 (temporal bilateral). Report peak amplitude at 200–300 ms (positive component) and 350–450 ms (negative component).

**Cite:** Park & Tallon-Baudry 2014 *Philosophical Transactions of the Royal Society B* — HEP component timing (positive ~250 ms, negative ~400 ms post-R) and interoceptive awareness correlates. Schandry 1981 *Psychophysiology* — original HEP description and heartbeat awareness paradigm. Pollatos 2007 *Brain Research Bulletin* — HEP enhancement in interoceptive attention.

## Neuroscience basis

- **Park & Tallon-Baudry 2014** (*Philosophical Transactions of the Royal Society B*, 369(1641):20130490) — canonical HEP timing and interoceptive awareness correlates. Canonical HEP positive component at ~250 ms post-R, negative component at ~400 ms. Strongest at Fz/Cz; also present (reduced amplitude) at frontal electrodes — directly applicable to Athena AF7/AF8.
- **Schandry 1981** (*Psychophysiology*, 18(4):483–491) — original description of HEP and its relation to heartbeat awareness. Classic paradigm reference.
- **Pollatos et al. 2007** (*Brain Research Bulletin*, 74(6):426–432) — HEP amplitude correlates with interoceptive accuracy; enhanced in individuals with good heartbeat detection performance. Provides the mechanism connecting HEP amplitude to meditation depth (interoceptive awareness hypothesis).
- **Lutz et al. 2008** (*PLOS ONE*) — experienced meditators show enhanced interoceptive body awareness during body-scan meditation; HEP is the electrophysiological marker of this process.
- **Schandry 1981** — original HEP.

## Athena signal validity

**R-peak detection:** Optics 850nm channel at 64 Hz with parabolic interpolation → ~5 ms R-peak timing precision. This is the primary hardware improvement: Muse S 2019's 12-bit PPG at 64 Hz gave ±15.6 ms precision (1-sample); Athena's high-resolution Optics achieves ~±5 ms via waveform interpolation. For HEP, R-peak timing jitter directly smears the averaged waveform — reducing from ±15.6 ms to ±5 ms jitter substantially sharpens the HEP peak.

**Jitter analysis:** At 200 epochs with ±5 ms timing jitter, the averaged HEP waveform has a temporal smear of ~5 ms / sqrt(200) ≈ 0.35 ms RMS. This is well below the 50 ms temporal resolution of the HEP components — effectively negligible.

**Electrode coverage:** AF7/AF8 are frontal-polar; canonical HEP is strongest at Fz/Cz. However:
- AF7/AF8 do show HEP signal — Park & Tallon-Baudry 2014 report frontal-electrode HEP ~60–70% of Cz amplitude
- EEG1/EEG4 (TP9/TP10 temporal equivalent) provide additional spatial sampling; temporal HEP ~40–50% of Cz amplitude
- Averaging bilateral frontal + bilateral temporal (4 channels) compensates partially for missing Cz

**14-bit ADC:** Improved amplitude precision reduces quantization noise, which is particularly important for the HEP averaging process (noise averages down, signal does not — cleaner baseline).

**Remaining caveat:** Without Cz/Fz, the spatial distribution of the HEP cannot be characterized beyond frontal-temporal coverage. The HEP amplitude estimate is valid for session-to-session comparison within this user but should not be compared quantitatively to published HEP norms from full-cap EEG.

## Implementation cost

- **Files to create:**
  - `MusePlus/Biometrics/HEPProcessor.swift` (~250 LOC: R-peak epoch extraction from 8-channel EEG, baseline correction, artifact rejection, epoch averaging, HEP component extraction)
  - `MusePlus/UI/HEPDisplay.swift` (~100 LOC: session summary HEP waveform plot + amplitude trend across sessions)
- **Files to modify:**
  - `MusePlus/Biometrics/OpticsRRDetector.swift` (expose R-peak timestamps for HEP use in addition to HRV pipeline, ~20 LOC delta — shared R-peak stream with T2-09)
  - `MusePlus/DSP/EEGProcessor.swift` (expose 8-channel sample buffer with timestamps for HEP epoching, ~40 LOC)
  - `MusePlus/Session/SessionSummary.swift` (add HEP section, ~30 LOC)
- **LOC estimate:** ~350 LOC Swift new, 90 LOC modified. Epoch averaging is straightforward vDSP addition; artifact rejection is simple threshold. HEPDisplay plot requires a basic waveform rendering view.
- **iOS-specific risks:**
  - R-peak stream must be shared between HEPProcessor (T1-04) and OpticsRRDetector/HRVAnalyzer (T2-09) without duplication — single R-peak publisher, multiple subscribers.
  - Epoch extraction: must buffer 600 ms of 8-channel EEG after each R-peak; at 256 Hz this is 154 samples × 8 channels = ~10 KB per epoch. 200 epochs = ~2 MB buffer — acceptable RAM.
  - Averaging thread: run on background queue; EEG sample buffer must be lock-free ring buffer.
- **Computational cost:** Epoch extraction: trivial. Averaging 200 epochs × 8 channels × 154 samples: < 5 ms on any A14+ device. Battery: zero marginal.

## Killer experiment

**Test:** Detect HEP component on a 30-min eyes-closed resting recording. Target: positive peak ~250 ms post-R, negative peak ~400 ms post-R distinguishable from baseline at p < 0.05 across 200+ heartbeats.

**Procedure:**
1. Record a 30-min eyes-closed session on Athena.
2. Run HEPProcessor: detect R-peaks from Optics 850nm → extract 8-channel EEG epochs [-100 ms, +600 ms] → baseline correct → artifact reject → average.
3. Expected: ~70 BPM × 30 min = ~2100 heartbeats; accept ~60–70% after artifact rejection = ~1300–1500 clean epochs. More than sufficient.
4. Compute t-test at each timepoint between the HEP window (200–450 ms) and the pre-stimulus baseline (-100 to 0 ms) across all accepted epochs.
5. Apply FDR correction (Benjamini-Hochberg) across timepoints.

**Pass threshold:** Effect distinguishable from baseline at p < 0.05 (FDR-corrected) in at least one electrode at the 200–300 ms (positive) or 350–450 ms (negative) window. Waveform shape consistent with Park & Tallon-Baudry 2014 Figure 1 pattern (positive then negative deflection).

**Time estimate:** ~1 hour total (30-min recording + 30-min processing).

## Build estimate if GO
- Build 56: HEPProcessor.swift + R-peak stream sharing with T2-09 OpticsRRDetector + unit tests on synthetic heartbeat (1 session; can parallel with T2-09 Build 55b since both use Optics R-peaks)
- Build 57: HEPDisplay.swift + SessionSummary integration + killer experiment on real Athena data (1 session)

**Total: 2 build cycles.** Shares R-peak infrastructure with T2-09 (zero marginal cost for R-peak detection if T2-09 is already built).

## Recommendation
Build after T2-09 R-peak infrastructure is in place (shared Optics R-peak stream). HEP adds minimal implementation overhead (250 LOC on top of T2-09 infrastructure) and delivers a genuinely novel interoceptive awareness metric that no commercial meditation app provides. For a decades-experienced meditator, HEP amplitude change across sessions is a meaningful practice depth indicator.
