import XCTest
@testable import PlayerKitNative

final class FrameRateMatcherTests: XCTestCase {
    private func assertLegacy(
        _ r: (minimum: Double, maximum: Double, preferred: Double),
        _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(r.minimum, FrameRateMatcher.legacyRange.minimum, accuracy: 0.001, context, file: file, line: line)
        XCTAssertEqual(r.maximum, FrameRateMatcher.legacyRange.maximum, accuracy: 0.001, context, file: file, line: line)
        XCTAssertEqual(r.preferred, FrameRateMatcher.legacyRange.preferred, accuracy: 0.001, context, file: file, line: line)
    }

    /// 24/25/30p → conservative doubled preferred rate (48/50/60): even 2:2
    /// gaps without sub-30Hz display modes. minimum pins at the content rate;
    /// maximum stays wide.
    func testCinematicRatesDoubleConservatively() {
        for (fps, preferred) in [(23.976, 47.952), (24.0, 48.0), (25.0, 50.0), (29.97, 59.94), (30.0, 60.0)] {
            let r = FrameRateMatcher.displayRange(contentFps: fps, matchingEnabled: true)
            XCTAssertEqual(r.preferred, preferred, accuracy: 0.001, "fps \(fps)")
            XCTAssertEqual(r.minimum, fps, accuracy: 0.001, "fps \(fps)")
            XCTAssertEqual(r.maximum, 120.0, accuracy: 0.001, "fps \(fps)")
        }
    }

    /// ≥50p content maps to itself — no doubling above the flicker band.
    func testFiftyPlusRatesMapToThemselves() {
        for fps in [50.0, 59.94, 60.0] {
            let r = FrameRateMatcher.displayRange(contentFps: fps, matchingEnabled: true)
            XCTAssertEqual(r.preferred, fps, accuracy: 0.001, "fps \(fps)")
            XCTAssertEqual(r.minimum, fps, accuracy: 0.001, "fps \(fps)")
            XCTAssertEqual(r.maximum, 120.0, accuracy: 0.001, "fps \(fps)")
        }
    }

    /// Disabled (host toggle) and unrecognized rates keep the pre-#106 fixed
    /// range — the feature must be a pure no-op in those cases.
    func testDisabledAndUnknownFallBackToLegacy() {
        assertLegacy(FrameRateMatcher.displayRange(contentFps: 23.976, matchingEnabled: false), "disabled")
        for bad in [0.0, -1.0, Double.nan, Double.infinity, 8.0, 27.0, 31.0, 200.0] {
            assertLegacy(FrameRateMatcher.displayRange(contentFps: bad, matchingEnabled: true), "fps \(bad)")
        }
    }

    /// Probed fps snaps to the nearest common rate within ±0.5; anything
    /// farther off (or nonsense) is rejected.
    func testSnapTolerance() throws {
        XCTAssertEqual(try XCTUnwrap(FrameRateMatcher.normalizedContentRate(24.0)), 24.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(FrameRateMatcher.normalizedContentRate(23.75)), 23.976, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(FrameRateMatcher.normalizedContentRate(29.96)), 29.97, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(FrameRateMatcher.normalizedContentRate(59.5)), 59.94, accuracy: 0.001)
        XCTAssertNil(FrameRateMatcher.normalizedContentRate(27.5))
        XCTAssertNil(FrameRateMatcher.normalizedContentRate(Double.nan))
        XCTAssertNil(FrameRateMatcher.normalizedContentRate(0))
    }
}
