import Foundation

/// zyno#106 — content-frame-rate → display refresh-rate matching.
///
/// 24/25/30fps content driven at a fixed 60/120Hz shows 3:2 pulldown judder
/// (33/50ms alternating frame gaps). Requesting a multiple of the content
/// rate gives even per-frame gaps. Doubling (24→48Hz) is the conservative
/// mapping: 2:2 pulldown is as judder-free as a native 24Hz mode, without
/// the low-frequency flicker some panels show below ~30Hz. Rates ≥50p map
/// to themselves.
enum FrameRateMatcher {
    /// The pre-#106 fixed range: pin high refresh, let the system pick ticks.
    static let legacyRange = (minimum: 60.0, maximum: 120.0, preferred: 120.0)

    /// Snap a probed fps to a common content rate. Nonsense input (NaN, ≤5,
    /// >120) and rates away from the table return nil → the caller keeps the
    /// legacy range.
    static func normalizedContentRate(_ fps: Double) -> Double? {
        guard fps.isFinite, fps > 5, fps <= 120 else { return nil }
        let common: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 90, 100, 120]
        guard let nearest = common.min(by: { abs(fps - $0) < abs(fps - $1) }) else { return nil }
        return abs(fps - nearest) <= 0.5 ? nearest : nil
    }

    /// The display-link range for a content rate. `minimum` pins at the
    /// content rate (the display drain loop must never be tick-starved below
    /// it); `maximum` stays wide so the system can still idle higher when it
    /// needs to.
    static func displayRange(contentFps: Double, matchingEnabled: Bool) -> (minimum: Double, maximum: Double, preferred: Double) {
        guard matchingEnabled, let base = normalizedContentRate(contentFps) else {
            return legacyRange
        }
        let preferred = base < 40 ? base * 2 : base
        return (minimum: base, maximum: max(legacyRange.maximum, preferred), preferred: preferred)
    }
}
