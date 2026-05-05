# Muse++ Feature Audit Index
**Date:** 2026-05-04 (revised)
**Build at time of audit:** Build 54 (TestFlight)
**Target hardware:** Muse S Athena (MS-03) — see [docs/ATHENA_SPECS.md](../ATHENA_SPECS.md) for canonical spec from SDK 8.0.5 headers
**User profile:** Decades-experienced meditator, personal non-commercial use, Tailscale fleet (Sparky 100.120.218.19 / Aurora 100.120.218.19 RTX 3090) for compute
**Algorithm standard:** State-of-the-art 2024–2026; 2018 baselines replaced throughout

---

## Summary Table

| # | Feature | Verdict | Verdict Change | Killer Experiment | Build Cost |
|---|---------|---------|----------------|-------------------|------------|
| T1-01 | EEG Microstates | **GO** | REOPENED (was NO-GO on 4-ch Muse S 2019) | 5-min rest: 4-template occupancy matches Koenig 2002 norms (A≈22%, B≈28%, C≈26%, D≈24%); Markov transitions present | 3 cycles |
| T1-04 | Heartbeat-Evoked Potential (HEP) | **GO-WITH-CAVEATS** | UPGRADED SNR (was weak-SNR GWCAV on 12-bit/4-ch) | 30-min eyes-closed: positive HEP peak ~250 ms, negative ~400 ms post-R, p<0.05 FDR-corrected across 200+ heartbeats | 2 cycles |
| T2-05 | fNIRS Prefrontal Features | **GO** | NEW MODALITY (Athena Optics only) | 5-min rest + 5-min mental arithmetic: task-rest HbO contrast d > 0.5 in ≥1 frontal region | ~1–2 marginal cycles (already in Build 55b plan) |
| T2-06 | RL Bandit Adaptive Audio | **SUPERSEDED** | was GO-WITH-CAVEATS (online bandit) | Collect 30 sessions → CQL offline → Pearson r > 0.6 vs. user's actual high-inDeep choices | 2 cycles (reduced from 4) |
| T2-07 | Phase-Locked Theta Entrainment | **GO-WITH-CAVEATS (wired only)** | REOPENED for wired path (was NO-GO BLE-only) | PHASTIMATE AR(16) phase prediction: circular variance < 0.3 rad at 100 ms forward horizon | 3 cycles |
| T2-08 | Drowsy vs. Deep Classifier | **SUPERSEDED** | SUBSUMED by Build 58 jhana classifier | MDM 8-ch pairwise distance ratio (between/within class) > 1.5 vs. 4-ch | 0 standalone (Build 58 jhana) |
| T2-09 | Vagal Coherence HRV+EEG Fusion | **GO** | UPGRADED from GO-WITH-CAVEATS | PhysioNet PPG→ECG LF-HRV Pearson r > 0.80; re-run on Athena Optics once available | 5 cycles |

---

## What Changed: Athena Hardware Impact on Each Verdict

Full Athena spec: [docs/ATHENA_SPECS.md](../ATHENA_SPECS.md)

| Feature | Key Athena Change | Verdict Impact |
|---------|------------------|----------------|
| **T1-01 Microstates** | 4 → 8 EEG channels (EEG1–4 + AUX1–4) | NO-GO → GO. Pascual-Marqui 2002 atomize-and-agglomerate requires ≥8 channels; exactly met. |
| **T1-04 HEP** | 12-bit → 14-bit ADC; Optics R-peak precision ~±5 ms (vs. ±15.6 ms) | Weak SNR → improved SNR. Timing jitter halved → sharper HEP peak averaging. Caveat remains: no Cz/Fz central coverage. |
| **T2-05 fNIRS** | Optics 730nm + 850nm × 16 channels at 64 Hz (entirely new modality) | Not-applicable → GO. Zero capability on Muse S 2019; full prefrontal fNIRS on Athena. |
| **T2-06 RL Bandit** | 8-channel EEG provides richer state features for CQL policy | No change to core verdict (already superseded by offline CQL logic); Athena adds richer state context for CQL training. |
| **T2-07 Phase Lock** | USB-C wired connector eliminates BLE jitter; BLE 5.3 reduces jitter (5–15 ms vs. 20–50 ms) | NO-GO → GO-WITH-CAVEATS (wired only). Wired path: USB frame latency ~1 ms; well inside 25 ms budget for 6 Hz theta. BLE path: still marginal. |
| **T2-08 Drowsy Classifier** | 8 channels → 8×8 covariance matrix improves Riemannian MDM separability | No change to superseded verdict; Athena makes the replacement (Build 58 jhana MDM classifier) more powerful. |
| **T2-09 Vagal Coherence** | Optics PPG replaces legacy IXNPpg; 850nm channel + parabolic interpolation → ±5 ms R-peak precision; PPG amplitude modulation enables respiration extraction (Charlton 2018) | GO-WITH-CAVEATS → GO. Sub-ms R-R precision resolves the 64 Hz precision caveat. Respiration extraction is a bonus. |

---

## Algorithm Updates (2018 baseline → 2024–2026 SOTA)

| Feature | Replaced | With |
|---------|---------|------|
| T2-06 | Thompson sampling online bandit | Conservative Q-Learning offline RL (Kumar et al. 2020 NeurIPS) |
| T2-07 | Causal Hilbert + window-edge artifact mitigation | PHASTIMATE (Wischnewski et al. 2024) — AR(16) predictive phase tracking, 100 ms forward prediction |
| T2-08 | Logistic regression on spectral features | Riemannian MDM (Barachant et al. 2014) on covariance matrices; BENDR self-supervised pretraining (Banville et al. 2021) if needed |
| T2-09 | Cubic spline R-R interpolation | Akima spline (Acharya et al. 2016 review recommendation); PPG-derived respiration (Charlton et al. 2018) added |

---

## Key Cross-Cutting Findings (revised)

**Wired path reopens closed-loop features.** T2-07 was killed by BLE jitter; USB-C wired sessions on Athena eliminate this constraint. Features requiring latency < 25 ms are buildable for wired sessions with graceful BLE fallback to open-loop.

**Offline RL > online bandit for single-user deployment.** T2-06: once N ≥ 30 sessions of logged (state, action, reward) data exist, CQL offline training on Aurora outperforms online Thompson sampling — no cold-start, no population prior refresh, no online infrastructure.

**8 channels unlocks microstates.** The 4→8 channel upgrade (T1-01) is the most categorical hardware-driven verdict change. Microstate analysis is the only T1 feature that was structurally impossible on 4 channels and is now fully viable.

**fNIRS is a new orthogonal modality.** T2-05 provides seconds-timescale hemodynamic depth tracking (HbO trajectory) that complements EEG's millisecond-timescale dynamics. HbO-EEG fusion for jhana classification (Build 58) is now feasible.

**5-minute minimum session unchanged.** T2-09 (LF-HRV) and T1-04 (HEP, 200+ heartbeats) both require ≥ 5 minutes clean signal. Sessions < 5 min disable or degrade these features gracefully.

**Build 58 is the convergence point.** Jhana classifier (Build 58) subsumes T2-08 (drowsy detection), consumes T1-01 microstate occupancy and T2-05 fNIRS HbO as features, and provides the richest per-state discrimination for an experienced meditator. T2-06 CQL policy uses jhana class as part of the reward state context.

---

## Build Priority Order (revised for Athena)

1. **Build 55a:** SDK 8.0.5 migration (prerequisite for all Athena features)
2. **Build 55b:** OpticsPipeline.swift (T2-05 fNIRS); PHASTIMATE offline validation (T2-07); SessionLogExporter (T2-06 data collection start)
3. **Build 56:** OpticsRRDetector + HRVAnalyzer (T2-09); MicrostateAnalyzer (T1-01)
4. **Build 57:** HEPProcessor (T1-04, shared R-peak stream with T2-09); PhaseLockedTrigger wired path (T2-07)
5. **Build 58:** JhanaClassifier with Riemannian MDM + HbO auxiliary input (subsumes T2-08); CQL policy training on accumulated sessions (T2-06)
6. **Build 59:** VagalCoherenceScore fusion + BreathPacer (T2-09 completion); fNIRS session summary UI

---

## Files in This Audit

| File | Feature | Verdict |
|------|---------|---------|
| `T1_01_microstates.md` | EEG Microstates | GO |
| `T1_04_HEP.md` | Heartbeat-Evoked Potential | GO-WITH-CAVEATS |
| `T2_05_fNIRS_features.md` | fNIRS Prefrontal Features | GO |
| `T2_06_RL_bandit_adaptive_audio.md` | RL Bandit / CQL Adaptive Audio | SUPERSEDED → CQL |
| `T2_07_phase_locked_entrainment.md` | Phase-Locked Theta Entrainment | GO-WITH-CAVEATS (wired) |
| `T2_08_drowsy_vs_deep_classifier.md` | Drowsy vs. Deep Classifier | SUPERSEDED → Build 58 jhana |
| `T2_09_vagal_coherence_HRV_EEG_fusion.md` | Vagal Coherence HRV+EEG Fusion | GO |
