# MusePlus — Session Journal

---

## 2026-05-02 | Sparky (laptop) | ~3h | Builds 45–48

**Focus:** Chart fixes, Mind Monitor redesign, spectral peak Hz display, CI debugging

**Decided:**
- Mind Monitor color scheme: Delta=red, Theta=violet-purple, Alpha=cyan, Beta=lime-green, Gamma=orange
- Spectral peak = `vDSP_maxvi` on existing FFT `mag2` within band bin range (no extra FFT cost)
- No 0.5 Hz resolution upgrade — would require 512-sample window, adds 0.5s latency, user declined
- Horizontal chart scale = rolling 60s window anchored to session time (not wall clock)

**Builds this session:**
| Build | What | Outcome |
|-------|------|---------|
| 45 | Chart X-axis rolling 60s window | Compiled; TestFlight upload FAIL (compile error in 46 pipeline) |
| 46 | Mind Monitor dark chart redesign | Compile FAIL: `BandPowers` struct field order mismatch in EEGPipeline |
| 47 | Spectral peak Hz display | Compile FAIL: same + `chartForegroundStyleScale([String:Color])` type error |
| 48 | Compile fixes only | Compiles clean; upload FAIL: Apple daily TestFlight limit hit |

**Root causes fixed in 48:**
1. `EEGPipeline.swift:108` — `BandPowers` init had labels interleaved `(delta,deltaPeak,theta,thetaPeak...)` but struct declares all powers first then all peaks
2. `BandChart.swift:65` — `chartForegroundStyleScale` rejects `[String:Color]`; needs `domain:/range:` array overload

**Left off at:** Build 48 code clean, pushed. Apple upload limit blocks TestFlight until ~2026-05-03 22:00 UTC.

**Next session needs:**
- Verify build 48 appeared in TestFlight (check `gh run list --limit 5`)
- Test on device: Mind Monitor chart, spectral peak Hz values, chart scrolling
- Test Spotify connect flow (muse-monitor://callback registered, never device-tested)
- If stable → consider App Store submission (full checklist in STATUS.md)

---

## 2026-05-03 | Sparky (laptop) | ~1h | Build 50 — TestFlight unblocked

**Focus:** CI debugging, Apple upload limit resolution, checkpoint/memory update

**Decided:** Nothing architectural — pure ops.

**What happened:**
- Discovered builds 45–47 were compile failures (never uploaded), build 48 uploaded but Apple daily limit was hit
- Fixed 2 compile errors: BandPowers label order (EEGPipeline) + chartForegroundStyleScale type (BandChart)
- Apple limit reset ~17:00 EST; triggered empty commit → build 50 uploaded successfully
- Build 50 is the first TestFlight build since 44 to include: rolling chart, Mind Monitor dark style, spectral peak Hz

**Left off at:** Build 50 live in TestFlight. User to test on device.

**Next session needs:**
- Test build 50: Mind Monitor chart, spectral peak Hz per band, chart scrolling
- Test Spotify connect flow (never device-tested)
- If stable → begin App Store submission prep (see STATUS.md Phase 1–5)

---

## 2026-05-04 | Sparky (laptop) | ~30min | Build 51 — comprehensive overhaul shipped

**Focus:** Commit Build 51 (already code-complete from prior session), push, fix one compile error, ship to TestFlight.

**Decided:** Nothing new architectural. Followed BUILD_PLAN_51.md verbatim through phases 1–5.

**What happened:**
- Pre-flight grep verified compile risks per plan §0.2: BandPowers init order, AVAudioUnitReverb.largeHall, IXNPpg.AMBIENT, iCloud entitlement — all clean
- Committed 80-file change set (commit `9f3df38`): 8 source files + project.yml + entitlements + 7 M4A soundscapes + STATUS.md + Reference/MuseStatsIosSwift/Muse.framework cleanup (~5MB)
- Pushed to origin/main → CI run 25351485915 → **archive failed** at MuseClient.swift:258–261
- Root cause: `IXNAccelerometer` enum bridges to `.X/.Y/.Z` (uppercase), not `.x/.y/.z` as STATUS.md note claimed. Swift SE-0005 treats single-letter cases as acronyms (preserved as-is). Plan §0.2 had documented this contingency.
- Fix commit: explicit `.X/.Y/.Z` + explicit `Double` type annotations to break sqrt overload ambiguity (Duration vs Double)
- CI run 25351592940 → **archived + uploaded in 2m4s** → Build 51 live in TestFlight

**Build 51 features delivered:** see STATUS.md "What Build 51 Contains" — 7 M4A soundscapes with crossfade + adaptive binaural, stereo ChimeEngine with reverb + Haas delay, 4-layer artifact rejection (now incl. accelerometer >0.25g), PPG heart rate via AMBIENT/Green channel autocorrelation, Peniston-Kulkosky meditation index, FAA bar, full UI redesign.

**Pending warnings (non-blocking, fix next session):**
- EEGPipeline.swift:76,81 — `DSPSplitComplex(realp: &realp, imagp: &imagp)` inout pointer outlives call. Refactor with `withUnsafeMutableBufferPointer` for safety. Compiles, runs, but technically UB.

**Left off at:** Build 51 live in TestFlight. Awaiting on-device test (per BUILD_PLAN_51 §6 checklist: connection, soundscapes, timer, chimes, depth gauge, FAA, artifact suppression, heart rate, session recording).

**Next session needs:**
- On-device test Build 51 against §6 checklist
- Fix DSPSplitComplex inout warnings if user wants Swift 6 cleanliness
- Continue pending list from STATUS.md continuation prompt: SessionRecorder fields, replay view, training stages, Sparky Python pipeline, ZIPFoundation, Spotify device test

---

## 2026-05-05 | Sparky (laptop) | ~1.5h | Roadmap + Build 55 plan + Tier 2 audits

**Focus:** Strategic planning. Pivot from "biofeedback meter" to "trainer that produces at-will state access". Build numbering reconciliation. Tier 2 feasibility audits.

**Decided:**
- Apple TestFlight build number = `github.run_number`, increments on every CI run including docs-only commits. Build 54 = current, binary identical to build 53 (= "Build 51 features" per BUILD_PLAN_51.md). Aligning labels going forward — build N = TestFlight number.
- 3-pillar trainer thesis: Entry (56-59) → Sustain (60-63) → At Will (64-68) → R&D stretch (69-70). Codified in ROADMAP.md.
- 5 non-negotiable architectural rules: no grasping; haptic-first feedback during practice; feature fade is a feature; personal baseline > absolute thresholds; interoception bridges to transfer.
- Build 55 = foundations: 1/f aperiodic slope (Donoghue 2020) + iTPF (Klimesch 1999, Mierau 2017) + complete SessionRecorder fields per STATUS pending list + BaselineView (Berger ratio capture). ~650 LOC, 1 session.
- T2-#7 Hilbert phase-lock **killed** by audit. BLE jitter ±20-50 ms structurally exceeds 25 ms latency budget at 6 Hz theta. Hardware kill-shot — no software fix; only wired/USB-C EEG would unblock.

**Verified facts (grep):** Build 54 has zero training/curriculum/lesson/onboard/haptic/metacognition primitives. SessionRecorder missing HR, FAA, soundscape events, baseline (per STATUS pending). Single Views/ file (BandChart only). App.swift = 959 LOC monolith. Confirmed all 9 advanced biomarkers + closed loops are 0/9 implemented.

**Artifacts shipped:**
- `ROADMAP.md` (10KB) — 16-build pillar roadmap with citations + dependencies + non-negotiables + open questions.
- `BUILD_PLAN_55.md` (8KB) — phases, compile risks, file list, 8 acceptance gates AS-1..AS-8, JSON back-compat strategy, synthetic-signal validation tests.
- `docs/audits/T2_06...T2_09.md` (~31KB total) — feasibility memos with neuroscience cites + Muse S signal validity analysis + LOC estimates + killer experiments + recommendations.
- `docs/audits/AUDIT_INDEX.md` — verdict summary table + cross-cutting findings.

**Tier 2 verdicts:**
| # | Feature | Verdict | Killer experiment |
|---|---------|---------|------------------|
| 6 | RL bandit adaptive audio | GO-WITH-CAVEATS | Simulate 100 sessions, Thompson + pop prior; pass < 30 sessions to converge |
| 7 | Phase-lock entrainment | **NO-GO** | (moot — BLE jitter is the kill-shot, not running) |
| 8 | Drowsy/deep classifier | GO-WITH-CAVEATS | Sleep-EDF Fpz-Cz @ 256 Hz logistic regression, AUROC > 0.78 |
| 9 | Vagal coherence HRV+EEG | GO-WITH-CAVEATS | 64 Hz PPG vs ECG LF-HRV on PhysioNet, r > 0.80 |

**Routing this session:** Sonnet agent (general-purpose, background) wrote all 4 audit memos in parallel — 264s wall-clock, 32K tokens. Opus inline did roadmap + plan-55 (high parent-context dependency, novel design synthesis). ctx_execute for grep/LOC ground truth.

**Left off at:** Builds 50-54 live in TestFlight, ROADMAP + plan-55 + audits all pushed to main, Build 55 implementation not yet started.

**Next session needs:**
1. Implement Build 55 per BUILD_PLAN_55.md (1/f slope + iTPF + SessionRecorder fields + BaselineView)
2. Or: run killer experiment for T2-#9 vagal coherence (PhysioNet PPG vs ECG comparison) — pre-build 62 gate
3. Or: pilot study setup for T2-#8 drowsy classifier (need 2-3 weeks labeled Muse data)
4. Recommended order: Build 55 first (unblocks 56-67), then T2-#9 killer experiment in parallel with Build 56-59 dev work

---

## Earlier sessions (pre-journal, reconstructed from git log)

| Date (approx) | Builds | Focus |
|---|---|---|
| 2026-04-28 | 1–18 | Skeleton, CI pipeline, framework linking, TestFlight setup |
| 2026-04-29 | 19–30 | EEGPipeline FFT, DepthScore, DepthGate, UI wiring |
| 2026-04-30 | 31–36 | Spotify PKCE, soundscapes, chime synthesis |
| 2026-05-01 | 37–44 | Audio crash fix (explicit format), timer, session recording, auto-reconnect, signal quality |

---

## 2026-05-09 — Sparky — ~6h — B82 → B83

**Focus.** B82 user-reported issues (no gong, TP9/TP10 yellow/green flicker, no countdown timer). Drove B83 as "instrumentation overhaul + audibility fix + everything-deferred-shipped" via 5-round audit-and-fix loop on user demand.

**Decided.**
- Synthesized gong fundamental at 84 Hz was below iPhone built-in speaker rolloff (~200 Hz). Raised to 432 Hz across playGong/playSuccessChime/playTimerEnd. Added EndGongPlayer for file-based playback (AVAudioPlayer); BowlAudioGenerator synthesizes Documents/Sounds/.wav at first launch. Bundle .m4a takes priority if user adds Pixabay tibetan-bowl files.
- B80 instrumentation was broken: per-sample contactState* fields all `undefined`, eventStream array empty (only one recordEvent site existed). B83 ships 5 new NDJSON _type records (event, audioState, gongLifecycle, mainStall, uiState, denoiseStats) + 7 SessionRecorder.append* helpers. Single source of truth = NDJSON.
- Timer HUD redesigned: 28pt rounded mono digits, opacity 0.85, MM:SS + elapsed/total. Presets [60,75,90] → [5,10,15,20,25,30,45,60,75,90,120].
- HSI hysteresis: 4-of-5 sliding majority on rounded tier suppresses single-sample chip flicker. Probe.lastValidHsi retainer fixes the race that left B82 contactState fields nil.
- EEGDenoiser 3-stage cascade (1077 LOC): db4 SWT + Riemannian Potato + rASR-lite. Sidecar mode — measurement-only via EEGWindowBuffer. Live-signal replacement deferred to B84 pending tap-mark validation. True log-Euclidean running mean (Arsigny 2006) via mat4LogSymm/mat4ExpSymm — NOT the Euclidean approximation that earlier commit used. Citation corrected: Barachant, Andreev & Congedo 2013 (NOT Barachant & Bonnet — agent fabricated authors initially).
- Pre-session fit-stability banner (B81 carryover): 5-second consecutive-allGood gate during calibration. Driven by pipeline.onBandPowers (~2 Hz steady), NOT by fit sink (CurrentValueSubject only fires on CHANGE — round-3 had this wrong).
- Per-session A/B/C/F grade in SessionDiagnostics. Computed from FIT-event rate not HSI-tier flips (round-3 corrected the metric conflation).
- museModel populated via MuseClient.museModelString (was hardcoded nil).
- 5 XCTest files (522 LOC).
- BowlAudioGenerator at app init writes ~14ms of file I/O — visible only on first launch.

**Audit loop history.** User explicitly demanded loop until I could honestly say everything fixed. Five rounds:
1. Initial commit `515304d` — instrumentation + audibility + HUD
2. Self-audit found 15 items → `a0116e3` closes deferred items
3. Round-2 audit → `b50191d` Riemannian log-Euclidean upgrade, citation fix, fit-banner build, museModel exposure, fireDiagnosticsSnapshot at gong, Mirror→direct, dual-write doc, grade metric correction
4. Round-3 audit → `a6826d9` fit-stability tick freeze fix (was reading wrong sink), chimeVolume cast bug, doc cleanups
5. Round-4 audit → `32e1070` gongLifecycle source-string lying on synth fallback
6. Final round → admitted residual unknowns (compile risk, mat4LogSymm failure rate, bowl audio quality on device, MainThreadStall stack limitation)

CI: run 25607452412 FAILED on `BowlAudioGenerator.swift:99` AVAudioFormat optional unwrap + iOS 17 onChange syntax. Hotfix `9a82d6e` pushed. CI run 25607522383 GREEN in 113s. Build counter 83 in TestFlight processing.

**Left off at.** B83 CI green, TestFlight processing IPA. Awaiting device install + 16-item validation checklist in STATUS.md. Critical first checks: bowl audible on built-in speaker (no earbuds), gongLifecycle scheduled→started→completed in NDJSON, audioState.chimeVolumeSetting reflects actual setting (≥0.7 expected — confirmed user did not adjust).

**Next session needs.** Sugato runs a B83 session. Sends NDJSON. I analyze:
1. gongLifecycle path complete?
2. audioState shows builtInSpeaker output + chimeVolumeSetting reading?
3. denoiseStats records present + alphaPowerRatio in [0.95, 1.05] for clean alpha intervals?
4. mainStall count = 0 in healthy session (or non-zero quantifies "freezing" claim)?
5. SessionDiagnostics.contactQualityGrade matches user's perceived headband stability?
6. fitEventsPerMin matches B82 baseline (~9.3/min) or improved post-banner?

If denoiser shows benefit on tap-marks: B84 wires live-signal replacement. If not: revert filter, investigate why.

**Honest residual uncertainty.** mat4LogSymm failure rate not telemetered. Bowl audio quality not ear-tested. MainThreadStall captures post-recovery stack not blocking-stack (documented). EEGDenoiser tests written by agent against pre-round-3 surface — possible mismatch CI didn't catch (only one error surfaced; tests might silently skip).

---

## 2026-05-11 | Sparky (laptop) | ~4h | Build 94

**Focus:** Full B94 implementation — 10 tasks via subagent-driven development. Kalman depth filter, FAA flow state, iTPF adaptive binaural, quality score, forecast banner, TrendsView.

**Decided:**

- **KalmanDepth replaces EMA for smoothedDisplay.** 2-state (depth + velocity), qD=2.16e-3, qV=1e-4, rBase=0.005, rNeutralQuality=0.6. Innovation clamped ±0.3, depth clamped [0,1]. Kalman frozen during contact loss — more honest than artificial decay. duckDisplay gets its own slower EMA (α=0.095) for proximity duck only — prevents audible volume pumping. Empirical: 76% fewer approach-zone threshold crossings vs raw smoothedDisplay.

- **End-of-session gong fix.** Root cause: stopAll(4s) + immediate playSuccess() → full-volume overlap → DAC clip → buzzing. Fix: stopAll(2s) + 1.5s deferred gong. recordEvent() moved to before the asyncAfter because endSession() closes the NDJSON file synchronously — writing after closure was a race condition bug caught in quality review.

- **FAA flow state.** inDeepState AND smoothedFaa > faaBaseline+0.25 sustained 5s (10 windows). Baseline locked at calibration end (population median −0.092). Exit: 3 consecutive below baseline+0.075 (1.5s hysteresis — single-sample exit would collapse genuine flow on FAA noise). playFlow() at 444 Hz (distinct from 528 Hz enter-deep, 432 Hz gong). Cooldown 120s.

- **iTPF adaptive binaural.** setAdaptiveBinauralIfActive() called from App.swift AFTER updateAdaptiveDepth — critical ordering. If called inside DepthGate.update(), updateAdaptiveDepth runs immediately after in App.swift and overwrites with iTPF-2.0 formula. Caught by quality reviewer. lastKnownITPF reset on session end.

- **Quality score.** 0-100: deep fraction (40pts, target 70%) + ECDF smoothness (25pts, ecdfStd/0.25) + contact quality (35pts, frontalGoodFraction). Main-phase samples only. Ring gauge in SessionSummarySheet with @State displayScore + .onAppear animation — original code animated against a constant Int (unreliable). Caught by quality reviewer.

- **Forecast banner.** 60s after calibration, mean of last 60s ECDF → strong (>0.52) / building (>0.38) / slow. 15s display. recentEcdf capped at 120 entries. calibrationCompleted flag prevents re-fire on session restart.

- **TrendsView.** Last 30 session_*.json files, async load, Swift Charts. TrendRecord decodes only top-level scalars (not sample arrays) for speed. durationSec field confirmed vs SessionRecorder schema. ContentUnavailableView safe — iOS 17 target confirmed in project.yml.

- **Build infrastructure.** XcodeGen (project.yml) auto-includes all .swift in MusePlus/ — no pbxproj editing ever needed. Windows can't run xcodebuild; CI (GitHub Actions on Mac runner) is the only compile gate.

**Build arc:**
| Commit | Task |
|--------|------|
| BuildTag B94 + alphaPowerRatio + qualityScore field | Task 1 |
| KalmanDepth 2-state filter | Task 2 |
| Wire Kalman + duckDisplay into DepthGate | Task 3 |
| Delay gong 1.5s after 2s fade | Task 4 |
| FAA flow state + playFlow() 444Hz | Task 5 |
| iTPF binaural after updateAdaptiveDepth | Task 6 |
| Quality score ring gauge | Task 7 |
| Early session forecast banner | Task 8 |
| TrendsView Swift Charts | Task 9 |
| STATUS.md B94 update | Task 10 |

**Left off at.** B94 pushed (5802706). CI pending. STATUS.md updated with B94 build table entry + 16-item validation checklist.

**Next session needs.**
1. `gh run list --limit 5` — verify CI green (should be run_number 94 or next available).
2. Install TestFlight build on device.
3. Run B94 Validation Checklist (STATUS.md, 16 items): gong clean (no buzz), 444Hz flow chime distinct, forecast banner appears at 60s then dismisses at 75s, TrendsView loads without stall.
4. alphaPowerRatio currently hardcoded 0.5 — B95 scope: wire actual denoiser signal quality to KalmanDepth adaptive measurement noise.

---

## 2026-05-12 | Sparky (laptop) | ~3h | Build 95

**Focus:** Volume bounce fix (session 2026-05-12_0337, recoveredFromCrash=true, disconnected at ~32.6 min). Crash data preservation. Pre-existing audio bug sweep.

**Decided:**

- **Volume bounce root cause.** `applyProximityDuck()` called `setProximityGain(1.0)` every 0.5s while `inDeepState=true`, continuously replacing deepStateGain with proximity level. Fix: `guard !inDeepState else { return }` in applyProximityDuck. Gain composition everywhere changed to `min(proximityGain, deepStateGain)` — not multiply, which caused 0.0225 at threshold crossing (0.15 × 0.15).

- **deepStateGain architecture.** New `SoundscapePlayer.deepStateGain: Float` (0.15 deep, 1.0 normal). `setDeepStateGain()` fades with `deepStateGeneration` counter — re-entry mid-exit-fade cancels the rising volume immediately. Entry fires immediately (removed 1.5s asyncAfter delay that was a workaround for the now-fixed isDucked bug). Exit volume rise IS the re-entry signal: user sees volume climbing → can deepen to cancel it.

- **fade() smart isDucked.** `isActuallyDucking = min(multiplier, deepStateGain) < capturedEffective - 0.02`. At exit, chime duck target (0.18) > deepStateGain floor (0.15), so `isActuallyDucking = false` → `guard` return → zero competing writes against setDeepStateGain → exit signal flows cleanly from t=0. Without this, fade() steps capped the rising volume at 0.18 for 0.35s. With it: pure unimpeded rise from 0.15 to 1.0 over 3s.

- **Crash data preservation.** `attachEnterThreshold()` now writes `{_type:"threshold", enterThreshold:…}` to NDJSON at calibration confirmation. `synthesiseRecord()` parses it and computes durationSec/deepFraction/qualityScore from crash-orphan NDJSON. Previously all three were lost on crash.

- **7 pre-existing audio bugs fixed (all identified by ruthless self-audit):**
  1. `unduckTimer` was declared but never assigned — `cancel()` always a no-op. Removed.
  2. `fade()` had no cancellation: added `fadeGeneration` counter, stale steps now auto-cancel.
  3. `startLayer()` ignored `isDucked`: new layer during chime now starts at duck level.
  4. `resumeActiveLayers()` called `applyProximityGain()` which is blocked by `isDucked=true` — BT reconnect mid-chime caused audible full-volume surge. Fixed: explicit duck-level restore branch.
  5. `resetDeepStateGain()` called `applyProximityGain()` blocked by `isDucked=true` — stuck-at-duck on session reset. Fixed: now clears `isDucked`, bumps `fadeGeneration`.
  6. `fade()` used live `cur` per step — non-linear, non-monotonic. Fixed: captured `startVols` at call time for true linear interpolation.
  7. `deepeningRing` off-by-one: `ring[(head+1)%N]` is second-oldest, not oldest — measured 29.5s window instead of 30s. Fixed: read `ring[head]` before overwrite.

- **Audit discipline.** Each implementation round followed by explicit self-audit identifying every assumption, gap, and vague claim before rewriting. This surfaced the guard/isActuallyDucking gap (submitted code ran volume steps even when isActuallyDucking=false, creating competing writes at exit) and all 7 pre-existing bugs.

**Build:** B95 pushed (4b47f59). CI pending.

**Left off at.** B95 pushed. STATUS.md updated with B95 section + 8-item validation checklist + B95 architecture invariants.

**Next session needs.**
1. `gh run list --limit 5` — verify B95 CI green.
2. Run B95 Validation Checklist (STATUS.md, 8 items): volume behavior at entry/exit, re-entry mid-fade, BT reconnect, new layer during chime, crash recovery, deepening cue timing.
3. B96 scope: alphaPowerRatio wire-in (denoiser signal quality → KalmanDepth adaptive measurement noise). Currently hardcoded 0.5.
