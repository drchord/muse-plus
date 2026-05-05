# T2-07: Phase-Locked Entrainment

## Executive verdict
NO-GO — the total trigger latency budget (BLE jitter 20–50 ms + iOS audio scheduling minimum 5–10 ms) structurally exceeds the ≤25 ms window required for effective theta phase entrainment; even in the best-case BLE delivery, Hilbert window-edge artifacts consume an additional 1–2 cycles, and there is no hardware path to fix BLE jitter without a wired/USB-C EEG.

## What it claims to do
The feature computes a real-time Hilbert transform on the theta-filtered EEG channel (4–8 Hz) to estimate the instantaneous phase of the ongoing theta oscillation. When the phase approaches the next zero-crossing (rising), the system schedules a brief chime or binaural pulse via `AVAudioPlayerNode` at a sample-accurate `AVAudioTime` offset. The stated goal is closed-loop phase-locked stimulation to reinforce and entrain endogenous theta rhythms during meditation, analogous to the auditory closed-loop stimulation protocols used in sleep slow-oscillation research.

## Neuroscience basis

- **Ngo et al. 2013** (*Neuron*, 78(3):545–553) — landmark closed-loop auditory stimulation study during slow-wave sleep. Tones delivered at the up-phase of slow oscillations (< 0.8 Hz) enhanced slow-oscillation amplitude and spindle activity. This is the primary existence proof for closed-loop phase-locked stimulation in humans. **Critical constraint from Ngo 2013:** the slow oscillation (0.5–1 Hz) has a half-period of 500–1000 ms, so a 50 ms trigger jitter is < 5% of the cycle — acceptable. Theta at 6 Hz has a period of ~167 ms; a 50 ms jitter is 30% of the cycle — phase targeting becomes near-random.
- **Helfrich et al. 2018** (*Current Biology*, 28(11):1748–1758) — closed-loop tACS phase-locking to endogenous alpha oscillations in visual cortex. Demonstrates that phase coherence degrades rapidly with trigger delays > 20 ms relative to oscillation period. Directly quantifies the latency kill-shot for fast oscillations.
- **Thut et al. 2011** (*Journal of Neuroscience*, 31(1):111–117) — alpha-phase-dependent TMS effects; establishes that phase specificity requires latency control within ~15 ms for 10 Hz oscillations. Theta at 6 Hz is slower but the same argument applies: jitter must be < ~12 ms for reliable phase targeting at a 6 Hz carrier.
- **Klimesch et al. 1999** (*Brain Research Reviews*, 29(2–3):169–195) — foundational review of theta and alpha in memory and attention. Relevant here as the mechanistic rationale for why theta entrainment during meditation would be beneficial — but also notes that theta in frontal electrodes is often mixed with mu and alpha, complicating phase isolation.

## Muse S signal validity

**Electrode geometry:** All published phase-locked stimulation studies use midline (Fz, Cz, Pz) or parietal/occipital electrodes. Muse S AF7/AF8 are frontal-polar. Theta detected at AF7/AF8 is predominantly frontal theta (prefrontal working memory / attention network) — not hippocampal theta. The phase of frontal theta is detectable but its relationship to the full theta network is weaker than midline coverage would provide.

**Sample rate:** 256 Hz → 3.9 ms per sample. In principle sufficient for 6 Hz theta (167 ms period). The Hilbert transform itself is sample-accurate.

**BLE jitter — the kill-shot:** Muse S transmits packets over BLE with ±20–50 ms jitter. The EEG timestamp attached to a packet reflects when the Muse *recorded* the sample, but the iOS app receives the packet 20–50 ms *after* the physiological event. This means the phase estimate is computed on data that is already 20–50 ms stale. Adding iOS AVAudioEngine scheduling latency (minimum 5–10 ms even with `AVAudioTime` sample-accurate scheduling, due to the hardware I/O buffer), the total pipeline latency is **25–60 ms**. For 6 Hz theta, this corresponds to 54°–130° of phase error — effectively random phase delivery at the high end.

**Hilbert window-edge artifacts:** A real-time Hilbert transform requires a causal approximation (e.g., analytic signal via short-window FFT or FIR analytic filter). Edge artifacts corrupt the last N/2 samples of any block-based Hilbert estimate, where N is the window length. For a 256-sample (1-second) window, the last ~128 ms of phase estimates are unreliable. This forces the system to use phase *prediction* (extrapolation from clean earlier samples) rather than current-sample phase, adding another 50–100 ms of effective latency. Total worst-case pipeline latency: ~160 ms = ~345° phase error at 6 Hz. This is indistinguishable from open-loop stimulation.

**Known degradation summary:**
- BLE jitter alone: ±30–160° phase error at theta (6 Hz)
- Edge-artifact forced prediction: +100 ms → +216° additional
- Audio I/O buffer: +5–10 ms → +11–22° additional
- Combined: effectively random phase delivery

## Implementation cost (realistic)

- **Files to create:** `MusePlus/DSP/HilbertFilter.swift` (~150 LOC, causal analytic signal via vDSP), `MusePlus/Audio/PhaseLockedTrigger.swift` (~200 LOC, phase prediction + `AVAudioTime` scheduling), `MusePlus/DSP/ThetaBandpass.swift` (~100 LOC, 4–8 Hz IIR, though theta BPF may already exist in the vDSP pipeline)
- **Files to modify:** `MusePlus/DSP/EEGProcessor.swift` (add theta phase output stream, ~40 LOC), `MusePlus/Audio/AudioEngine.swift` (accept phase-triggered cue scheduling, ~50 LOC)
- **LOC estimate:** 540 LOC new, 90 LOC modified. Phase prediction and BLE latency compensation logic will inflate this to ~800 LOC in practice.
- **iOS-specific risks:**
  - `AVAudioTime` sample-accurate scheduling works correctly in AVAudioEngine, but the hardware I/O buffer (default 256 samples at 44.1 kHz = 5.8 ms) sets a hard floor. Requesting 128-sample buffer via `AVAudioSession.setPreferredIOBufferDuration` reduces this to ~2.9 ms but increases CPU overhead and can cause dropouts on older devices.
  - BLE timestamp jitter cannot be compensated in software without a ground-truth reference — the Muse SDK does not expose a reliable hardware timestamp with sub-ms accuracy.
  - Real-time Hilbert on the audio thread risks priority inversion; must run on a dedicated high-priority DSP thread with lock-free ring buffer handoff to the audio thread.
- **Computational cost:** Causal Hilbert via 256-point vDSP FFT per 10 ms slice ≈ 0.2 ms CPU. Negligible. Memory < 5 KB. Battery: near zero marginal.

## Killer experiment (1 hour to run on Sparky / device)

**Test:** Measure actual end-to-end BLE→phase-estimate→audio-trigger latency on the real device.

**Procedure:**
1. On the Muse S, use a signal generator (or the Muse SDK test signal) to inject a known 6 Hz sine wave into the EEG stream.
2. In Build 54, log the iOS-side timestamp of each 256-Hz EEG sample packet arrival (`Date.timeIntervalSinceReferenceDate` when the Muse SDK delegate fires).
3. Compare arrival timestamps against the Muse SDK's embedded sample timestamps (if available) or against a BLE-connected reference clock.
4. Compute the distribution of arrival jitter over 5 minutes.

**Expected output:** A histogram of per-packet arrival latencies. Pass if median < 15 ms AND 95th percentile < 25 ms. Fail if 95th percentile > 25 ms (which all published Muse BLE characterization data predicts it will be).

**Pass threshold for GO:** 95th-percentile BLE delivery jitter < 25 ms. Prior published work (de Cheveigné & Nelken 2019, BioRxiv characterizations of consumer EEG) strongly predicts FAIL.

## Build estimate if GO (hypothetical)
- Build 55: Causal Hilbert filter + BLE latency logger (1 session)
- Build 56: Phase predictor with latency compensation model (2 sessions — prediction logic is subtle)
- Build 57: AVAudioTime-scheduled trigger integration + phase coherence verification (1 session)
- Build 58: Parametric jitter study, closed-loop validation against open-loop baseline (1–2 sessions)

**Total: 5–6 build cycles** — but this estimate is moot given the NO-GO verdict.

## Recommendation
Kill — BLE jitter is a hardware constraint with no software fix; revisit only if Muse ever ships a USB-C/wired mode or if Apple adds BLE isochronous audio with sub-10ms guaranteed delivery (IEEE 802.15.3 profile, not currently on iOS roadmap).
