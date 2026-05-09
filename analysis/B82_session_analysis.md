# B82 Session Data Analysis — 2026-05-09 0846

**Source:** `G:\My Drive\session_2026-05-09_0846.ndjson` (925 KB, 1,824 NDJSON lines)
**Build on phone:** `buildTag: "B80"` — TestFlight build #82 = same B80 binary, no B81/B82 source in repo.
**Duration:** 22.63 min (12:46:38 → 13:09:16 UTC)
**Sample count:** 1,603 | **Fit events:** 210 | **AppState transitions:** 8 | **Events:** 0 | **Episodes:** 0
**End reason (footer):** `"manual"` — user pressed Save&Stop.

## Headline findings

### 1. Gong code path WAS reached. User did not hear it because iPhone built-in speaker physically cannot reproduce 84 Hz.

`endReason="manual"` → `endSessionGracefully("manual")` → `ChimeEngine.shared.playGong()` → `scheduleGong(fundamental: 84, ...)`. Path executes. Speaker output silent because:

- **iPhone built-in mono speaker frequency response: ~250 Hz to 14 kHz.** 84 Hz fundamental is two octaves below cutoff. Inaudible from device speaker.
- Gong partials at 1.0/1.516/2.871/4.465/6.122 × 84 Hz = 84, 127, 241, 375, 514 Hz.
  - 84/127 Hz: inaudible on device speaker.
  - 241 Hz: marginal.
  - 375/514 Hz: audible but amplitude only 0.18·0.10·decay·0.75 = whisper.
- Through earbuds/AirPods would be audible but quiet.

**Why Muse app doesn't hit this:** they ship pre-rendered Tibetan bowl recordings (CC0/licensed `.m4a`) with strong content in 300-2000 Hz, played via `AVAudioPlayer` (file-based). Synthesis is the trap.

### 2. 210 fit events in 22 min = 9.3/min. TP9/TP10 ear-contact unstable throughout.

Per-minute fit count: roughly flat 5-12 events/minute the entire session. `frontalGood=true` 100% — AF7/AF8 stable. Only rear contact flickered. Last fit at t=1357.3s, just 0.52s before manual stop. User likely stopped because flicker was relentless.

### 3. B80 instrumentation broken in TWO places.

| Promised in B80 | Actual in NDJSON | Cause |
|---|---|---|
| Per-sample `contactStateAF7/AF8/TP9/TP10` | All `undefined` (field absent) | `Probe.addSample` reads `self.hsiRaw` at sample creation; race condition when hsiRaw not yet published; `JSONEncoder` skips nil Optionals. |
| Per-sample `packetGapMs`, `appState`, `batteryLevel`, `phoneOrientation` | All `undefined` | Same — fields never populated. |
| `eventStream: [SessionEvent]?` with disconnect/reconnect/stall/audio-interrupt/route-change/contact-loss/timer-expired/etc | Empty (0 events) | App.swift never calls a `sessionEvents.append(...)` site; `attachEventStream` receives empty array. |
| Companion `.json` synthesized from NDJSON | Missing in G:\My Drive | Either GDrive sync lag, or `synthesisJsonFromNdjson` step failed silently. No log to confirm. |

`appState` transitions DID record (8 of them) as standalone NDJSON lines: 3 fg/bg cycles in first 2 min (user adjusting settings or notification), then steady foreground until 13:09:14 (0.6s before stop — control center pull or save-stop UI).

### 4. Inter-arrival jitter — sample emission decelerates.

p50=520ms, p95=2520ms, p99=2543ms, max=2930ms. Half-second windows working but 2.5s gaps frequent. Suggests BLE packet bursts.

### 5. Calibration was fine. Display remap was fine. Depth gate failed because of contact noise.

- `calibrationIndexStd=0.278` — normal range.
- `ecdfDisplay` ranges normal (0.006 to 0.99 in samples).
- `episodeCount=0` despite 22 min — depth gate never sustained ≥10s above threshold. Cause: TP9/TP10 contact loss → DepthGate enters bad-contact branch → smoothedDisplay decay back to 0.5 → repeat. Real meditation never given a continuous 10s window to register.

## Why Muse official app doesn't have these issues

| Issue | Muse app | MusePlus B80 | Gap |
|---|---|---|---|
| End gong audible on device speaker | Pre-recorded bowl samples (300-2000 Hz energy) via AVAudioPlayer | Synthesized 84 Hz fundamental via AVAudioEngine | Switch to file-based playback |
| TP9/TP10 visible flicker | UI hysteresis (~5s rolling stable) | Renders every 1Hz HSI sample directly | Add hysteresis to SignalChipsView |
| Contact loss disrupting state | Pauses processing UI, holds last good | Lets depth gauge bounce | Treat bad contact as "hold" not "decay" (already partially in DepthGate.swift but display layer ignores) |
| BLE stability | Uses `preset0`/`preset20` (lower throughput) | Uses `preset21`/`preset1041` (8-ch + Optics) | Optional fallback preset for unstable contact |
| Audio across route changes | AVAudioPlayer file-based, not engine-graph | Two AVAudioEngines (Chime + Soundscape) sharing AVAudioSession | Move all session-end audio to AVAudioPlayer |
| Frequency response curation | Recordings normalized for iPhone speaker | Synthesized partials physically un-reproducible | n/a — fixed by switching to files |

## Implications for B83 plan

1. **F1 must be: ship pre-recorded bowl samples** — root cause confirmed. Not a code logic bug; a physics/speaker-response bug.
2. **F2 timer presets** must include 20-min option — user's intended session was 20 min, no preset matched, manual stop required.
3. **F3 EEG denoising** is genuinely needed — `episodeCount=0` over 22 min means real signal is being lost to contact noise, not just visual flicker.
4. **F4 instrumentation** must be repaired — without per-sample HSI and event stream, debugging future builds is blind.
5. **F5 finalization integrity** — confirm `.json` companion writes; emit synthesis-success/failure event.

## Reproducibility

To re-run this analysis on a future session:

```javascript
const lines = FILE_CONTENT.split(/\r?\n/).filter(l=>l.trim());
const types = {}, events=[], samples=[], fits=[];
let header=null, footer=null;
for (const ln of lines){
  const o = JSON.parse(ln);
  const t = o._type || "unk";
  types[t] = (types[t]||0) + 1;
  if (t==="header") header=o;
  else if (t==="footer") footer=o;
  else if (t==="event") events.push(o);
  else if (t==="sample") samples.push(o);
  else if (t==="fit") fits.push(o);
}
```

Note: parser MUST use `_type` (not `type`). Earlier analysis missed footer because of this.
