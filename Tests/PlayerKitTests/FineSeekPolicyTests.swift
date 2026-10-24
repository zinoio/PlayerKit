import XCTest
@testable import PlayerKitNative

/// zyno#358: after a byte-domain seek the fine-seek discard must arm for ANY
/// backward landing, not only for gaps above 0.5 s. With the old threshold the
/// audio of a BD m2ts started at its own (earlier) first packet while the clock
/// was labelled with the video landing, so audio lagged the picture by the
/// audio-ahead-of-video mux lead.
///
/// The gaps below are the ones measured on `DISC1 · 00046.m2ts` (31 GB, 4K
/// HEVC HDR10, 115): a track switch landing 0.36 s before its target left the
/// audio 1039 ms behind; one landing 0.21 s before left it 787 ms behind; the
/// initial play landing 1.42 s before was armed and was in sync (+11 ms).
final class FineSeekPolicyTests: XCTestCase {
    func testIndexGuidedSeeksNeverArm() {
        // MKV/MP4: the demuxer reports no landing — historical behaviour.
        XCTAssertFalse(FineSeekPolicy.shouldArm(landed: nil, target: 1573.1))
    }

    func testLandingPastTargetCannotBeDiscardedBack() {
        XCTAssertFalse(FineSeekPolicy.shouldArm(landed: 1573.2, target: 1573.1))
    }

    func testLandingExactlyAtTargetHasNothingToDiscard() {
        XCTAssertFalse(FineSeekPolicy.shouldArm(landed: 1573.1, target: 1573.1))
    }

    func testMeasuredSmallGapsArm_zyno358() {
        // Track switch to AC3: landed 1572.74, target 1573.1 (gap 0.36 s) → audio −1039 ms.
        XCTAssertTrue(FineSeekPolicy.shouldArm(landed: 1572.74, target: 1573.1))
        // Track switch back to TrueHD: landed 1606.19, target 1606.4 (gap 0.21 s) → audio −787 ms.
        XCTAssertTrue(FineSeekPolicy.shouldArm(landed: 1606.19, target: 1606.4))
    }

    func testGapExactlyAtOldThresholdArms() {
        // The old rule was `gap > 0.5`, so exactly 0.5 s fell through unarmed.
        XCTAssertTrue(FineSeekPolicy.shouldArm(landed: 1000.0, target: 1000.5))
    }

    func testLargeGapStillArms() {
        // Initial play of the same disc: landed 1550.84, target 1552.26 (gap 1.42 s) — in sync.
        XCTAssertTrue(FineSeekPolicy.shouldArm(landed: 1550.84, target: 1552.26))
    }
}
