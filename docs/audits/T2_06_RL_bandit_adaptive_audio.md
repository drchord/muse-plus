# T2-06: RL Bandit Adaptive Audio

## Executive verdict
**SUPERSEDED** — For a single-user personal-use deployment with accumulated session history, offline policy learning (Conservative Q-Learning, Kumar et al. 2020) on the full state-action-reward dataset outperforms online contextual bandit once N ≥ 30 sessions. Recommend CQL offline RL over Thompson bandit. Online bandit infrastructure (population prior bake-in, per-build prior refresh) is unnecessary and adds deployment complexity without benefit for a solo meditator accumulating a private session corpus.

> **Athena impact:** No hardware change to verdict — reward signal is still DepthGate `inDeep` duration. Athena's 8-channel EEG does provide richer state context (bilateral theta, frontal asymmetry, temporal sites TP9/TP10) that can be added as state features for CQL without altering the reward or action space.

## What it claims to do
A contextual bandit (LinUCB or Thompson sampling) continuously tunes three audio dimensions — binaural beat frequency tier, soundscape category, and output intensity — to maximize the cumulative time a user spends in the `inDeep` state during a session. Over multiple sessions the bandit learns a per-user preference surface, replacing the current static audio defaults with an adaptive system that self-optimizes toward deeper meditation.

## Why CQL supersedes online bandit (for this user, this use case)

**Online bandit problem:** contextual bandit optimizes in an environment where the policy is continuously updated as data arrives. For a single experienced meditator collecting 1 session/day, the online update adds complexity (population prior seeding, prior flush on backgrounding, cold-start management across builds) with minimal marginal benefit vs. a batch update trained offline every 30 sessions.

**CQL advantage (Kumar et al. 2020):** Conservative Q-Learning trains a policy on a logged dataset of (state, action, reward) tuples — exactly what accumulated session logs provide. CQL adds a conservative penalty that prevents the learned policy from exploiting out-of-distribution (state, action) combinations that were never tried. For a sparse-reward single-user corpus this is critical: standard offline Q-learning would overfit to a handful of high-reward sessions.

**Practical workflow:** After 30 sessions, export the session log as a (state, action, reward) table → train CQL offline on Sparky or Aurora (RTX 3090) → embed the policy as a CoreML model → ship in next build. Retrain every 30-50 sessions as corpus grows.

## Neuroscience basis

- **Huang & Charyton 2008** (*Alternative Therapies in Health and Medicine*) — systematic review establishing that binaural beats in theta (4–7 Hz) and alpha (8–12 Hz) ranges reliably shift EEG power in corresponding bands in resting participants. Direct support for the claim that frequency tier selection affects meditation depth.
- **Brewer et al. 2011** (*PNAS*) — experienced meditators show increased posterior cingulate deactivation and correlated self-report of "effortless awareness"; confirms that sustained `inDeep` dwell time is a valid behavioral correlate of meditative quality, not an artifact. Extra weight here: user is a decades-experienced meditator — Brewer's expert cohort is directly applicable.
- **Lutz et al. 2004** (*PNAS*) — long-range gamma synchrony in experienced meditators, distinguishing novice vs. expert response profiles. Supports individualized rather than population-averaged audio targets.
- **Sutton & Barto 2018** (*Reinforcement Learning: An Introduction*, MIT Press, 2nd ed.) — bandit and RL foundations.
- **Kumar et al. 2020** (*NeurIPS*) — "Conservative Q-Learning for Offline Reinforcement Learning." CQL adds a simple regularizer to standard Q-learning that lower-bounds the soft Bellman error on in-distribution actions while penalizing out-of-distribution actions. Achieves near-SOTA offline RL on D4RL benchmarks. Key property: no online interaction required — trains entirely on logged (s, a, r, s') tuples. This is the algorithm to implement.

## Muse S / Athena signal validity
Reward signal: DepthGate `inDeep` duration — unaffected by hardware change (already abstracted). State features available with Athena upgrade:
- Session number, time-in-session, prior `inDeep` fraction (existing)
- 8-channel band powers (new on Athena): bilateral theta (TP9, AF7, AF8, TP10), temporal alpha, frontal asymmetry
- Optics HbO level at session start (new): prefrontal hemodynamic baseline as state context
Action space: binaural tier × soundscape × intensity (unchanged, 36 arms or continuous).

## Implementation cost (revised)

- **Files to create:** `MusePlus/Audio/CQLPolicy.swift` (~200 LOC, CoreML inference wrapper), `model_training/cql_audio.py` (~400 LOC Python: D4RL-style dataset construction + CQL training via d3rlpy library), `MusePlus/Persistence/SessionLogExporter.swift` (~120 LOC, exports session log as JSON/CSV for offline training)
- **Files to modify:** `MusePlus/Audio/AudioEngine.swift` (inject CQL policy arm selection at session start, ~30 LOC), `MusePlus/Session/DepthGateStateMachine.swift` (emit full state-action-reward tuple to session log on `inDeep` exit, ~20 LOC)
- **LOC estimate:** ~350 LOC Swift new, 50 LOC modified. Python training script ~400 LOC. **Total: 2 build cycles** (no online infrastructure, no population prior management).
- **Build cost reduced from 4 → 2 cycles** because online infrastructure (prior persistence, per-build prior refresh, cold-start mitigation) is eliminated.
- **Computational cost:** CQL training on Aurora (RTX 3090): < 10 min for 30-session corpus. CoreML inference < 1 ms. Battery: zero marginal.

## Killer experiment (revised)

**Test:** Collect 30 sessions of full state-action-reward data (binaural tier, soundscape, volume chosen; `inDeep` duration as reward; EEG band powers at session start as state). Train CQL offline. Compare policy's top-ranked (soundscape, binaural, volume) tuples to the user's actual choices that produced the highest `inDeep` durations. Pearson r between CQL-ranked reward predictions and observed rewards on a held-out 10-session test set.

**Pass threshold:** Pearson r > 0.6. If < 0.6, the state features are insufficient to predict reward — consider adding more Athena-derived state context (fNIRS HbO baseline, time-of-day, prior session count).

**Input:** Session logs from 30 real meditation sessions (no simulation needed — logging is already instrumented via the analytics pipeline).

**Computation:** ~400 LOC Python with d3rlpy; run on Aurora in < 10 minutes.

## Build estimate if GO
- Build 55: SessionLogExporter.swift + data collection mode + unit tests (1 session)
- Build 57: CQL training script (Python/d3rlpy on Aurora) + CoreML export + CQLPolicy.swift integration (1 session)

**Total: 2 build cycles.** Depends on 30 accumulated sessions (elapsed time, not build sessions).

## Recommendation
Collect 30 sessions of instrumented data first (SessionLogExporter in Build 55), then train CQL offline and ship the policy in Build 57. Superior to online bandit for solo experienced meditator use case. No population prior needed. No cold-start problem (policy is retrained on actual user data).
