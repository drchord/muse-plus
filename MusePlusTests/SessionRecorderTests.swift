import XCTest
@testable import MusePlus

final class SessionRecorderTests: XCTestCase {
    // MARK: - Helpers

    private func latestNDJSONURL() -> URL? {
        let dir = SessionRecorder.sessionsDirURL()
        return try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private func lines(from url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        // End any lingering session from a previous test.
        if SessionRecorder.shared.isRecording {
            SessionRecorder.shared.endSession(reason: "test-teardown")
        }
    }

    override func tearDown() async throws {
        if SessionRecorder.shared.isRecording {
            SessionRecorder.shared.endSession(reason: "test-teardown")
        }
        // Clean up NDJSON files written during the test.
        let dir = SessionRecorder.sessionsDirURL()
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        {
            for url in urls where url.pathExtension == "ndjson" || url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Tests

    func testAppendEventWritesNDJSONLine() throws {
        SessionRecorder.shared.startSession()
        let event = SessionEvent(time: 1.0, kind: "test", detail: nil)
        SessionRecorder.shared.appendEvent(event)
        // Give async queue a moment to flush.
        Thread.sleep(forTimeInterval: 0.05)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file found after startSession()")
        }
        let rows = lines(from: url)
        let eventLines = rows.filter { ($0["_type"] as? String) == "event" }
        XCTAssertFalse(eventLines.isEmpty, "Expected at least one _type:event line")
        let firstEvent = eventLines.first
        XCTAssertEqual(firstEvent?["kind"] as? String, "test")
    }

    func testAppendAudioStateAllFields() throws {
        SessionRecorder.shared.startSession()
        // All 11 NDJSONAudioState fields:
        SessionRecorder.shared.appendAudioState(
            trigger: "playGong",
            outputVolume: 0.8,
            category: "playback",
            mode: "default",
            isOtherAudioPlaying: false,
            outputs: ["builtInSpeaker"],
            chimeEngineRunning: true,
            chimeEnginePlayerPlaying: false,
            soundscapeEngineRunning: false,
            chimeVolumeSetting: 0.5,
            secondsSinceLastRouteChange: 10
        )
        Thread.sleep(forTimeInterval: 0.05)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file found")
        }
        let rows = lines(from: url)
        let audioLines = rows.filter { ($0["_type"] as? String) == "audioState" }
        XCTAssertFalse(audioLines.isEmpty, "Expected _type:audioState line")
        let row = audioLines.first!
        XCTAssertEqual(row["trigger"] as? String, "playGong")
        XCTAssertEqual(row["category"] as? String, "playback")
        XCTAssertNotNil(row["outputVolume"], "outputVolume must be present")
        XCTAssertNotNil(row["secondsSinceLastRouteChange"], "secondsSinceLastRouteChange must be present")
    }

    func testAppendGongLifecyclePhases() throws {
        SessionRecorder.shared.startSession()
        let phases = ["scheduled", "started", "completed", "failed"]
        for phase in phases {
            SessionRecorder.shared.appendGongLifecycle(
                phase: phase,
                source: "file:bowl_success.m4a",
                detail: nil
            )
        }
        Thread.sleep(forTimeInterval: 0.05)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file found")
        }
        let rows = lines(from: url)
        let gongLines = rows.filter { ($0["_type"] as? String) == "gongLifecycle" }
        XCTAssertEqual(gongLines.count, phases.count,
                       "Expected one gongLifecycle line per phase")
        let writtenPhases = gongLines.compactMap { $0["phase"] as? String }
        for phase in phases {
            XCTAssertTrue(writtenPhases.contains(phase), "Missing phase: \(phase)")
        }
    }

    func testAppendMainStallSerializesStack() throws {
        SessionRecorder.shared.startSession()
        let stack = "frame0 | frame1 | frame2 | frame3 | frame4"
        SessionRecorder.shared.appendMainStall(
            deltaSec: 2.1,
            thermalState: "nominal",
            appState: "active",
            topStack: stack
        )
        Thread.sleep(forTimeInterval: 0.05)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file found")
        }
        let rows = lines(from: url)
        let stallLines = rows.filter { ($0["_type"] as? String) == "mainStall" }
        XCTAssertFalse(stallLines.isEmpty, "Expected _type:mainStall line")
        let row = stallLines.first!
        XCTAssertEqual(row["topStack"] as? String, stack,
                       "topStack pipe-separated string must round-trip")
        XCTAssertEqual(row["thermalState"] as? String, "nominal")
    }

    func testAppendUIStateRenderCounters() throws {
        SessionRecorder.shared.startSession()
        SessionRecorder.shared.appendUIState(
            trigger: "render",
            timerHudRendered: 42,
            depthGaugeRendered: 7,
            chipViewRendered: 100
        )
        Thread.sleep(forTimeInterval: 0.05)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file found")
        }
        let rows = lines(from: url)
        let uiLines = rows.filter { ($0["_type"] as? String) == "uiState" }
        XCTAssertFalse(uiLines.isEmpty, "Expected _type:uiState line")
        let row = uiLines.first!
        XCTAssertEqual(row["timerHudRendered"] as? Int, 42)
        XCTAssertEqual(row["depthGaugeRendered"] as? Int, 7)
        XCTAssertEqual(row["chipViewRendered"] as? Int, 100)
    }

    func testCurrentSessionElapsedReturnsZeroWhenNotRecording() {
        // Ensure no session is active.
        if SessionRecorder.shared.isRecording {
            SessionRecorder.shared.endSession(reason: "test-pre-check")
        }
        let elapsed = SessionRecorder.shared.currentSessionElapsed()
        XCTAssertEqual(elapsed, 0.0, accuracy: 0.001)
    }

    func testEventStreamSurvivesCrash() throws {
        // Simulate crash: start session, append events, do NOT call endSession().
        SessionRecorder.shared.startSession()
        for i in 0..<3 {
            SessionRecorder.shared.appendEvent(
                SessionEvent(time: Double(i), kind: "disconnect", detail: "sim-\(i)")
            )
        }
        // Flush without calling endSession (simulates crash mid-session).
        Thread.sleep(forTimeInterval: 0.1)

        guard let url = latestNDJSONURL() else {
            return XCTFail("No NDJSON file written before simulated crash")
        }
        // Force-end so tearDown can clean up, but check file content first.
        let rows = lines(from: url)
        let eventRows = rows.filter { ($0["_type"] as? String) == "event" }
        XCTAssertGreaterThanOrEqual(eventRows.count, 3,
            "NDJSON must retain events appended before crash (no endSession call)")
    }
}
