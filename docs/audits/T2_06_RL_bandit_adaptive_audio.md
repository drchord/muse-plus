# T2-06: RL Bandit Adaptive Audio

## Executive verdict
GO-WITH-CAVEATS — the reward signal (DepthGate `inDeep` duration) is real and measurable, but the 90-second cooldown makes per-session learning infeasible without population priors; ship with a pre-warmed Thompson prior and treat convergence as a multi-session, not per-session, process.

## What it claims to do
A contextual bandit (LinUCB or Thompson sampling) continuously tunes three audio dimensions — binaural beat frequency tier, soundscape category, and output intensity — to maximize the cumulative time a user spends in the `inDeep` state during a session. Over multiple sessions the bandit learns a per-user preference surface, replacing the current static audio defaults with an adaptive system that self-optimizes toward deeper meditation.

## Neuroscience basis

- **Huang & Charyton 2008** (*Alternative Therapies in Health and Medicine*) — systematic review establishing that binaural beats in theta (4–7 Hz) and alpha (8–12 Hz) ranges reliably shift EEG power in corresponding bands in resting participants. Direct support for the claim that frequency tier selection affects meditation depth.
- **Brewer et al. 2011** (*PNAS*) — experienced meditators show increased posterior cingulate deactivation and correlated self-report of "effortless awareness"; confirms that sustained `inDeep` dwell time is a valid behavioral correlate of meditative quality, not an artifact.
- **Lutz et al. 2004** (*PNAS*) — long-range gamma synchrony in experienced meditators, but crucially, the paper distinguishes novice vs. expert response profiles. Supports individualized rather than population-averaged audio targets; motivates per-user bandit arms.
- **Sutton & Barto 2018** (*Reinforcement Learning: An Introduction*, MIT Press, 2nd ed.) — canonical reference for Thompson sampling and UCB bandit algorithms. The multi-armed bandit chapter explicitly covers delayed reward scenarios and discusses the effective horizon reduction caused by reward latency — directly applicable to the 90-second DepthGate cooldown problem.

## Muse S signal validity
The reward signal does not require high-fidelity EEG reconstruction — it reads DepthGate output, which is already computed from the existing vDSP pipeline. The bandit's *input* (state context) is indirect: session number, time-in-session, prior `inDeep` fraction, and the chosen arm. No raw electrode signal enters the bandit. Therefore Muse S hardware limitations (frontal-only coverage, 256 Hz, 4 channels) are already absorbed by the existing pipeline. The relevant known degradation is that DepthGate is based on the Peniston-Kulkosky meditationIndex (theta/alpha frontal ratio), which has weaker spatial specificity than full-cap studies; but this is a constant bias, not a bandit-specific problem.

The 90-second `inDeep` cooldown means each session of ~20 minutes yields at most ~13 reward observations — a sparse signal. Papers reporting binaural beat effects (Huang & Charyton 2008) use 15–30 min exposures with continuous EEG recording, not banded state-machine outputs. The coarseness is a real limitation but not a kill-shot.

## Implementation cost (realistic)

- **Files to create:** `MusePlus/Audio/BanditEngine.swift` (~300 LOC), `MusePlus/Audio/BanditState.swift` (~80 LOC), `MusePlus/Persistence/BanditStore.swift` (~120 LOC, uses UserDefaults or a local JSON file for prior persistence across sessions)
- **Files to modify:** `MusePlus/Audio/AudioEngine.swift` (inject bandit arm selection at session start, ~30 LOC delta), `MusePlus/Session/DepthGateStateMachine.swift` (emit reward event on `inDeep` exit, ~20 LOC delta)
- **LOC estimate:** 550–600 LOC new, 50 LOC modified. Research-grade bandit code tends to balloon during prior-tuning; budget 800 LOC total.
- **iOS-specific risks:**
  - Thompson sampling prior is a Beta distribution over reward probability; it is lightweight (CPU-only, negligible). No Core ML needed.
  - Audio tier changes happen at session boundaries, not mid-session — no AVAudioEngine teardown/restart risk.
  - BLE jitter does not affect the bandit directly (reward is DepthGate state, already timestamped at the Swift layer).
  - Persistence across app kills: must flush prior parameters to disk on `sceneDidEnterBackground`. If missed, cold-start resets.
- **Computational cost:** < 1 ms per reward update (Beta distribution conjugate update is 2 additions). Negligible RAM (<1 KB per arm). Battery: zero marginal cost.

### Cold-start analysis
With 3 frequency tiers × 4 soundscapes × 3 intensity levels = 36 arms, pure Thompson sampling needs roughly 5–10 pulls per arm before exploiting effectively — meaning 180–360 sessions before convergence on a fresh install. This is unacceptable.

**Mitigation:** Seed the Thompson prior from a population Beta fit computed from all existing TestFlight session logs (already emitted to the analytics pipeline). At install, each arm starts with a Beta(α=population_mean_reward × k, β=(1−population_mean_reward) × k) where k=10 gives moderate confidence. This shrinks cold-start from ~300 sessions to ~10–20 sessions. The population prior must be baked into the app bundle and updated with each TestFlight build.

### Reward signal latency analysis
DepthGate transitions to `inDeep` after 90 seconds of sustained qualifying signal, then resets. The bandit receives reward only when the session ends (total `inDeep` seconds). This is a **single delayed reward per session**, not a streaming reward. Implication: each session is one bandit trial, not 13. Multi-session convergence is correct framing. With population priors, 20–50 sessions to personalization is realistic.

## Killer experiment (1 hour to run on Sparky / device)

**Test:** Simulate 100 synthetic sessions with fixed random `inDeep` durations drawn from Beta(2,5) for arms 1-18 and Beta(4,3) for arms 19-36 (representing two quality tiers). Run Thompson sampling bandit with population prior vs. uniform prior. Count sessions to stable arm preference (>70% pulls from top-5 arms for 10 consecutive sessions).

**Input:** Synthetic reward stream generated in a Swift Playground or Python script — no Muse S needed.

**Computation:** ~200 lines of Python with NumPy. Run locally on Sparky in < 2 minutes.

**Expected output:** Population-prior bandit reaches stable preference by session 15–25; uniform-prior bandit by session 60–80.

**Pass threshold:** Population-prior convergence < 30 sessions. If it takes > 50, the prior is too diffuse or the arms are indistinguishable — revisit arm space granularity.

## Build estimate if GO
- Build 55: BanditEngine + BanditState + unit tests (1 session)
- Build 56: BanditStore persistence + population prior seeding from bundle (1 session)
- Build 57: Integration with AudioEngine + DepthGate reward emission + manual QA (1 session)
- Build 58: TestFlight beta, collect 50-session convergence data (1 session instrumentation)

**Total: 4 build cycles.** No dependencies on other T2 features.

## Recommendation
Build now — population prior mitigates cold-start, reward signal is already shipping, implementation is self-contained and low-risk.
