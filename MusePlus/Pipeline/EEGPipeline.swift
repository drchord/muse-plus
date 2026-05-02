import Accelerate
import Foundation

final class EEGPipeline {
    static let sampleRate: Float = 256.0
    static let windowSize: Int  = 256   // 1-second window
    static let hopSize: Int     = 128   // 50% overlap → output every 0.5 s

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hannWindow: [Float]
    private var buffers: [[Float]]  // [channel][sample], 4 channels

    var onBandPowers: (([BandPowers]) -> Void)?

    init() {
        let n = EEGPipeline.windowSize
        log2n   = vDSP_Length(log2(Float(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        hannWindow = w
        buffers    = Array(repeating: [], count: 4)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func process(_ packet: EEGPacket) {
        let chCount = min(packet.channels.count, 4)
        for ch in 0..<chCount {
            buffers[ch].append(packet.channels[ch])
        }
        guard buffers[0].count >= EEGPipeline.windowSize else { return }

        let ts = packet.timestamp
        let powers = (0..<4).map { ch in
            bandPowers(Array(buffers[ch].prefix(EEGPipeline.windowSize)),
                       channel: ch, timestamp: ts)
        }
        onBandPowers?(powers)

        for ch in 0..<4 { buffers[ch].removeFirst(EEGPipeline.hopSize) }
    }

    private func bandPowers(_ samples: [Float], channel: Int, timestamp: TimeInterval) -> BandPowers {
        let n = EEGPipeline.windowSize
        var work = samples

        // 1. Remove DC (demean)
        var mean: Float = 0
        vDSP_meanv(work, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(work, 1, &negMean, &work, 1, vDSP_Length(n))

        // 2. Apply Hann window
        vDSP_vmul(work, 1, hannWindow, 1, &work, 1, vDSP_Length(n))

        // 3. Pack real signal as split-complex for vDSP_fft_zrip
        //    real[k] = signal[2k], imag[k] = signal[2k+1]
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        work.withUnsafeBytes { rawBuf in
            let complexPtr = rawBuf.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
            var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ctoz(complexPtr, 1, &split, 1, vDSP_Length(n / 2))
        }

        // 4. Real FFT in-place
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // 5. Power spectrum (magnitude squared), normalized
        var mag2 = [Float](repeating: 0, count: n / 2)
        vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(n / 2))
        var scale = 1.0 / Float(n * n)
        vDSP_vsmul(mag2, 1, &scale, &mag2, 1, vDSP_Length(n / 2))

        // 6. Log10 mean power per band
        //    Frequency resolution: sampleRate / windowSize = 1 Hz/bin
        let res = EEGPipeline.sampleRate / Float(n)

        func logPow(_ lo: Float, _ hi: Float) -> Float {
            let i0 = max(1, Int((lo / res).rounded()))
            let i1 = min(Int((hi / res).rounded()), n / 2 - 1)
            guard i0 <= i1 else { return -4.0 }
            var sum: Float = 0
            mag2.withUnsafeBufferPointer { ptr in
                vDSP_sve(ptr.baseAddress! + i0, 1, &sum, vDSP_Length(i1 - i0 + 1))
            }
            let meanPow = sum / Float(i1 - i0 + 1)
            return meanPow > 0 ? log10(meanPow) : -4.0
        }

        return BandPowers(
            delta: logPow(1, 4),
            theta: logPow(4, 8),
            alpha: logPow(8, 13),
            beta:  logPow(13, 30),
            gamma: logPow(30, 50),
            channel: channel,
            timestamp: timestamp
        )
    }
}
