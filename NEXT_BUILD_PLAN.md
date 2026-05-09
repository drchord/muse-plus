# MusePlus — Next Build Plan (Post-B83)

**Last updated:** 2026-05-09

## Pre-condition: B83 device validation

Do not start B84 work until B83 ships and produces an NDJSON with:

- `gongLifecycle` events (scheduled→started→completed)
- `audioState` records every 30s
- `uiState.timerHudRendered > 0`
- Per-sample `contactStateTP9/TP10/AF7/AF8` populated (not undefined)
- `packetGapMs` populated per sample
- `event` records matching runtime activity (fits, route changes, etc.)
- `mainStall` count quantifying any "freezing" sensation

If B83 fails any of those, B84 is blocked on B83 hotfix.

---

## B84 — Filter wire-in + B81 carryovers

### Theme

With B83 instrumentation in place, we can finally validate filter benefit objectively against tap-to-mark ground truth. Plus deliver the B81 carryovers that were always queued.

### B84 scope

| # | Feature | Why now | Files |
|---|---|---|---|
| 1 | **Wire `EEGDenoiser` into `handleEEG`** with `denoiseEnabled` UserDefault toggle (default OFF) | B83 collected baseline; B84 enables A/B test via tap-mark validator | `MuseClient.swift`, new `Pipeline/EEGWindowBuffer.swift` |
| 2 | Per-window `_type:"denoiseStats"` NDJSON record | Quantifies alpha-band power preservation, spike RMS reduction, gamma coherence drop | `EEGDenoiser.swift`, `SessionRecorder.swift` |
| 3 | Pre-session fit guide (5 s contact-stable gate before "Start" enables) | B81 carryover; addresses underlying TP9/TP10 physical issue not just UI hysteresis | `App.swift` (new ConnectGate view), `MuseClient` (fit-stability tracker) |
| 4 | Per-session contact-quality grade (A/B/C/F) in summary | B81 carryover; trains user awareness of headband fit | `App.swift` (sessionSummary view), `SessionRecorder` (compute from B83 contactState fields) |
| 5 | Athena auto-preset (`preset1041` MS-03, `preset21` legacy) | B81 carryover | `MuseClient.swift` |
| 6 | XCTest scaffolding for B83 instrumentation + B80 resilience | Prevent regressions before TestFlight | `MusePlusTests/` |
| 7 | Bowl `.m4a` files in `MusePlus/Resources/Sounds/` (drop-in by user) | Replaces 432 Hz synthesis fallback with proper recordings | resources only |

**B84 estimated total:** ~700 LOC across 5-6 files + ~600 LOC tests.

### B84 sub-agent split

- **Agent FILTER-WIRE** — #1, #2 (EEG window buffer, denoise stats emission)
- **Agent FIT** — #3, #4 (pre-session guide + grade)
- **Agent A2** — #5 (Athena auto-preset)
- **Agent TEST** — #6 (XCTest)

Per `feedback_patch_file_workflow.md` — agents emit OLD/NEW patch blocks; Opus integrates.

---

## B85 — Filter expansion (conditional)

**Trigger:** B84's `denoiseStats` records show alpha preservation 0.95-1.05, spike-RMS reduction ≥50%, gamma coherence drop ≥30%, AND tap-mark validator shows mean(deep_marks)−mean(shallow_marks) gauge difference INCREASES with denoiser ON vs OFF.

If those criteria pass on real B84 sessions:

- Add **Riemannian Potato** stage (Barachant & Bonnet 2013) — 4×4 SPD covariance distance from running geometric mean. Flags whole-window failures.
- Add **rASR** stage (Mullen 2015 ASR + Blum 2019 RANSAC calibration) — sample-level reconstruction from clean PCA basis.

If the criteria fail on B84 sessions: revert filter, re-evaluate. **No cargo-culting.**

---

## B86+ — Speculative

| Idea | Notes |
|---|---|
| Apple Watch HRV companion | Cross-validation against Optics7/8 |
| iCloud session sync | Multi-device continuity |
| Adaptive soundscape via depth | Layer mix shifts as depth deepens |
| Trainer mode | Two-headband paired session |
| Deep-learning denoiser benchmark | EEGDfus 2024 vs SWT+Potato+rASR |
| fNIRS OpticsPipeline | Beer-Lambert HbO/HbR from Athena Optics1-6 |

None queued.

---

## Process Discipline (lessons from B82→B83)

- **Data first, theory second.** B82 root-cause changed from "speaker physics" to "sub-resonant on iPhone speaker AND broken instrumentation" only after reading the actual NDJSON. Skip the data-read at your peril.
- **Ship instrumentation BEFORE the fix.** Speculation costs CI builds. B83 ships measurement, not just remediation.
- **No fabrication of facts about what other apps do.** I made unfounded claims about Muse app's internals in early plans. B83 plan dropped them.
- **Filter on validation, not on feel.** EEGDenoiser library is built but not wired until tap-mark validation harness has data. "Adding more layers because they're famous" is not a strategy.
- **Compile gate is CI.** No Mac locally; every push = ~1 build quota. Batch fixes.
- **HARD RULE preserved**: never push without user "go". B83 commits locally only.

---

## Routing reminders (per `feedback_opus_reserve_hard.md`)

- T1 (status check, single-line edit) → Bash/Edit direct, no model call
- T2 (small refactor, format) → `model_router.py --tier T2`
- T3 (multi-step reasoning, 1-file change) → `model_router.py --tier T3` or single Sonnet Agent
- T4 (multi-file feature) → 3-4× parallel Sonnet Agents in worktrees, Opus integrates
- T5 (architectural rewrite) → Opus orchestrator + Sonnet workers

Opus only for T4-T5 orchestration and tricky merges. Drift to Opus for T1-T3 is a failure.
