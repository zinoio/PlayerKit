import XCTest
@testable import PlayerKitNative

/// zyno#358: with the audio anchored at the seek target (fine-seek armed) the clock
/// must NOT be re-labelled forward to a first video frame that landed after the
/// target; otherwise audio starts `videoLand` seconds before the label and lags the
/// picture by that much. The `videoLand` values below were measured on
/// `DISC1 · 00046.m2ts` (31 GB, 4K HEVC HDR10, 115): the audio start offsets after
/// the previous fix (−323 / −167 / −83 ms) were exactly these gaps.
final class ClockCalibrationPolicyTests: XCTestCase {
    private let maxGap = 15.0
    /// audioTime right after a fine-seek reset: target minus the silent primer.
    private let primer = 0.06

    private func decide(frame: Double, audio: Double, force: Bool = false, anchored: Bool) -> Bool {
        ClockCalibrationPolicy.shouldCalibrate(firstFramePts: frame, audioTime: audio,
                                               force: force, audioAnchoredAtTarget: anchored, maxGap: maxGap)
    }

    func testForcedCalibrationAlwaysApplies() {
        XCTAssertTrue(decide(frame: 500.0, audio: 100.0, force: true, anchored: true))
        XCTAssertTrue(decide(frame: 500.0, audio: 100.0, force: true, anchored: false))
    }

    func testAnchoredAudioIsNotRelabelledForwardToALateFirstFrame_zyno358() {
        let target = 1974.84
        for videoLand in [0.083, 0.167, 0.323] {
            XCTAssertFalse(decide(frame: target + videoLand, audio: target - primer, anchored: true),
                           "videoLand +\(videoLand)s must not move the clock forward")
        }
    }

    func testAnchoredAudioStillCalibratesToAnEarlierFrame() {
        // A frame earlier than the clock is the original purpose of calibration.
        XCTAssertTrue(decide(frame: 1974.50, audio: 1974.78, anchored: true))
    }

    func testUnanchoredSmallForwardGapStillCalibrates() {
        // Index-guided seeks (MKV/MP4) and plain play: historical behaviour.
        XCTAssertTrue(decide(frame: 1975.17, audio: 1974.78, anchored: false))
    }

    func testUnanchoredHugeGapDoesNotCalibrate() {
        XCTAssertFalse(decide(frame: 5000.0, audio: 100.0, anchored: false))
    }
}
