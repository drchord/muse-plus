# MusePlus — Next Build Plan (Post-B83)

**Last updated:** 2026-05-09 (after audit-loop round 2)

## What B83 actually shipped (corrected)

Items previously listed under "B84 carryovers" that ARE in B83:
- ✅ EEGDenoiser wired (sidecar mode; live-signal replacement still gated for B84)
- ✅ Per-window `denoiseStats` NDJSON
- ✅ Pre-session fit-stability banner (calibration-phase 5-s contact-stable gate)
- ✅ Per-session A/B/C/F contact-quality grade (in `SessionDiagnostics`, computed from
   fit-event rate not HSI-transition rate — corrected metric)
- ✅ Athena auto-preset (already there since pre-B81; STATUS.md was stale)
- ✅ XCTest scaffolding (5 files, 522 LOC)
- ✅ Bowl WAV auto-generation at first launch (`BowlAudioGenerator`)

## Pre-condition: B83 device validation

Do not start B84 until B83 ships and the NDJSON contains:
- `gongLifecycle` (`scheduled` → `started` → `completed` for manual end)
- `audioState` (every 30 s + `endSession-pre-gong` snapshot)
- `audioState.chimeVolumeSetting` ≥ 0.7 at gong-pre snapshot
- `audioState.outputs` showing `["builtInSpeaker"]` confirms speaker route
- `uiState.timerHudRendered` > 0
- Per-sample `contactStateTP9/TP10/AF7/AF8` populated
- `packetGapMs` populated per sample
- `event` records matching runtime activity
- `mainStall` count (0 in healthy session)
- `denoiseStats` records every 1 s (or `bypassReason` when disabled)
- `SessionDiagnostics.contactQualityGrade` and `museModel` populated

If any of those is missing or wrong, B84 is blocked on B83 hotfix.

---

## B84 — Live-signal denoise + filter validation + remaining gaps

| # | Feature | Why | Files |
|---|---|---|---|
| 1 | **Live-signal denoise replacement** (gated by `eegDenoiseLiveSignal` UserDefault, default OFF) | Once tap-mark validator shows benefit, route cleaned packets back through MuseClient → EEGPipeline | `Muse/MuseClient.swift`, `Pipeline/EEGWindowBuffer.swift` |
| 2 | **True Riemannian matrix log via eigendecomposition** for Potato distance | Replaces the B83 log-Euclidean approximation; aligns with Barachant, Andreev & Congedo 2013 prescription | `Pipeline/EEGDenoiser.swift` (extend Jacobi eigendecomp already present) |
| 3 | **Tap-mark validation harness expansion** | Compute `Δ(deep_marks − shallow_marks)` with denoiseEnabled ON vs OFF on the same session. Threshold for promoting to live: >0.05 ECDF-display gap improvement | `analysis/tapmark_validation.js` (extend) |
| 4 | **Bowl `.m4a` drop-in support test** | Confirm `Bundle.main.url(forResource:withExtension:"m4a")` priority works once user adds files | manual test |
| 5 | **`MainThreadStall` blocking-stack capture** via signpost-style watchdog dispatch queue | The B83 implementation captures post-recovery stack only; for actual blocking frames need a parallel queue that snapshots main thread when threshold crossed | `Diagnostics/MainThreadStall.swift` rewrite |
| 6 | **Session-summary card** displaying `contactQualityGrade` and `museModel` to user | Makes B83 grade visible (currently only in saved JSON) | `App.swift` `SessionSummaryView` |
| 7 | **`BowlAudioGenerator` audio-quality validation** | Listen to generated WAVs on device; tune partial mix if they sound thin | manual test + tweak constants |

## B85+ — Conditional, pending B84 evidence

| Item | Trigger |
|---|---|
| Deep-learning denoiser benchmark (EEGDfus 2024) | Only if B84 SWT/Potato/rASR pipeline doesn't show monotonic tap-mark benefit |
| Apple Watch HRV companion | Backlog |
| iCloud session sync | Backlog |
| Adaptive soundscape via depth | Backlog |
| fNIRS OpticsPipeline (Beer-Lambert HbO/HbR) | Backlog |

---

## Process discipline

- **Audit loops are real.** B82 → B83 went through three audit-and-fix rounds before
   landing. The "ship a clean V1" instinct lies; multiple passes are honest.
- **Every claim must trace to a logged metric.** B83 instrumentation overhaul exists
   precisely because B82 had no way to disambiguate hypotheses about audio, HSI, or
   timer rendering.
- **No fabricating algorithm provenance.** Citations must be verifiable. Approximations
   must be clearly labeled as such (B83 Potato uses log-Euclidean direct, not full
   matrix log).
- **HARD RULE preserved**: never push without explicit user "go".

## Routing reminders

- T1–T3 → external models / direct edits
- T4 → 3-4× parallel Sonnet sub-agents in worktrees, Opus integrates
- T5 → Opus orchestrator + Sonnet workers
- Opus only for T4–T5 + tricky merges
