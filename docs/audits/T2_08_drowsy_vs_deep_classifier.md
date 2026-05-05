# T2-08: Drowsy vs. Deep Meditation Classifier

## Executive verdict
GO-WITH-CAVEATS — a binary classifier is technically feasible on 4-electrode 256 Hz EEG with the specified feature set, but the domain shift from PSG training data to Muse S is severe; ship only after collecting 20+ labeled Muse S sessions using a within-user protocol, and accept ~15% false-alarm rate as a design constraint rather than a bug.

## What it claims to do
An on-device CoreML binary classifier distinguishes genuine deep meditation (sustained alpha/theta with preserved cortical complexity) from drowsiness/stage-1 sleep (theta bursts with flattened complexity, slow eye rolls, vertex sharp waves). Features include spectral entropy, theta/alpha ratio, 1/f slope (aperiodic exponent), beta variance, and eye-blink rate (estimated from frontal electrode artifact amplitude). Classification runs every 10–30 seconds on a rolling window. If the classifier outputs `drowsy` for two consecutive windows, the app emits a gentle haptic or audio cue to re-engage the meditator.

## Neuroscience basis

- **Kemp et al. 2000 / Sleep-EDF dataset** (*Journal of Sleep Research*, 9(4):317–322; also PhysioNet) — 197-hour polysomnography corpus, 2-channel EEG (Fpz-Cz, Pz-Oz), 100 Hz. Stage W, N1 (drowsy), N2, N3, REM labels. The primary training source candidate. **Critical caveat:** Fpz-Cz approximates frontal midline, which partially overlaps Muse S AF7/AF8 spatial territory — this is the best available PSG data for transfer learning. However, 100 Hz PSG vs. 256 Hz Muse S, and 2-channel vs. 4-channel geometry, require careful feature normalization.
- **Donoghue et al. 2020** (*Nature Neuroscience*, 23(12):1655–1665) — FOOOF/specparam method for decomposing EEG into periodic (oscillatory) + aperiodic (1/f) components. The aperiodic exponent steepens during drowsiness and stage-N1 relative to alert rest. Feature directly implementable from the existing vDSP log10 µV² band powers via a 2-point (or multi-point) log-log slope fit. No new DSP infrastructure needed.
- **Brewer et al. 2011** (*PNAS*) — posterior cingulate deactivation in deep meditators correlates with self-report; frontal alpha increases in experienced practitioners during eyes-closed meditation differ from pre-sleep drowsiness by preserved beta activity and lower theta/alpha ratio variance. Provides feature-space intuition for the classifier boundary.
- **Klimesch 2007** (*Brain Research Reviews*, 53(1):63–88) — review distinguishing upper vs. lower alpha bands and their different cognitive correlates. Upper alpha (10–12 Hz) is preserved or enhanced in attentive meditation; lower alpha + theta dominance with reduced upper alpha signals drowsiness. This motivates splitting the alpha band into lower (8–10 Hz) and upper (10–12 Hz) sub-bands as additional features.
- **Subasi & Ercelebi 2005** (*Expert Systems with Applications*, 28(4):701–711) — EEG sleep classification with SVM on spectral features; 76–85% accuracy on held-out subjects using frontal channels only. Sets a realistic accuracy ceiling for cross-subject frontal-only classification.

## Muse S signal validity

**Domain shift — the central problem:** Sleep-EDF was recorded with clinical gel electrodes at 100 Hz, impedances < 5 kΩ, with subjects lying still. Muse S uses dry electrodes at ~20 kΩ, subjects seated, with the Muse notch filter pre-applied. Expected consequences:
- Higher baseline noise floor in Muse S (dry electrode contact noise ~5–10 µV RMS vs. gel ~1–2 µV RMS)
- Sleep-EDF vertex sharp waves (Cz electrode) are absent in Muse S — feature not available
- K-complexes: not visible in frontal-polar electrodes at AF7/AF8
- Spindles (12–15 Hz): weakly visible frontally, if at all
- Eye-roll slow waves (stage N1): partially captured at AF7/AF8 due to frontal proximity to orbits — *this is a useful signal*

**Features available on Muse S:**
- Spectral entropy: YES — computable from existing vDSP band powers
- Theta/alpha ratio: YES — already in the meditationIndex pipeline
- 1/f slope (aperiodic exponent): YES — 2-point fit on log-log power spectrum from existing pipeline
- Beta variance: YES — rolling std of beta band power, trivial addition
- Eye-blink rate: PARTIAL — blink artifacts visible as amplitude spikes > 150 µV at AF7/AF8; already partially handled by the 4-layer artifact rejection; need to repurpose amplitude events as blink-rate counter rather than just rejecting them

**What is NOT available:**
- Vertex sharp waves (no Cz)
- Spindle detection (spindles not reliably visible at frontal-polar in dry EEG)
- EOG channel (no dedicated eye movement channel; only indirect via AF artifact)

**Effective classification:** Limited to the W vs. N1 boundary (wake/deep meditation vs. drowsy), which is the clinically meaningful boundary for this application. N2/N3 detection is not feasible with this hardware.

**SNR assessment:** A 20+ session within-user Muse S dataset with manual labels (video + self-report) is the minimum viable training set. OpenNeuro ds002723 contains open-eyes resting-state Muse data but has limited drowsy/sleep labels — useful for normalization but not for supervised training labels.

## Implementation cost (realistic)

- **Files to create:**
  - `MusePlus/ML/DrowsyClassifier.swift` (~120 LOC, CoreML model wrapper + feature extraction call)
  - `MusePlus/ML/Features/SpectralFeatures.swift` (~180 LOC, spectral entropy, 1/f slope, band ratio computation on rolling window)
  - `MusePlus/ML/Features/ArtifactEvents.swift` (~80 LOC, blink-rate counter from existing amplitude rejection events)
  - `MusePlus/ML/DrowsyAlert.swift` (~60 LOC, two-window confirmation logic + haptic/audio trigger)
  - `model_training/drowsy_classifier.ipynb` (~300 LOC Python, Sleep-EDF feature extraction + fine-tune on Muse S labels)
  - `MusePlus/ML/DrowsyClassifier.mlmodel` (CoreML model, target < 5 MB)
- **Files to modify:**
  - `MusePlus/Session/DepthGateStateMachine.swift` (consume classifier output, ~30 LOC)
  - `MusePlus/DSP/EEGProcessor.swift` (expose rolling feature vector, ~50 LOC)
  - `MusePlus/Artifact/ArtifactRejection.swift` (expose blink amplitude events instead of silently dropping, ~20 LOC)
- **LOC estimate:** ~790 LOC Swift, ~300 LOC Python training code. Expect ~1000 LOC Swift after iteration.
- **iOS-specific risks:**
  - CoreML model inference on 10-second windows: < 1 ms on A14+ Neural Engine. Model size target 2–4 MB (logistic regression or small random forest; deep neural net not needed and would risk size budget).
  - False-alarm UX: waking a practitioner in genuine deep state is the worst possible failure mode. Must implement two-window confirmation (20–60 s confirmation delay) and a user-facing "dismiss" gesture that penalizes the classifier.
  - Thread safety: feature extraction must not block the real-time EEG processing thread; use a dedicated background queue with a copy of the feature vector.
  - Battery: CoreML on Neural Engine draws < 50 mW marginal. Acceptable.
- **Model size budget:** A 6-feature logistic regression or gradient-boosted tree (100 trees, depth 4) is well under 500 KB. A small MLP (3 layers, 64 hidden units) in CoreML is ~800 KB. Both are within budget.

### Label noise analysis
The primary label noise source is self-report ambiguity: users cannot accurately recall whether they were meditating or drowsy during a specific 10-second window after the fact. Mitigation: use a "tap to mark" button during sessions that allows users to flag perceived drowsiness in real time; combine with video-based drowsiness labels (head nod detection via front camera) in a pilot study before committing to model training.

## Killer experiment (1 hour to run on Sparky / device)

**Test:** Measure feature separability between known-alert and known-drowsy epochs using existing Sleep-EDF data, restricting to Fpz-Cz channel and resampling to 256 Hz to simulate Muse S.

**Procedure:**
1. Download Sleep-EDF Cassette subset (20 nights, freely available on PhysioNet) — ~200 MB.
2. Extract 30-second epochs labeled W (wake/alert) and N1 (drowsy) from the Fpz-Cz channel.
3. Resample to 256 Hz, apply 45–65 Hz notch filter, compute: spectral entropy, theta/alpha ratio, 1/f slope, beta variance.
4. Train a logistic regression (sklearn, 5-fold cross-validation) and report AUROC.

**Expected output:** AUROC 0.80–0.88 on Sleep-EDF Fpz-Cz resampled data (consistent with Subasi & Ercelebi 2005 frontal-only benchmark).

**Pass threshold:** AUROC > 0.78 on held-out subjects. If < 0.78, the feature set is insufficient even before domain shift to Muse S — kill or add features before proceeding.

**Time estimate:** ~45 minutes on Sparky with Python/sklearn. No Muse S required for this gate experiment.

## Build estimate if GO
- Build 55: SpectralFeatures.swift + unit tests against known synthetic signals (1 session)
- Build 56: ArtifactEvents blink-rate counter + data collection mode (in-app labeled epoch logger) (1 session)
- Build 57: Collect 20+ labeled Muse S sessions from TestFlight users (2–3 weeks elapsed, not a build session)
- Build 58: Train CoreML model on collected data, convert with coremltools, integrate DrowsyClassifier.swift (1 session)
- Build 59: Two-window confirmation + DrowsyAlert UX + TestFlight beta (1 session)
- Build 60: Iterate on false-alarm rate with user feedback (1 session)

**Total: 5 active build sessions + 2–3 weeks data collection.** This is a multi-sprint feature.

## Recommendation
Pilot study first — run the killer experiment now; if AUROC > 0.78, proceed to Build 55 and data collection immediately, but do not ship the classifier until 20+ Muse S labeled sessions exist.
