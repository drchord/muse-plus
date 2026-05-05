import Foundation

struct EEGPacket {
    let timestamp: TimeInterval     // seconds since reference, monotonic
    let channels: [Float]           // length 4 (legacy Muse S) or 8 (Athena: EEG1-4 + AUX1-4)
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
    // Spectral peak: dominant frequency within each band (Hz)
    let deltaPeak: Float
    let thetaPeak: Float
    let alphaPeak: Float
    let betaPeak:  Float
    let gammaPeak: Float
    let channel: Int        // 0=TP9, 1=AF7, 2=AF8, 3=TP10
    let timestamp: TimeInterval

    // Weighted index: general depth term + Peniston alpha-theta crossover bonus.
    // All log10 µV² values, so (alpha+theta)-2*beta = log10(αθ/β²).
    // max(0, theta-alpha) rewards theta>alpha (deep absorption marker).
    var meditationIndex: Float {
        0.7 * ((alpha + theta) - 2 * beta) + 0.3 * max(0, theta - alpha)
    }
}

struct DepthResult {
    let score: Float               // 0.0 (alert) – 1.0 (deep meditation)
    let isCalibrated: Bool
    let calibrationProgress: Float // 0–1 during calibration
    let faa: Float                 // Frontal Alpha Asymmetry: af8α - af7α, positive = positive affect
}

struct BandSample: Identifiable {
    let id: Int
    let time: Double        // seconds since session start
    let alpha: Float
    let theta: Float
    let beta:  Float
    let delta: Float
    let gamma: Float
    let alphaPeak: Float    // Hz — dominant frequency within band
    let thetaPeak: Float
    let betaPeak:  Float
    let deltaPeak: Float
    let gammaPeak: Float
    let faa: Float          // Frontal Alpha Asymmetry at this sample
}

enum MuseClientError: Error {
    case connectionFailed(String)
    case dataStreamLost(String)
    case unsupportedFirmware(String)
}
