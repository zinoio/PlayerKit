import Foundation

/// zyno#358: decides whether the display loop re-labels `audioClock` to the first
/// post-seek video frame.
///
/// After a fine-seek (zyno#142) the audio clock is anchored AT the seek target and
/// audio is discarded up to it, so the first audible sample IS the target. The first
/// decodable video frame can land LATER than the target (`videoLand` +0.05…+0.32 s on
/// a 31 GB 4K disc). Re-labelling the clock forward to that frame would play the
/// audio from the target while the clock claims it is `videoLand` seconds further on —
/// sound lags the picture by exactly that much. When the audio is anchored we keep
/// the clock where it is and let the freeze-ahead guard hold the (late) first frame
/// until the audio reaches it, i.e. converge on what is actually audible. A frame that
/// is EARLIER than the clock still calibrates (the original zyno#142-era purpose).
enum ClockCalibrationPolicy {
    static func shouldCalibrate(firstFramePts: Double,
                                audioTime: Double,
                                force: Bool,
                                audioAnchoredAtTarget: Bool,
                                maxGap: Double) -> Bool {
        if force { return true }
        let gap = firstFramePts - audioTime
        if audioAnchoredAtTarget, gap > 0 { return false }
        return abs(gap) < maxGap
    }
}
