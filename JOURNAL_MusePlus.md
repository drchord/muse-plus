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

## Earlier sessions (pre-journal, reconstructed from git log)

| Date (approx) | Builds | Focus |
|---|---|---|
| 2026-04-28 | 1–18 | Skeleton, CI pipeline, framework linking, TestFlight setup |
| 2026-04-29 | 19–30 | EEGPipeline FFT, DepthScore, DepthGate, UI wiring |
| 2026-04-30 | 31–36 | Spotify PKCE, soundscapes, chime synthesis |
| 2026-05-01 | 37–44 | Audio crash fix (explicit format), timer, session recording, auto-reconnect, signal quality |
