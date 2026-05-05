# Muse++ ROADMAP — Builds 55a → 66

**Drafted:** 2026-05-04  
**Revised:** 2026-05-04 (Athena hardware upgrade, advanced-practitioner reframe)  
**Current TestFlight build:** 54  
**Hardware:** Muse S Athena (MS-03) — 8 EEG @ 256 Hz/14-bit + 16 fNIRS @ 64 Hz + BLE 5.3 + USB-C wired  
**Canonical hardware spec:** `docs/ATHENA_SPECS.md`

---

## NORTH STAR (revised)

Muse++ is not a trainer. It is a **personal contemplative instrument** for a decades-experienced practitioner.

The instrument serves four functions:

1. **State discrimination** — precision biofeedback to distinguish FA, OM, non-dual, jhana depth gradations, cessation-adjacent events
2. **Drift detection in long sits** — online Bayesian change-point detection surfaces subtle deterioration the practitioner cannot introspect with certainty
3. **Transfer measurement** — no-headband self-rating calibrated against EEG ground truth on periodic check-ins; quantified interoceptive accuracy
4. **Post-session insight reports** — retrospective analytics (Sparky compute via Tailscale) reveal trends invisible within any single session

> **The app is not making itself necessary over time. It is making the invisible legible.**

---

## NON-NEGOTIABLE ARCHITECTURAL RULES

1. **No grasping.** Never signal "deeper is better." Reward *noticing*, *return*, *self-knowledge*. Scoring is informational, not motivational.
2. **Haptic-first feedback during practice.** Audio interrupts; haptic informs without disrupting. All real-time cues = haptic. Audio = optional soundscape backdrop only.
3. **Feature fade still applies — even for advanced practitioners.** Fade closes the "at-will" loop. A decades-practitioner still benefits from closing the interoceptive feedback gap. Build flags + milestone-gated removal from day 1.
4. **Personal baseline > absolute thresholds.** All spectral features normalized against same-session eyes-open baseline. No fixed expert-mode thresholds.
5. **Interoception bridges to transfer.** HEP-cued, HRV-cued, and fNIRS-visible attention training builds context-independent access to depth. The *cue* is the instrument; the EEG is the mirror.

---

## BUILD MAP

### Build 55a — SDK Migration + Athena Verification + Signal Foundations

> Core prerequisites. Unblocks everything downstream.

| Component | Detail |
|---|---|
| SDK 8.0.5 migration | Full Muse SDK update; BLE 5.3 service UUIDs + wired USB-C session fallback path |
| Athena spec verification | Live confirmation of 8-ch EEG layout, 16-ch fNIRS optics addresses, 256 Hz/14-bit ADC, 64 Hz optics sync with EEG timestamps; log mismatch vs `ATHENA_SPECS.md` |
| IRASA aperiodic exponent | Wen & Liu 2016 irregular-resampling auto-spectral analysis; separates 1/f slope from oscillatory peaks; feeds drift detector (57) and jhana classifier (58) |
| Gaussian-fit iTPF | Klimesch 1999 individual alpha-peak frequency via curve fitting; per-session; normalized against eyes-open baseline; feeds all depth scoring |
| 8-channel EEG pipeline | Independent spectral decomposition across all 8 channels; spatial averaging per region (frontal, temporal, parietal); replaces 4-channel pipeline |
| SessionRecorder (complete) | All fields: timestamps, raw epoch JSONs, IRASA output, iTPF, microstate sequence (placeholder for build 56), HRV R-R series, fNIRS HbO/HbR (placeholder for 55b), self-ratings (placeholder for 62), jhana labels (placeholder for 58) |

**Exit criterion:** live session captures full 8-channel spectral output + IRASA slope + iTPF per session; SessionRecorder writes complete JSON without empty fields crashing downstream parsers.

---

### Build 55b — fNIRS Integration

> 16-channel optics → hemodynamic biomarker stream. Parallel-trackable after 55a passes.

| Component | Detail |
|---|---|
| Modified Beer-Lambert transform | HbO and HbR per channel; extinction coefficients at Athena wavelengths (per `ATHENA_SPECS.md`); path-length correction via differential path-length factor |
| Bandpass filter | 0.01–0.5 Hz Butterworth (removes cardiac + motion artifacts, preserves slow hemodynamic envelope) |
| Frontal-region averaging | Bilateral prefrontal fNIRS channels averaged to single HbO/HbR scalar per second; this scalar enters SessionRecorder |
| Real-time fNIRS panel | Optional debug view during development; collapsed behind toggle in production |
| Motion artifact rejection | Spline interpolation on segments exceeding 2.5 SD acceleration threshold (from Athena IMU) |

**Exit criterion:** bandpassed HbO/HbR signal correlates visually with known hemodynamic response (breath-hold test) during validation session.

---

### Build 56 — 8-Channel Microstates

> **T1-#1 REOPENED.** Previously skipped on Muse S 2019 (4-electrode, insufficient spatial coverage). Athena's 8-channel layout makes canonical microstate analysis feasible.

**Algorithm:** Pascual-Marqui 2002 atomize-and-agglomerate (AAHC) clustering; Faber 2017 meditation-specific microstate signatures as prior template.

| Component | Detail |
|---|---|
| Template matching | Canonical 4-state (A/B/C/D) Lehmann template + Faber meditation states; cosine similarity assignment per 40 ms window |
| Microstate metrics | Duration, occurrence rate, transition probability matrix; per session |
| Meditation signatures | State D (global synchrony) elevated in experienced practitioners (Faber 2017 reference); track D-state duration across sessions as secondary depth index |
| SessionRecorder integration | Microstate sequence at 25 Hz label rate appended to session JSON |
| Stability gating | If 8-channel template stability (mean GEV explained) < 65%, log warning; do not display microstate panel to user that session |

**Exit criterion:** AAHC clustering on 5-min synthetic 8-channel data produces stable 4-state solution with GEV > 65%; D-state duration reliably increases during eyes-closed rest vs task in self-test.

---

### Build 57 — Subtle Drift Detector for Long Sits

> Online Bayesian change-point detection. Purpose: surface subtle deterioration in long-form practice before the practitioner's own awareness catches it — then get out of the way.

**Algorithm:** Adams & MacKay 2007 Bayesian online change-point detection (BOCPD) on compound signal: 1/f aperiodic slope + α/θ ratio (iTPF-normalized).

| Component | Detail |
|---|---|
| Input signal | 30-second sliding window IRASA slope + iTPF-normalized α/θ ratio; updated every 10 s |
| BOCPD hazard rate | Geometric prior with λ = 200 s (expects run lengths ~3 min between change-points in long sits) |
| Drift event | Posterior probability of change-point > 0.85 AND slope change in unfavorable direction → single soft haptic (40 ms, low intensity) |
| No-alarm floor | First 5 min always silent; prevents false positives during settling |
| Retrospective log | All change-point probabilities written to session JSON; offline Sparky report can reconstruct full drift trajectory |

**Exit criterion:** BOCPD correctly identifies step-change in synthetic 1/f signal within 2 windows; no false positive rate > 0.05 on flat synthetic signal over 60-min simulated session.

---

### Build 58 — Jhana State Discriminator

> Offline-trained Riemannian geometry MDM classifier. Distinguishes baseline, light absorption, jhana-adjacent absorption, and cessation-adjacent states. Designed for experienced-practitioner label variance.

**Algorithm:** Barachant 2014 Minimum Distance to Mean (MDM) in Riemannian geometry on covariance matrices; robust on small N=20-50 sessions; no curse of dimensionality on 8 channels.

| Component | Detail |
|---|---|
| Feature space | 8×8 covariance matrix per 5-second epoch; Riemannian mean per class; geometric distance as discriminator |
| Label schema | 4 classes: Baseline / Focused-Absorption / Deep-Absorption / Cessation-Adjacent; practitioner hand-labels first 20 sessions via post-session review UI |
| Training pipeline | Offline on Sparky (Python/pyriemann); model exported as CoreML; re-trains every 10 sessions once N ≥ 20 |
| Drowsy detection folded in | Drowsy = 5th class (high θ, low α, slow IRASA slope); supersedes T2-#8 as separate feature |
| Confidence gating | Only display label if MDM confidence margin > 0.3; otherwise show "unclassified" |
| UI integration | Non-intrusive state indicator (icon, not text) visible only in post-session summary; never during sit |

**Exit criterion:** MDM classifier achieves leave-one-session-out cross-validation accuracy ≥ 70% on practitioner's own labeled sessions once N ≥ 20; drowsy class separated from deep-absorption with precision ≥ 0.75.

---

### Build 59 — Cessation Event / Phasic Insight Detector

> Sliding-window novelty detection on covariance trajectory. Detects sudden EEG reorganization events consistent with cessation signatures.

**References:** Davis 2024 cessation signatures; Yang 2024 PNAS cessation electrophysiology; Lutz & Slagter P3-like phasic responses post-cessation.

| Component | Detail |
|---|---|
| Covariance trajectory | Riemannian distance between consecutive 5-s covariance matrices; time series of geodesic distances |
| Novelty threshold | Session-adaptive: event flagged when geodesic distance > μ + 3σ of session baseline; onset-locked 10-second window saved |
| Post-event log | Timestamps of all phasic events; written to SessionRecorder with full raw epoch |
| Practitioner review UI | Post-session list of flagged events with EEG spectral thumbnail; practitioner can confirm/dismiss; builds labeled cessation dataset |
| N ≥ 30 requirement | Pattern only surfaced in reports once 30+ labeled-confirmed events accumulate |

**Exit criterion:** novelty detector flags synthetic step-change covariance events with sensitivity ≥ 0.85 and specificity ≥ 0.90 on simulated session.

---

### Build 60 — HRV Coherence + Breath Pacer (Precision Grade)

> **T2-#9 REOPENED as GO.** Athena's 20-bit Optics-derived PPG eliminates R-R precision concern that gave T2-#9 its GO-WITH-CAVEATS verdict on Muse S 2019.

**References:** Acharya 2016 HRV review; Charlton 2018 PPG-derived respiration; McCraty HeartMath protocol.

| Component | Detail |
|---|---|
| R-peak detection | PPG from 20-bit Optics (64 Hz); Akima cubic spline interpolation to 4 Hz uniform R-R series (Acharya 2016) |
| LF coherence metric | Welch PSD on R-R series; LF peak (0.04–0.15 Hz) amplitude; resonance frequency locking at 5.5 breaths/min |
| Breath pacer | Visual breath circle + optional haptic pulse (inhale/exhale); defaults to 5.5 breaths/min; adjustable 4.5–6.5 range |
| PPG-derived respiration | Charlton 2018 amplitude modulation extraction; breath rate estimate from PPG envelope; shown in post-session summary |
| SessionRecorder integration | R-R series + LF coherence per minute appended to session JSON |

**Exit criterion:** R-R series correlation with manually marked peaks ≥ r=0.95 across 10-minute test recording; LF peak detectable during paced breathing session.

---

### Build 61 — Adaptive Audio via Offline Policy Learning

> **T2-#6 SUPERSEDED.** LinUCB bandit (old plan) replaced by Conservative Q-Learning (Kumar 2020 NeurIPS). Recommends rather than autonomously changes. Requires N ≥ 30 sessions of history before activating.

| Component | Detail |
|---|---|
| Action space | (volume level, binaural beat intensity, soundscape type) — discrete 3D grid |
| Reward signal | Session depth score + HRV coherence; retrospective per session (not real-time) |
| CQL training | Conservative Q-Learning on offline session history; Python on Sparky; exported as lookup table (not neural net) for CoreML |
| Recommendation mode | App *suggests* audio configuration at session start; practitioner accepts/overrides; override logged |
| N ≥ 30 gate | Policy silently accumulates data until N=30; before that, default audio configuration + no recommendations shown |
| Fade schedule | Recommendations offered for 60 sessions; then silenced; practitioner has built own audio intuition |

**Exit criterion:** CQL lookup table produces consistent non-trivial recommendations on held-out synthetic session histories; no recommendation degeneracy (all actions mapping to same choice).

---

### Build 62 — No-Headband Mode + Self-Rating UI

> Transfer measurement instrument. Decouples the practice skill from the device presence.

| Component | Detail |
|---|---|
| No-headband session | Same session UI; EEG/fNIRS panels hidden; session timer + soundscape + haptic pacer still available |
| Self-rating prompts | 3 randomized haptic taps per session; practitioner rates depth 1–7 (7-point Likert) at each tap; momentary ratings averaged to session self-score |
| Transfer score baseline | Self-rating distribution tracked across no-headband sessions; variance decreases as interoception accuracy improves |
| Headband/no-headband flag | All session JSONs tagged; Sparky retrospective can separate distributions |

**Exit criterion:** no-headband session completes without crash; self-ratings saved to SessionRecorder; UI is clean (no dangling EEG panels or nil-pointer errors).

---

### Build 63 — Calibration Check-In + Transfer Score

> Every 10th session wears headband. Closes the interoceptive feedback loop.

| Component | Detail |
|---|---|
| Check-in trigger | Session counter mod 10 = 0 → app suggests headband session (practitioner can skip once) |
| Comparison view | Post-session: self-rating vs actual EEG depth score scatter plot across last 30 sessions with headband |
| Pearson r display | Transfer score = r(self-rating, EEG depth) shown as single number; rolling 10-session window |
| Threshold milestones | r ≥ 0.5: "interoception emerging"; r ≥ 0.7: "transfer active"; r ≥ 0.85: "instrument optional" |
| Spaciousness mode unlock | r ≥ 0.85 sustained for 3 consecutive calibration check-ins → app enters minimal UI mode (timer + record only) |

**Exit criterion:** Pearson r calculated correctly on mock data; milestone thresholds trigger UI state changes without false positives.

---

### Build 64 — Sparky Retrospective Pipeline

> Tailscale → Python on 100.120.218.19 → analytics → PDF → email.

| Component | Detail |
|---|---|
| Session export | iOS share trigger uploads session JSON bundle over Tailscale to Sparky (rsync or HTTP PUT to local Flask endpoint) |
| Sparky analysis scripts | Python: microstate dynamics (transition entropy over time), jhana frequency trends, HRV LF coherence trajectory, fNIRS HbO trends, self-rating vs EEG r trajectory |
| PDF report | WeasyPrint or ReportLab; one page per domain; trend charts via matplotlib; auto-generated every 10 sessions or on demand |
| Email delivery | Sends to sugato@purdue.edu via Sparky sendmail; subject "Muse++ Retrospective — [date range]" |
| Privacy | All data stays within Tailscale mesh; no external cloud; session JSONs encrypted (iOS Data Protection API, NSFileProtectionComplete) before transit |

**Exit criterion:** end-to-end pipeline produces PDF for 10 synthetic sessions; email delivered to correct address.

---

### Build 65 — HEP Averaging

> **T1-#4 REOPENED as GO-WITH-CAVEATS.** 8 channels + 14-bit ADC + 20-bit Optics R-detection makes HEP feasible. Previously weak verdict on 4-channel Muse S.

**References:** Park & Tallon-Baudry 2014; Schandry 1981 heartbeat perception.

| Component | Detail |
|---|---|
| R-peak detection | PPG-derived R-peaks from 20-bit Optics; jitter tolerance ±15 ms (tighter than old Muse S PPG) |
| Epoching | −300 to +600 ms around R-peak; baseline correction −100 to 0 ms pre-R |
| Averaging | Minimum 60 artifact-free epochs per session; ICA-based artifact rejection on 8 channels (precomputed ICA model) |
| HEP index | Mean amplitude 200–400 ms post-R over frontal channels (Fz equivalent); reported in post-session summary |
| Research-mode toggle | HEP panel shown only when developer toggle enabled; not surfaced in standard UI |
| Interoception bridge | HEP index correlated with self-rating accuracy across sessions; surfaced in Sparky retrospective report |

**Exit criterion:** HEP visible (>0.5 µV mean deflection in expected window) on synthetic R-locked epoching of 8-channel test data; baseline correction removes pre-R drift correctly.

---

### Build 66 (R&D Stretch) — Phase-Locked Entrainment via Wired USB-C Only

> **T2-#7 REOPENED as GO-WITH-CAVEATS for wired path only.** BLE 5.3 jitter (±20–50 ms) still kills BLE-connected mode. USB-C wired path achieves sub-5 ms hardware latency, making theta-band phase prediction feasible.

**Algorithm:** PHASTIMATE (Wischnewski 2024) — predictive phase tracking via adaptive autoregressive model; no Hilbert transform (non-causal); causal real-time phase estimate updated per sample.

| Component | Detail |
|---|---|
| Wired-only gate | Feature activates only when USB-C session confirmed (USB-C session flag in SessionRecorder); silently disabled over BLE |
| PHASTIMATE pipeline | 8-channel EEG → bandpass 4–8 Hz → PHASTIMATE AR phase estimate → target phase trigger |
|Audio/haptic trigger | Haptic pulse or brief audio chime at target phase (θ peak or θ trough, configurable) |
| Phase-locking accuracy | Log actual phase at trigger delivery; mean circular error reported in session JSON |
| Safety gate | Disabled automatically if jhana classifier reports cessation-adjacent state (phase entrainment contraindicated) |
| R&D toggle | Ships behind explicit "Research Features" toggle; not visible in default settings |

**Exit criterion:** PHASTIMATE phase estimate latency < 10 ms on Sparky benchmark; wired-path gate correctly suppresses feature when BLE flag is set.

---

## REOPENED AUDIT VERDICTS — ATHENA vs MUSE S 2019

| # | Feature | Old Verdict (Muse S 2019) | New Verdict (Athena) | Basis |
|---|---|---|---|---|
| T1-#1 | EEG microstates | SKIPPED — insufficient channels | **GO** | 8 channels → canonical AAHC; Pascual-Marqui 2002 feasible |
| T1-#4 | HEP averaging | WEAK — 4 ch + noisy PPG | **GO-WITH-CAVEATS** | 8 ch + 14-bit + 20-bit Optics R-detection; research-mode toggle |
| T2-#6 | RL bandit (adaptive audio) | GO-WITH-CAVEATS | **SUPERSEDED** | Offline CQL (Kumar 2020) replaces online bandit; safer convergence |
| T2-#7 | Hilbert phase-lock | NO-GO — BLE jitter killed | **GO-WITH-CAVEATS (wired only)** | USB-C path sub-5 ms; PHASTIMATE causal; BLE still NO-GO |
| T2-#8 | Drowsy classifier | GO-WITH-CAVEATS | **SUPERSEDED** | Jhana MDM classifier (build 58) covers drowsy as 5th class |
| T2-#9 | Vagal HRV coherence | GO-WITH-CAVEATS — 64 Hz PPG precision | **GO** | 20-bit Optics PPG eliminates R-R precision concern |

---

## DEPENDENCIES

```
55a ──► 55b ──► 56 ──► 57 ──► 58 ──► 59
 │                              │
 │         (parallelizable)     └──► 60 ──► 61
 │                                           │
 └──────────────────────────────────────────►62 ──► 63 ──► 64
                                                           │
                                                          65
                                                           │
                                                     66 (R&D, wired)
```

**Parallelism opportunities:**
- 55b can begin immediately after 55a verification passes (fNIRS pipeline independent of EEG spectral pipeline)
- 56 and 57 share IRASA output from 55a; can be developed in parallel by separate dev branches
- 60 is independent of 56/57/58/59; can start after 55b (needs Optics PPG only)
- 61 requires session history (N ≥ 30); can be developed concurrently with 62/63 against synthetic session logs
- 65 (HEP) development can start alongside 63; only needs R-peak detection from 55b

---

## EXPLICITLY OUT OF SCOPE

To prevent scope creep. These are closed, not deferred.

| Item | Reason |
|---|---|
| Pillar 1 entry training (builds 56–59 in old plan) | User has decades of experience. Entry training is unnecessary. |
| Apple Watch | Engagement driver, not contemplative instrument. Conflicts with Rule 1 (no grasping). |
| Streaks / gamification | Direct conflict with Rule 1. |
| Multi-user / social / commercial features | Personal instrument. Non-commercial. |
| Cloud-required features (external SaaS) | Privacy posture: local + Tailscale mesh only. No external telemetry. |
| Guided audio courses | User instructs themselves. App provides biofeedback, not instruction. |
| Drowsy classifier as standalone feature | Folded into jhana MDM classifier (build 58) as 5th class. |
| Music control expansion beyond Spotify | Not a priority. |

---

## VALIDATION STRATEGY

### Phase 1 (Builds 55a–58): N=1 Self-Experiment

- Detailed session logging; journal entries cross-referenced with session JSONs
- No external participants; personal baseline establishment
- Key questions: microstate stability across sessions; IRASA slope variance; jhana label accumulation rate
- Exit gate: N ≥ 20 labeled sessions for MDM training; r(self-rating, EEG depth) > 0.3 (early interoception signal)

### Phase 2 (Build 60 onward): N=5 Friend Pilot

- Structured invitation to 5 experienced meditators (not beginners)
- Structured interview: perceived accuracy of drift detector, cessation flag precision, audio recommendations
- Paper consent form; GDPR-style data handling statement (session data stays on their device; no upload without explicit action)
- No IRB required: non-commercial personal use research; pilot is optional validation, not clinical trial
- Collect: self-rating accuracy, drop-out rate, qualitative feedback on haptic intrusiveness

### GitHub Public Release (post-stabilization)

- Consider open-sourcing once Sparky pipeline + safety docs are stable
- Ship with `SAFETY.md` covering Lindahl 2017 / Britton 2019 adverse-effect guidance
- Clinical safety docs precondition for any public release

---

## SAFETY SCREENING

### First-Launch Intake (mandatory, one-time)

At first launch, before any session, app presents a brief screening questionnaire:

- Active depersonalization or derealization symptoms? (clinically relevant question)
- Any personal or family history of psychosis or dissociative disorder?
- Prescribed medication change (especially SSRIs, antipsychotics) within the past 90 days?
- History of significant trauma with meditation-related adverse reactions?

**If any "yes":** opt-out flow with message referencing professional resources; app does not proceed to headband pairing.  
**References:** Lindahl 2017 (phenomenology of meditation-related adverse effects); Britton 2019 (adverse effects in mindfulness); Van Dam 2018 (perspective on clinical safety).

### Crash-Out Detection (ongoing)

Even for a decades-practitioner:

- **Trigger:** 3 consecutive sessions with anomalous depth pattern (BOCPD flags excessive change-points AND HRV coherence below session 5th percentile AND flat fNIRS HbO relative to baseline)
- **Response:** surface aggregate 30-session trend (not today's session data); suggest no-headband micro-sit break; optionally display therapist resource link (practitioner can dismiss permanently after first display)
- **Never:** interrupt a session; never show streak-broken language; never frame as failure

---

## PRIVACY POSTURE

| Layer | Policy |
|---|---|
| Default storage | Device-local only; no background sync |
| Session encryption | iOS Data Protection API (NSFileProtectionComplete); encrypted at rest |
| Tailscale fleet sync | Optional; user-initiated only; Sparky (100.120.218.19) within private mesh |
| External cloud | Never; zero telemetry |
| Share | User-initiated ShareLink only; no automatic upload |
| Analytics | No third-party analytics SDK (no Mixpanel, Amplitude, Firebase Analytics) |
| Crash reporting | Optional; if enabled, crash reports stripped of session content before upload |

---

## DISCOURAGEMENT-RECOVERY FLOW

Detect → surface trend → suggest alternative → get out of the way.

**Trigger:** 3 consecutive low-engagement sessions (session duration < 10 min AND self-rating ≤ 2 if available) OR BOCPD detecting chronic flat trajectory across 7+ days.

**Response:**
1. Surface aggregate trend chart (30-session rolling) — not today's session in isolation
2. Suggest no-headband micro-sit (60 seconds, anywhere, no feedback)
3. Optionally suggest a longer break without framing it as failure

**Never:**
- Show streak-broken language
- Frame short sessions as regression
- Pop up during a session

---

## ACCESSIBILITY

- **Color-blind safe palette** throughout all visualizations (Okabe-Ito 8-color palette)
- **Haptic equivalents** for all audio chimes (VoiceOver users receive haptic-only cues)
- **VoiceOver labels** on all interactive elements and data displays
- **Dynamic Type** support across all text; no fixed-size labels
- **Reduce Motion** respected; all animated transitions replaced with crossfades when enabled

---

## OPEN QUESTIONS (revisit after device validation sessions)

1. **Athena BLE 5.3 actual 95th-percentile jitter?** Determines whether wired-vs-BLE gate for T2-#7 can be relaxed for lower-frequency targets (delta-band entrainment at 2 Hz is more jitter-tolerant).
2. **Optics-derived PPG R-R precision in practice?** Validate against chest-strap reference (Polar H10 or equivalent) across 10 sessions before HEP and HRV pipelines are finalized.
3. **8-channel microstate template stability across sessions?** GEV explained variance as a function of session count; determines how many sessions before template is considered stable for cross-session comparison.
4. **Jhana MDM classifier convergence rate for an experienced practitioner?** Expected: faster label accumulation rate and lower within-class variance vs novice (literature suggests experienced practitioners produce more stereotyped EEG signatures). Empirical N to track.
5. **fNIRS signal quality in standard Athena headband fit?** Frontal optics contact pressure varies with scalp anatomy; validate coupling quality metric from `ATHENA_SPECS.md` before relying on HbO signal.
6. **CQL policy stability at N=30?** Conservative Q-Learning requires sufficient coverage of action space; 30 sessions may be insufficient if practitioner uses narrow audio preferences. Monitor Q-value spread.

---

## REFERENCES

- Lutz A, Slagter HA, Dunne JD, Davidson RJ. 2008. Attention regulation and monitoring in meditation. *Trends Cogn Sci* 12:163–169.
- Britton WB. 2019. Can mindfulness be too much of a good thing? The value of a middle way. *Curr Opin Psychol* 28:159–165.
- Brewer JA, et al. 2011. Meditation experience is associated with differences in default mode network activity and connectivity. *PNAS* 108:20254–20259.
- Donoghue T, et al. 2020. Parameterizing neural power spectra into periodic and aperiodic components. *Nat Neurosci* 23:1655–1665.
- Klimesch W. 1999. EEG alpha and theta oscillations reflect cognitive and memory performance: a review and analysis. *Brain Res Rev* 29:169–195.
- Mierau A, Klimesch W, Lefebvre J. 2017. State-dependent alpha peak frequency shifts: implications for dynamic brain analyses. *Neuroscience* 360:146–154.
- Tort ABL, et al. 2010. Measuring phase-amplitude coupling between neuronal oscillations of different frequencies. *J Neurophysiol* 104:1195–1210.
- Pascual-Marqui RD, et al. 2002. Functional imaging with low-resolution brain electromagnetic tomography (LORETA): a review. *Methods Find Exp Clin Pharmacol* 24(Suppl C):91–95. [microstate algorithm reference]
- Faber PL, et al. 2017. EEG microstates in meditation: a replication and extension. [meditation-specific microstate signatures]
- Adams RP, MacKay DJC. 2007. Bayesian online changepoint detection. *arXiv:0710.3742*.
- Barachant A, et al. 2014. Classification of covariance matrices using a Riemannian-based kernel for BCI applications. *Neurocomputing* 112:172–178.
- Wen H, Liu Z. 2016. Separating fractal and oscillatory components in the power spectrum of neurophysiological signal. *Brain Topogr* 29:13–26. [IRASA]
- Kumar A, et al. 2020. Conservative Q-Learning for offline reinforcement learning. *NeurIPS* 33:1179–1191.
- Davis PH, et al. 2024. Neural correlates of cessation in advanced meditators. [cessation signatures — cite full ref when published]
- Yang CM, et al. 2024. Electrophysiological signatures of meditation-induced cessation. *PNAS* [verify full citation on publication].
- Lindahl JR, et al. 2017. The varieties of contemplative experience: a mixed-methods study of meditation-related challenges in Western Buddhists. *PLOS ONE* 12:e0176239.
- Van Dam NT, et al. 2018. Mind the hype: a critical evaluation and prescriptive agenda for research on mindfulness and meditation. *Perspect Psychol Sci* 13:36–61.
- Acharya UR, et al. 2016. Heart rate variability: a review. *Med Biol Eng Comput* — [use Acharya 2006 full HRV review; verify exact citation].
- Charlton PH, et al. 2018. Breathing rate estimation from the electrocardiogram and photoplethysmogram: a review. *IEEE Rev Biomed Eng* 11:2–20.
- Wischnewski M, et al. 2024. PHASTIMATE: Real-time phase estimation for neurostimulation and neurofeedback. *bioRxiv* [verify final journal on publication].
- Schandry R. 1981. Heart beat perception and emotional experience. *Psychophysiology* 18:483–488.
- Park HD, Tallon-Baudry C. 2014. The neural subjective frame: from bodily signals to perceptual consciousness. *Phil Trans R Soc B* 369:20130208.
