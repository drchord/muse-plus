# T1-01: EEG Microstates

## Executive verdict
**GO** — reopened by Athena hardware upgrade. Canonical Lehmann microstate analysis requires ≥ 8 channels; Muse S 2019 (4 channels) was a hard NO-GO. Athena provides exactly 8 channels (EEG1–EEG4 + AUX1–AUX4), meeting the minimum threshold. Meditation-specific microstate signatures (Faber 2017 state C deactivation during absorption) are directly relevant to the user profile (decades-experienced meditator pursuing deep absorption states).

> **Previous verdict (Muse S 2019, 4 channels):** NO-GO — canonical Lehmann atomize-and-agglomerate microstate analysis requires ≥ 8 channels for stable template extraction. 4-channel Muse S 2019 cannot produce reliable topographic maps.

> **Athena hardware impact:** 8 channels (EEG1 ~ TP9, EEG2 ~ AF7, EEG3 ~ AF8, EEG4 ~ TP10, AUX1–AUX4) provides the minimum viable channel count for the Pascual-Marqui 2002 atomize-and-agglomerate algorithm. Template extraction from GFP peaks is stable at ≥ 8 channels per published benchmarks.

## What it does
EEG microstates are quasi-stable topographic maps of electrical scalp activity, each lasting 60–120 ms, that recur throughout continuous EEG. Four canonical templates (A, B, C, D) account for ~70% of the variance in resting EEG. During meditation, template C (associated with default mode network deactivation and reduced self-referential processing) shows reduced occupancy and dwell time, while template D (associated with attentional control) increases — a signature of absorbed states (Faber 2017).

Microstate sequence statistics (occupancy, mean duration, transition probabilities) provide a temporally resolved measure of meditation depth that complements DepthGate's amplitude-based `inDeep` signal.

## Algorithm: Pascual-Marqui atomize-and-agglomerate

**Pascual-Marqui et al. 2002** (*Methods in Experimental and Clinical Pharmacology*) — the canonical microstate algorithm:

1. **GFP peaks:** Compute Global Field Power (GFP) at each sample: `GFP(t) = std(EEG channels at t)`. Extract samples at local GFP maxima — these are the most "prototypical" topographic moments.
2. **Agglomerative clustering:** Apply modified k-means clustering on GFP-peak topographic maps, using spatial correlation (ignoring polarity) as the distance metric. K=4 canonical templates.
3. **Template assignment (backfit):** Assign each EEG sample (not just GFP peaks) to the template with the highest absolute spatial correlation. This produces a continuous microstate sequence.
4. **Statistics:** Compute for each template: occupancy (% time), mean duration, and transition probability matrix.

**Koenig et al. 2002** (*NeuroImage*) — validation of the 4-template solution (A, B, C, D) as the canonical resting-state decomposition. Published normative values: A=22%, B=28%, C=26%, D=24% occupancy.

**Faber et al. 2017** (meditation microstate signatures) — meditation increases state D occupancy (attentional control network); state C occupancy decreases during absorption. Directly applicable to jhana depth tracking for the experienced meditator user profile.

## Neuroscience basis

- **Lehmann et al. 1987** (original microstate concept) — quasi-stable EEG topography as the "atom of thought." Historical foundation.
- **Pascual-Marqui et al. 2002** *Methods in Experimental and Clinical Pharmacology* — atomize-and-agglomerate algorithm; canonical reference for k-means microstate analysis on ≥ 8 channels.
- **Koenig et al. 2002** *NeuroImage* — 4-template canonical solution; normative occupancy values (A 22%, B 28%, C 26%, D 24%). Pass criterion for killer experiment.
- **Faber et al. 2017** (meditation-specific microstate signatures) — state C deactivation = absorption indicator; state D increase = sustained attention. Directly applicable to jhana depth tracking.
- **Michel & Koenig 2018** (*NeuroImage*, 180:577–593) — comprehensive microstate review; discusses channel count requirements (≥ 8 for stable template extraction) and transition matrix Markov structure.

## Athena signal validity

**Channel count:** 8 channels exactly meets the ≥ 8 minimum. Coverage: frontal (AF7/AF8), temporal (TP9/TP10), and 4 AUX channels. The AUX channels on Athena are available in the SDK (`AUX1`–`AUX4` in `IXNEeg` enum) — their physical location on the Athena softband must be confirmed from hardware documentation, but ATHENA_SPECS.md indicates they are on-head.

**GFP computation:** GFP = `std()` across all 8 channels at each sample — directly implementable via vDSP `vDSP_meanv` + `vDSP_rmsqv`.

**Polarity invariance:** Microstate spatial correlation ignores polarity (uses absolute value of correlation) — robust to reference electrode choice.

**14-bit ADC:** Lower noise floor improves GFP peak SNR, increasing the number of reliable topographic prototypes extracted per session.

**Known limitation:** Athena's 8 channels are not a full 64-channel cap. Templates A–D will be less spatially resolved than in high-density EEG studies. However, the 4 canonical templates are resolvable at 8 channels (Pascual-Marqui 2002 original work used 16 channels; 8 is the validated minimum). The occupancy statistics (not spatial maps) are the target output — robust to spatial undersampling.

## Implementation cost

- **Files to create:**
  - `MusePlus/DSP/MicrostateAnalyzer.swift` (~300 LOC: GFP computation, polarity-invariant k-means clustering, backfit assignment, occupancy + duration + transition matrix statistics)
  - `MusePlus/UI/MicrostateDisplay.swift` (~150 LOC: real-time 4-bar occupancy display + session summary microstate timeline)
  - `model_training/microstate_templates.json` — pre-computed canonical A/B/C/D template vectors (from published Koenig 2002 data or computed offline from a normative 8-channel dataset; baked into app bundle)
- **Files to modify:**
  - `MusePlus/DSP/EEGProcessor.swift` (expose 8-channel sample matrix for GFP computation, ~30 LOC)
  - `MusePlus/Session/SessionSummary.swift` (add microstate occupancy section, ~40 LOC)
- **LOC estimate:** ~450 LOC Swift new, 70 LOC modified. k-means polarity-invariant iteration converges in < 20 iterations on 5-minute data; trivial CPU.
- **iOS-specific risks:**
  - k-means on GFP peaks: 8-channel × N_peaks (typically ~1500 per 5-min recording). Runs on background thread; < 100 ms total.
  - Template pre-loading from bundle JSON: load on session start, cache in memory.
  - AUX channel availability: must verify `AUX1`–`AUX4` emit data on Athena in preset 1041. If AUX channels are not connected on the softband, fall back to 4-channel analysis with degraded template quality.
- **Computational cost:** GFP per sample: 8 multiplications + std = negligible. k-means: < 10 ms for 1500 peaks × 20 iterations. Backfit: linear scan, trivial. Battery: zero marginal.

## Killer experiment

**Test:** Run on 5 min eyes-closed rest data, compute occupancy of 4 templates, compare to published normative values (Koenig 2002: A=22%, B=28%, C=26%, D=24%) and verify Markov transition structure.

**Procedure:**
1. Record 5 min eyes-closed rest session on Athena (or use an existing 8-channel EEG open dataset resampled to 256 Hz, e.g., from OpenNeuro).
2. Run MicrostateAnalyzer: GFP peaks → k-means K=4 → backfit → occupancy statistics.
3. Compare occupancy vector [A, B, C, D] to Koenig 2002 norms via chi-square goodness-of-fit.
4. Inspect transition probability matrix for Markov structure (A→B, B→C, C→D, D→A dominant transitions per published literature).

**Pass threshold:** Templates identifiable (all 4 templates claim > 5% occupancy); occupancy distribution not significantly different from published norms (chi-square p > 0.05 at α=0.05, or qualitatively consistent if N is small). Transition matrix shows dominant A→B, B→C, D→A arcs (Markov structure per Koenig 2002).

**Time estimate:** ~2 hours including data collection and analysis.

## Build estimate if GO
- Build 55b: MicrostateAnalyzer.swift + GFP + k-means + backfit + unit tests on synthetic data (1 session)
- Build 56: Template bundle JSON pre-load + session integration + killer experiment on real Athena data (1 session)
- Build 57: MicrostateDisplay.swift UI + SessionSummary integration (1 session)

**Total: 3 build cycles.** No dependencies on other T1 or T2 features.

## Recommendation
Build now. Hardware barrier eliminated by Athena upgrade. Algorithm is ~300 LOC, well-understood, and produces a novel real-time meditation depth signal (state C vs. D occupancy) that complements the existing DepthGate amplitude metric. For a decades-experienced meditator, microstate C deactivation is a direct correlate of absorption depth.
