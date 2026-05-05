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
