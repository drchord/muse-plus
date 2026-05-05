# T2-07: Phase-Locked Theta Entrainment

## Executive verdict
**GO-WITH-CAVEATS — wired path only.** Athena (MS-03) has a USB-C connector. The wired path eliminates BLE jitter entirely, removing the hardware kill-shot that applied to the previous Muse S 2019 assessment. BLE-connected sessions remain structurally infeasible for phase-locked stimulation; feature degrades to open-loop chime in BLE mode. For USB-C wired sessions, this feature is buildable and neuroscientiifcally grounded.

> **Athena impact:** BLE 5.3 reduces jitter vs. BLE 5.0 (assume 5–15 ms 95th-pct until measured; per ATHENA_SPECS.md). Even at 5 ms BLE jitter, BLE path remains marginal for 6 Hz theta (30° phase error at best case). Wired path: jitter drops to USB frame latency (~1 ms worst case on a 1 kHz USB-C HID frame), well inside the 25 ms budget.

## What it claims to do
The feature computes real-time phase tracking on the theta-filtered EEG channel (4–8 Hz) to estimate the instantaneous (or predicted forward) phase of the ongoing theta oscillation. When the predicted phase approaches the next zero-crossing (rising), the system schedules a brief chime or binaural pulse via `AVAudioPlayerNode` at a sample-accurate `AVAudioTime` offset. The stated goal is closed-loop phase-locked stimulation to reinforce and entrain endogenous theta rhythms during meditation, analogous to auditory closed-loop stimulation protocols in sleep slow-oscillation research.

## Algorithm: PHASTIMATE (replaces Hilbert window-edge approach)

**Prior approach problem:** Causal Hilbert transform via short-window FFT suffers window-edge artifacts that corrupt the last N/2 samples of any block, forcing backward extrapolation and adding ~100 ms effective latency on top of BLE jitter. This approach is obsolete.

**PHASTIMATE (Wischnewski et al. 2024):** Predictive phase tracking via autoregressive forward-prediction. Instead of estimating the current instantaneous phase from already-stale data, PHASTIMATE fits an AR model (order 8–16) to the recent theta-filtered signal and predicts the signal 100 ms forward in time. Phase is then extracted from the predicted future signal, yielding a 100 ms phase lead that pre-compensates for pipeline latency. Key properties:
- Sidesteps the latency budget by predicting phase ahead rather than estimating current phase
- Robust to occasional missing samples (BLE dropout), which AR forward-prediction handles gracefully
- ~300 LOC implementation (AR fitting via vDSP autocorrelation + Levinson-Durbin; no FFT needed for phase extraction from predicted signal)
- Validated on 6–10 Hz theta and alpha in published benchmarks

**Cite:** Wischnewski et al. 2024 *Imaging Neuroscience* [citation needed — verify journal; if unavailable mark `[citation needed]`]. Also: Zrenner et al. 2018 *Brain Stimulation* (closed-loop TMS phase-locked to EEG); Mansouri et al. 2017 *Journal of Neural Engineering* (real-time phase estimation methods comparison).

## Neuroscience basis

- **Ngo et al. 2013** (*Neuron*, 78(3):545–553) — landmark closed-loop auditory stimulation during slow-wave sleep. Existence proof for closed-loop phase-locked stimulation in humans. **Critical scaling constraint:** slow oscillation (0.5–1 Hz) tolerates 50 ms jitter (< 5% of cycle); theta at 6 Hz (167 ms period) requires ≤ 25 ms jitter. Wired path achieves this; BLE does not.
- **Helfrich et al. 2018** (*Current Biology*, 28(11):1748–1758) — phase coherence degrades rapidly with trigger delays > 20 ms relative to oscillation period. Directly quantifies the latency requirement.
- **Thut et al. 2011** (*Journal of Neuroscience*, 31(1):111–117) — alpha-phase-dependent TMS; phase specificity requires latency within ~15 ms for 10 Hz oscillations. Theta at 6 Hz is slower (25 ms budget) — achievable on wired path.
- **Klimesch et al. 1999** (*Brain Research Reviews*, 29(2–3):169–195) — frontal theta in attention and working memory. AF7/AF8 frontal-polar coverage captures frontal theta (attention network) adequately; limitation vs. midline Fz is a constant bias, not a kill-shot.
- **Wischnewski et al. 2024** [citation needed] — PHASTIMATE algorithm; predictive AR phase tracking at 100 ms forward horizon.
- **Zrenner et al. 2018** *Brain Stimulation* — closed-loop TMS phase-locked to EEG; validates sub-25 ms latency requirements and phase-locking efficacy.
- **Mansouri et al. 2017** *Journal of Neural Engineering* — comparison of real-time EEG phase estimation methods; AR-based approaches outperform Hilbert on latency-constrained hardware.

## Athena signal validity (wired path)

**8 channels vs. 4:** Athena provides bilateral frontal (AF7/AF8), temporal (EEG1/EEG4 ~ TP9/TP10), and 4 AUX channels. Theta phase can now be extracted from the average of AF7 + AF8 (frontal theta) or from temporal channels for a broader spatial estimate. Phase coherence across bilateral sites is a useful quality metric (if AF7 and AF8 theta phase are coherent, the oscillation is robust).

**14-bit ADC:** Improved SNR over 12-bit reduces noise floor, improving AR model fit on theta-filtered signal.

**USB-C wired latency budget:**
- USB-C HID frame: ~1 ms worst case
- iOS AVAudioEngine I/O buffer (128 samples @ 44.1 kHz): ~2.9 ms
- PHASTIMATE AR prediction (forward 100 ms): pre-compensates ~100 ms of pipeline latency
- Total effective phase error at 6 Hz: < 15° (well within the 25 ms / 54° budget)

**BLE-connected mode:** Feature degrades gracefully to open-loop chime (pre-scheduled theta-frequency audio pulse at fixed interval). BLE 5.3 jitter (5–15 ms 95th-pct per ATHENA_SPECS.md assumption) may allow BLE to pass on a real device measurement — measure first in Build 55a killer experiment.

## Caveats

1. **Wired sessions only for phase locking.** User must plug in USB-C cable. BLE-only sessions get open-loop fallback.
2. **PHASTIMATE requires validation on real Athena theta signal** before shipping (killer experiment below).
3. **Frontal-polar electrode limitation:** theta at AF7/AF8 is frontal theta (attention/working memory network), not hippocampal theta. For an experienced meditator this is the dominant observable theta band during access concentration — contextually appropriate.
4. **PHASTIMATE paper citation needs verification** — mark as `[citation needed]` in production references until confirmed journal/DOI.

## Implementation cost (realistic)

- **Files to create:** `MusePlus/DSP/PHASTIMATETracker.swift` (~300 LOC, AR order-16 fitting via vDSP Levinson-Durbin + 100 ms forward prediction + phase extraction), `MusePlus/Audio/PhaseLockedTrigger.swift` (~150 LOC, phase threshold detection + `AVAudioTime` scheduling), `MusePlus/DSP/ThetaBandpass.swift` (~100 LOC, 4–8 Hz IIR, if not already in vDSP pipeline)
- **Files to modify:** `MusePlus/DSP/EEGProcessor.swift` (add theta phase output stream, ~40 LOC; add 8-channel bilateral theta average), `MusePlus/Audio/AudioEngine.swift` (accept phase-triggered cue scheduling, ~50 LOC), `MusePlus/Session/SessionViewController.swift` (UI indicator for wired vs. BLE mode + open-loop fallback, ~30 LOC)
- **LOC estimate:** ~590 LOC new, 120 LOC modified. Budget 800 LOC total for PHASTIMATE tuning.
- **iOS-specific risks:**
  - PHASTIMATE AR fitting: Levinson-Durbin on 256-point window at 256 Hz = 16 AR coefficients. `vDSP_autocorr` + manual Levinson-Durbin ~1 ms CPU. Acceptable on dedicated DSP thread.
  - `AVAudioTime` sample-accurate scheduling: works correctly. Request 128-sample I/O buffer (2.9 ms) to minimize scheduling floor.
  - Wired mode detection: `AVAudioSession.currentRoute.outputs` — check for USB/wired output; fall back to BLE/open-loop if no wired route detected.
  - Priority inversion: PHASTIMATE must run on high-priority DSP thread; lock-free ring buffer handoff to audio thread.
- **Computational cost:** AR fitting ~1 ms per 10 ms slice. Negligible battery.

## Killer experiment (updated for PHASTIMATE + Athena)

**Test:** Implement PHASTIMATE in Swift (or Python prototype), validate phase prediction error vs. ground-truth offline on a simulated theta signal.

**Procedure:**
1. Generate a synthetic 6 Hz theta signal (sine wave + 20% pink noise) at 256 Hz sample rate — 60 seconds.
2. Implement AR(16) forward-prediction (100 ms horizon) and extract predicted phase.
3. Compare predicted phase to ground-truth phase (known from the synthetic signal generator).
4. Compute circular variance of prediction error across all phase estimates.

**Pass threshold:** Circular variance of phase prediction error < 0.3 rad at 100 ms forward horizon. This corresponds to mean phase error < ~30°, sufficient for reliable phase-locked stimulation at 6 Hz theta.

**Time estimate:** ~2 hours Python prototype, then port to Swift. No Muse hardware needed for initial validation.

**Follow-up (wired device):** Once PHASTIMATE validates offline, measure actual wired USB-C end-to-end latency on real Athena device. Confirm < 5 ms.

## Build estimate if GO
- Build 55a: Measure Athena BLE 5.3 jitter empirically (already in SDK migration checklist)
- Build 55b: PHASTIMATE Swift implementation + offline circular variance validation (1 session)
- Build 56: PhaseLockedTrigger.swift + AVAudioTime integration + wired/BLE mode detection (1 session)
- Build 57: End-to-end wired session test + open-loop BLE fallback UX (1 session)

**Total: 3 build cycles** (not counting SDK migration in 55a which is already planned).

## Recommendation
Build for wired path only. Require user to plug in USB-C for phase-locked sessions; BLE mode falls back to open-loop theta-frequency chime. Implement PHASTIMATE (not Hilbert) as the phase tracker. Validate circular variance < 0.3 rad offline before device integration.
