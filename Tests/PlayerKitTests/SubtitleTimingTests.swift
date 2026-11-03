import XCTest
import PlayerKit

/// Embedded-subtitle delay semantics (feat/player-reskin, reflux issue #444 P1):
/// the user delay shifts the cue window relative to the *display* clock.
/// Positive delay ⇒ subtitles appear LATER (window moves forward); negative
/// ⇒ earlier. The display loop calls `shifted` once per frame and matches
/// cues with `contains` — text, PGS image, and ASS all share the semantics.
final class SubtitleTimingTests: XCTestCase {

    func testZeroDelayKeepsWindow() {
        let pts = SubtitleTiming.shifted(7.0, delay: 0)
        XCTAssertTrue(SubtitleTiming.contains(startPts: 5, endPts: 10, pts: pts))
        XCTAssertFalse(SubtitleTiming.contains(startPts: 10, endPts: 20, pts: pts))
    }

    func testPositiveDelayShowsSubtitleLater() {
        // Display clock at 4.5s, cue covers 5–10s: without delay the cue is
        // not yet active; +1s delay shifts the lookup to 5.5s ⇒ active.
        let pts = SubtitleTiming.shifted(4.5, delay: 1.0)
        XCTAssertTrue(SubtitleTiming.contains(startPts: 5, endPts: 10, pts: pts))
    }

    func testNegativeDelayShowsSubtitleEarlier() {
        // Display clock at 10.5s (cue 5–10 already expired): −1s delay looks
        // back to 9.5s ⇒ still active.
        let pts = SubtitleTiming.shifted(10.5, delay: -1.0)
        XCTAssertTrue(SubtitleTiming.contains(startPts: 5, endPts: 10, pts: pts))
    }

    func testHalfOpenWindowEndIsExclusive() {
        // Cue [5, 10): pts exactly at endPts is NOT active — mirrors the
        // previous `startPts <= displayPts && displayPts < endPts` semantics.
        let pts = SubtitleTiming.shifted(10.0, delay: 0)
        XCTAssertFalse(SubtitleTiming.contains(startPts: 5, endPts: 10, pts: pts))
    }
}
