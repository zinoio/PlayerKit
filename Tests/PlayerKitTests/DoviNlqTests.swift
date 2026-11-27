import XCTest
import simd
@testable import PlayerKit

final class DoviNlqTests: XCTestCase {

    func testMELDetectionAndNoOpCombine() {
        let mel = DoviNlqData(components: [
            .init(offset: 0, vdrInMax: 1.0, slope: 0, threshold: 0),
            .init(offset: 0, vdrInMax: 1.0, slope: 0, threshold: 0),
            .init(offset: 0, vdrInMax: 1.0, slope: 0, threshold: 0),
        ])
        XCTAssertTrue(mel.isMEL)
        let bl = SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertEqual(DolbyVisionNlq.combine(blSignal: bl, elSignal: SIMD3(0.8, 0.2, 0.9), nlq: mel), bl)
    }

    func testLinearDeadzoneResidualSignClampAndDeadzoneZero() {
        let p = DoviNlqData.Component(offset: 0.5, vdrInMax: 0.2, slope: 0.5, threshold: 0.02)

        // Exact offset → 0 residual
        XCTAssertEqual(DolbyVisionNlq.residual(0.5, params: p), 0, accuracy: 1e-6)

        // Positive residual: (0.7 - 0.5) * 0.5 + 0.02 = 0.12
        XCTAssertEqual(DolbyVisionNlq.residual(0.7, params: p), 0.12, accuracy: 1e-6)

        // Negative symmetry: -(|0.3 - 0.5| * 0.5 + 0.02) = -0.12
        XCTAssertEqual(DolbyVisionNlq.residual(0.3, params: p), -0.12, accuracy: 1e-6)

        // vdrInMax clamping: (1.0 - 0.5) * 0.5 + 0.02 = 0.27 → clamped to 0.2
        XCTAssertEqual(DolbyVisionNlq.residual(1.0, params: p), 0.2, accuracy: 1e-6)
        XCTAssertEqual(DolbyVisionNlq.residual(0.0, params: p), -0.2, accuracy: 1e-6)
    }

    func testCombineAddsResidualAndClampsToUnitRange() {
        let fel = DoviNlqData(components: [
            .init(offset: 0.5, vdrInMax: 0.3, slope: 0.5, threshold: 0.02),
            .init(offset: 0.5, vdrInMax: 0.3, slope: 0.5, threshold: 0.0),
            .init(offset: 0.5, vdrInMax: 0.3, slope: 0.5, threshold: 0.0),
        ])
        XCTAssertFalse(fel.isMEL)

        let out = DolbyVisionNlq.combine(
            blSignal: SIMD3(0.9, 0.5, 0.05),
            elSignal: SIMD3(0.9, 0.6, 0.1),
            nlq: fel
        )
        // x: 0.9 + 0.22 = 1.12 → 1.0
        // y: 0.5 + 0.05 = 0.55
        // z: 0.05 - 0.20 = -0.15 → 0.0
        XCTAssertEqual(out.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(out.y, 0.55, accuracy: 1e-6)
        XCTAssertEqual(out.z, 0.0, accuracy: 1e-6)

        // Missing EL → fallback unchanged
        XCTAssertEqual(DolbyVisionNlq.combine(blSignal: SIMD3(0.4, 0.5, 0.6), elSignal: nil, nlq: fel),
                       SIMD3(0.4, 0.5, 0.6))
    }
}
