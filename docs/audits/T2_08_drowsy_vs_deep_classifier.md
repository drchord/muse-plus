# T2-08: Drowsy vs. Deep Meditation Classifier

## Executive verdict
**SUPERSEDED by Build 58 jhana classifier.** The planned Build 58 jhana state classifier discriminates among: rest / access concentration / 1st jhana / 2nd jhana / 3rd jhana / 4th jhana / open monitoring / drowsy / sleep — a 9-class problem in which "drowsy" is one class. A standalone binary drowsy/deep classifier is redundant and architecturally wasteful. Recommendation: defer as standalone; integrate drowsy detection as one class within the Build 58 jhana classifier.

> **Athena impact:** Athena's 8 channels (vs. 4) substantially improve the classifier's feature space (bilateral temporal theta, frontal asymmetry via FAA, 14-bit SNR). This hardware upgrade makes the 9-class jhana problem more tractable, not less — strengthening the case for deferring standalone T2-08 and building it right in Build 58.

## What it claims to do
An on-device CoreML binary classifier distinguishes genuine deep meditation (sustained alpha/theta with preserved cortical complexity) from drowsiness/stage-1 sleep (theta bursts with flattened complexity, slow eye rolls). Classification runs every 10–30 seconds on a rolling window. If the classifier outputs `drowsy` for two consecutive windows, the app emits a gentle haptic or audio cue to re-engage the meditator.

## Why superseded: jhana classifier covers the full problem

The drowsy/deep binary framing is a 2018-era baseline approach. For a decades-experienced meditator the meaningful state space is much richer:

| Class | EEG signature |
|-------|--------------|
| Rest (eyes-closed baseline) | 1/f background, mixed alpha |
| Access concentration | Sustained frontal alpha, reduced alpha variability |
| 1st jhana | Theta + alpha, reduced beta, sustained |
| 2nd jhana | Theta dominant, further beta suppression |
| 3rd jhana | High-amplitude theta, strong frontal coherence |
| 4th jhana | Equanimous — near-flat EEG, very low delta |
| Open Monitoring | Frontal alpha + gamma microbursts |
| Drowsy | Theta bursts + flattering complexity + slow eye rolls |
| Sleep (N1/N2) | Vertex sharp waves (not visible on Athena), spindles absent at frontal-polar |

A binary classifier throws away 7 of 9 classes. The jhana classifier solves drowsy detection as a byproduct.

## Algorithm: Riemannian geometry MDM (replaces logistic regression baseline)

**Why not logistic regression:** Logistic regression on spectral features assumes feature independence and Gaussian distributions — neither holds for EEG covariance structure. On small N (20–50 sessions per individual), feature-based classifiers overfit.

**MDM (Minimum Distance to Mean, Barachant et al. 2014):** Operates directly on EEG covariance matrices in Riemannian geometry. Covariance matrices live on a symmetric positive definite (SPD) manifold; Euclidean averaging of SPD matrices is incorrect. MDM computes geodesic distances on the SPD manifold and classifies by nearest class centroid. Properties:
- Robust on small N (works well with 20–50 labeled sessions per class)
- No feature engineering required — raw covariance matrix is the input
- Naturally handles multi-class (9-class) via one-vs-rest geodesic voting
- Athena 8-channel covariance: 8×8 SPD matrix (36 unique values) — richer than 4×4 Muse S 2019

**Why not transformers:** Insufficient data per individual user. A decoder-only transformer for EEG (e.g., LaBraM or EEG-GPT) requires 100k+ labeled epochs for fine-tuning. A solo meditator accumulating 1 session/day will never reach this. MDM converges on 20–50 sessions.

**Pre-training (if label efficiency needed):** BENDR self-supervised pretraining (Banville et al. 2021) learns EEG representations from unlabeled data, reducing labeled session requirements. BENDR pretrained on TUAB (Temple University Hospital EEG corpus) can be fine-tuned with MDM-style covariance features using as few as 10 labeled sessions. Useful if jhana labels are expensive to collect.

**Cite:** Barachant et al. 2014 *IEEE Transactions on Biomedical Engineering* ("Classification of covariance matrices using a Riemannian-based kernel for BCI applications"). Banville et al. 2021 *Journal of Neural Engineering* ("Uncovering the structure of clinical EEG signals with self-supervised learning").

## Neuroscience basis (retained from prior audit, updated for jhana scope)

- **Kemp et al. 2000 / Sleep-EDF** — drowsy (N1) vs. wake EEG signatures; remains valid for the "drowsy" class within the 9-class jhana classifier.
- **Donoghue et al. 2020** (*Nature Neuroscience*) — FOOOF aperiodic exponent steepens during drowsiness. Valid feature for jhana vs. drowsy discrimination.
- **Brewer et al. 2011** (*PNAS*) — experienced meditators' frontal alpha increases during deep states; directly applicable to user profile (decades-experienced meditator).
- **Klimesch 2007** (*Brain Research Reviews*) — upper vs. lower alpha band distinction; upper alpha preserved in deep meditation, lower alpha + theta signals drowsiness. Motivates the 8–10 Hz / 10–12 Hz split as jhana classifier features.
- **Barachant et al. 2014** *IEEE Trans Biomed Eng* — MDM Riemannian classifier; small-N robust BCI classification.
- **Banville et al. 2021** *J Neural Eng* — BENDR self-supervised EEG pretraining; reduces label requirements for individual fine-tuning.

## Athena signal validity

**Channels:** 8-channel covariance matrix is 8×8 = 36 unique values vs. 4×4 = 10 for Muse S 2019. The temporal channels (TP9/TP10-equivalent) capture theta differently from frontal (AF7/AF8), enabling bilateral temporal-frontal phase relationships as implicit Riemannian features.

**14-bit ADC:** Lower noise floor improves covariance matrix conditioning (fewer ill-conditioned matrices due to noise regularization issues).

**Optics state context:** fNIRS HbO at session start provides a hemodynamic prior that can be used as an auxiliary feature for jhana class initialization (e.g., low prefrontal HbO at baseline correlates with absorbed states per Brewer 2011 fMRI analog).

## Implementation cost (revised for jhana integration)

Standalone T2-08 is not built. Instead, the jhana classifier (Build 58) incorporates:
- `MusePlus/ML/JhanaClassifier.swift` (~150 LOC CoreML wrapper)
- `MusePlus/ML/RiemannianMDM.swift` (~250 LOC, SPD manifold geodesic distance + MDM)
- `MusePlus/ML/CovarianceExtractor.swift` (~120 LOC, rolling 8-channel covariance matrix computation via vDSP)
- `model_training/jhana_mdm.py` (~300 LOC Python, BENDR pretraining + MDM fine-tune on personal session corpus)
- **No standalone DrowsyClassifier.swift** — drowsy is a label in the jhana dataset.

**Savings from deferral:** Eliminates 5 active build sessions + 2-3 week data collection gap of the standalone design. Replaces with a single Build 58 effort producing a more capable classifier.

## Killer experiment (deferred to Build 58 gate)

**Test (for jhana classifier, replacing standalone drowsy test):**
Run MDM on simulated jhana-class EEG data (synthesized from published EEG signatures: theta power, alpha power, aperiodic exponent per class). Validate that 8-channel Riemannian distances separate classes better than 4-channel.

**Pass threshold:** 8-channel MDM pairwise distance ratio (between-class / within-class) > 1.5 vs. 4-channel MDM on same synthetic data. Confirms Athena hardware advantage for jhana classification.

**Prior experiment (for reference):** The original killer experiment (AUROC > 0.78 on Sleep-EDF Fpz-Cz logistic regression) is no longer the gate — MDM on real covariance matrices supersedes logistic regression on spectral features. Re-run with MDM if needed for baseline comparison.

## Build estimate
- **Build 58:** JhanaClassifier.swift + RiemannianMDM.swift + CovarianceExtractor.swift + jhana_mdm.py training script (2 sessions — MDM Riemannian implementation is non-trivial in Swift without a dedicated linear algebra library)
- **Not built:** Standalone DrowsyClassifier.swift, SpectralFeatures.swift (unless needed elsewhere), ArtifactEvents blink-rate counter

## Recommendation
Do not build as standalone. Integrate drowsy detection into Build 58 jhana classifier using Riemannian MDM. Accumulate labeled jhana session data starting now. If BENDR pretraining is needed, run on Aurora (RTX 3090) before Build 58.
