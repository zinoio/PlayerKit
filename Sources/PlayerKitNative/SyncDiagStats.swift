import Foundation

/// Distribution accumulator for the A/V sync diagnostics (晃动 localization,
/// 2026-10-12; see zyno#98 follow-up).
///
/// The 5s-cadence `logSync` sample only reports ONE frame's `pts - audioTime`
/// per window — an oscillating offset (user-visible picture wobble / subtitle
/// drift) is invisible in it. This accumulator records EVERY sample and
/// summarizes the window: mean/spread, the largest change between consecutive
/// samples (`maxJump`) and sign flips — a pacing oscillation shows up as a
/// large `maxJump` with many `signFlips`, a constant offset does not.
///
/// Pure accumulator: no I/O, no locks (callers guard), zero allocations on
/// `record` — safe for the display-loop and AudioQueue-callback hot paths.
struct SyncDiagStats {
    private(set) var count: Int = 0
    private(set) var min: Double = .infinity
    private(set) var max: Double = -.infinity
    private(set) var sum: Double = 0
    private(set) var sumSq: Double = 0
    /// Largest absolute change between consecutive samples.
    private(set) var maxJump: Double = 0
    /// How often the sign flipped between consecutive samples.
    private(set) var signFlips: Int = 0
    private var last: Double?

    mutating func record(_ v: Double) {
        guard v.isFinite else { return }
        count += 1
        if v < min { min = v }
        if v > max { max = v }
        sum += v
        sumSq += v * v
        if let l = last {
            let jump = abs(v - l)
            if jump > maxJump { maxJump = jump }
            if (v > 0) != (l > 0) { signFlips += 1 }
        }
        last = v
    }

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    /// Population standard deviation over the recorded window.
    var stddev: Double {
        guard count > 0 else { return 0 }
        let m = mean
        return Swift.max(0, (sumSq / Double(count)) - m * m).squareRoot()
    }

    /// Merge another window's totals into this one (maxJump / sign continuity
    /// is not preserved across the seam — acceptable for second-scale chunks).
    mutating func merge(_ other: SyncDiagStats) {
        guard other.count > 0 else { return }
        if count == 0 { self = other; return }
        count += other.count
        min = Swift.min(min, other.min)
        max = Swift.max(max, other.max)
        sum += other.sum
        sumSq += other.sumSq
        maxJump = Swift.max(maxJump, other.maxJump)
        signFlips += other.signFlips
    }

    mutating func reset() { self = SyncDiagStats() }
}
