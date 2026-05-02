import Foundation

struct EEGPacket {
    let timestamp: TimeInterval     // seconds since reference, monotonic
    let channels: [Float]           // length 4: TP9, AF7, AF8, TP10
}

struct FitCheckSnapshot: Equatable {
    let tp9: Bool
    let af7: Bool
    let af8: Bool
    let tp10: Bool

    static let zero = FitCheckSnapshot(tp9: false, af7: false, af8: false, tp10: false)

    var allGood: Bool { tp9 && af7 && af8 && tp10 }
}

// MARK: - Gate 2

struct BandPowers {
    let delta: Float        // 1–4 Hz, log10(µV²)
    let theta: Float        // 4–8 Hz
    let alpha: Float        // 8–13 Hz
    let beta:  Float        // 13–30 Hz
    let gamma: Float        // 30–50 Hz
    let channel: Int        // 0=TP9, 1=AF7, 2=AF8, 3=TP10
    let timestamp: TimeInterval

    var meditationIndex: Float { alpha - beta }
}

struct DepthResult {
    let score: Float        // 0.0 (alert) – 1.0 (deep meditation)
    let isCalibrated: Bool
    let calibrationProgress: Float  // 0–1 during calibration
}

enum MuseClientError: Error {
    case connectionFailed(String)
    case dataStreamLost(String)
    case unsupportedFirmware(String)
}
