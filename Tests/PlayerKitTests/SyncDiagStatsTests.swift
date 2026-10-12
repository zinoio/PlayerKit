import XCTest
@testable import PlayerKitNative

/// Unit tests for the [diag] sync distribution accumulator (晃动 localization).
final class SyncDiagStatsTests: XCTestCase {

    func testEmptyWindow() {
        var s = SyncDiagStats()
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.mean, 0)
        XCTAssertEqual(s.stddev, 0)
        XCTAssertEqual(s.maxJump, 0)
        XCTAssertEqual(s.signFlips, 0)
    }

    func testKnownSeriesDistribution() {
        var s = SyncDiagStats()
        for v in [0.01, 0.03, -0.01, 0.01] { s.record(v) }
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.min, -0.01, accuracy: 1e-12)
        XCTAssertEqual(s.max, 0.03, accuracy: 1e-12)
        XCTAssertEqual(s.mean, 0.01, accuracy: 1e-12)
        // Consecutive |Δ|: 0.02, 0.04, 0.02.
        XCTAssertEqual(s.maxJump, 0.04, accuracy: 1e-12)
        // Sign sequence + + - + → two flips.
        XCTAssertEqual(s.signFlips, 2)
        // Population sd of {0.01, 0.03, -0.01, 0.01}.
        XCTAssertEqual(s.stddev, 0.0141421356, accuracy: 1e-9)
    }

    func testConstantOffsetHasNoJumpsOrFlips() {
        var s = SyncDiagStats()
        for _ in 0..<100 { s.record(0.045) }
        XCTAssertEqual(s.maxJump, 0, accuracy: 1e-12)
        XCTAssertEqual(s.signFlips, 0)
        XCTAssertEqual(s.stddev, 0, accuracy: 1e-6)  // float accumulation in sum/sumSq
        XCTAssertEqual(s.mean, 0.045, accuracy: 1e-9)
    }

    /// The 晃动 signature: a symmetric oscillation must scream through
    /// flips/jump while a plain large-but-constant offset must not.
    func testOscillationSignature() {
        var s = SyncDiagStats()
        for i in 0..<60 { s.record(i.isMultiple(of: 2) ? 0.05 : -0.05) }
        XCTAssertEqual(s.signFlips, 59)
        XCTAssertEqual(s.maxJump, 0.10, accuracy: 1e-12)
        XCTAssertEqual(s.stddev, 0.05, accuracy: 1e-9)
    }

    func testNonFiniteIgnored() {
        var s = SyncDiagStats()
        s.record(.nan)
        s.record(.infinity)
        s.record(-.infinity)
        XCTAssertEqual(s.count, 0)
    }

    func testMergeAndReset() {
        var a = SyncDiagStats()
        a.record(0.01); a.record(0.02)
        var b = SyncDiagStats()
        b.record(0.03); b.record(-0.05)
        a.merge(b)
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(a.min, -0.05, accuracy: 1e-12)
        XCTAssertEqual(a.max, 0.03, accuracy: 1e-12)
        XCTAssertEqual(a.maxJump, 0.08, accuracy: 1e-12)  // inside b
        XCTAssertEqual(a.mean, 0.0025, accuracy: 1e-12)

        var empty = SyncDiagStats()
        empty.merge(b)
        XCTAssertEqual(empty.count, 2)  // merge into empty adopts the chunk

        a.reset()
        XCTAssertEqual(a.count, 0)
    }
}
