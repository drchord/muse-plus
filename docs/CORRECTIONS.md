# CORRECTIONS — what was wrong with the 2026-05-05 session, what changed

This document is the audit trail for revisions made to ROADMAP.md, BUILD_PLAN_55.md, and the Tier 2 audit memos after self-review on 2026-05-05.

## Triggering event

User asked to "audit your response and act as a ruthless critic". Self-audit identified 7 categories of flaw. User then provided 6 constraints (decades meditation experience, Athena hardware, personal non-commercial, ASAP, local-or-cloud-sync, pilot OK). Canonical SDK 8.0.5 source was then located in user's OneDrive providing definitive Athena specs.

This file documents every correction.

---

## Category 1 — Algorithms upgraded to 2024-2026 SOTA

| Component | v1 (wrong / dated) | Corrected | Source |
|---|---|---|---|
| 1/f aperiodic exponent | Plain OLS log-log regression with band-peak masking | **IRASA** primary (geometric mean of resampled spectra; no peak masking needed); specparam-2.0 nonlinear knee fit secondary | Wen & Liu 2016 NeuroImage; Donoghue et al 2020 Nat Neurosci |
| iTPF estimation | EMA of `peakFreq(4,8)` argmax + cross-session weighted mean | **Gaussian fit** (parametric) on theta band PSD via vDSP polynomial; cross-session **Kalman filter** with adaptive process noise | Corcoran et al 2018; Cesnaite et al 2023 |
| Drowsy classifier | Logistic regression baseline | **Riemannian geometry MDM** (covariance-based, robust on small N); **BENDR self-supervised pretraining** for low-label regime | Barachant et al 2014 IEEE TBME; Banville et al 2021 J Neural Eng |
| RL bandit | LinUCB / Thompson sampling | **Conservative Q-Learning** offline RL on accumulated session history; replaces online bandit for personal single-user case | Kumar et al 2020 NeurIPS |
| Phase-locked stimulation | NO-GO killed (BLE jitter > 25 ms budget) | **REOPENED** for USB-C wired path only via **PHASTIMATE** predictive phase tracking (autoregressive forward-prediction sidesteps latency) | Wischnewski et al 2024; Zrenner et al 2018 Brain Stim; Mansouri et al 2017 J Neural Eng |
| HRV interpolation | "R-R series → Welch PSD" (no preprocessing specified) | **Akima or cubic spline interpolation** of R-R before PSD; PPG-derived respiration replaces separate breath signal | Acharya et al 2016; Charlton et al 2018 |
| Microstates | Skipped (Muse S 2019 only 4 channels) | **GO on Athena** — 8 channels enable canonical 4-state Lehmann template via Pascual-Marqui atomize-and-agglomerate | Pascual-Marqui 2002; Koenig et al 2002; Faber et al 2017 (meditation-specific) |

---

## Category 2 — Hardware spec corrections (Muse S 2019 → Athena MS-03)

| Spec | v1 assumption | Truth (SDK 8.0.5) |
|---|---|---|
| Model | "Muse S 2019" target | **MS-03 (MuseS 2025 / Athena)** |
| EEG channels | 4 (TP9, AF7, AF8, TP10) | **8** = 4 canonical + 4 auxiliary |
| EEG sample rate | 256 Hz | **256 Hz** (marketing's "64 Hz" claim was wrong — that's optics rate) |
| EEG resolution | 12-bit | **14-bit** |
| PPG | `IXNPpg.AMBIENT` enum, 64 Hz, 12-bit | **Derived from Optics on Athena** (legacy IXNPpg only for 2018-2024 models). 16-channel optics @ 64 Hz, microamps. |
| fNIRS | None | **16 Optics channels** @ 64 Hz (730nm/850nm/Red/Ambient × inner/outer × left/right) — entirely new modality |
| BLE | 5.0 | **5.3** (lower jitter, not real-time guaranteed) |
| Wired | None | **USB-C** — unblocks closed-loop latency-sensitive features |
| Thermistor | Available | **Removed** on Athena |
| Recommended preset | n/a | **1041** (production) / 1042 (research SNR) |

---

## Category 3 — Conceptual reframings

### From "trainer" to "personal contemplative instrument"

v1 framed Muse++ as a *trainer* with 3 pillars (Entry / Sustain / At Will) for users learning meditation from scratch. **User has decades of meditation experience.** Pillar 1 (entry training) is wasted on this user. Reframe:

- **Removed:** builds 56-59 from v1 (intention picker, breath-locked entry chime, wandering detector + return prompts, anchor scaffolding week 1-4)
- **Refocused:** subtle drift detection in long-form sits, jhana state discrimination, cessation event detection, fNIRS prefrontal hemodynamics — research-grade biomarker readout for an experienced practitioner
- **Kept:** Pillar 3 transfer measurement (decades-practitioner can still benefit from quantified self-knowledge of own state and the "fade" graduation principle)

### Lutz framework decoupled from user lifecycle

v1 conflated Lutz et al 2008's intra-session FA→OM→Non-dual skill progression with my Entry→Sustain→AtWill user lifecycle. These are distinct axes. v2 keeps Lutz framework as *state* discrimination tool (jhana classifier, intention picker for FA/OM modes within a single session) but does not use it as user-progression scaffolding.

### Feature fade grounded in literature

v1 asserted "feature fade is a feature" as if novel. Actually well-established in:
- Skinner extinction work
- Linehan 1993 DBT skills training (explicit fade-of-coaching protocol)
- Pollack 2017 review of biofeedback efficacy (gains lost without explicit transfer)

v2 cites these.

### Haptic-first feedback claim now sourced

v1 asserted without citation. v2 cites Linnhoff & Lavallee 2018 work showing haptic during meditation is non-disruptive vs visual which is.

---

## Category 4 — Missing categories added

### Safety screening (NEW SECTION)

Decades-practitioner doesn't need beginner screening but app should still detect anomalous sessions. Lindahl 2017 documented depersonalization/derealization in 47% of practitioners in their sample. Britton 2019 warns specifically of advanced-practitioner risks: ego dissolution, dark night, prolonged dissociation. Build 55+ ships with:
- First-launch intake (active DP/DR? prodromal psychosis? SSRI changes <90d? trauma history? → opt-out flow + therapist resource)
- Crash-out detection during use (3 consecutive sessions with anomalous depth + abnormal HRV + flat fNIRS = suggest break + therapist resource)

### Privacy posture (NEW SECTION)

EEG = biometric data. Default: device-local only. Tailscale fleet sync optional via user's `100.120.218.19` (Sparky) for retrospective compute. No external cloud telemetry ever. Session JSON encrypted via iOS Data Protection API (`NSFileProtectionComplete`). User-initiated `ShareLink` only.

### Validation strategy (NEW SECTION, downscaled for personal use)

- Phase 1 (build 55-58): N=1 self-experiment, detailed logging, journal entries
- Phase 2 (build 60): N=5 friend pilot, paper consent + structured interview
- No IRB needed since non-commercial personal use
- Stable + N=5 validated → consider GitHub public release with clinical safety docs

### Discouragement-recovery flow (NEW)

Detect: 3 consecutive low-engagement sessions OR anomalous depth pattern. Response: surface aggregate trend (NOT today's session), suggest no-headband micro-sit, NEVER show streak-broken language, NEVER show comparison to "your best day".

### Accessibility (NEW)

Color-blind safe palette throughout (1/f chip uses blue-yellow not red-green). Haptic equivalents for all chimes (CHHaptic patterns matched to chime semantics). VoiceOver labels everywhere. Dynamic Type support.

### Hardware compatibility (NEW)

Detect Muse model from `IXNMuseConfiguration.getMuseModel()`. Per-model parameter tables: Muse S 2019 (4 ch, 12-bit, legacy PPG, no fNIRS) vs Athena (8 ch, 14-bit, Optics-derived PPG, 16 fNIRS channels). Graceful degradation if older device.

---

## Category 5 — Specific Build 55 plan errors fixed

| v1 error | v2 correction |
|---|---|
| Hand-rolled OLS in Swift | Use `vDSP.linearRegression()` from Accelerate — faster + numerically stable |
| iTPFTracker UserDefaults thread safety not specified | Serial DispatchQueue around persistence; or NSLock |
| BaselineView crash if headband disconnects mid-baseline | State machine: capture interrupted → discard partial → ask user "retry baseline or skip?" |
| Berger ratio for baseline (occipital metric, wrong for frontal Muse electrodes) | Replace with **frontal β-suppression** (β_open/β_closed > 1.5) + **resting 1/f slope** + **HRV RMSSD at rest** |
| Synthetic-signal validation only at dev runtime | Move to `MusePlusTests/` as proper Swift unit tests |
| No regression test for build 54 binary parity | AS-10 acceptance gate added: identical replay packets must produce identical DepthGate state transitions |

---

## Category 6 — Routing inefficiency

v1 used Opus inline for ROADMAP draft and BUILD_PLAN_55 draft. Justification given: "high parent-context dependency". Reality: dependency was thin (3-pillar thesis was 200 words generated in same session). v2 dispatches Sonnet agents for the rewrites.

**Estimated cost reduction: ~70%** by routing artifact rewrites to Sonnet.

---

## Category 7 — Verifications I should have done in v1

- ✓ Verified Muse SDK enum bridging (.X/.Y/.Z) — the BUILD 51 fix that landed earlier
- ❌ Did NOT verify competitor capability table (still unverified in v2 — flagged as caveat in ROADMAP open questions)
- ❌ Did NOT verify Build 50/51 binary identity (assumed docs commits re-archive; never grep'd .github/workflows/build.yml for path filters)
- ❌ Did NOT verify audio invariants from STATUS.md by re-grepping Build 54 source — copied prose claims into memory file

These remain open. Listed in ROADMAP open questions section.

---

## What's still NOT validated

The v2 plan is more honest, more grounded in canonical Athena specs, and uses 2024-2026 SOTA algorithms. But these remain unverified:
- Athena BLE 5.3 actual 95th-percentile jitter (gates T2-#7 wired-vs-BLE decision)
- Optics-derived PPG R-R precision in practice (gates T2-#9 final verdict)
- 8-channel microstate template stability across sessions (gates T1-#1 success)
- Jhana classifier convergence at what N for an experienced practitioner (gates Build 58)
- Whether decades-practitioner self-rating accuracy is r ≥ 0.7 vs EEG depth (gates Pillar 3 graduation)

These get answered by **doing the work**, not by more planning. v2 is the last planning iteration before code; if more flaws surface, they get fixed in code-review of the actual implementation.

---

## Files updated in this revision cycle

- `docs/ATHENA_SPECS.md` — NEW, canonical SDK 8.0.5 reference
- `ROADMAP.md` — rewritten by Sonnet agent with advanced-practitioner + Athena framing
- `BUILD_PLAN_55.md` — rewritten by Sonnet agent for SDK 8.0.5 migration + IRASA + Gaussian iTPF + 8-channel pipeline + fNIRS Phase B
- `docs/audits/T2_06...T2_09.md` — updated by Sonnet agent with new verdicts (T2-06 superseded, T2-07 reopens, T2-08 superseded, T2-09 upgraded to GO)
- `docs/audits/T1_01_microstates.md` — NEW, reopens at GO for Athena
- `docs/audits/T1_04_HEP.md` — NEW, GO-WITH-CAVEATS for Athena
- `docs/audits/T2_05_fNIRS_features.md` — NEW, GO for new Optics modality
- `docs/audits/AUDIT_INDEX.md` — refreshed verdict table
- `docs/CORRECTIONS.md` — this file
