import Foundation

/// B126: adaptive shaping of the deep-state gate sustained-window requirement.
///
/// Replaces the constant `kEnterSustained` (was 20 windows / 10s — empirically unreachable
/// for many users; published neurofeedback protocols use 0.5–3s for raw amplitude thresholds).
/// New default: 12 windows (6s) for users with no shaping history.
///
/// NOTE: 6 windows (3s) was the original target but self-audit identified that smoothedDisplay
/// is Kalman-filtered (not raw amplitude). A 3s window on a smoothed signal risks false positives.
/// 6s on a smoothed signal corresponds roughly to 3s on raw EEG — matching published protocols.
///
/// Shaping rule:
///   - 3 consecutive sessions with deepFraction == 0 → decrement by 2 windows (min 4 / 2s)
///   - 3 consecutive sessions with deepFraction  > 0 → increment by 1 window (max 20 / 10s)
///
/// State persists in UserDefaults. Within a session the value is read once at reset() and
/// never re-read. The gate cannot change while the user is meditating.
enum EnterSustainedShaping {
    private static let kCurrent    = "kEnterSustainedShaping"
    private static let kZeroStreak = "kEnterSustainedShapingZeroStreak"
    private static let kHitStreak  = "kEnterSustainedShapingHitStreak"
    static let defaultWindows: Int = 12   // 6s on Kalman-smoothed signal ≈ 3s on raw EEG
    static let minWindows:     Int = 4    // 2s floor
    static let maxWindows:     Int = 20   // 10s ceiling — preserves B125 behaviour

    /// Returns the current sustained-window requirement. Migrates legacy "kEnterSustainedWindows"
    /// UserDefault on first call if present in range [6, 24].
    static func currentWindows() -> Int {
        let ud = UserDefaults.standard
        if let legacy = ud.object(forKey: "kEnterSustainedWindows") as? Int,
           legacy >= 6 && legacy <= 24,
           ud.object(forKey: kCurrent) == nil {
            ud.set(legacy, forKey: kCurrent)
            ud.removeObject(forKey: "kEnterSustainedWindows")
        }
        let v = ud.object(forKey: kCurrent) as? Int
        return v.map { max(minWindows, min(maxWindows, $0)) } ?? defaultWindows
    }

    /// Record the outcome of a completed session and possibly adjust the requirement.
    /// Call AFTER deepFraction is finalised in the end-session pathway.
    static func recordSession(deepFraction: Double) {
        let ud = UserDefaults.standard
        var zeros = ud.integer(forKey: kZeroStreak)
        var hits  = ud.integer(forKey: kHitStreak)

        if deepFraction > 0 {
            hits  += 1
            zeros  = 0
        } else {
            zeros += 1
            hits   = 0
        }

        var w = currentWindows()
        if zeros >= 3 {
            w = max(minWindows, w - 2)
            zeros = 0
        }
        if hits >= 3 {
            w = min(maxWindows, w + 1)
            hits = 0
        }

        ud.set(w,     forKey: kCurrent)
        ud.set(zeros, forKey: kZeroStreak)
        ud.set(hits,  forKey: kHitStreak)
    }

    /// Test / Settings helper — force a specific value, clear streak counters.
    static func setWindows(_ v: Int) {
        let clamped = max(minWindows, min(maxWindows, v))
        let ud = UserDefaults.standard
        ud.set(clamped, forKey: kCurrent)
        ud.set(0, forKey: kZeroStreak)
        ud.set(0, forKey: kHitStreak)
    }
}
