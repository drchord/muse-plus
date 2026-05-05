import Accelerate
import Foundation

// IRASA aperiodic exponent (1/f slope).
// Wen X & Liu Y 2016 Brain Topogr 29:13–26. Donoghue T et al 2020 Nat Neurosci 23:1655.
// Chi < 0: typical range −0.8 (alert) to −2.0 (deep absorption).

struct AperiodicResult {
    let chi: Float    // aperiodic exponent; expected negative
    let offset: Float // log10 intercept
    let r2: Float     // goodness of fit [0, 1]
}

enum AperiodicSlope {
    // 18 h-factors per Wen & Liu 2016: 1.10, 1.15, …, 1.95
    private static let hFactors: [Float] = stride(from: Float(1.1), through: Float(1.95), by: Float(0.05)).map { $0 }

    static let r2Threshold: Float = 0.85

    // Inputs: mag2 one-sided power spectrum (windowSize/2 bins), sample rate, window size.
    // Returns nil when R² < r2Threshold (fit too poor to trust).
    static func fit(psd: [Float], sampleRate: Float, windowSize: Int) -> AperiodicResult? {
        let n = psd.count   // = windowSize / 2
        guard n > 10 else { return nil }
        let binHz = sampleRate / Float(windowSize)

        // Accumulate log of geometric mean across h-factors (Double for precision).
        var logAccum = [Double](repeating: 0, count: n)

        for h in hFactors {
            for i in 0..<n {
                // Upsampled: read from bin i/h (stretches PSD → lower-freq origin).
                let srcUp = Float(i) / h
                let loUp  = Int(srcUp)
                let hiUp  = min(loUp + 1, n - 1)
                let tUp   = srcUp - Float(loUp)
                let pUp   = (1 - tUp) * psd[loUp] + tUp * psd[hiUp]

                // Downsampled: read from bin i*h (compresses PSD → higher-freq origin).
                let srcDn = Float(i) * h
                let loDn  = Int(srcDn)
                let hiDn  = min(loDn + 1, n - 1)
                let tDn   = srcDn - Float(loDn)
                let pDn   = loDn < n
                    ? (1 - tDn) * psd[loDn] + tDn * psd[hiDn]
                    : psd[n - 1]

                let gm = sqrt(max(Double(pUp), 1e-30) * max(Double(pDn), 1e-30))
                logAccum[i] += log(max(gm, 1e-300))
            }
        }

        // Geometric mean over h-factors → fractal (aperiodic) PSD
        let nH = Double(hFactors.count)
        let fractalPSD = logAccum.map { exp($0 / nH) }

        // OLS: log10(power) ~ chi * log10(freq) + offset for 1–40 Hz
        let lo = max(1, Int((1.0 / binHz).rounded()))
        let hi = min(Int((40.0 / binHz).rounded()), n - 1)
        guard hi > lo + 5 else { return nil }

        var xs = [Float]()
        var ys = [Float]()
        xs.reserveCapacity(hi - lo + 1)
        ys.reserveCapacity(hi - lo + 1)

        for i in lo...hi {
            guard fractalPSD[i] > 0 else { continue }
            xs.append(log10(Float(i) * binHz))
            ys.append(Float(log10(fractalPSD[i])))
        }
        guard xs.count > 5 else { return nil }

        var mx: Float = 0, my: Float = 0
        vDSP_meanv(xs, 1, &mx, vDSP_Length(xs.count))
        vDSP_meanv(ys, 1, &my, vDSP_Length(ys.count))

        var xc = xs.map { $0 - mx }
        var yc = ys.map { $0 - my }

        var num: Float = 0, den: Float = 0
        vDSP_dotpr(xc, 1, yc, 1, &num, vDSP_Length(xc.count))
        vDSP_dotpr(xc, 1, xc, 1, &den, vDSP_Length(xc.count))
        guard den > 0 else { return nil }

        let chi = num / den
        let offset = my - chi * mx

        var ssRes: Float = 0, ssTot: Float = 0
        for (y, x) in zip(ys, xs) {
            let pred = offset + chi * x
            ssRes += (y - pred) * (y - pred)
            ssTot += (y - my)   * (y - my)
        }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0

        return AperiodicResult(chi: chi, offset: offset, r2: r2)
    }
}
