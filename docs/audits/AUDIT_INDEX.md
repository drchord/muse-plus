# Muse++ T2 Feature Audit Index
**Date:** 2026-05-04  
**Build at time of audit:** Build 54 (TestFlight)  
**Auditor:** Claude Sonnet (T3)

---

## Summary Table

| # | Feature | Verdict | Killer Experiment | Build Cost | Recommendation |
|---|---------|---------|-------------------|------------|----------------|
| T2-06 | RL Bandit Adaptive Audio | GO-WITH-CAVEATS | Simulate 100 synthetic sessions: Thompson prior vs. uniform prior; pass = cold-start convergence < 30 sessions | 4 build cycles | Build now — use population prior to bypass cold-start |
| T2-07 | Phase-Locked Theta Entrainment | NO-GO | Measure real BLE packet arrival jitter over 5 min; pass = 95th-pct jitter < 25 ms (expected FAIL) | 5–6 cycles (moot) | Kill — BLE jitter structurally exceeds 25 ms latency budget for 6 Hz theta |
| T2-08 | Drowsy vs. Deep Classifier | GO-WITH-CAVEATS | Train logistic regression on Sleep-EDF Fpz-Cz @ 256 Hz resample; pass = AUROC > 0.78 on held-out subjects | 5 active sessions + 2–3 wks data collection | Pilot study first — run killer experiment, then collect 20+ labeled Muse S sessions before committing |
| T2-09 | Vagal Coherence HRV+EEG Fusion | GO-WITH-CAVEATS | Downsample PhysioNet PPG to 64 Hz, compute LF-HRV, compare to ECG ground truth; pass = Pearson r > 0.80 | 5 build cycles | Build now (after killer experiment) — breath pacer delivers standalone UX value; defer EEG fusion to follow-on build |

---

## Key Cross-Cutting Findings

**BLE jitter is the hardest constraint.** T2-07 is killed entirely by BLE ±20–50 ms jitter. Any future feature requiring closed-loop stimulation latency < 50 ms faces the same kill-shot until Apple ships isochronous BLE or Muse ships wired connectivity.

**5-minute minimum session for biometrics.** Both T2-08 (classifier stability) and T2-09 (LF-HRV window) require ≥ 5 minutes of clean signal. Sessions shorter than 5 minutes should disable or degrade gracefully these features in UI.

**DepthGate reward signal is already the right abstraction.** T2-06 correctly uses the existing DepthGate `inDeep` output as its reward; no raw EEG needed by the bandit. This insulates the feature from Muse S hardware limitations.

**Frontal-only coverage is a constant bias, not a variable.** All four features are affected equally. The Peniston-Kulkosky meditationIndex and the existing vDSP pipeline already incorporate this limitation. New features should treat frontal-only coverage as a design constraint, not a bug to work around.

**Build priority order (given verdicts):**
1. T2-06 (RL Bandit) — build now, low risk, 4 cycles
2. T2-09 (HRV+EEG) — build now after killer experiment, 5 cycles, breath pacer has standalone value
3. T2-08 (Drowsy Classifier) — pilot study first, then build; 2–3 week data gap
4. T2-07 (Phase Lock) — killed, do not build

---

## Files in This Audit

| File | Feature |
|------|---------|
| `T2_06_RL_bandit_adaptive_audio.md` | RL Bandit Adaptive Audio |
| `T2_07_phase_locked_entrainment.md` | Phase-Locked Theta Entrainment |
| `T2_08_drowsy_vs_deep_classifier.md` | Drowsy vs. Deep Classifier |
| `T2_09_vagal_coherence_HRV_EEG_fusion.md` | Vagal Coherence HRV+EEG Fusion |
