# Muse++ ROADMAP — Builds 55 → 70

**Drafted:** 2026-05-05
**Current TestFlight build:** 54 (Build 51 features = comprehensive overhaul)
**Source:** the 3-pillar trainer thesis (entry / sustain / transfer) — see end of file for design rationale.

---

## NORTH STAR

Muse++ is not a biofeedback meter. It is a **trainer** that:

1. **Teaches users to land in deep states** (Pillar 1 — Entry, builds 55–59)
2. **Helps them stay there without grasping** (Pillar 2 — Sustain, builds 60–63)
3. **Transfers the skill so they can do it without the device** (Pillar 3 — At Will, builds 64–68)
4. **Adds research-grade biomarkers where Muse S signal quality permits** (R&D, builds 69–70)

The contrarian principle: **the app must intentionally make itself less necessary over time.** Every other meditation app maximizes engagement. This one minimizes it after milestone N. That is what produces "at will."

---

## NON-NEGOTIABLE ARCHITECTURAL RULES

1. **No grasping.** Never reward "deeper is better." Reward *return from drift*, *consistency*, *self-knowledge*.
2. **Haptic-first feedback during practice.** Audio interrupts; haptic doesn't. Cued returns, drift warnings, heartbeat cues = haptic. Audio = scaffolding only (chimes at boundaries, soundscape backdrop).
3. **Feature fade is a feature.** Build flags + milestone-gated removal from day 1.
4. **Personal baseline > absolute thresholds.** Today's α normalized against today's eyes-open. No "expert mode" fixed thresholds.
5. **Interoception is the bridge to transfer.** HEP-cued + breath-cued attention training even when Muse S can't reliably measure HEP — the *cue* is the training.
6. **Tier 2 audits gate Tier 2 builds.** Hilbert phase-lock (#7), drowsy classifier (#8), vagal coherence (#9), bandit (#6) — each requires audit GO before scheduling.

---

## BUILD MAP

### Foundations (build 55)

Necessary primitives. No pillar advancement on its own.

| Build | Features | Why first |
|---|---|---|
| **55** | 1/f aperiodic slope (Tier 1 #3) + iTPF (Tier 1 #5) + complete SessionRecorder fields + BaselineView | Aperiodic feeds drift detection (60); iTPF feeds personalized binaural (56) and bandit (61); SessionRecorder fields feed every transfer-tracking feature (64-67); BaselineView is the first user touchpoint of "personal baseline" rule. |

### Pillar 1 — Entry (builds 56–59)

Train arrival into depth. Skill: intentional shift from default-mode wandering to focused absorption. Goal: user lands in DepthGate `inDeep=true` within 3 minutes, 5 sessions in a row.

| Build | Features | Notes |
|---|---|---|
| **56** | Pre-session intention picker (FA/OM/Inquiry — Lutz framework) + per-mode DepthScore variants | Three contemplative modes scored differently. FA rewards stable α. OM rewards low β + high spectral entropy. Inquiry rewards θ-α coupling. |
| **57** | Breath-locked entry chime (5 inhales) + respiration extraction from PPG envelope | Chime softly on inhale during first 60s. Trains "this sound = breath = land here." Drops β by 30-40% within 5 breaths in healthy users. |
| **58** | Haptic infrastructure (CHHaptic) + wandering detector + return prompts | Detect β rises >2σ above session baseline for >8s OR depth EMA fall 0.3 in 15s → soft haptic tick. Practices the *return* (Posner). |
| **59** | Anchor scaffolding (week 1: count breaths; week 2: silent label; week 3: bare attention; week 4: no anchor) | Graduated removal of cognitive crutches. Each week different pre-session prompt + chime cadence. Adherence tracking. |

**Pillar 1 graduation:** App-side feature unlocks Pillar 2 features when user shows 5 consecutive sessions of <3 min entry time. Visible to user as "Pillar 1: Entry — graduated 2026-XX-XX".

### Pillar 2 — Sustain (builds 60–63)

Notice subtle drift, re-stabilize without grasping. Goal: sustained `inDeep` ≥15 min in 3 of 5 consecutive sessions, ≤2 cued returns per session.

| Build | Features | Notes |
|---|---|---|
| **60** | 1/f drift early-warning (β slope + 1/f flattening) + Brewer noticing-reward loop | Predicts depth loss 5-15s before DepthGate exits. Soft haptic (NOT audible). Reward = brief positive haptic on drift recovery (Brewer 2011 craving substrate work — reward the noticing, not the state). |
| **61** | Adaptive challenge — RL bandit on (volume, binaural intensity, soundscape) | Tier 2 #6. Audit gates this build. Starts conservative, fades only when sustained ≥10min for 3 sessions. LinUCB-lite over 3-dim action space. Reward = sustained DepthGate fires. |
| **62** | HRV 0.1Hz coherence pacer + visual breath circle | Tier 2 #9. Audit gates this build (R-R precision at 64Hz). Welch PSD on R-R series, lock breathing at 5.5/min if audit passes. McCraty HeartMath protocol. |
| **63** | Heartbeat-cued chime (interoception primer) | When stable depth, occasional gentle chime *on PPG R-peak*. Schandry 1981 framework. Not measuring HEP — *cueing* it. Trains user to find own pulse without device. |

**Pillar 2 graduation:** triggered after 5 sustained-deep sessions. Unlocks Pillar 3.

### Pillar 3 — At Will (builds 64–68)

The hard part. Decouple skill from device. Goal: user can self-rate state with r ≥ 0.7 correlation to actual EEG depth on calibration check-ins.

| Build | Features | Notes |
|---|---|---|
| **64** | No-headband mode + self-rating UI | Same UI, no EEG required. User self-rates depth at 3 random points during session. App tracks self-rating distribution + variance. |
| **65** | Calibration check-in (every 10th session wears headband) + comparison view | Show divergence between self-rating and actual EEG depth over time. Closes interoceptive feedback loop. |
| **66** | State recall practice ("micro-sit" — 60s anywhere) + iOS Shortcuts integration | Open eyes, no audio, no headband. Calendar/location triggers via Shortcuts. Builds context-independent retrieval. |
| **67** | Sparky retrospective report (every 10 sessions, Python pipeline → Drive → email) | "You hit depth 0.65 within 4 min reliably; your no-headband self-ratings correlate r=0.72 with actual EEG." Quantifies *transfer*. |
| **68** | Graduation events (30/90/365 days) + intentional feature-fade logic | App removes features at milestones. Less feedback, more silence. **The app gets less helpful on purpose.** |

**Pillar 3 graduation:** transfer score (self-rating r vs EEG) ≥ 0.7 sustained for 3 calibration check-ins. App enters "spaciousness mode" — minimal UI, no scoring, no chimes, no haptics. Just a timer and a record. User has the skill.

### R&D / Stretch (builds 69–70)

Tier 2 #7 and #8 are higher risk; Tier 1 #1 #2 #4 limited by Muse S coverage.

| Build | Features | Status |
|---|---|---|
| **69** | Tier 2 #7 Hilbert phase-locked entrainment (only if iOS audio latency audit passes) + Tier 2 #8 drowsy classifier (CoreML) | Audits gate. #7 likely no-go due to BLE jitter; #8 likely go-with-caveats (training data). |
| **70** | Tier 1 #1 EEG microstates (2-state proxy on 4-electrode Muse S) + Tier 1 #2 theta-gamma PAC (frontal only, 30-45 Hz upper bound) + Tier 1 #4 HEP averaging (interoception-trained users only, frontal-only signal — research-grade only, not clinical) | All limited by frontal-only 4-electrode coverage; ship as research-mode feature behind developer toggle. |

---

## DEPENDENCIES

```
55 ── 56 ── 57 ── 58 ── 59 ──┐
 │     │                      ▼
 │     └─► (FA/OM/Inquiry) ──► 61
 │                              ▲
 │     ┌──────────────────────┘
 │     │
 ▼     │
60 ──► 61 ──► 62 ──► 63 ──► [P2 graduation]
                              │
                              ▼
                        64 ──► 65 ──► 66 ──► 67 ──► 68
                                                      │
                                                      ▼
                                              [P3 graduation = "spaciousness mode"]
```

Build 55 unblocks everything. Builds 60 + 61 + 62 + 63 can be parallelized after 60 if dev capacity allows. Builds 64-68 are mostly sequential (each adds to transfer-tracking framework).

---

## TIER 2 AUDIT GATING

Before scheduling any Tier 2 build, the corresponding audit memo in `docs/audits/` must show GO or GO-WITH-CAVEATS.

| Build | Audit | Status |
|---|---|---|
| 61 | T2-#6 RL bandit | drafted 2026-05-05 (parallel to this roadmap) |
| 62 | T2-#9 vagal coherence | drafted 2026-05-05 |
| 69 part 1 | T2-#7 Hilbert phase-lock | drafted 2026-05-05 |
| 69 part 2 | T2-#8 drowsy classifier | drafted 2026-05-05 |

If audit verdict = NO-GO, drop that feature; rebalance roadmap (e.g. if #7 is no-go, build 69 ships only #8 + advance build 70 by one).

---

## WHAT'S EXPLICITLY OUT OF SCOPE

To prevent scope creep:

- **Apple Watch app** — engagement-driver, not skill-trainer; conflicts with non-negotiable rule #3 (fade).
- **Guided audio courses (Muse-app style)** — courses are someone else's voice telling user what to do. Pillar 1 anchor scaffolding (build 59) is the trainer-equivalent: user learns to instruct themselves.
- **Streaks / gamification** — direct conflict with non-negotiable rule #1 (no grasping).
- **Social features / community** — not the bottleneck; nervous-system retraining is.
- **Music control beyond Spotify (Apple Music, YouTube)** — Spotify already coded; not a priority.
- **Multi-device / cloud sync** — single device, single user. Privacy by default.

---

## DESIGN RATIONALE — why 3 pillars, why this order

Most "EEG meditation apps" fail at "at will" because the device IS the practice. Lutz, Slagter, Davidson, Britton's contemplative neuroscience work shows three distinct skills with three distinct neural signatures:

- **FA (Focused Attention)** — sustained α on attended modality, β suppression on others. Beginner skill. Pillar 1.
- **OM (Open Monitoring)** — broad attentional aperture, *paradoxically lower α* but high spectral entropy. Intermediate. Built into Pillar 1 mode picker (build 56).
- **Non-dual / non-referential** — α, θ rise together with collapsed FAA difference. Advanced. Implicit in Pillar 2 sustained-depth state.

Skill transfer (Pillar 3) requires:
- **Interoception** as scaffolding — Brewer 2011 work on insula-based awareness training. HEP cueing (build 63) primes this.
- **Self-monitoring accuracy** — must develop across cohort (Pinedo, Galante 2023 contemplative training studies show self-rating accuracy lags 100+ hours behind actual proficiency). Pillar 3 calibration loop (build 65).
- **Context-independent retrieval** — practice in varied settings (build 66 micro-sits).

The "fade" is grounded in:
- Skinner / Bouton extinction work — conditioned cues become barriers if never extinguished.
- Pollack 2017 review of biofeedback efficacy — gains lost when device removed unless explicit transfer training.

---

## OPEN QUESTIONS (revisit after Tier 2 audits)

1. Does Muse S BLE jitter really kill Hilbert phase-locking? (T2-#7 audit will say.)
2. Is HRV 0.1Hz peak resolvable from 64Hz PPG? (T2-#9 audit.)
3. Is Sleep-EDF data transferable to 4-electrode 256Hz Muse S? (T2-#8 audit.)
4. Will users tolerate "the app gets less helpful" graduation at month 12? (Pilot study needed before build 68 ships — survey N=20.)
5. Should "no-headband mode" require the headband for occasional check-ins, or be fully optional? Likely required (build 65 calibration) but escapable.

---

## REFERENCES (selection)

- Lutz A, Slagter HA, Dunne JD, Davidson RJ. 2008. *Attention regulation and monitoring in meditation.* Trends Cogn Sci 12:163–169.
- Britton WB. 2019. *Can mindfulness be too much of a good thing? The value of a middle way.* Curr Opin Psychol 28:159–165.
- Brewer JA, et al. 2011. *Meditation experience is associated with differences in default mode network activity and connectivity.* PNAS 108:20254–20259.
- Donoghue T, et al. 2020. *Parameterizing neural power spectra into periodic and aperiodic components.* Nat Neurosci 23:1655–1665.
- Klimesch W. 1999. *EEG alpha and theta oscillations reflect cognitive and memory performance.* Brain Res Rev 29:169–195.
- Mierau A, Klimesch W, Lefebvre J. 2017. *State-dependent alpha peak frequency shifts.* Neuroscience 360:146–154.
- Park HD, Tallon-Baudry C. 2014. *The neural subjective frame: from bodily signals to perceptual consciousness.* Phil Trans R Soc B 369:20130208.
- Schandry R. 1981. *Heart beat perception and emotional experience.* Psychophysiology 18:483–488.
- Tang YY, Posner MI. 2009. *Attention training and attention state training.* Trends Cogn Sci 13:222–227.
- Tort ABL, et al. 2010. *Measuring phase-amplitude coupling between neuronal oscillations of different frequencies.* J Neurophysiol 104:1195–1210.
- Wallace BA. 2006. *The Attention Revolution.* (9-stage shamatha framework, lay reference.)
