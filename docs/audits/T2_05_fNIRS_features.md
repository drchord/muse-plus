# T2-05: fNIRS Features (Prefrontal Hemodynamics)

## Executive verdict
**GO** — new modality enabled entirely by Athena's 16-channel Optics system. Muse S 2019 had no fNIRS capability; this feature did not exist in the prior audit scope. Athena's 730nm/850nm dual-wavelength channels enable modified Beer-Lambert HbO/HbR computation. Prefrontal hemodynamic response measurement during meditation provides a slow (seconds-scale) complementary signal to EEG's fast (ms-scale) dynamics, enabling HbO-EEG state fusion. Already covered in Build 55b (~400 LOC `OpticsPipeline.swift` per ATHENA_SPECS.md migration checklist).

> **Athena hardware:** 16 Optics channels at 64 Hz. 730nm (HbR) channels: OPTICS1/2/5/6. 850nm (HbO) channels: OPTICS3/4/7/8. Inner pairs (5,6,7,8) = shorter source-detector separation (~1 cm, more superficial). Outer pairs (1,2,3,4) = longer separation (~2.5 cm, deeper cortical penetration). HbO/HbR via modified Beer-Lambert on 730nm + 850nm pairs.

## What it does
Measures prefrontal cortical hemodynamic response (HbO and HbR trajectories) during meditation sessions using near-infrared spectroscopy. Key signals:

- **HbO decrease during absorption:** Deeply absorbed meditation states are associated with reduced prefrontal HbO (Brewer 2011 fMRI analog: posterior cingulate deactivation; prefrontal hemodynamics track default-mode suppression in absorbed meditators).
- **HbO/HbR ratio dynamics:** The HbO/HbR ratio encodes neurovascular coupling efficiency. Stable ratio with low absolute HbO = metabolically quiet prefrontal cortex = absorption indicator.
- **fNIRS-EEG fusion:** HbO trajectory (slow, 10–30 s timescale) combined with EEG theta power (fast, 1–5 s timescale) enables dual-modality state classification — each modality compensates for the other's temporal/spatial blind spots.
- **Mayer wave (0.1 Hz) extraction:** Slow oscillation in HbO at ~0.1 Hz reflects vasomotor/sympathetic tone. Coherence between Mayer wave and HRV LF peak (also ~0.1 Hz, from T2-09) provides HRV-fNIRS coupling metric for vagal tone assessment.

## Algorithm

**Modified Beer-Lambert (Cope & Delpy 1988):**

```
ΔOD_λ = -log10(I_t / I_0)   [optical density change at wavelength λ]

[ΔHbO]   [ε_HbO_730  ε_HbO_850]^-1   [ΔOD_730]
[ΔHbR] = [ε_HbR_730  ε_HbR_850]    × [ΔOD_850]
```

Where ε values are extinction coefficients from Cope & Delpy 1988 table (730nm: HbO=0.366, HbR=0.775 cm^-1/mM; 850nm: HbO=1.027, HbR=0.405 cm^-1/mM — multiplied by differential path length factor DPF ≈ 6.0 for adult prefrontal cortex).

**Post-processing pipeline:**
1. Modified Beer-Lambert → ΔHbO, ΔHbR per channel pair
2. Bandpass 0.01–0.5 Hz → removes slow drift (< 0.01 Hz) and cardiac (0.8–3 Hz) — **note:** Mayer wave at 0.1 Hz must be preserved within this band
3. For HRV-fNIRS coupling: separately extract 0.05–0.15 Hz band from HbO envelope (Mayer wave)
4. Spatial averaging across 4 frontal regions: left-outer, left-inner, right-outer, right-inner
5. Baseline: pre-session 60-second rest epoch; all ΔHbO expressed relative to rest baseline

**Cite:**
- Cope & Delpy 1988 *Medical and Biological Engineering and Computing* — modified Beer-Lambert; extinction coefficients
- Brewer et al. 2011 *PNAS* — experienced meditator prefrontal hemodynamics during absorbed meditation
- Schroeter et al. 2003 *NeuroImage* — canonical fNIRS task-rest contrast (mental arithmetic HbO increase in DLPFC)
- Ferrari & Quaresima 2012 *NeuroImage* — comprehensive fNIRS review; methodology, DPF values, artifacts

## Neuroscience basis

- **Cope & Delpy 1988** (*Medical and Biological Engineering and Computing*, 26:289–294) — modified Beer-Lambert law for fNIRS; extinction coefficients at 730nm and 850nm. Foundational algorithm reference.
- **Brewer et al. 2011** (*PNAS*, 108(50):20254–20259) — experienced meditators show posterior cingulate and prefrontal default-mode deactivation during absorbed meditation; prefrontal HbO decrease is the fNIRS analog of this fMRI finding.
- **Schroeter et al. 2003** (*NeuroImage*, 18(4):828–835) — fNIRS detects HbO increase in dorsolateral prefrontal cortex (DLPFC) during mental arithmetic vs. rest. The canonical fNIRS task-rest contrast; used as the killer experiment ground truth.
- **Ferrari & Quaresima 2012** (*NeuroImage*, 63(2):921–935) — comprehensive fNIRS methodology review. DPF values, artifact sources (motion, hair contact), channel placement standards.
- **Acharya et al. 2016** (*Computers in Biology and Medicine*, 71:101–125) — HRV Mayer wave (0.1 Hz vasomotor oscillation) extraction; HRV-fNIRS coupling methodology.

## Athena signal validity

**Channel geometry (from ATHENA_SPECS.md):**
- 730nm: OPTICS1 (left outer), OPTICS2 (right outer), OPTICS5 (left inner), OPTICS6 (right inner)
- 850nm: OPTICS3 (left outer), OPTICS4 (right outer), OPTICS7 (left inner), OPTICS8 (right inner)
- 4 HbO/HbR pairs: left-outer (1+3), right-outer (2+4), left-inner (5+7), right-inner (6+8)

**Coverage:** Athena sits over prefrontal/frontopolar cortex (Fp1/Fp2 ~ AF7/AF8 region). This is the anterior prefrontal cortex (aPFC), not DLPFC (which requires electrode placement further posterior). Schroeter 2003 DLPFC finding uses longer source-detector separation; Athena's coverage is aPFC + outer channels reaching approximately F3/F4.

**DPF consideration:** Standard adult DPF ≈ 6.0 at 730nm and 850nm for prefrontal cortex (Ferrari & Quaresima 2012). For non-commercial single-user use, fixed DPF is acceptable (age-corrected DPF adds < 5% difference for adults).

**Hair interference:** Athena softband positions sensors over forehead — relatively hair-free for frontal fNIRS. Less of an issue than occipital placement.

**Motion artifacts:** Head movements during meditation produce HbO spikes. The existing accelerometer >0.25g motion gate must be applied to OpticsPipeline output; epochs with motion artifacts must be flagged. Wavelet-based motion artifact correction (Molavi & Dumont 2012) can be applied offline.

**16-channel vs. 4-channel mode:** Use 16-channel mode (preset 1041) for full outer+inner pairs. 4-channel mode (inner pairs only) provides shorter source-detector distances and more superficial signal — useful as a sensitivity check.

## Implementation cost

Already covered in Build 55b per ATHENA_SPECS.md migration checklist (`OpticsPipeline.swift` ~400 LOC). Breakdown:

- **`MusePlus/Pipeline/OpticsPipeline.swift`** (~400 LOC total):
  - Modified Beer-Lambert matrix computation (~80 LOC)
  - Bandpass filtering 0.01–0.5 Hz via vDSP IIR (~60 LOC)
  - Mayer wave extraction (0.05–0.15 Hz separate bandpass, ~40 LOC)
  - Spatial averaging across 4 frontal regions (~30 LOC)
  - Baseline subtraction and drift correction (~50 LOC)
  - Motion artifact flag (accelerometer gate integration, ~40 LOC)
  - HbO/HbR output stream publisher (~50 LOC)
  - Unit tests and calibration check (~50 LOC)
- **`MusePlus/UI/fNIRSDisplay.swift`** (~150 LOC, HbO/HbR trajectory plot, session summary fNIRS panel)
- **Files to modify:**
  - `MusePlus/Session/SessionSummary.swift` (add fNIRS section: HbO trajectory, aPFC lateralization, Mayer wave coherence if T2-09 is also built, ~50 LOC)
  - `MusePlus/ML/JhanaClassifier.swift` (accept HbO feature as auxiliary input for Build 58 jhana classifier, ~20 LOC)
- **LOC total:** ~550 LOC new (incl. OpticsPipeline), 70 LOC modified.
- **iOS-specific risks:**
  - `getOpticsChannelValue` per SDK 8.0.5: must subscribe to `IXNMuseDataPacketTypeOptics` and index by `IXNOptics` enum (OPTICS1–OPTICS16).
  - 16 channels at 64 Hz = 1024 samples/sec total. At 4 bytes/float: ~4 KB/sec. Trivial bandwidth.
  - IIR bandpass at 0.01 Hz on 64 Hz signal requires high-order filter (≥ 6th order Butterworth) for sharp roll-off at 0.01 Hz. Use offline-designed coefficients (precomputed via Python/scipy, baked into Swift as static arrays).
  - Preset 1041 must be set for 16-channel Optics; verify via `muse.setPreset(.preset1041)` in `MuseClient.swift`.
- **Computational cost:** Beer-Lambert 2×2 matrix solve: < 0.1 ms. IIR filter per channel: < 0.1 ms. Total: < 2 ms per Optics packet. Battery: marginal (Optics LEDs draw current; already managed by preset power setting).

## Killer experiment

**Test:** Load 5 min resting fNIRS + 5 min cognitive task (mental arithmetic — e.g., serial 7-subtractions). Expect HbO increase in aPFC during task vs. rest (Schroeter 2003 canonical finding). Pass = task-rest contrast effect size > 0.5 (Cohen's d).

**Procedure:**
1. Record: 5 min eyes-closed rest → 5 min mental arithmetic (count backward by 7 from 500) → 5 min rest.
2. Run OpticsPipeline: Beer-Lambert → bandpass → spatial average.
3. Compute mean HbO in task block vs. mean HbO in rest block (per region: left-inner, right-inner, left-outer, right-outer).
4. Compute Cohen's d = (HbO_task - HbO_rest) / pooled_std.
5. Confirm sign: HbO should increase (not decrease) during mental arithmetic in aPFC.

**Pass threshold:** Cohen's d > 0.5 in at least one of the 4 frontal regions (DLPFC signal expected strongest in outer channels given deeper penetration). If d < 0.5, pipeline requires calibration (DPF adjustment, artifact correction, or baseline correction).

**Meditation sub-experiment (follow-on):** Record 20-min meditation session. Expect HbO decrease during deep absorption (Brewer 2011 analog). Compare HbO in first 5 min (settling) vs. minutes 15-20 (stable absorption). For experienced meditator user, d > 0.3 expected.

**Time estimate:** ~2 hours (recording + processing).

## Build estimate if GO
Build 55b: OpticsPipeline.swift + killer experiment (already in ATHENA_SPECS.md SDK migration plan, 1 session)
Build 56: fNIRSDisplay.swift + SessionSummary integration (1 session)
Build 58: JhanaClassifier integration — HbO as auxiliary input (1 session, parallel with jhana classifier build)

**Total: Already partially planned in Build 55b.** Additional UI + jhana integration = 1–2 sessions marginal.

## Recommendation
Build as part of SDK 8.0.5 migration (Build 55b). OpticsPipeline.swift is already in the migration checklist. Run the killer experiment (mental arithmetic task-rest contrast) on day 1 of Athena hardware availability — this validates the entire fNIRS pipeline before committing to meditation-specific analysis. No standalone dependencies; feeds into T2-09 (Mayer wave coherence) and Build 58 jhana classifier as auxiliary input.
