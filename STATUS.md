# MusePlus — STATUS

**Last updated:** 2026-05-10 (B91 — drone race fix, bowl audio fix, proximity duck, depth trace, warmup ECDF fix)

---

## Build State

| Build | Theme | CI / TestFlight | Status |
|-------|-------|----------------|--------|
| 40–83 | Foundation → soundscape → HRV → ECDF → instrumentation overhaul | ✅ Historical | See journal |
| **86** | Layout fix attempt 1 (GeometryReader — flawed) | ✅ TestFlight | Superseded by B89 |
| **87** | Unified timers (MeditationTimer deleted), touch targets, fit-event HSI | ✅ TestFlight | Stable baseline |
| **88** | frontalContactGood rename, adaptive DepthGate threshold, Spotify in Soundscape, JSON summary scalars | ✅ TestFlight | Data confirmed in session_2026-05-09_2203 |
| **89** | ScrollView layout — band chart visible, buttons normal size | ✅ CI green (run 25615473857) | Pushed 2026-05-09 |
| **90** | Gong floor 0.85 + drone fix attempt (engine.stop in stopAll) + chime preview 0% warning + Anchor Tone label | ✅ CI green (run 25618431186) | Pushed 2026-05-09 |
| **91** | Bowl audio fix + drone race fix (ordering + isStopping) + proximity approach duck + depth trace chart + warmup ECDF fix + buildTag | ⏳ Pending CI | Pushed 2026-05-10 |

---

## B91 Changes

### Drone race condition (complete fix)
- Root cause: B90 fixed `engine.stop()` at fade completion but ordering was still wrong — `playSuccess()` fired BEFORE `stopAll()`. `configureAudioSession()` inside playSuccess triggered `AVAudioEngineConfigurationChange` ~0.5s later while `activeLayers` still populated → `resumeActiveLayers()` restarted nodes.
- Fix 1: `SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)` now called BEFORE `EndGongPlayer.shared.playSuccess()` in `endSessionGracefully`.
- Fix 2: `isStopping` flag added to `SoundscapePlayer`. Set true on `stopAll()` entry; `resumeActiveLayers()` returns early when true; cleared at fade completion and in `activate()`.
- Fix 3: `guard !activeLayers.isEmpty` in `stopAll()` now still calls `engine.stop()` even when no soundscape was active.

### BowlAudioGenerator — fix buzzing/clipping
- Root cause: normalization happened BEFORE reverb. Post-reverb peak = `peakAmplitude + reverbMix * peakAmplitude` → hard clip → distortion harmonics → buzzing on speaker.
- Fix: normalization moved to AFTER reverb. Tuned: `peakAmplitude` 0.9→0.65, `reverbMix` 0.25→0.12, `baseDecay` 0.4→0.6 (cleaner decay).
- Version key `"B91"` in UserDefaults forces regeneration of cached WAV files on first launch.

### Proximity approach duck (new feature)
- Gap: approach zone (0→threshold) was completely silent. No feedback loop before threshold.
- Implementation: `DepthGate.applyProximityDuck()` called every 0.5s update. Maps `smoothedDisplay` [0.30 → enterThresholdEcdf] to `SoundscapePlayer.setProximityGain()` [1.0 → 0.15].
- Effect: soundscape silently fades to 15% as user approaches threshold. No new tone — silence is the signal.
- Chime duck takes precedence (checked via `isDucked`). Contact loss and deep-state entry restore gain to 1.0.

### Warmup ECDF contamination fix
- Fix: `PersonalZDistribution.ingestSession()` now filters `s.phase == "main"` only. Warmup samples (first 300s) no longer inflate the distribution.

### Post-session depth trace (new feature)
- `SessionSummarySheet` now shows `DepthTraceChart`: ecdfDisplay over session time (minutes), orange dashed threshold line, grey calibration boundary at 5 min.
- Data was already stored per sample (`ecdfDisplay: Float?`). No new capture needed. Downsampled to ≤300 points for render performance.
- `enterThresholdAtSession: Float?` added to `SessionRecord` — populated via `attachEnterThreshold(gate.enterThresholdEcdf)` before `endSession()`.

### Coaching line — near-miss case
- When no deep state and peak ecdfDisplay ≥ 88% of threshold: "Peak depth X% — Y points from Z% threshold. The approach is there. You arrived without crossing. Less monitoring of state, more surrender to the breath."

### BuildTag fix
- `SessionRecorder.static let currentBuildTag = "B91"`. Both stale `"B87"` literals in SessionRecorder + `"B83"` in App.swift replaced.

---

## B91 Validation Checklist

**Audio:**
1. Session-end gong sounds clean (bowl ring, no buzzing). `bowl_success.wav` regenerated on first B91 launch.
2. No drone after session ends. Soundscape fades to silence and stays silent.
3. After session ends, start new soundscape — plays normally (engine restarts, `isStopping` cleared).

**Proximity duck (requires active soundscape):**
4. Start session with soundscape active. As calibration completes and depth rises toward threshold, soundscape volume gradually lowers.
5. At threshold: soundscape near-silent. Entry chime fires. After chime, soundscape restores to full volume.
6. No soundscape active: no effect (proximity duck silently no-ops).

**Session summary:**
7. After session: `SessionSummarySheet` shows "Depth Trace" section with chart.
8. Orange dashed line at correct threshold (55% for first session, higher for experienced users).
9. If no deep state but peak ≥ 88% of threshold: Insight shows "Peak depth X% — Y points from Z% threshold..."
10. `session_*.json` contains `enterThresholdAtSession` field.

**ECDF:**
11. After session, `PersonalZDistribution` updated using main-phase samples only (verify no warmup depthZ spikes in next session's threshold).

**Telemetry:**
12. `buildTag` in JSON and NDJSON header shows `"B91"` (not `"B87"` or `"B83"`).

---

## B86–B90 Changes (cumulative since B83)

### B87 — Timer unification
- `MeditationTimer` deleted entirely. `SessionTimer.shared` is the single timer.
- `BottomButton` touch targets fixed (`.padding(.vertical,16)` replaces greedy `maxHeight:.infinity`).
- Fit-event rate metric corrected: was counting HSI-tier flips, now counts `allGood→bad` transitions.

### B88 — Four-fix commit
- `DepthGate.contactsGood` → `frontalContactGood` (clarity rename; behavior unchanged since B77.1).
- Adaptive `enterThresholdEcdf` by `PersonalZDistribution.sessionCount`:
  - n=0: enter=0.55, exit=0.40 (cold start)
  - n<5: 0.60/0.45
  - n<20: 0.65/0.48
  - n≥20: 0.70/0.50
- Spotify row in `SoundscapeSheet` (shows when `SpotifyManager.isConnected`).
- `SessionRecord` stored scalars: `durationSec`, `summarySampleCount`, `deepFraction` (Codable, populated at `endSession()`).

### B89 — Layout fix (correct)
- Root cause: B86 GeometryReader inside VStack splits remaining space 50/50 with `maxHeight:.infinity` BottomButton. Band chart invisible, buttons 40% of screen.
- Fix: `ScrollView(.vertical).frame(maxHeight:.infinity)` between ElementsStripView and BottomButton HStack. No GeometryReader. BandChart inside scroll — reachable on all iPhone sizes.

### B90 — Gong + drone partial fix + chime preview
- `EndGongPlayer.gongVolumeFloor = 0.85`. `resolvedVolume()` returns `max(0.85, userSetting)`.
- `SoundscapePlayer.stopAll()`: `engine.stop()` at fade completion (partial drone fix — B91 completes it).
- Chime preview: orange "0% — drag slider to hear preview" label. Session End preview calls `EndGongPlayer.shared.playSuccess()`.
- Anchor Tone label: "7 Hz θ binaural · headphones only".

---

## Architecture Invariants

**Carryover (B80+):**
- `handleIsGood` 5s rate limit — NEVER REMOVE.
- Contact chimes gated behind `depth.isCalibrated`.
- Beta cue: additive `bm + 1.5 * bs`.
- AVAudioEngine stereo format explicit on all `engine.connect()`.
- `SessionRecorder` serial DispatchQueue (single-writer).
- `SessionRecorder` file protection `.completeUnlessOpen`.
- `MuseClient.registerAllListeners` idempotent reconnect path.

**B88+:**
- `DepthGate.thresholdConfigured` flag — adaptive threshold set ONCE per session. Reset in `reset()`.
- `SessionRecord.durationSec/summarySampleCount/deepFraction` stored properties — Codable synthesis includes them.

**B90+:**
- `EndGongPlayer.gongVolumeFloor = 0.85` — gong always ≥ 85% regardless of `chimeVolume` UserDefault.

**B91+:**
- `SoundscapePlayer.stopAll()` called BEFORE `EndGongPlayer.playSuccess()` in `endSessionGracefully` — ordering is load-bearing.
- `SoundscapePlayer.isStopping` — blocks `resumeActiveLayers()` during session-end fade. Never remove.
- `BowlAudioGenerator.kBowlAudioVersion = "B91"` — bump when synthesis params change to force WAV regen.
- `SessionRecord.enterThresholdAtSession` stored at session end — used by depth trace chart.
- PersonalZDistribution ingests main-phase samples only — warmup excluded.

---

## Pending (next build)

1. **EEGDenoiser live-signal wire-in** — replace raw EEG with cleaned signal in MuseClient.handleEEG. Gated by `eegDenoiseLiveSignal` UserDefault.
2. **`playTimerEnd()` cleanup** — dead code in ChimeEngine (preview row calls EndGongPlayer.playSuccess()). Remove.
3. **BowlAudioGenerator quality** — B91 fixes clipping; bowl sound quality after fix to be validated by user.
4. **MainThreadStall blocking-stack** — MetricKit MXCallStackTree deferred.
5. **fNIRS Gate 13** — HbO/HbR from Optics1-6 (backlog).
6. **NSFileCoordinator** — add to SessionRecorder.save() + CrashRecovery writes to prevent iCloud conflict copies.

---

## How to Resume

1. Read STATUS.md (this file) — canonical.
2. `gh run list --limit 5` — verify CI green.
3. Install TestFlight build and run B91 Validation Checklist above.
4. Hard rule: never push without explicit "go" per `MusePlus/CLAUDE.md`.
