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

enum MuseClientError: Error {
    case connectionFailed(String)
    case dataStreamLost(String)
    case unsupportedFirmware(String)
}
