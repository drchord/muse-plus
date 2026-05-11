import Foundation

/// 2-state Kalman filter for meditation depth estimation.
/// State vector: [depth, velocity]. Depth = personal ECDF rank [0, 1].
///
/// Parameters empirically derived from session_2026-05-11:
///   Q (process noise): var(Δecdf per 0.5s window) = 2.16e-3
///   R (measurement noise): residual var from 10s rolling mean in approach zone = 5.0e-3
///   Steady-state Kalman gain ≈ 0.30 for depth, small for velocity.
///
/// Velocity estimate (ecdf/window) captures depth trend; used for deepening detection
/// and iTPF binaural trigger timing. Replaces raw rate from deepening ring buffer.
struct KalmanDepth {
    private(set) var depth: Float = 0.5
    private(set) var vel:   Float = 0.0

    private var Pdd: Float = 0.10
    private var Pdv: Float = 0.0
    private var Pvd: Float = 0.0
    private var Pvv: Float = 0.05

    private let dt:             Float = 0.5      // update interval seconds
    private let qD:             Float = 0.0022   // process noise: depth
    private let qV:             Float = 0.00010  // process noise: velocity
    private let rBase:          Float = 0.005    // base measurement noise (approach-zone residual var)
    private let rNeutralQuality: Float = 0.6     // reference quality level for R scaling

    /// Update with new ECDF observation z ∈ [0,1].
    /// alphaPowerRatio ∈ [0.3, 0.9]: higher = cleaner signal = lower effective R.
    /// Default 0.5 = neutral (no denoiser data).
    /// Returns updated depth clamped to [0,1] and velocity estimate.
    mutating func update(z: Float, alphaPowerRatio: Float = 0.5) -> (depth: Float, vel: Float) {
        // Predict
        let pd   = depth + dt * vel
        let pv   = vel
        let pPdd = Pdd + dt * (Pdv + Pvd) + dt * dt * Pvv + qD
        let pPdv = Pdv + dt * Pvv
        let pPvd = Pvd + dt * Pvv
        let pPvv = Pvv + qV

        // Adaptive measurement noise: better signal → lower R → trust measurement more
        let quality = max(0.3, min(0.9, alphaPowerRatio))
        let R = rBase * (rNeutralQuality / quality)   // at quality=rNeutralQuality: R=rBase

        // Update (H = [1, 0] — we observe depth only)
        let S     = pPdd + R
        let Kd    = pPdd / S
        let Kv    = pPvd / S
        let innov = max(-0.3, min(0.3, z - pd))   // clip ±0.3 to reject sensor glitches

        depth = max(0.0, min(1.0, pd + Kd * innov))
        vel   = pv + Kv * innov
        Pdd   = (1.0 - Kd) * pPdd
        Pdv   = (1.0 - Kd) * pPdv
        Pvd   = pPvd - Kv * pPdd
        Pvv   = pPvv - Kv * pPdv

        return (depth, vel)
    }

    mutating func reset() {
        depth = 0.5; vel = 0.0
        // Covariance reset to initial values. Note: P symmetry (Pdv==Pvd) is not enforced
        // during filtering — expected for (I-KH)P updates with asymmetric gains. Harmless at float precision.
        Pdd = 0.10; Pdv = 0.0; Pvd = 0.0; Pvv = 0.05
    }
}
