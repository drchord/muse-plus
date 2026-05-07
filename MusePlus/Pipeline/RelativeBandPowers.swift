import Combine
import Foundation

// SDK Muse Elements consumer — subscribes to Interaxon's pre-computed band powers
// and session scores. Used for cross-validation against our own pipeline, not yet
// to drive the depth score.
//
// Why: Interaxon spent years tuning Elements algorithms (V20→V50). Their session-score
// algorithm uses linear p10→p90 mapping over recent rolling history — same family as
// our personal ECDF. If our pipeline diverges substantially from theirs, one is wrong.
// Running both in parallel surfaces that.
//
// Discontinuation note: Interaxon retired "Mellow" and "Concentration" unified scores
// in 2016 because they were inaccurate. The per-band Elements remained because they're
// transparent and statistically grounded. Single-number unified depth is genuinely hard.

struct ElementsValues {
    var alphaAbsolute: Float = .nan  // log10 µV², 4 channels averaged
    var betaAbsolute:  Float = .nan
    var thetaAbsolute: Float = .nan
    var deltaAbsolute: Float = .nan
    var gammaAbsolute: Float = .nan

    var alphaRelative: Float = .nan  // [0, 1] fraction of total linear-scale band power
    var betaRelative:  Float = .nan
    var thetaRelative: Float = .nan

    var alphaScore: Float = .nan     // [0, 1] session score, p10→p90 of rolling history
    var betaScore:  Float = .nan
    var thetaScore: Float = .nan

    var lastUpdated: Date? = nil

    // Composite "Muse-style" depth indicator: theta + alpha dominance over beta in score space.
    // Used only for cross-comparison display, not gate input.
    var museStyleDepth: Float? {
        guard alphaScore.isFinite, thetaScore.isFinite, betaScore.isFinite else { return nil }
        return max(0, min(1, 0.5 * thetaScore + 0.4 * alphaScore + 0.1 * (1 - betaScore)))
    }
}

final class ElementsTracker: ObservableObject {
    static let shared = ElementsTracker()
    @Published private(set) var values = ElementsValues()

    // Average values across channels for the just-arrived packet.
    func ingest(_ vals: [NSNumber], type: IXNMuseDataPacketType) {
        guard !vals.isEmpty else { return }
        let nums = vals.map { Float($0.doubleValue) }.filter { $0.isFinite }
        guard !nums.isEmpty else { return }
        let mean = nums.reduce(0, +) / Float(nums.count)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .alphaAbsolute: self.values.alphaAbsolute = mean
            case .betaAbsolute:  self.values.betaAbsolute  = mean
            case .thetaAbsolute: self.values.thetaAbsolute = mean
            case .deltaAbsolute: self.values.deltaAbsolute = mean
            case .gammaAbsolute: self.values.gammaAbsolute = mean
            case .alphaRelative: self.values.alphaRelative = mean
            case .betaRelative:  self.values.betaRelative  = mean
            case .thetaRelative: self.values.thetaRelative = mean
            case .alphaScore:    self.values.alphaScore    = mean
            case .betaScore:     self.values.betaScore     = mean
            case .thetaScore:    self.values.thetaScore    = mean
            default: return
            }
            self.values.lastUpdated = Date()
        }
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in self?.values = ElementsValues() }
    }
}
