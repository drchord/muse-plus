# MusePlus — STATUS

**Last updated:** 2026-05-09 (B83 — instrumentation + audibility + HUD + filter library; awaiting CI + user "go" for push)

## Build State

| Build | Theme | TestFlight | Status |
|-------|-------|-----------|--------|
| 40–73 | Foundation → calibration → soundscape → HRV → ECDF | ✅ Historical | See journal |
| 74 | Soundscape overhaul + HRV + Ad Hoc CI | ✅ TestFlight | Last stable pre-depth-fix |
| 75–77.2 | Depth scoring overhaul + ECDF + tap-to-mark | ✅ TestFlight | See journal |
| 80 (build #81) | Silent-disconnect resilience: NDJSON streaming + alerts + watchdog + timer + gong + bg modes | ✅ TestFlight | **Was running on phone during B82 session** |
| **82 (build counter)** | Same B80 binary; TestFlight build counter incremented during user trials | ✅ Live | User reported 3 issues from 22-min eyes-open/closed session — see B82 analysis |
| **83** | **Instrumentation overhaul + audibility fix + HUD + filter library** | ⏳ **Local — awaiting CI + push approval** | All edits in working tree; not yet committed |

---

## What B82 Data Showed (analysis: `analysis/B82_session_analysis.md`)

`G:\My Drive\session_2026-05-09_0846.ndjson` — 1,824 lines, `buildTag: "B80"`. Key findings:

| Issue user reported | Root cause from data |
|---|---|
| No gong at end of 22-min session | `endReason: "manual"` confirmed gong code path was reached. Gong fundamental was 84 Hz — below iPhone built-in speaker rolloff (~200-250 Hz). Not "physically impossible" as I overclaimed earlier; *probably* sub-resonant on device speaker. B83 logs definitive audioState + gongLifecycle to confirm vs hypothesize. |
| TP9/TP10 yellow/green flicker | 210 fit events / 22 min (9.3/min). `frontalGood=true` 100%; only TP9/TP10 unstable. UI rendered every 1Hz HSI sample directly. |
| No countdown timer visible | HUD existed but was `.caption` opacity 0.45 (dim), tucked under hero gauge. Plus `allowedDurations = [60,75,90]` had no 20-min preset matching the user's intended length. |
| (Hidden) B80 instrumentation broken | All `contactState*`, `packetGapMs`, `appState` fields `undefined` in NDJSON. `eventStream` empty (only one `recordEvent` call site existed). `episodeCount=0` despite 22 min. |

---

## What B83 Changes (over B80)

### B83-A — Instrumentation suite (NEW)

Five new NDJSON `_type` records, each with a typed `SessionRecorder.append*` API:

| `_type` | When | Fields |
|---|---|---|
| `audioState` | Session start, every 30s, every chime/gong call, route change | outputVolume, category, mode, isOtherAudioPlaying, outputs, chimeEngineRunning, chimeEnginePlayerPlaying, soundscapeEngineRunning, chimeVolumeSetting, secondsSinceLastRouteChange |
| `gongLifecycle` | Every gong/bowl call | phase ∈ {scheduled, started, completed, failed}, source (file/synth) |
| `mainStall` | Main-thread tick > 1.5 s | deltaSec, thermalState, appState, topStack (5 frames mangled) |
| `uiState` | 30s periodic | timerHudRendered, depthGaugeRendered, chipViewRendered (proves bindings fired) |
| `event` | Every recordEvent site | time, kind, detail (replaces empty B80 in-memory eventStream) |

`recordEvent` now writes to NDJSON immediately via `SessionRecorder.appendEvent` — **single source of truth**. Crash mid-session no longer loses every event.

### B83-B — Audibility fix

- `EndGongPlayer.swift` (NEW) — file-based AVAudioPlayer wrapping `bowl_success`/`bowl_failure` from `MusePlus/Resources/Sounds/`. Falls back to `ChimeEngine.playGong()` / `playFailureChime()` if files absent. Independent of AVAudioEngine state — immune to route-change-killed engine.
- `ChimeEngine.playGong/playSuccessChime/playTimerEnd` fundamental: **84 Hz → 432 Hz**. iPhone built-in speaker has known rolloff below ~200 Hz; 432 Hz with inharmonic gong partials puts most energy in 432-2645 Hz band (passband).
- `ChimeEngine.init` — Apple-recommended `engine.prepare()` before `engine.start()` (pre-allocates buffers, stabilizes engine across route changes).
- `endSessionGracefully(reason:)` calls `EndGongPlayer.shared.playSuccess()` instead of `playGong()`.
- `performFinalDisconnect(...)` now calls `EndGongPlayer.shared.playFailure()` AND extends soundscape fade to 4 s (was abrupt 0.5 s with no chime).

### B83-C — Timer HUD redesign + 11 presets

- `SessionTimer.allowedDurations`: `[60, 75, 90]` → `[5, 10, 15, 20, 25, 30, 45, 60, 75, 90, 120]` minutes.
- HUD redesigned: 28 pt rounded mono digits, opacity 0.85, format `MM:SS` + `elapsed/total remaining` line.
- `Probe.timerHudRendered: Int` (`@Published`) increments on each second's body invocation via `.onChange(of:)`. `appendUIState` drains it every 30 s — proves the binding rendered.

### B83-D — HSI display hysteresis (UI flicker fix)

- `Probe.lastValidHsi: [Double]` (NEW) — retainer for last non-empty HSI vector. Used by `addSample` to populate per-sample `contactState*` fields. **B82 had every contactState undefined because `hsiRaw` was `[]` when first sample built; lastValidHsi survives.**
- `Probe.hsiStableTier: [Int]` (`@Published`, NEW) — 4-of-5 sliding majority on rounded HSI tier (1=good, 2=mediocre, 4=bad). Suppresses single-sample chip flicker. Latency ≤5 s.
- `SignalChipsView` reads `hsiStable` first; falls back to `hsi` only if buffer empty.

### B83-E — EEG denoising library (NOT yet wired into live pipeline)

- `MusePlus/Pipeline/EEGDenoiser.swift` (NEW, 493 LOC) — db4 SWT 5-level + universal-threshold soft-thresholding via Accelerate vDSP. Citations: Donoho & Johnstone 1994 (universal threshold); Krishnaveni et al. 2006 (EEG SWT denoising); Daubechies 1992 (db4 coefficients); Mallat 1999 (Stationary WT).
- **Library only — not yet invoked in `handleEEG`.** Adding a 1-second-window buffer manager + dispatcher is non-trivial scope. Validation harness (`analysis/tapmark_validation.js`) exists; needs raw-EEG-bearing NDJSON sessions (B83+ samples) AND user tap-to-mark labels (deep + shallow) before filter can be evaluated against ground truth. This is intentional — adding an unvalidated filter to the live path could mask real signal.
- B84 will wire in once B83 sessions provide raw EEG samples + tap-to-mark labels.

### B83-F — Main-thread freeze quantifier

- `MusePlus/Diagnostics/MainThreadStall.swift` (NEW) — 1 Hz Timer on `RunLoop.main` `.common`; if `delta > 1.5 s`, fires `appendMainStall` with deltaSec, thermalState, appState, top-5 mangled stack frames. Started at session start, stopped at session end. Quantifies the "freezing" sensation user reports.

### B83-G — MuseClient packet gap tracking

- `MuseClient.lastPacketGapMs: Float` (NEW, atomic static). Updated on every SDK callback. Read by Probe.addSample → per-sample `packetGapMs` populated for first time.

---

## What's NOT in B83 (deferred, honest scope)

| Item | Why deferred |
|---|---|
| EEGDenoiser wired into `handleEEG` | Buffer + dispatcher is new architecture; needs raw-EEG NDJSON sessions + tap labels for validation first. Library compiled and ready. |
| Riemannian Potato + rASR additional stages | Will only add after SWT-only proves it helps via tap-mark correlation. Avoids cargo-culting "more layers = better." |
| Pre-recorded bowl `.m4a` files | User drops in from Pixabay tibetan-bowl pack. README in `MusePlus/Resources/Sounds/`. |
| Pre-session fit guide (B81 carryover) | Not in user's reported issues; defer to next sprint. |
| Athena auto-preset detection (B81 carryover) | Same. |
| XCTest scaffolding | Same. |
| fNIRS OpticsPipeline | Aspirational. |

---

## B83 Validation Checklist (run on device after install)

1. **Audibility** (built-in speaker, no earbuds): manual stop at 5 min — bowl/gong heard at >50% device volume
2. **gongLifecycle** present in NDJSON: `scheduled` → `started` → `completed` (or `failed`)
3. **audioState** records present every 30s + at gong sites — answers "was speaker actually outputting?" deterministically
4. **Timer HUD** large + visible: 20-min preset from Settings → `MM:SS` digits at 28pt opacity 0.85
5. **`uiState.timerHudRendered`** > 0 in NDJSON — proves binding rendered
6. **HSI hysteresis**: wiggle TP9/TP10 contact → chip stays green ≥4 s before flipping orange
7. **Per-sample `contactStateTP9` etc populated** in NDJSON (no longer `undefined`)
8. **`packetGapMs`** populated per sample (not nil)
9. **`event` records** match runtime: 210 fits → 210+ event lines (vs B82 zero)
10. **`mainStall`** records: 0 in a healthy session; non-zero proves the "freezing" claim quantitatively
11. **No B80 regressions**: NDJSON crash recovery still works; soundscape still adapts to depth; calibration still completes in 60s

---

## Files Changed in B83

**New files:**
- `MusePlus/Audio/EndGongPlayer.swift` (202 LOC)
- `MusePlus/Diagnostics/MainThreadStall.swift` (138 LOC, post-edit)
- `MusePlus/Pipeline/EEGDenoiser.swift` (493 LOC)
- `MusePlus/Resources/Sounds/README.md` (bowl drop-in instructions)
- `analysis/tapmark_validation.js` (offline filter validator)
- `analysis/B82_session_analysis.md` (data-driven diagnosis)

**Modified files:**
- `MusePlus/App.swift` — Probe new fields (lastValidHsi, hsiStableTier, hsiBuffer, render counters, lastRouteChangeAt, diagnosticsTimer); HSI sink hysteresis logic; addSample reads lastValidHsi + MuseClient.lastPacketGapMs; recordEvent writes NDJSON; endSessionGracefully uses EndGongPlayer; performFinalDisconnect plays failure bowl + 4s fade; route-change observer stamps + snapshots; session-start fires diagnosticsTimer + MainThreadStall; timer HUD redesign; SignalChipsView uses stable tier
- `MusePlus/Audio/ChimeEngine.swift` — engine.prepare(); 84 Hz → 432 Hz in playGong/playSuccessChime/playTimerEnd; isEngineRunning/isPlayerPlaying public accessors; Telemetry.audio notice on synthesis
- `MusePlus/Audio/SoundscapePlayer.swift` — isEngineRunning public accessor
- `MusePlus/SessionRecorder.swift` — 5 new NDJSON struct types; appendEvent + appendAudioState + appendGongLifecycle + appendMainStall + appendUIState + currentSessionElapsed; NDJSONSample fields populated; addFitEvent now also emits event line; buildTag B80 → B83
- `MusePlus/Muse/MuseClient.swift` — lastPacketGapMs static; computed in handleEEG
- `MusePlus/Session/SessionTimer.swift` — allowedDurations expanded

---

## How to Resume

1. Read STATUS.md (this file)
2. Verify CI: `gh run list --limit 5` (do not push until user "go")
3. If pre-push: open Xcode, build clean (no Mac available locally — CI is the compile gate)
4. Drop bowl_success.m4a + bowl_failure.m4a into `MusePlus/Resources/Sounds/` (optional — synthesis fallback works)
5. Wait for explicit user "go" per `MusePlus/CLAUDE.md` HARD RULE
6. After push + TestFlight install: run B83 Validation Checklist above

---

## Architecture Invariants (do NOT break)

All B80 invariants persist. New B83 invariants:

- `recordEvent` is the single canonical event-append site — DO NOT add a parallel in-memory list
- `MuseClient.lastPacketGapMs` is atomic static; written on SDK callback thread, read on any thread
- `Probe.lastValidHsi` retains across reconnects (vs `lastHsiRaw` which resets) — keep separate
- `EndGongPlayer` configures AVAudioSession defensively before every play — DO NOT remove
- `ChimeEngine.engine.prepare()` MUST precede `engine.start()` (Apple recommendation)
- Bowl synthesis fundamental is 432 Hz, NOT 84 Hz — DO NOT revert
- `MainThreadStall.shared.start()` at session start; `.stop()` at session end (idempotent)
- `diagnosticsTimer` runs on `.common` mode RunLoop — must invalidate at session end (memory leak otherwise)
