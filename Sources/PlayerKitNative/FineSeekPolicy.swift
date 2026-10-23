import Foundation

/// zyno#142 / zyno#358: decides whether a byte-domain seek arms the fine-seek
/// discard (video: display-loop pops, audio: demux-loop packet drop, both up to
/// the target). Shared by `performDemuxerSeek` and the slow-path track switch so
/// the two can't drift apart.
///
/// Audio and video MUST be armed together. A BDMV/m2ts muxes audio ahead of
/// video, so the first audio packet after a landing is earlier than the first
/// decodable video frame (measured: 0.74 s on a 31 GB 4K disc). Without the
/// discard, audio plays from its own earlier start while the clock is labelled
/// with the video landing — sound lags the picture by that mux lead.
enum FineSeekPolicy {
    /// Minimum backward landing gap (seconds) for which the discard is armed.
    /// Was 0.5 s (zyno#142 targeted landings ±2 s off); that left audio lagging the
    /// picture by the mux lead whenever the landing was within 0.5 s (zyno#358).
    static let minGap: Double = 0

    /// - Parameters:
    ///   - landed: the demuxer's reported landing PTS (`lastSeekLandedPTS`);
    ///     nil for index-guided seeks (MKV/MP4), which never arm the discard.
    ///   - target: the requested seek target.
    static func shouldArm(landed: Double?, target: Double) -> Bool {
        guard let landed, landed <= target else { return false }
        return target - landed > minGap
    }
}
