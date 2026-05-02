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

## Earlier sessions (pre-journal, reconstructed from git log)

| Date (approx) | Builds | Focus |
|---|---|---|
| 2026-04-28 | 1–18 | Skeleton, CI pipeline, framework linking, TestFlight setup |
| 2026-04-29 | 19–30 | EEGPipeline FFT, DepthScore, DepthGate, UI wiring |
| 2026-04-30 | 31–36 | Spotify PKCE, soundscapes, chime synthesis |
| 2026-05-01 | 37–44 | Audio crash fix (explicit format), timer, session recording, auto-reconnect, signal quality |
