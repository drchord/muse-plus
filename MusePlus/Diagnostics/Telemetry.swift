import OSLog

// MARK: - Telemetry
//
// Centralised Logger singletons for the four observability categories.
// All new logging goes through these — never through print().
// Categories map to OSLog subsystem filtering in Console.app and OSLogStore.

enum Telemetry {
    static let connection = Logger(subsystem: "com.drchord.museplus", category: "connection")
    static let recording  = Logger(subsystem: "com.drchord.museplus", category: "recording")
    static let audio      = Logger(subsystem: "com.drchord.museplus", category: "audio")
    static let eeg        = Logger(subsystem: "com.drchord.museplus", category: "eeg")
}
