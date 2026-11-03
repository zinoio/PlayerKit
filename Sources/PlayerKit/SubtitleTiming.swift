import Foundation

/// Embedded-subtitle delay semantics (feat/player-reskin; reflux issue #444 P1).
///
/// The user subtitle delay shifts the cue window relative to the *display*
/// clock: the display loop computes `shifted(displayPts, delay)` once per
/// frame and matches cue windows with `contains`. Text cues, PGS image cues,
/// and ASS typeset rendering all share these two functions, so the direction
/// of the shift has exactly one definition:
///
/// - `delay > 0` — subtitles appear **later** (a cue covering 5–10s becomes
///   active when the display clock reaches 4s with delay +1).
/// - `delay < 0` — subtitles appear **earlier**.
public enum SubtitleTiming {

    /// Apply the user delay to a display-clock PTS.
    public static func shifted(_ displayPts: Double, delay: Double) -> Double {
        displayPts + delay
    }

    /// Half-open window test, mirroring the original
    /// `startPts <= pts && pts < endPts` matching semantics.
    public static func contains(startPts: Double, endPts: Double, pts: Double) -> Bool {
        startPts <= pts && pts < endPts
    }
}
