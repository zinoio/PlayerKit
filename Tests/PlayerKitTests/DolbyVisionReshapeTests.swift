import XCTest
import simd
@testable import PlayerKit

/// Unit tests for the DoVi RPU reshape CPU reference implementation
/// (`DolbyVisionReshape`) — synthetic curves with hand-computed expectations.
///
/// Reference semantics: libplacebo `pl_shader_dovi_reshape` +
/// `PL_COLOR_SYSTEM_DOLBYVISION` decode (shaders/colorspace.c). Every test
/// below encodes one of the semantics that is easy to get wrong.
final class DolbyVisionReshapeTests: XCTestCase {

    // MARK: - Helpers

    /// Identity polynomial piece: s' = s.
    private static let identityPiece = DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 1, 0))

    /// SIMD3 doesn't conform to FloatingPoint — assert per component.
    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<3 {
            XCTAssertEqual(a[i], b[i], accuracy: accuracy, file: file, line: line)
        }
    }

    private func singlePieceCurve(_ piece: DoviReshapingCurve.Piece,
                                  pivots: [Float] = [0, 1],
                                  rgbToLms: [[Float]]? = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]) -> DoviReshapingCurve {
        DoviReshapingCurve(
            components: (0..<3).map { _ in
                DoviReshapingCurve.Component(pivots: pivots, pieces: [piece])
            },
            rgbToLms: rgbToLms)
    }

    // MARK: - Polynomial

    func testPolyOrder1LinearGain() {
        // s' = 0.1 + 0.5·s
        let curve = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0.1, 0.5, 0)))
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.5))
        assertEqual(out, SIMD3(repeating: 0.35), accuracy: 1e-6)
    }

    func testPolyOrder2Quadratic() {
        // s' = s²
        let curve = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 0, 1)))
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.5))
        assertEqual(out, SIMD3(repeating: 0.25), accuracy: 1e-6)
    }

    func testPieceSelectionByPivots() {
        // Two pieces on [0, 0.5, 1]: below 0.5 → s' = 2s; at/above 0.5 → s' = s - 0.5.
        let curve = DoviReshapingCurve(
            components: (0..<3).map { _ in
                DoviReshapingCurve.Component(
                    pivots: [0, 0.5, 1],
                    pieces: [
                        DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 2, 0)),
                        DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(-0.5, 1, 0)),
                    ])
            },
            rgbToLms: nil)
        XCTAssertEqual(DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.25)).x, 0.5, accuracy: 1e-6)
        // Boundary value belongs to the upper piece (s >= pivots[1]).
        XCTAssertEqual(DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.5)).x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.75)).x, 0.25, accuracy: 1e-6)
    }

    func testOutputClampsToPivotRange() {
        // s' = 4s blows past the pivot ceiling of 1; negative intercept blows
        // past the floor of 0. Both must clamp to the component's pivots.
        let high = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 4, 0)),
                                    pivots: [0, 1])
        XCTAssertEqual(DolbyVisionReshape.apply(high, signal: SIMD3(repeating: 0.8)).x, 1.0, accuracy: 1e-6)
        let low = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(-0.5, 1, 0)),
                                   pivots: [0, 1])
        XCTAssertEqual(DolbyVisionReshape.apply(low, signal: SIMD3(repeating: 0.2)).x, 0.0, accuracy: 1e-6)
    }

    func testNonNormalizedInputIsClampedToUnitRangeBeforeReshaping() {
        // sig = clamp(rgb, 0, 1) — out-of-range code values (10-bit carrier
        // overflow) enter the curve saturated.
        let curve = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 1, 0)))
        XCTAssertEqual(DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 1.4)).x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: -0.2)).x, 0.0, accuracy: 1e-6)
    }

    // MARK: - MMR

    func testMMROrder1LinearAndConstant() {
        // c0: s' = 0.1 + sx;  c1: s' = 0.1 + sy;  c2: s' = 0.1 + sz
        var curve = DoviReshapingCurve(
            components: [], rgbToLms: nil)
        for c in 0..<3 {
            var coefs = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 1)
            coefs[0][c] = 1
            curve.components.append(DoviReshapingCurve.Component(
                pivots: [0, 1],
                pieces: [DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 1, mmrConstant: 0.1, mmrCoef: coefs)]))
        }
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(0.5, 0.2, 0.8))
        XCTAssertEqual(out.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(out.y, 0.3, accuracy: 1e-6)
        XCTAssertEqual(out.z, 0.9, accuracy: 1e-6)
    }

    func testMMRCrossTerms() {
        // c0 linear coefficient zero, cross coefficient sx·sy = 1 → s' = sx·sy.
        // c1 picks sx·sz, c2 picks sy·sz.
        var curve = DoviReshapingCurve(components: [], rgbToLms: nil)
        let crossIndex = [3, 4, 5] // (sx·sy, sx·sz, sy·sz)
        for c in 0..<3 {
            var coefs = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 1)
            coefs[0][crossIndex[c]] = 1
            curve.components.append(DoviReshapingCurve.Component(
                pivots: [0, 1],
                pieces: [DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 1, mmrConstant: 0, mmrCoef: coefs)]))
        }
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(0.5, 0.4, 0.8))
        XCTAssertEqual(out.x, 0.2, accuracy: 1e-6)  // 0.5·0.4
        XCTAssertEqual(out.y, 0.4, accuracy: 1e-6)  // 0.5·0.8
        XCTAssertEqual(out.z, 0.32, accuracy: 1e-6) // 0.4·0.8
    }

    func testMMRUsesRawSignalNotReshapedValues() {
        // Component 0 doubles sx (reshaped 0.8); component 1's linear term
        // uses sx. If the implementation cascaded reshaped values it would
        // see 0.8 — the correct answer is the raw 0.4.
        var curve = DoviReshapingCurve(components: [], rgbToLms: nil)
        var coefs0 = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 1)
        coefs0[0][0] = 2
        curve.components.append(DoviReshapingCurve.Component(
            pivots: [0, 1],
            pieces: [DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 1, mmrConstant: 0, mmrCoef: coefs0)]))
        var coefs1 = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 1)
        coefs1[0][0] = 1
        curve.components.append(DoviReshapingCurve.Component(
            pivots: [0, 1],
            pieces: [DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 1, mmrConstant: 0, mmrCoef: coefs1)]))
        curve.components.append(DoviReshapingCurve.Component(pivots: [0, 1], pieces: []))

        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(0.4, 0.4, 0.4))
        XCTAssertEqual(out.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(out.y, 0.4, accuracy: 1e-6, "MMR must see raw code-domain signal, not reshaped component 0")
        XCTAssertEqual(out.z, 0.4, accuracy: 1e-6, "component without pieces passes through")
    }

    func testMMROrder2SquaredTerms() {
        // s' = 0.5·sx² (squared linear slot of order 2).
        var coefs = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 2)
        coefs[1][0] = 0.5
        let curve = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 2, mmrConstant: 0, mmrCoef: coefs))
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.5))
        XCTAssertEqual(out.x, 0.125, accuracy: 1e-6)
    }

    func testMMROrder3CubicTerms() {
        // s' = sx³ (cubic linear slot of order 3) … via 0.5·sx²·sx.
        var coefs = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 3)
        coefs[2][0] = 0.5
        let curve = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: true, mmrOrder: 3, mmrConstant: 0, mmrCoef: coefs))
        let out = DolbyVisionReshape.apply(curve, signal: SIMD3(repeating: 0.5))
        XCTAssertEqual(out.x, 0.0625, accuracy: 1e-6) // 0.5 · 0.125
    }

    // MARK: - Decode (shaped → BT.2020 PQ)

    func testIdentityCurveDecodeKeepsNeutralGray() {
        // Identity reshape + an rgb_to_lms whose rows are identical: the
        // decoded triplet is three-channel-equal (gray) regardless of the
        // per-channel linear values. (Real P5 streams guarantee code-domain
        // neutrality through the *pair* of curve + matrix; the gray
        // invariant under test here is decodeShaped's alone.)
        let curve = singlePieceCurve(Self.identityPiece,
                                     rgbToLms: [[1, 0, 0], [1, 0, 0], [1, 0, 0]])
        let shaped = DolbyVisionReshape.apply(curve, signal: SIMD3(0.9, 0.5, 0.5))
        assertEqual(shaped, SIMD3(0.9, 0.5, 0.5), accuracy: 1e-6)
        let decoded = DolbyVisionReshape.decodeShaped(shaped, rgbToLms: curve.rgbToLms!)
        XCTAssertEqual(decoded.x, decoded.y, accuracy: 1e-3)
        XCTAssertEqual(decoded.y, decoded.z, accuracy: 1e-3)
    }

    func testDecodeShapedMonotonicInIntensity() {
        let rgbToLms = [[Float(1), 0, 0], [0, 1, 0], [0, 0, 1]]
        let low = DolbyVisionReshape.decodeShaped(SIMD3(repeating: 0.2), rgbToLms: rgbToLms)
        let high = DolbyVisionReshape.decodeShaped(SIMD3(repeating: 0.6), rgbToLms: rgbToLms)
        XCTAssertLessThan(low.x, high.x)
        XCTAssertLessThan(low.y, high.y)
        XCTAssertLessThan(low.z, high.z)
        // PQ is bounded [0, 1] for in-range input.
        XCTAssertTrue(high.x.isFinite && high.x <= 1.0)
    }

    // MARK: - Piece cache sanity

    func testCurvesWithDifferentPiecesAreNotEqual() {
        let a = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 1, 0)))
        let b = singlePieceCurve(DoviReshapingCurve.Piece(isMMR: false, polyCoef: SIMD3(0, 2, 0)))
        XCTAssertNotEqual(a, b, "uniform-cache Equatable must distinguish coefficient changes")
    }
}
