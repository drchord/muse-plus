# MusePlus — STATUS

**Last updated:** 2026-05-09 (B91 pushed — drone fix + chime preview UX)

---

## Build State

| Build | Theme | CI / TestFlight | Status |
|-------|-------|----------------|--------|
| 40–83 | Foundation → soundscape → HRV → ECDF → instrumentation overhaul | ✅ Historical | See journal |
| **84** | Layout fix attempt 1 (GeometryReader — flawed) | ✅ TestFlight | Superseded by B89-corrected |
| **87** | Unified timers (MeditationTimer deleted), touch targets, fit-event HSI | ✅ TestFlight | Stable baseline |
| **88** | frontalContactGood rename, adaptive DepthGate threshold, Spotify in Soundscape, JSON summary scalars | ✅ TestFlight | Data confirmed in session_2026-05-09_2203 |
| **89-corrected** | ScrollView layout — band chart visible, buttons normal size | ✅ CI green | Pushed 2026-05-09 |
| **90-corrected** | Gong volume floor 0.85, resolved volume in telemetry, footer inside Section | ✅ CI green | Pushed 2026-05-09 |
| **91** | Drone fix (engine.stop in stopAll), chime preview 0% warning, Anchor Tone label | ⏳ CI in progress (run 25618431186) | Pushed 2026-05-09 |

---

## B84–B91 Changes (cumulative since B83)

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

### B89-corrected — Layout fix (second attempt, correct)
- Root cause: B84 GeometryReader inside VStack splits remaining space 50/50 with `maxHeight:.infinity` BottomButton. Band chart invisible, buttons 40% of screen.
- Fix: `ScrollView(.vertical).frame(maxHeight:.infinity)` between ElementsStripView and BottomButton HStack. No GeometryReader. BandChart inside scroll — reachable on all iPhone sizes.
- `BottomButton`: `.frame(maxWidth:.infinity)` + `.padding(.vertical,16)`. Touch target via `.contentShape(Rectangle())`.

### B90-corrected — Silent gong fix
- Root cause (confirmed from session_2026-05-09_2203.ndjson): `chimeVolumeSetting=0` → `EndGongPlayer.resolvedVolume()` returned 0 → `bowl_success.wav` played silently. Gong DID fire (gongLifecycle scheduled+started present).
- Fix: `EndGongPlayer.gongVolumeFloor = 0.85`. `resolvedVolume()` returns `max(0.85, userSetting)`. At system vol 0.3: 0.85×0.3 = 25.5% max — audible.
- Also handles NSNumber UserDefaults storage type.
- `gongLifecycle.started` event now includes `_vol0.85` in detail — self-diagnosing.
- Settings footer text updated: "Session-end gong enforces an 85% minimum regardless."

### B91 — Drone fix + chime preview UX
- **Drone root cause**: `SoundscapePlayer.stopAll()` stopped nodes but not the engine. `AVAudioEngineConfigurationChange` (triggered by `EndGongPlayer.configureAudioSession()` at session end) fired `restartEngine()` → `resumeActiveLayers()` → re-scheduled looping nodes during the 4s fade window.
- Fix: `engine.stop()` added at the end of `stopAll()` fade completion. `ensureRunning()` / `restartEngine()` restart the engine on next `activate()`. `activeLayers` is empty at that point → `resumeActiveLayers()` does nothing.
- **Chime preview silent**: `ChimeEngine.schedule()` applies `chimeVolume` (was 0) to all preview chimes. No indication in UI that slider is at 0.
- Fix: `LabeledContent("Chime Volume")` row shows "0% — drag slider to hear preview" in orange when volume is 0.
- **Anchor Tone 200 Hz**: collapses to mono buzz on built-in speaker without headphones.
- Fix: detail label updated to "7 Hz θ binaural · headphones only".
- Session End preview row now calls `EndGongPlayer.shared.playSuccess()` (exact session-end path, was `ChimeEngine.playTimerEnd()` — wrong method).

---

## B91 Validation Checklist

**Pre-test:**
1. Open Settings → Chimes preview. Confirm "Chime Volume" row shows orange "0% — drag slider to hear preview."
2. Drag slider to ~70%. Confirm row updates to "70%."
3. Tap each preview button — all chimes now audible. "Session End" plays bowl_success.wav (8s synthesized bowl).
4. "Anchor Tone" label says "headphones only" — connects Muse headband, tries with headphones.

**Session-end gong:**
5. Run 5-min session. At expiry: hear bowl gong at ≥ 85% volume regardless of chime slider position.
6. Check NDJSON: `gongLifecycle.started` detail includes `_vol0.85` (or higher).
7. No drone after session ends (SoundscapePlayer engine stopped).

**Layout (iPhone 16 Pro Max):**
8. Band chart visible post-calibration (below DepthGaugeView, scrollable if timer+marks+FAA all shown).
9. Timer/Sounds/End buttons normal height (~56pt), not 40% of screen.

**Data:**
10. `session_*.json` has `durationSec`, `summarySampleCount`, `deepFraction` at top level.
11. `session_*.json` has `inDeep > 0` if session reached deep state (adaptive threshold now calibrates by session count).

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

**B83+:**
- `recordEvent` is the canonical event-append site.
- `MuseClient.lastPacketGapMs` atomic static — written on SDK thread, read on any thread.

**B88+:**
- `DepthGate.thresholdConfigured` flag — adaptive threshold set ONCE per session (after calibration, before first frontalContactGood check). Reset in `reset()`.
- `SessionRecord.durationSec/summarySampleCount/deepFraction` are stored properties (not computed) — Codable synthesis includes them.

**B91+:**
- `SoundscapePlayer.stopAll()` stops engine after fade — `resumeActiveLayers()` cannot resurrect nodes post-session.
- `EndGongPlayer.gongVolumeFloor = 0.85` — gong always ≥ 85% regardless of `chimeVolume` UserDefault.

---

## Pending (next build)

1. **EEGDenoiser live-signal wire-in** — replace raw EEG with cleaned in MuseClient.handleEEG. Gated by `eegDenoiseLiveSignal` UserDefault. Trigger: tap-mark validator shows mean(deep)−mean(shallow) gauge gap INCREASES with denoiser ON.
2. **`playTimerEnd()` cleanup** — now dead code (preview row removed). Remove from ChimeEngine + update STATUS/journal.
3. **Contact quality grade nil** — `SessionDiagnostics.contactQualityGrade` may still be nil. Verify from new session.
4. **BowlAudioGenerator quality** — first user hearing of synthesized bowl. Tune amplitude/decay/reverb if thin or harsh.
5. **MainThreadStall blocking-stack** — current capture is post-recovery. MetricKit MXCallStackTree deferred.
6. **fNIRS Gate 13** — HbO/HbR from Optics1-6 (backlog).

---

## How to Resume

1. Read STATUS.md (this file) — canonical.
2. `gh run list --limit 5` — verify CI green.
3. Install TestFlight build from run 25618431186.
4. Run B91 Validation Checklist above.
5. Hard rule: never push without explicit "go" per `MusePlus/CLAUDE.md`.
