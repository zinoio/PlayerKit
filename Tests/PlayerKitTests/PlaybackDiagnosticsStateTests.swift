import XCTest
import PlayerKit

/// P1 playback diagnostics (zinora #445 ①): the two new state fields are
/// additive and default to "unknown" so old consumers keep working.
final class PlaybackDiagnosticsStateTests: XCTestCase {
    func testDefaultsAreUnknown() {
        let state = PlayerState()
        XCTAssertNil(state.videoDecoderPath)
        XCTAssertFalse(state.videoBitrateIsEstimated)
        XCTAssertEqual(state.recentDroppedVideoFrames, 0)
        XCTAssertEqual(state.droppedVideoFramesPerSecond, 0)
    }

    func testDiagnosticsFieldsAreAssignable() {
        var state = PlayerState()
        state.videoDecoderPath = .videoToolbox
        state.videoBitrateIsEstimated = true
        state.recentDroppedVideoFrames = 7
        state.droppedVideoFramesPerSecond = 1.4
        XCTAssertEqual(state.videoDecoderPath, .videoToolbox)
        XCTAssertTrue(state.videoBitrateIsEstimated)
        XCTAssertEqual(state.recentDroppedVideoFrames, 7)
        XCTAssertEqual(state.droppedVideoFramesPerSecond, 1.4)

        state.videoDecoderPath = .ffmpegSoftware
        XCTAssertEqual(state.videoDecoderPath, .ffmpegSoftware)
    }
}
