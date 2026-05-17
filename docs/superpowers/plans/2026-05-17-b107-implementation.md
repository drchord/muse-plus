# B107 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship B107 with six improvements: NDJSON data integrity, physiologicalScore, adaptive Kalman qD, EEGDenoiser live wire-in (off by default), HRV enhancements, and TrendsView path fix + charts.

**Architecture:** All changes are additive to existing structs/classes. No file splits. Each task is independently buildable. Compile after each task before proceeding.

**Tech Stack:** Swift 5.9, iOS 17+, XCTest (`MusePlusTests/`), XcodeGen (`project.yml` auto-includes all `.swift` in `MusePlus/`)

**Test command (macOS/Xcode required):**
```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MusePlusTests/<TestClassName>
```

**No pushes until user says "go".**

---

## Corrections from spec (verified against live code)

| Spec claim | Reality (verified) |
|------------|-------------------|
| "Add timeOfDay to NDJSONHeader" | Already in NDJSONFooter (line 182) + written in appendFooter (line 923). No change needed. |
| "Add enterThresholdAtSession to NDJSONHeader" | Header written at session START (before calibration). Footer written at session END. Add to footer. |
| "buildTag line 31" | `static let currentBuildTag = "B103"` is at line 330. |
| "KalmanDepth qD line 25" | `private let qD: Float = 0.0022` is at line 23. |
| "sessionBetaMean new field" | `mainBetaMean: Float?` already in SessionRecord line 143. Use directly. |

---

## File Map

| File | Change |
|------|--------|
| `MusePlus/SessionRecorder.swift` | buildTag, NDJSONFooter, SessionRecord fields, attachCalibrationBeta, stallCount, physiologicalScore computation |
| `MusePlus/App.swift` | grace period 45s, attachCalibrationBeta call, adaptive qD wire-in, stall/reconnect counters, denoiser routing |
| `MusePlus/Pipeline/DepthScore.swift` | calibrationEcdfVariance property + finalizeBaseline |
| `MusePlus/Audio/KalmanDepth.swift` | qD: let → var |
| `MusePlus/Audio/DepthGate.swift` | kalman.qD assignment (no struct changes needed) |
| `MusePlus/Pipeline/EEGWindowBuffer.swift` | cleanedBatch PassthroughSubject |
| `MusePlus/Pipeline/HRVPipeline.swift` | SDNN, SD1, SD2, DFA α1, calibrationRmssd |
| `MusePlus/TrendsView.swift` | path fix, TrendRecord expansion, new charts, time-of-day filter |
| `MusePlusTests/KalmanDepthTests.swift` | adaptive qD test |
| `MusePlusTests/SessionRecorderTests.swift` | footer field tests |
| `MusePlusTests/HRVPipelineTests.swift` | new file: SDNN, SD2, DFA α1 tests |

---

## Task 1: buildTag + grace period

**Files:**
- Modify: `MusePlus/SessionRecorder.swift:330`
- Modify: `MusePlus/App.swift:357`

- [ ] **Step 1: Update buildTag**

In `SessionRecorder.swift` line 330:
```swift
// Before:
static let currentBuildTag = "B103"
// After:
static let currentBuildTag = "B107"
```

- [ ] **Step 2: Extend grace period**

In `App.swift` line 357:
```swift
// Before:
DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: gracework)
// After:
DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: gracework)
```

Also update the comment at line 1320:
```swift
// Before:
// B80 (B2): Called when the 30s grace period expires without reconnect.
// After:
// B80/B107: Called when the 45s grace period expires without reconnect.
```

- [ ] **Step 3: Build (compile check)**

Open project in Xcode, Product → Build. Expect: Build Succeeded with 0 errors.

- [ ] **Step 4: Commit**
```bash
git add MusePlus/SessionRecorder.swift MusePlus/App.swift
git commit -m "build(B107): bump buildTag to B107, extend BLE grace period to 45s"
```

---

## Task 2: NDJSONFooter — add enterThresholdAtSession

**Context:** `enterThresholdAtSession` is already written as a mid-session `{_type:"threshold"}` NDJSON record (via `attachEnterThreshold`). Adding it to the footer allows offline scripts to read it from the last line without parsing the full file.

**Files:**
- Modify: `MusePlus/SessionRecorder.swift:175-187` (NDJSONFooter struct)
- Modify: `MusePlus/SessionRecorder.swift:915-932` (appendFooter)
- Modify: `MusePlusTests/SessionRecorderTests.swift`

- [ ] **Step 1: Write failing test**

Add to `MusePlusTests/SessionRecorderTests.swift` (after existing tests):
```swift
func testNDJSONFooterContainsEnterThreshold() throws {
    // This test requires a completed session with a known threshold.
    // We verify the footer line of the most recent NDJSON contains enterThresholdAtSession.
    // Run after a session has been completed with attachEnterThreshold called.
    guard let url = latestNDJSONURL() else {
        // No session file — skip rather than fail (CI has no session data).
        throw XCTSkip("No session NDJSON available")
    }
    let allLines = lines(from: url)
    let footer = allLines.last { $0["_type"] as? String == "footer" }
    XCTAssertNotNil(footer, "Footer line must exist in NDJSON")
    // enterThresholdAtSession added in B107; nil is acceptable for pre-B107 files
    // but the key must be present (even if null) once a B107 session is recorded.
    // We can only assert the key exists in B107 sessions — skip for older files.
    let buildTag = allLines.first { $0["_type"] as? String == "header" }?["buildTag"] as? String
    guard buildTag == "B107" else { throw XCTSkip("Pre-B107 session file") }
    XCTAssertTrue(footer?.keys.contains("enterThresholdAtSession") == true,
                  "Footer must contain enterThresholdAtSession in B107 sessions")
}
```

- [ ] **Step 2: Add field to NDJSONFooter struct**

In `SessionRecorder.swift`, replace lines 175-187:
```swift
private struct NDJSONFooter: Codable {
    var _type = "footer"
    let endDate: String
    let episodeCount: Int
    let sampleCount: Int
    let endReason: String
    let qualityScore: Int?
    let timeOfDay: String?
    let rmssdDepthDelta: Float?
    let meditationIndexCorrelation: Float?
    let warmupFAAMean: Float?
    let mainBetaMean:  Float?
    let enterThresholdAtSession: Float?   // B107: entry threshold active for this session
    let physiologicalScore: Int?          // B107: signal-quality score independent of deep gate
}
```

- [ ] **Step 3: Update appendFooter call**

In `SessionRecorder.swift` at `appendFooter` (line 915), update the `NDJSONFooter` initializer:
```swift
private func appendFooter(rec: SessionRecord, reason: String) {
    let footer = NDJSONFooter(
        _type: "footer",
        endDate:    iso8601.string(from: rec.endDate ?? Date()),
        episodeCount: rec.episodes.count,
        sampleCount:  rec.samples.count,
        endReason:    reason,
        qualityScore: rec.qualityScore,
        timeOfDay:    rec.timeOfDay,
        rmssdDepthDelta: rec.rmssdDepthDelta,
        meditationIndexCorrelation: rec.meditationIndexCorrelation,
        warmupFAAMean: rec.warmupFAAMean,
        mainBetaMean:  rec.mainBetaMean,
        enterThresholdAtSession: rec.enterThresholdAtSession,
        physiologicalScore: rec.physiologicalScore
    )
    appendLine(footer)
    ndjsonHandle?.synchronizeFile()
    Telemetry.recording.notice("NDJSON footer written: samples=\(rec.samples.count, privacy: .public) quality=\(rec.qualityScore.map(String.init) ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
}
```

Note: `physiologicalScore` is added here but not yet in `SessionRecord` — add a placeholder `var physiologicalScore: Int? = nil` to `SessionRecord` (line 146, after `warmupFAAMean`) to compile:
```swift
// B107 — signal-quality score independent of deep-gate binary.
var physiologicalScore: Int? = nil
```

- [ ] **Step 4: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 5: Commit**
```bash
git add MusePlus/SessionRecorder.swift MusePlusTests/SessionRecorderTests.swift
git commit -m "feat(B107): add enterThresholdAtSession + physiologicalScore to NDJSONFooter"
```

---

## Task 3: SessionRecord — add calibrationBetaMean + attachCalibrationBeta

**Context:** `DepthScore.calibrationBetaMean` and `calibrationBetaStd` exist as `private(set)` properties but are not in `SessionRecord`. The physiologicalScore betaZ formula requires them. `mainBetaMean` already in `SessionRecord` (line 143) serves as session beta.

**Files:**
- Modify: `MusePlus/SessionRecorder.swift` (SessionRecord struct, new attach method)
- Modify: `MusePlus/App.swift` (calibrationFiredRecording block)
- Modify: `MusePlusTests/SessionRecorderTests.swift`

- [ ] **Step 1: Write failing test**

Add to `SessionRecorderTests.swift`:
```swift
func testAttachCalibrationBeta() throws {
    // attachCalibrationBeta must store values in the rec object.
    // We test the public interface: after calling it, endSession JSON contains the fields.
    // This test uses the recorder's existing test infrastructure.
    // Skip if no session running (no way to trigger calibration in unit test).
    throw XCTSkip("Requires live session — verify manually post-B107")
    // Placeholder: after B107 session, open .json file and confirm
    // calibrationBetaMean != nil and calibrationBetaStd != nil.
}
```

(Test is skeletal — calibration requires real EEG data. The important test is the compile check and manual verification.)

- [ ] **Step 2: Add fields to SessionRecord**

In `SessionRecorder.swift`, after line 145 (`var warmupFAAMean: Float? = nil`), add:
```swift
// B107 — calibration-phase beta baseline for physiologicalScore betaZ computation.
var calibrationBetaMean: Float? = nil
var calibrationBetaStd:  Float? = nil
```

- [ ] **Step 3: Add attachCalibrationBeta method**

In `SessionRecorder.swift`, after the `attachEnterThreshold` method (after line 1294):
```swift
func attachCalibrationBeta(mean: Float, std: Float) {
    queue.sync {
        guard isRecording else { return }
        current?.calibrationBetaMean = mean
        current?.calibrationBetaStd  = std
        Telemetry.recording.notice("calibrationBeta attached: mean=\(mean, privacy: .public) std=\(std, privacy: .public)")
    }
}
```

- [ ] **Step 4: Call attachCalibrationBeta from App.swift**

In `App.swift`, inside the `calibrationFiredRecording` block. The block starts at line 806 (`if result.isCalibrated && !self.calibrationFiredRecording`). Add this immediately after `attachEnterThreshold` at line 1112 — but that's in `endSessionGracefully`. The calibration fire block is at line 806. Find the matching `attachEnterThreshold` call pattern in that same block:

Actually, `attachEnterThreshold` is called in `endSessionGracefully` (line 1112), not in the calibrationFiredRecording block. The calibrationFiredRecording block (lines 806-~900) is where we should call `attachCalibrationBeta`. Add it right after `self.calibrationFiredRecording = true` at line 807:

```swift
if result.isCalibrated && !self.calibrationFiredRecording {
    self.calibrationFiredRecording = true
    // B107: capture calibration beta baseline for physiologicalScore
    SessionRecorder.shared.attachCalibrationBeta(
        mean: self.scorer.calibrationBetaMean,
        std:  self.scorer.calibrationBetaStd
    )
    // ... rest of existing block unchanged
```

- [ ] **Step 5: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 6: Commit**
```bash
git add MusePlus/SessionRecorder.swift MusePlus/App.swift MusePlusTests/SessionRecorderTests.swift
git commit -m "feat(B107): add calibrationBetaMean to SessionRecord + attachCalibrationBeta"
```

---

## Task 4: SessionRecord — stallCount + bleReconnectCount

**Context:** BLE stalls are untracked. Today's 33.4s stall (which terminated the session) would have been recorded as `stallCount=1`.

**Files:**
- Modify: `MusePlus/SessionRecorder.swift` (SessionRecord struct)
- Modify: `MusePlus/App.swift` (grace period handler + reconnect handler)

- [ ] **Step 1: Add fields to SessionRecord**

In `SessionRecorder.swift`, after `var calibrationBetaStd: Float? = nil` (from Task 3), add:
```swift
// B107 — BLE resilience counters.
var stallCount:        Int? = nil   // BLE interruptions >0s that triggered grace period
var bleReconnectCount: Int? = nil   // successful reconnects during session
```

- [ ] **Step 2: Add increment methods to SessionRecorder**

After `attachCalibrationBeta` (from Task 3), add:
```swift
func recordBLEStall() {
    queue.async { [self] in
        guard isRecording else { return }
        current?.stallCount = (current?.stallCount ?? 0) + 1
    }
}

func recordBLEReconnect() {
    queue.async { [self] in
        guard isRecording else { return }
        current?.bleReconnectCount = (current?.bleReconnectCount ?? 0) + 1
    }
}
```

- [ ] **Step 3: Call recordBLEStall in App.swift**

Find where grace period work item is set up (around line 357). The grace work is a `DispatchWorkItem`. Add the stall record call right before `gracework` is created, at the point where we know a BLE disconnect happened during recording. The relevant block is where `gracePeriodWork = gracework` is set (line 356). Add `SessionRecorder.shared.recordBLEStall()` after line 355 (the disconnect detection):

```swift
// B107: record stall for post-session analysis
SessionRecorder.shared.recordBLEStall()
self?.gracePeriodWork = gracework
DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: gracework)
```

- [ ] **Step 4: Call recordBLEReconnect in App.swift**

Verified at App.swift lines 281-286: the reconnect path cancels `gracePeriodWork` inside `isPausedForReconnect == true`. Add after line 284 (`self?.gracePeriodWork = nil`):

```swift
// App.swift — inside isPausedForReconnect block, after gracePeriodWork = nil:
self?.gracePeriodWork?.cancel()
self?.gracePeriodWork = nil
SessionRecorder.shared.recordBLEReconnect()  // B107: ADD THIS LINE
self?.isPausedForReconnect = false
self?.gracePeriodStarted = nil
```

- [ ] **Step 5: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 6: Commit**
```bash
git add MusePlus/SessionRecorder.swift MusePlus/App.swift
git commit -m "feat(B107): track BLE stallCount + bleReconnectCount per session"
```

---

## Task 5: physiologicalScore — computation in endSession

**Context:** Compute physiologicalScore (0–100) at session end using betaZ + rmssdResponse + signalCoherence. All inputs are already available in `SessionRecord` by the time `appendFooter` is called.

**Note on rmssdResponse:** This requires `calibrationRmssd` from HRVPipeline (implemented in Task 11). In this task, implement the score but stub `calibrationRmssd` as 0.0 until Task 11 wires it in. The betaZ and signalCoherence components work immediately.

**Files:**
- Modify: `MusePlus/SessionRecorder.swift` (endSession, before appendFooter)

- [ ] **Step 1: Locate insertion point**

In `SessionRecorder.swift`, the `appendFooter(rec: rec, reason: reason)` call is at line 521. The score computation must go before it. Find the block that computes `qualityScore` (around lines 452-473) and add physiologicalScore computation immediately after.

- [ ] **Step 2: Add physiologicalScore computation**

After the existing `qualityScore` computation block (after the line that sets `rec.qualityScore`), add:
```swift
// B107: physiologicalScore — independent of deep-gate binary.
// betaZ: calibration vs session frontal beta suppression (0-50)
// rmssdResponse: HRV increase vs calibration baseline (0-30)
// signalCoherence: frontal contact quality (0-20)
let physScore: Int = {
    // Component 1: betaZ (0-50)
    let betaZScore: Float
    if let calBeta = rec.calibrationBetaMean,
       let calBetaStd = rec.calibrationBetaStd,
       let sessBeta = rec.mainBetaMean,
       calBetaStd > 0 {
        let bz = (calBeta - sessBeta) / max(calBetaStd, 0.10)
        betaZScore = min(max(bz / 2.0 * 50.0, 0.0), 50.0)
    } else {
        betaZScore = 0.0
    }
    // Component 2: rmssdResponse (0-30)
    // calibrationRmssd comes from HRVPipeline via attachCalibrationRmssd (Task 11).
    // Until then, rec.calibrationRmssd is nil → component contributes 0.
    let rmssdScore: Float
    if let sessRmssd = rec.rmssd,
       let calRmssd = rec.calibrationRmssd,
       calRmssd > 1.0 {
        let response = (Double(sessRmssd) - calRmssd) / calRmssd
        rmssdScore = Float(min(max(response * 30.0, 0.0), 30.0))
    } else {
        rmssdScore = 0.0
    }
    // Component 3: signalCoherence (0-20) — frontalGoodFrac already computed above
    let coherenceScore = frontalGoodFrac * 20.0
    return Int((betaZScore + rmssdScore + coherenceScore).rounded())
}()
rec.physiologicalScore = physScore
```

- [ ] **Step 3: Add `calibrationRmssd` and `rmssd` to SessionRecord**

These are referenced in the code above. `rmssd` (session mean RMSSD) is NOT currently in `SessionRecord` (only in `SessionSample`). Add both fields after `bleReconnectCount` (from Task 4):
```swift
// B107 — session-level HRV scalars for physiologicalScore and TrendsView.
var rmssd:            Double? = nil   // mean RMSSD over main phase (ms)
var calibrationRmssd: Double? = nil   // mean RMSSD during calibration window (ms)
```

And populate `rec.rmssd` from existing RMSSD samples. In `endSession`, `rmssd` values are stored per-sample in `SessionSample.rmssd`. Compute the mean over main-phase samples:
```swift
// B107: session-level RMSSD mean (main phase)
let mainRMSSD = rec.samples
    .filter { $0.phase == "main" }
    .compactMap { $0.rmssd }
    .filter { $0 > 0 }
if !mainRMSSD.isEmpty {
    rec.rmssd = mainRMSSD.reduce(0, +) / Double(mainRMSSD.count)
}
```

Place this block before the physiologicalScore computation above.

- [ ] **Step 4: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 5: Commit**
```bash
git add MusePlus/SessionRecorder.swift
git commit -m "feat(B107): compute physiologicalScore at session end"
```

---

## Task 6: DepthScore — calibrationEcdfVariance

**Context:** Per-session calibration variance drives the adaptive Kalman qD. Must be computed BEFORE `calibrationSamples` is cleared inside `finalizeBaseline()`.

**Files:**
- Modify: `MusePlus/Pipeline/DepthScore.swift`

- [ ] **Step 1: Add property**

In `DepthScore.swift`, after `calibrationBetaStd` (line 23), add:
```swift
private(set) var calibrationEcdfVariance: Float = 0.0
```

Also add reset in `startCalibration()` (after line 48):
```swift
calibrationEcdfVariance = 0.0
```

- [ ] **Step 2: Compute in finalizeBaseline()**

In `finalizeBaseline()`, `baselineStd` is computed from MAD×1.4826 (line 147). Add the variance computation immediately after that line, BEFORE any array clearing:
```swift
baselineStd = max(mad * 1.4826, 0.10)

// B107: variance proxy for adaptive Kalman qD.
// Must be set BEFORE calibrationSamples = [] below.
calibrationEcdfVariance = baselineStd * baselineStd
```

Verify: `calibrationSamples = []` appears at line 151 (after `calibrationIndexStd` assignments). The new line goes after line 147 (baselineStd computation), before line 151. The existing code in that region:
```swift
baselineStd = max(mad * 1.4826, 0.10)      // line 147 — ADD AFTER THIS
calibrationIndexMean = baselineMean         // line 149
calibrationIndexStd  = baselineStd         // line 150
calibrationSamples   = []                  // line 151 — MUST REMAIN AFTER new line
```

- [ ] **Step 3: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 4: Commit**
```bash
git add MusePlus/Pipeline/DepthScore.swift
git commit -m "feat(B107): add calibrationEcdfVariance to DepthScore for adaptive Kalman qD"
```

---

## Task 7: Adaptive Kalman qD

**Context:** Wire `calibrationEcdfVariance` from DepthScore into KalmanDepth.qD at calibration end. Bounded to [0.0005, 0.020].

**Files:**
- Modify: `MusePlus/Audio/KalmanDepth.swift:23`
- Modify: `MusePlus/App.swift` (calibrationFiredRecording block)
- Modify: `MusePlusTests/KalmanDepthTests.swift`

- [ ] **Step 1: Write failing test**

Add to `KalmanDepthTests.swift`:
```swift
func testQDMutable() {
    var k = KalmanDepth()
    let originalQD = k.qD
    k.qD = 0.010
    XCTAssertEqual(k.qD, 0.010, accuracy: 0.0001, "qD must be mutable")
    XCTAssertNotEqual(k.qD, originalQD)
}

func testHigherQDTracksFaster() {
    var kSlow = KalmanDepth()
    kSlow.qD = 0.0005
    var kFast = KalmanDepth()
    kFast.qD = 0.015
    // Feed 10 sudden-jump observations
    for _ in 0..<10 { _ = kSlow.update(z: 0.9) }
    for _ in 0..<10 { _ = kFast.update(z: 0.9) }
    XCTAssertGreaterThan(kFast.depth, kSlow.depth,
                         "Higher qD should track faster (closer to 0.9 after 10 steps)")
}
```

- [ ] **Step 2: Run test to verify failure**

```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MusePlusTests/KalmanDepthTests/testQDMutable
```
Expected: FAIL — `'qD' is inaccessible due to 'private' protection level`

- [ ] **Step 3: Make qD mutable in KalmanDepth.swift**

In `KalmanDepth.swift` line 23:
```swift
// Before:
private let qD:             Float = 0.0022
// After:
var qD:                     Float = 0.0022
```

- [ ] **Step 4: Run tests to verify pass**
```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MusePlusTests/KalmanDepthTests
```
Expected: All KalmanDepthTests PASS.

- [ ] **Step 5: Wire adaptive qD in App.swift**

In `App.swift`, inside the `calibrationFiredRecording` block, after `attachCalibrationBeta` (added in Task 3), add:
```swift
// B107: adaptive Kalman qD from calibration variance.
// Clamped to [0.0005, 0.020]: prevents over-smoothing and runaway tracking.
let adaptiveQD = min(max(self.scorer.calibrationEcdfVariance * 0.01, 0.0005), 0.020)
self.gate.kalman.qD = adaptiveQD
Telemetry.recording.notice("B107 adaptiveQD=\(adaptiveQD, privacy: .public) ecdfVar=\(self.scorer.calibrationEcdfVariance, privacy: .public)")
```

Note: `gate` is the `DepthGate` instance in App.swift. Verify the property name by checking App.swift: `grep -n "private var gate\|let gate\|DepthGate()" App.swift`.

- [ ] **Step 6: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 7: Commit**
```bash
git add MusePlus/Audio/KalmanDepth.swift MusePlus/App.swift MusePlusTests/KalmanDepthTests.swift
git commit -m "feat(B107): adaptive Kalman qD from calibration ECDF variance"
```

---

## Task 8: EEGDenoiser live wire-in

**Context:** EEGDenoiser is fully implemented (1133 lines, NOT a stub). Runs as sidecar via `EEGWindowBuffer.shared`. `denoiser.denoise(window:)` returns `(cleaned: [[Float]], stats: EEGDenoiseStats)` — verified at EEGDenoiser.swift line 210. The raw EEG path uses `Set<AnyCancellable>` bag (App.swift line 147) — cannot cancel individually. Raw path is gated by UserDefault cached once at session start.

**Important:** `EEGPipeline.process(_ packet: EEGPacket)` expects per-packet calls. Cleaned output is `[[Float]]` (4 channels × 256 samples). Add `EEGPipeline.processCleanedWindow()` to accept it directly.

**Files:**
- Modify: `MusePlus/Pipeline/EEGWindowBuffer.swift`
- Modify: `MusePlus/Pipeline/EEGPipeline.swift`
- Modify: `MusePlus/App.swift`

- [ ] **Step 1: Add cleanedBatch publisher to EEGWindowBuffer**

EEGWindowBuffer.swift — add Combine import after Foundation:
```swift
import Combine
import Foundation
```

Add property after `latestAlphaPowerRatio` (line 55):
```swift
let cleanedBatch = PassthroughSubject<[[Float]], Never>()
```

In `processWindowLocked()` (line 129), the denoise call is:
```swift
let result = denoiser.denoise(window: window)
```
Add immediately after that line:
```swift
cleanedBatch.send(result.cleaned)   // B107: emit for live-path subscribers
```

- [ ] **Step 2: Add processCleanedWindow to EEGPipeline.swift**

In `EEGPipeline.swift`, add after `process(_ packet:)`:
```swift
// B107: accepts a pre-denoised 4-channel × 256-sample window directly.
// Bypasses per-packet accumulation. Uses current time as window timestamp.
func processCleanedWindow(_ channels: [[Float]]) {
    guard channels.count >= 4, channels[0].count == EEGPipeline.windowSize else { return }
    // Replace buffer contents with cleaned window
    for ch in 0..<min(channels.count, 8) {
        buffers[ch] = Array(channels[ch])
    }
    activeChannelCount = max(activeChannelCount, channels.count)
    let ts = Date().timeIntervalSinceReferenceDate
    var allPowers = [BandPowers]()
    var allPSDs   = [[Float]]()
    for ch in 0..<activeChannelCount {
        let (psd, bp) = computeWindow(Array(buffers[ch].prefix(EEGPipeline.windowSize)),
                                       channel: ch, timestamp: ts)
        allPowers.append(bp)
        allPSDs.append(psd)
    }
    for ch in 0..<activeChannelCount {
        buffers[ch].removeFirst(EEGPipeline.hopSize)
    }
    // Reuse existing IRASA + DepthScore dispatch path
    dispatchPowers(allPowers, psds: allPSDs, timestamp: ts)
}
```

**Prerequisite:** Verify `EEGPipeline.windowSize`, `hopSize`, `computeWindow()`, and `dispatchPowers()` are accessible from this new method (all are `private` — change to `private` or `fileprivate` as needed, or make `processCleanedWindow` a private extension within the same file). If `dispatchPowers` doesn't exist as a separate method, extract it from `process()` first — read the file to confirm the exact refactor needed.

- [ ] **Step 3: Gate raw path in App.swift**

The raw EEG sink is at App.swift lines 451-461, in `Set<AnyCancellable>` bag. Add a cached gate property:
```swift
private var liveDenoiseEnabled = false
```

Set at session start (in the `calibrationFiredRecording` block or wherever session starts):
```swift
liveDenoiseEnabled = UserDefaults.standard.bool(forKey: "eegDenoiseLiveSignal")
```

Modify the existing raw sink (lines 451-461):
```swift
client.eegPacket
    .receive(on: RunLoop.main)
    .sink { [weak self] pkt in
        guard let self else { return }
        self.lastEEG = pkt.channels
        self.packetCount += 1
        guard !self.liveDenoiseEnabled else { return }  // B107: skip raw when live denoiser active
        self.pipeline.process(pkt)
        LivenessWatchdog.shared.packetReceived()
    }
    .store(in: &bag)
```

Add cleaned-batch subscription alongside the existing subscriptions (also `.store(in: &bag)`):
```swift
EEGWindowBuffer.shared.cleanedBatch
    .receive(on: RunLoop.main)
    .sink { [weak self] channels in
        guard let self, self.liveDenoiseEnabled else { return }
        self.pipeline.processCleanedWindow(channels)
        LivenessWatchdog.shared.packetReceived()
    }
    .store(in: &bag)
```

**Invariant:** At any moment, exactly one path feeds `pipeline`. The `liveDenoiseEnabled` flag is checked in both sinks — raw path skips when true, cleaned path skips when false.

- [ ] **Step 4: Build — check dispatchPowers refactor first**

Before building, read EEGPipeline.swift from line 75 to the end of `process()` to confirm `dispatchPowers` extraction is correct. If the pipeline's power dispatch is inline in `process()`, extract it to a private method and call it from both `process()` and `processCleanedWindow()`.

Product → Build. Expect: Build Succeeded.

- [ ] **Step 5: Commit**
```bash
git add MusePlus/Pipeline/EEGWindowBuffer.swift \
        MusePlus/Pipeline/EEGPipeline.swift \
        MusePlus/App.swift
git commit -m "feat(B107): EEGDenoiser cleanedBatch + processCleanedWindow + UserDefault gate (off by default)"
```

**Note:** `liveDenoiseEnabled` defaults `false`. Enable via debugger: `UserDefaults.standard.set(true, forKey: "eegDenoiseLiveSignal")`. Not exposed in Settings UI until ground truth validated.
```

**Invariant:** At any moment, exactly one of `rawEEGSub` or `liveDenoiseSub` is active. Never both.

- [ ] **Step 3: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 4: Commit**
```bash
git add MusePlus/Pipeline/EEGWindowBuffer.swift MusePlus/App.swift
git commit -m "feat(B107): EEGDenoiser cleanedBatch publisher + UserDefault gate (off by default)"
```

---

## Task 9: HRV — SDNN + SD1 + SD2

**Files:**
- Modify: `MusePlus/Pipeline/HRVPipeline.swift`
- Create: `MusePlusTests/HRVPipelineTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MusePlusTests/HRVPipelineTests.swift`:
```swift
import XCTest
@testable import MusePlus

final class HRVPipelineTests: XCTestCase {

    // Known RR series (seconds). Hand-computed ground truth:
    // RR = [0.8, 0.9, 0.7, 0.85, 0.75, 0.82, 0.78, 0.88, 0.72, 0.84]
    // mean = 0.814
    // SDNN = std(RR) = sqrt(mean of squared deviations)
    // diffs = [0.1, -0.2, 0.15, -0.1, 0.07, -0.04, 0.1, -0.16, 0.12]
    // squared diffs = [0.01, 0.04, 0.0225, 0.01, 0.0049, 0.0016, 0.01, 0.0256, 0.0144]
    // RMSSD = sqrt(mean) = sqrt(0.01611) ≈ 0.1269 s = 126.9 ms
    // SDNN = sqrt(var(RR)) — computed below

    private let testRR: [Double] = [0.8, 0.9, 0.7, 0.85, 0.75, 0.82, 0.78, 0.88, 0.72, 0.84]

    func testSDNN() {
        let mean = testRR.reduce(0, +) / Double(testRR.count)
        let variance = testRR.map { pow($0 - mean, 2) }.reduce(0, +) / Double(testRR.count)
        let expectedSDNN = sqrt(variance)  // ≈ 0.0614 s
        // Invoke HRVPipeline's internal SDNN method (exposed via @testable import)
        let computed = HRVPipeline.computeSDNN(testRR)
        XCTAssertEqual(computed, expectedSDNN, accuracy: 0.0001, "SDNN must match hand-computed value")
    }

    func testSD1() {
        // SD1 = RMSSD / sqrt(2)
        let diffs = zip(testRR.dropFirst(), testRR).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let expectedSD1 = rmssd / sqrt(2.0)
        let computed = HRVPipeline.computeSD1(testRR)
        XCTAssertEqual(computed!, expectedSD1, accuracy: 0.0001)
    }

    func testSD2() {
        // SD2 = sqrt(2·SDNN² − RMSSD²/2)
        let mean = testRR.reduce(0, +) / Double(testRR.count)
        let sdnn = sqrt(testRR.map { pow($0 - mean, 2) }.reduce(0, +) / Double(testRR.count))
        let diffs = zip(testRR.dropFirst(), testRR).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let inner = 2 * pow(sdnn, 2) - pow(rmssd, 2) / 2
        XCTAssertGreaterThan(inner, 0, "inner must be positive for healthy RR series")
        let expectedSD2 = sqrt(inner)
        let computed = HRVPipeline.computeSD2(testRR)
        XCTAssertEqual(computed!, expectedSD2, accuracy: 0.0001)
    }

    func testSD2NilOnNegativeInner() {
        // Pathological series where 2·SDNN² < RMSSD²/2 (all identical values except last)
        let degenerate = [Double](repeating: 0.8, count: 9) + [1.5]
        XCTAssertNil(HRVPipeline.computeSD2(degenerate), "SD2 must be nil if inner term is negative")
    }
}
```

- [ ] **Step 2: Add static helper methods to HRVPipeline.swift**

These are `static` so they can be called by tests without a live pipeline. Add after the `computeLFHF` method:

```swift
// MARK: - Poincaré / SDNN (B107)

static func computeSDNN(_ rr: [Double]) -> Double {
    guard rr.count >= 2 else { return 0 }
    let mean = rr.reduce(0, +) / Double(rr.count)
    let variance = rr.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rr.count)
    return sqrt(variance)
}

static func computeSD1(_ rr: [Double]) -> Double? {
    guard rr.count >= 2 else { return nil }
    let diffs = zip(rr.dropFirst(), rr).map { pow($0 - $1, 2) }
    let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
    return rmssd / sqrt(2.0)
}

static func computeSD2(_ rr: [Double]) -> Double? {
    guard rr.count >= 2 else { return nil }
    let sdnn = computeSDNN(rr)
    let diffs = zip(rr.dropFirst(), rr).map { pow($0 - $1, 2) }
    let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
    let inner = 2 * pow(sdnn, 2) - pow(rmssd, 2) / 2
    guard inner >= 0 else { return nil }
    return sqrt(inner)
}
```

- [ ] **Step 3: Expose results via onRMSSD callback or new callback**

The existing `onRMSSD: ((Double, Double?) -> Void)?` carries `(rmssd, lfhf)`. To add SDNN/SD1/SD2 without breaking the existing callback signature, add a new callback:

```swift
// B107: fires with extended HRV metrics alongside onRMSSD
var onHRVExtended: ((sdnn: Double, sd1: Double, sd2: Double?) -> Void)?
```

In `runAMPD()`, after computing `rmssd` and `lfhf`, compute and fire:
```swift
let sdnn = Self.computeSDNN(cleanRR)
let sd1  = Self.computeSD1(cleanRR) ?? rmssd / sqrt(2.0)
let sd2  = Self.computeSD2(cleanRR)

DispatchQueue.main.async { [weak self] in
    self?.onRMSSD?(rmssd, lfhf)
    if let sd2 = sd2 {
        self?.onHRVExtended?((sdnn: sdnn, sd1: sd1, sd2: sd2))
    }
}
```

- [ ] **Step 4: Run tests**
```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MusePlusTests/HRVPipelineTests
```
Expected: All 4 HRVPipelineTests PASS.

- [ ] **Step 5: Build full project**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 6: Store session-level SDNN/SD2 in SessionRecord**

Add to `SessionRecord` (after `dfaAlpha1` placeholder — add the field even though DFA is in Task 10, to avoid double-editing):
```swift
var sdnn:   Double? = nil
var sd1:    Double? = nil
var sd2:    Double? = nil
var dfaAlpha1: Double? = nil   // populated in Task 10
```

Add session-level scalars to HRVPipeline:
```swift
private(set) var latestSDNN: Double = 0.0
private(set) var latestSD1:  Double = 0.0
private(set) var latestSD2:  Double?
```

Update in `runAMPD()` after computing SDNN/SD1/SD2:
```swift
latestSDNN = sdnn
latestSD1  = sd1
latestSD2  = sd2
```

Add `attachHRVScalars` to SessionRecorder (same pattern as other attach methods):
```swift
func attachHRVScalars(sdnn: Double, sd1: Double, sd2: Double?) {
    queue.async { [self] in
        guard isRecording else { return }
        current?.sdnn = sdnn
        current?.sd1  = sd1
        current?.sd2  = sd2
    }
}
```

In App.swift's `endSessionGracefully`, before `endSession()`:
```swift
SessionRecorder.shared.attachHRVScalars(
    sdnn: hrv.latestSDNN,
    sd1:  hrv.latestSD1,
    sd2:  hrv.latestSD2
)
```

- [ ] **Step 7: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 8: Commit**
```bash
git add MusePlus/Pipeline/HRVPipeline.swift \
        MusePlus/SessionRecorder.swift \
        MusePlus/App.swift \
        MusePlusTests/HRVPipelineTests.swift
git commit -m "feat(B107): add SDNN, SD1, SD2 to HRVPipeline (Brennan 2002)"
```

---

## Task 10: HRV — DFA α1

**Context:** Short-range fractal scaling exponent (Peng et al. 1995). Box sizes n=4–16 beats. Returns nil if RR count < 200. Per session total (not per window) — computed at session end.

**Files:**
- Modify: `MusePlus/Pipeline/HRVPipeline.swift`
- Modify: `MusePlusTests/HRVPipelineTests.swift`
- Modify: `MusePlus/SessionRecorder.swift` (add dfaAlpha1 to SessionRecord, compute at endSession)

- [ ] **Step 1: Write failing tests**

Add to `HRVPipelineTests.swift`:
```swift
func testDFAAlpha1NilUnder200() {
    // 100 RR intervals — must return nil
    let shortRR = [Double](repeating: 0.8, count: 100)
    XCTAssertNil(HRVPipeline.computeDFAAlpha1(shortRR),
                 "DFA α1 must return nil for RR count < 200")
}

func testDFAAlpha1HealthyRange() {
    // 1/f noise has α1 ≈ 1.0. We use a correlated series:
    // Generate 300 RR using AR(1) with φ=0.9 (strong positive autocorrelation).
    var rr = [Double]()
    var prev = 0.8
    for _ in 0..<300 {
        prev = 0.9 * prev + 0.08 + Double.random(in: -0.005...0.005)
        rr.append(max(0.4, min(1.5, prev)))
    }
    guard let alpha = HRVPipeline.computeDFAAlpha1(rr) else {
        XCTFail("DFA α1 must not be nil for n=300")
        return
    }
    // AR(1) with high φ → α1 in range [0.8, 1.5]
    XCTAssertGreaterThan(alpha, 0.5, "α1 must be > 0.5 for correlated series")
    XCTAssertLessThan(alpha, 2.0, "α1 must be < 2.0 (not super-diffusive)")
}
```

- [ ] **Step 2: Implement computeDFAAlpha1**

Add to `HRVPipeline.swift` after `computeSD2`:
```swift
// DFA α1: short-range scaling exponent (Peng et al. 1995).
// Box sizes 4-16 beats cover the short-range (sympathetic) window.
// Returns nil if fewer than 200 RR intervals (insufficient for reliable estimate).
static func computeDFAAlpha1(_ rr: [Double]) -> Double? {
    guard rr.count >= 200 else { return nil }
    let n = rr.count
    let mean = rr.reduce(0, +) / Double(n)

    // Integrate: y[k] = sum_{i=1..k}(RR[i] - mean)
    var y = [Double](repeating: 0, count: n)
    var cum = 0.0
    for i in 0..<n {
        cum += rr[i] - mean
        y[i] = cum
    }

    let boxSizes = [4, 5, 6, 8, 10, 12, 16]
    var logN = [Double]()
    var logF = [Double]()

    for boxLen in boxSizes {
        guard boxLen <= n / 4 else { continue }
        let numBoxes = n / boxLen
        guard numBoxes >= 4 else { continue }
        var sumSq = 0.0
        var count = 0
        for b in 0..<numBoxes {
            let start = b * boxLen
            let end   = start + boxLen
            let segment = Array(y[start..<end])
            // Linear detrend via least-squares fit
            let xi = (0..<boxLen).map { Double($0) }
            let xm = Double(boxLen - 1) / 2.0
            let ym = segment.reduce(0, +) / Double(boxLen)
            let num = zip(xi, segment).map { ($0 - xm) * ($1 - ym) }.reduce(0, +)
            let den = xi.map { pow($0 - xm, 2) }.reduce(0, +)
            guard den > 0 else { continue }
            let slope = num / den
            let intercept = ym - slope * xm
            for i in 0..<boxLen {
                let trend = slope * Double(i) + intercept
                sumSq += pow(segment[i] - trend, 2)
                count += 1
            }
        }
        guard count > 0 else { continue }
        let F = sqrt(sumSq / Double(count))
        guard F > 0 else { continue }
        logN.append(log(Double(boxLen)))
        logF.append(log(F))
    }

    guard logN.count >= 3 else { return nil }

    // OLS slope of log(F) vs log(n)
    let xm = logN.reduce(0, +) / Double(logN.count)
    let ym = logF.reduce(0, +) / Double(logF.count)
    let num = zip(logN, logF).map { ($0 - xm) * ($1 - ym) }.reduce(0, +)
    let den = logN.map { pow($0 - xm, 2) }.reduce(0, +)
    guard den > 0 else { return nil }
    return num / den
}
```

- [ ] **Step 3: Accumulate full-session RR in HRVPipeline**

DFA requires the full session RR array. Add storage:
```swift
private var sessionRR: [Double] = []
```

In `runAMPD()`, after computing `cleanRR`, append to session array:
```swift
sessionRR.append(contentsOf: cleanRR)
```

Add public method to retrieve and reset:
```swift
func extractSessionRR() -> [Double] {
    let rr = sessionRR
    sessionRR = []
    return rr
}
```

Reset `sessionRR` in `reset()`:
```swift
func reset() {
    queue.async { [self] in
        rawBuffer.removeAll()
        updateCounter = 0
        sessionRR.removeAll()
    }
}
```

- [ ] **Step 4: Compute dfaAlpha1 at session end in SessionRecorder**

Add `dfaAlpha1: Double? = nil` to SessionRecord (after `calibrationRmssd`):
```swift
var dfaAlpha1: Double? = nil
```

In `endSession()`, before `appendFooter`, add:
```swift
// B107: DFA α1 from full-session RR
let sessionRR = hrv.extractSessionRR()  // hrv passed as parameter — see below
if let alpha = HRVPipeline.computeDFAAlpha1(sessionRR) {
    rec.dfaAlpha1 = alpha
}
```

**Important:** `endSession()` is on the `SessionRecorder.queue`. `hrv` (HRVPipeline) is owned by App.swift. Two options:
1. Pass the RR array in via `attachSessionRR(_ rr: [Double])` — same pattern as other attach methods
2. Call `hrv.extractSessionRR()` in App.swift before calling `endSession()` and attach the result

Option 2 is simpler and avoids threading complexity. Add to `SessionRecorder`:
```swift
func attachDFAAlpha1(_ alpha: Double) {
    queue.async { [self] in
        current?.dfaAlpha1 = alpha
    }
}
```

In App.swift's `endSessionGracefully`, before the `endSession()` call:
```swift
// B107: DFA α1 from full-session RR
let sessionRR = hrv.extractSessionRR()
if let alpha = HRVPipeline.computeDFAAlpha1(sessionRR) {
    SessionRecorder.shared.attachDFAAlpha1(alpha)
}
```

- [ ] **Step 5: Run tests**
```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MusePlusTests/HRVPipelineTests
```
Expected: All 6 HRVPipelineTests PASS.

- [ ] **Step 6: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 7: Commit**
```bash
git add MusePlus/Pipeline/HRVPipeline.swift \
        MusePlus/SessionRecorder.swift \
        MusePlus/App.swift \
        MusePlusTests/HRVPipelineTests.swift
git commit -m "feat(B107): DFA α1 short-range scaling exponent (Peng 1995)"
```

---

## Task 11: HRV — calibrationRmssd

**Context:** Needed for the rmssdResponse component of physiologicalScore. Requires distinguishing calibration-phase HR samples. Uses the same `runAMPD` infrastructure.

**Files:**
- Modify: `MusePlus/Pipeline/HRVPipeline.swift`
- Modify: `MusePlus/SessionRecorder.swift`
- Modify: `MusePlus/App.swift`

- [ ] **Step 1: Add calibration gate to HRVPipeline**

Add to HRVPipeline:
```swift
private var isInCalibration: Bool = false
private var calibrationRR: [Double] = []
private(set) var calibrationRmssd: Double = 0.0

func setCalibrationPhase(_ active: Bool) {
    queue.async { [self] in
        isInCalibration = active
        if !active && !calibrationRR.isEmpty {
            let diffs = zip(calibrationRR.dropFirst(), calibrationRR).map { pow($0 - $1, 2) }
            calibrationRmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count)) * 1000.0
            calibrationRR.removeAll()
        }
    }
}
```

In `runAMPD()`, after computing `cleanRR`:
```swift
if isInCalibration {
    calibrationRR.append(contentsOf: cleanRR)
}
```

Reset in `reset()`:
```swift
calibrationRR.removeAll()
calibrationRmssd = 0.0
isInCalibration = false
```

- [ ] **Step 2: Wire calibration phase gate in App.swift**

In `App.swift`, in the DepthScore result handler:
```swift
// When not yet calibrated → calibration phase active
hrv.setCalibrationPhase(!result.isCalibrated)
```

At calibration end (inside `calibrationFiredRecording` block):
```swift
hrv.setCalibrationPhase(false)
SessionRecorder.shared.attachCalibrationRmssd(hrv.calibrationRmssd)
```

- [ ] **Step 3: Add attachCalibrationRmssd to SessionRecorder**

```swift
func attachCalibrationRmssd(_ rmssd: Double) {
    queue.async { [self] in
        guard isRecording else { return }
        current?.calibrationRmssd = rmssd
        Telemetry.recording.notice("calibrationRmssd=\(rmssd, privacy: .public)")
    }
}
```

(This populates the `calibrationRmssd` field added to `SessionRecord` in Task 5.)

- [ ] **Step 4: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 5: Commit**
```bash
git add MusePlus/Pipeline/HRVPipeline.swift \
        MusePlus/SessionRecorder.swift \
        MusePlus/App.swift
git commit -m "feat(B107): calibrationRmssd from HRV calibration window for physiologicalScore"
```

---

## Task 12: TrendsView — path fix + TrendRecord expansion

**Context:** TrendsView reads from documentDirectory root. Sessions saved in documentDirectory/MuseSessions/. Fix causes TrendsView to show sessions for the first time.

**Files:**
- Modify: `MusePlus/TrendsView.swift`

- [ ] **Step 1: Fix loadSessions path**

In `TrendsView.swift` line 131-134:
```swift
// Before:
private func loadSessions() async {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: docs, includingPropertiesForKeys: [.nameKey], options: .skipsHiddenFiles

// After:
private func loadSessions() async {
    let docs = SessionRecorder.sessionsDirURL()
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: docs, includingPropertiesForKeys: [.nameKey], options: .skipsHiddenFiles
```

- [ ] **Step 2: Expand TrendRecord**

Replace the existing `TrendRecord` struct (lines 14-20):
```swift
private struct TrendRecord: Codable {
    let id:           String
    let startDate:    Date
    var deepFraction:  Double? = nil
    var qualityScore:  Int?    = nil
    var durationSec:   Double? = nil
    // B107 additions — all optional for back-compat with pre-B107 files
    var physiologicalScore:        Int?    = nil
    var meditationIndexCorrelation: Float? = nil
    var mainBetaMean:              Float?  = nil
    var calibrationBetaMean:       Float?  = nil
    var timeOfDay:                 String? = nil
    var enterThresholdAtSession:   Float?  = nil
    var rmssd:                     Double? = nil
    var dfaAlpha1:                 Double? = nil
    var stallCount:                Int?    = nil
}
```

- [ ] **Step 3: Expand TrendSession**

Replace `TrendSession` (lines 5-11):
```swift
private struct TrendSession: Identifiable {
    let id:            String
    let date:          Date
    let deepFraction:  Double?
    let qualityScore:  Int?
    let durationMin:   Double?
    // B107
    let physiologicalScore:        Int?
    let meditationIndexCorrelation: Float?
    let betaSuppression:           Float?   // calibrationBetaMean - mainBetaMean (positive = good)
    let timeOfDay:                 String?
    let enterThreshold:            Float?
    let rmssd:                     Double?
    let dfaAlpha1:                 Double?
}
```

- [ ] **Step 4: Update session construction from TrendRecord**

Find where `TrendSession` is constructed from `TrendRecord` in `loadSessions()`. Update to map new fields:
```swift
TrendSession(
    id:           r.id,
    date:         r.startDate,
    deepFraction: r.deepFraction,
    qualityScore: r.qualityScore,
    durationMin:  r.durationSec.map { $0 / 60 },
    physiologicalScore: r.physiologicalScore,
    meditationIndexCorrelation: r.meditationIndexCorrelation,
    betaSuppression: {
        guard let cal = r.calibrationBetaMean, let sess = r.mainBetaMean else { return nil }
        return cal - sess
    }(),
    timeOfDay:      r.timeOfDay,
    enterThreshold: r.enterThresholdAtSession,
    rmssd:          r.rmssd,
    dfaAlpha1:      r.dfaAlpha1
)
```

- [ ] **Step 5: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 6: Commit**
```bash
git add MusePlus/TrendsView.swift
git commit -m "fix(B107): TrendsView path fix + expand TrendRecord for B107 fields"
```

---

## Task 13: TrendsView — new charts + time-of-day filter

**Files:**
- Modify: `MusePlus/TrendsView.swift`

- [ ] **Step 1: Add time-of-day filter state**

At the top of `TrendsView` struct, after existing `@State` properties:
```swift
@State private var timeOfDayFilter: String? = nil  // nil = show all
```

- [ ] **Step 2: Add filtered sessions computed property**

```swift
private var filteredSessions: [TrendSession] {
    guard let f = timeOfDayFilter else { return sessions }
    return sessions.filter { $0.timeOfDay == f }
}
```

- [ ] **Step 3: Add filter picker**

In the `List` body, before `deepFractionSection`, add:
```swift
Section {
    Picker("Time of Day", selection: $timeOfDayFilter) {
        Text("All").tag(String?.none)
        Text("Morning").tag(String?.some("morning"))
        Text("Afternoon").tag(String?.some("afternoon"))
        Text("Evening").tag(String?.some("evening"))
        Text("Night").tag(String?.some("night"))
    }
    .pickerStyle(.segmented)
}
```

- [ ] **Step 4: Add physiologicalScore section**

Add after `qualityScoreSection`:
```swift
private var physiologicalScoreSection: some View {
    Section("Physiological Score") {
        Chart(filteredSessions.filter { $0.physiologicalScore != nil }, id: \.id) { s in
            LineMark(
                x: .value("Date", s.date),
                y: .value("Score", s.physiologicalScore!)
            )
            .foregroundStyle(.purple)
            PointMark(
                x: .value("Date", s.date),
                y: .value("Score", s.physiologicalScore!)
            )
            .foregroundStyle(.purple)
        }
        .chartYScale(domain: 0...100)
        .frame(height: 150)
    }
}
```

Wire into `List` body:
```swift
if filteredSessions.contains(where: { $0.physiologicalScore != nil }) {
    physiologicalScoreSection
}
```

- [ ] **Step 5: Add threshold progression section**

```swift
private var thresholdSection: some View {
    Section("Entry Threshold Progression") {
        Chart(filteredSessions.enumerated().compactMap { (i, s) -> (Int, Float)? in
            guard let t = s.enterThreshold else { return nil }
            return (i + 1, t)
        }, id: \.0) { pair in
            LineMark(
                x: .value("Session", pair.0),
                y: .value("Threshold (ECDF)", pair.1)
            )
            .foregroundStyle(.orange)
        }
        .chartYScale(domain: 0...1)
        .frame(height: 150)
    }
}
```

Wire in same pattern as other conditional sections.

- [ ] **Step 6: Add RMSSD section**

```swift
private var rmssdSection: some View {
    Section("RMSSD Trend (ms)") {
        Chart(filteredSessions.filter { $0.rmssd != nil }, id: \.id) { s in
            LineMark(
                x: .value("Date", s.date),
                y: .value("RMSSD", s.rmssd!)
            )
            .foregroundStyle(.green)
        }
        .frame(height: 150)
    }
}
```

- [ ] **Step 7: Add DFA α1 section with reference line**

```swift
private var dfaSection: some View {
    Section("DFA α1 (Short-Range HRV Scaling)") {
        Chart {
            ForEach(filteredSessions.filter { $0.dfaAlpha1 != nil }, id: \.id) { s in
                PointMark(
                    x: .value("Date", s.date),
                    y: .value("α1", s.dfaAlpha1!)
                )
                .foregroundStyle(.teal)
            }
            RuleMark(y: .value("Healthy", 1.0))
                .foregroundStyle(.gray.opacity(0.5))
                .lineStyle(StrokeStyle(dash: [4]))
                .annotation(position: .trailing) {
                    Text("1.0").font(.caption2).foregroundStyle(.gray)
                }
        }
        .chartYScale(domain: 0...2)
        .frame(height: 150)
        if filteredSessions.filter({ $0.dfaAlpha1 != nil }).count < 5 {
            Text("DFA α1 needs ≥200 RR intervals per session (~17+ min at 60 BPM)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

Wire in all new sections with guard checks like existing sections.

- [ ] **Step 8: Build**

Product → Build. Expect: Build Succeeded.

- [ ] **Step 9: Manual UI test**

Run on iPhone 16 simulator. Open TrendsView. Verify:
- [ ] Charts render (not blank)
- [ ] Filter picker shows All/Morning/Afternoon/Evening/Night
- [ ] Selecting a filter narrows visible sessions
- [ ] DFA α1 section shows note if < 5 sessions have α1 data

- [ ] **Step 10: Commit**
```bash
git add MusePlus/TrendsView.swift
git commit -m "feat(B107): TrendsView new charts (physScore, threshold, RMSSD, DFA α1) + time-of-day filter"
```

---

## Final Build Verification

- [ ] Clean build: Product → Clean Build Folder, then Product → Build
- [ ] Run full test suite:
```
xcodebuild test -scheme MusePlus \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: All tests pass. Note any new failures.

- [ ] Do NOT push. Wait for explicit "go" from user.

---

## Post-Implementation Monitoring (first B107 session)

After first B107 session, verify in the saved `.json`:
- `buildTag: "B107"` ✓
- `calibrationBetaMean`: non-zero Float ✓
- `physiologicalScore`: non-nil Int ✓
- `stallCount`: present (0 if clean session) ✓
- `calibrationRmssd`: non-zero if HR data available ✓
- `dfaAlpha1`: present if session ≥17 min at resting HR ✓

In NDJSON footer (last line, `_type:"footer"`):
- `enterThresholdAtSession`: present ✓
- `physiologicalScore`: matches .json value ✓

In TrendsView:
- Sessions visible (path fix working) ✓
- Log `adaptiveQD` value from os_log to verify per-session variance ✓
