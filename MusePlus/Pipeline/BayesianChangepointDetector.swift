import Foundation
import Accelerate

/// B126 — Bayesian Online Change-Point Detection (Adams & MacKay 2007).
///
/// Streaming, O(maxRunLength) per step. Conjugate Normal-Inverse-Gamma prior.
/// Input is logit-transformed before NIG update (smoothedDisplay is [0,1]-bounded;
/// logit maps to (-∞,+∞) making Gaussian/NIG assumptions valid).
///
/// AUDIT FIXES vs original plan:
///   - maxRunLength: was 200 (100s at 2Hz). A 60-min session = 7200 steps. Use 7200.
///   - Observation model: raw [0,1] input causes NIG bias at boundaries. Logit-transform
///     input first. mu0 = 0.0 (logit(0.5) = 0, center of transformed space).
struct BayesianChangepointDetector {
    private let hazardRate: Float
    private let maxRunLength: Int
    // NIG prior parameters (on logit-transformed observations).
    private let mu0:    Float
    private let kappa0: Float
    private let alpha0: Float
    private let beta0:  Float
    private var runProbs: [Float]
    private var mu:    [Float]
    private var kappa: [Float]
    private var alpha: [Float]
    private var beta:  [Float]
    private(set) var lastPosterior: Float = 0

    init(hazardRate: Float = 1.0 / 250.0,
         maxRunLength: Int = 7200,
         mu0: Float = 0.0,     // logit(0.5) = 0; center of transformed space
         kappa0: Float = 1,
         alpha0: Float = 1,
         beta0: Float = 0.5) { // tighter prior variance for logit-transformed signal
        self.hazardRate   = hazardRate
        self.maxRunLength = maxRunLength
        self.mu0 = mu0; self.kappa0 = kappa0; self.alpha0 = alpha0; self.beta0 = beta0
        self.runProbs = [Float](repeating: 0, count: maxRunLength + 1)
        self.runProbs[0] = 1
        self.mu     = [mu0]
        self.kappa  = [kappa0]
        self.alpha  = [alpha0]
        self.beta   = [beta0]
    }

    /// Observe a new sample (raw [0,1] smoothedDisplay). Returns P(changepoint at this step).
    mutating func observe(_ rawX: Float) -> Float {
        // Logit-transform: [0,1] → (-∞,+∞). Clamp to avoid logit(0) / logit(1) = ±∞.
        let clamped = max(1e-4, min(1 - 1e-4, rawX))
        let x = log(clamped / (1 - clamped))

        // 1. Predictive probabilities for each existing run-length under Student-t.
        let n = mu.count
        var preds = [Float](repeating: 0, count: n)
        for k in 0..<n {
            preds[k] = studentTPdf(x: x, mu: mu[k], kappa: kappa[k],
                                    alpha: alpha[k], beta: beta[k])
        }
        // 2. Growth probabilities (no changepoint) and CP probability.
        var newProbs = [Float](repeating: 0, count: min(n + 1, maxRunLength + 1))
        let cpProb = (0..<n).reduce(Float(0)) { $0 + runProbs[$1] * preds[$1] * hazardRate }
        newProbs[0] = cpProb
        for k in 0..<n {
            let dst = k + 1
            if dst <= maxRunLength {
                newProbs[dst] = runProbs[k] * preds[k] * (1 - hazardRate)
            }
        }
        // 3. Normalize.
        let sum = newProbs.reduce(0, +)
        let scale: Float = sum > 1e-30 ? 1 / sum : 1
        vDSP_vsmul(newProbs, 1, [scale], &newProbs, 1, vDSP_Length(newProbs.count))
        // 4. Update sufficient stats.
        var newMu    = [mu0];    newMu.reserveCapacity(n + 1)
        var newKappa = [kappa0]; newKappa.reserveCapacity(n + 1)
        var newAlpha = [alpha0]; newAlpha.reserveCapacity(n + 1)
        var newBeta  = [beta0];  newBeta.reserveCapacity(n + 1)
        for k in 0..<n where k + 1 <= maxRunLength {
            let kappa_p = kappa[k] + 1
            let mu_p    = (kappa[k] * mu[k] + x) / kappa_p
            let alpha_p = alpha[k] + 0.5
            let beta_p  = beta[k] + (kappa[k] * (x - mu[k]) * (x - mu[k])) / (2 * kappa_p)
            newMu.append(mu_p); newKappa.append(kappa_p)
            newAlpha.append(alpha_p); newBeta.append(beta_p)
        }
        // 5. Commit.
        runProbs = newProbs + [Float](repeating: 0, count: maxRunLength + 1 - newProbs.count)
        mu = newMu; kappa = newKappa; alpha = newAlpha; beta = newBeta
        lastPosterior = newProbs[0]
        return lastPosterior
    }

    private func studentTPdf(x: Float, mu: Float, kappa: Float,
                              alpha: Float, beta: Float) -> Float {
        let nu    = 2 * alpha
        let scale = beta * (kappa + 1) / (alpha * kappa)
        let z     = (x - mu) / sqrt(scale)
        let coef  = tgamma((nu + 1) / 2) / (sqrt(nu * .pi) * tgamma(nu / 2))
        let kernel = pow(1 + z * z / nu, -(nu + 1) / 2)
        return coef * kernel / sqrt(scale)
    }
}
