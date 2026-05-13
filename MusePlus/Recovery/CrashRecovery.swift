import Foundation
import OSLog
import SwiftUI

// MARK: - Crash Recovery (B80 — A2)
//
// On each app launch, CrashRecovery scans MuseSessions/ for NDJSON files that have
// no matching .json (orphans). These are sessions that were active when the app
// crashed or was force-killed. Each orphan is synthesised into a canonical .json
// using SessionRecorder.synthesiseRecord(from:) and written to disk.
//
// A SwiftUI alert is presented once per launch if any sessions were recovered,
// giving the user visibility into recovered data.

final class CrashRecovery: ObservableObject {
    static let shared = CrashRecovery()

    /// Non-nil when recovered sessions exist; drives the SwiftUI alert.
    @Published var recoveryAlert: RecoveryInfo? = nil

    struct RecoveryInfo: Identifiable {
        let id = UUID()
        let count: Int
        let oldestDate: Date
    }

    /// Scan for orphan NDJSON files and synthesise .json for each.
    /// Call from ProbeView.onAppear (before probe.start() triggers BLE).
    /// This is synchronous on a background queue; publishes result on main.
    func recoverOrphans() {
        DispatchQueue.global(qos: .utility).async {
            let dir = SessionRecorder.sessionsDirURL()
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { return }

            // Find all .ndjson files
            let ndjsonFiles = contents.filter { $0.pathExtension == "ndjson" }

            // Collect orphans: ndjson with no matching .json
            let orphans = ndjsonFiles.filter { ndjson in
                let json = ndjson.deletingPathExtension().appendingPathExtension("json")
                return !FileManager.default.fileExists(atPath: json.path)
            }

            guard !orphans.isEmpty else { return }

            var recoveredCount = 0
            var oldestDate: Date = .distantFuture
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting     = .prettyPrinted

            for ndjsonURL in orphans {
                guard var rec = SessionRecorder.synthesiseRecord(from: ndjsonURL) else {
                    Telemetry.recording.error("recovery: failed to parse \(ndjsonURL.lastPathComponent, privacy: .public)")
                    continue
                }

                // Mark as crash-recovered
                rec.recoveredFromCrash = true

                // Write .json with same base name as .ndjson
                let jsonURL = ndjsonURL.deletingPathExtension().appendingPathExtension("json")
                do {
                    let data = try enc.encode(rec)
                    // B96: NSFileCoordinator prevents iCloud conflict copies during recovery write.
                    var writeError: Error?
                    var coordError: NSError?
                    let coord = NSFileCoordinator()
                    coord.coordinate(writingItemAt: jsonURL, options: .forReplacing, error: &coordError) { writingURL in
                        do {
                            try data.write(to: writingURL, options: [.atomic, .completeFileProtection])
                        } catch {
                            writeError = error
                        }
                    }
                    if let err = coordError ?? writeError { throw err }
                    recoveredCount += 1
                    if rec.startDate < oldestDate { oldestDate = rec.startDate }
                    let mins = String(format: "%.1f", rec.durationMinutes)
                    Telemetry.recording.notice("recovered session: \(jsonURL.lastPathComponent, privacy: .public) samples=\(rec.samples.count, privacy: .public) duration=\(mins, privacy: .public)min")
                } catch {
                    Telemetry.recording.error("recovery write failed \(jsonURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            guard recoveredCount > 0 else { return }

            // Refresh saved sessions list
            SessionRecorder.shared.loadSavedSessions()

            // Publish alert info on main thread
            let info = RecoveryInfo(count: recoveredCount, oldestDate: oldestDate)
            DispatchQueue.main.async {
                self.recoveryAlert = info
                Telemetry.recording.notice("recovery complete: count=\(recoveredCount, privacy: .public)")
            }
        }
    }
}

// MARK: - Recovery alert modifier

/// SwiftUI ViewModifier that presents the crash-recovery alert.
/// Usage: add `.crashRecoveryAlert()` to the root view.
struct CrashRecoveryAlertModifier: ViewModifier {
    @ObservedObject private var recovery = CrashRecovery.shared

    func body(content: Content) -> some View {
        content
            .alert(
                item: $recovery.recoveryAlert
            ) { info in
                let dateFmt = DateFormatter()
                dateFmt.dateStyle = .short
                dateFmt.timeStyle = .short
                let dateStr = dateFmt.string(from: info.oldestDate)
                let noun    = info.count == 1 ? "session" : "sessions"
                return Alert(
                    title: Text("Session Recovered"),
                    message: Text("Recovered \(info.count) \(noun) from \(dateStr) after an unexpected exit. Your data is safe in the Sessions list."),
                    dismissButton: .default(Text("OK"))
                )
            }
    }
}

extension View {
    /// Attach crash-recovery alert to any view.
    func crashRecoveryAlert() -> some View {
        modifier(CrashRecoveryAlertModifier())
    }
}
