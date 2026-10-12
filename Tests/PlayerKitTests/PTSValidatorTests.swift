import XCTest
@testable import PlayerKitNative

final class PTSValidatorTests: XCTestCase {
    func testNormalPTSPassesThrough() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        XCTAssertEqual(v.validate(0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(v.validate(0.04), 0.04, accuracy: 0.001)
    }
    func testNaNPTSSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(1.0)
        let result = v.validate(.nan)
        XCTAssertEqual(result, 1.04, accuracy: 0.001)
    }
    func testNegativePTSSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(5.0)
        let result = v.validate(-1.0)
        XCTAssertEqual(result, 5.04, accuracy: 0.001)
    }
    func testLargeJumpSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(1.0)
        let result = v.validate(7.0)  // 跳变 6s > jumpThreshold(5s)
        XCTAssertEqual(result, 1.04, accuracy: 0.001)
    }
    func testBlindClockContinuesIncrementing() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        _ = v.validate(.nan)  // predictPTS = 1.04
        let r2 = v.validate(.nan)  // predictPTS = 1.08
        XCTAssertEqual(r2, 1.08, accuracy: 0.001)
    }
    func testRecoveryFromBlindClock() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        _ = v.validate(.nan)  // 盲估 → predictPTS ≈ 1.04
        let result = v.validate(1.05)  // 与 predictPTS 偏差 < 1.0s → 切回
        XCTAssertEqual(result, 1.05, accuracy: 0.001)
    }
    func testResetClearsState() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(100.0)
        v.reset()
        let result = v.validate(0.0)  // reset 后首帧不触发跳变检测
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }
    func testForceRebaseAdoptsLargeJumpWithoutBlindClock() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        // 多clip边界:rebase 后的全局 PTS 从 1s 跳到 60s(59s 跳变 > 5s 阈值)。
        // forceRebase 直接采信为可信基准,后续正常包不被误判进盲钟。
        v.forceRebase(to: 60.0)
        let result = v.validate(60.04)
        XCTAssertEqual(result, 60.04, accuracy: 0.001)
    }
    func testForceRebaseClearsBlindClock() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        _ = v.validate(.nan)  // 进入盲钟
        v.forceRebase(to: 2.0)  // 强制重建基准
        let result = v.validate(2.04)  // 直接通过,不再走盲钟增量
        XCTAssertEqual(result, 2.04, accuracy: 0.001)
    }

    // MARK: - Persistent-offset blind lock (2026-10-13 切轨后画面来回晃)

    /// A physical jump the validator is NOT told about (no reset/rebase) locks
    /// it into the blind clock FOREVER when the jump is a pure offset: the
    /// synthesized prediction and the real timestamps advance at the same rate,
    /// so |pts − predict| never drops below recoveryWindow. Every frame's PTS
    /// is then synthesized, PTS-ordered insertion degenerates to decode order,
    /// and B-frames display out of order — the picture rocks back and forth on
    /// fast motion. This is why a demuxer jump MUST bump
    /// physicalSeekGeneration (performDemuxerSeek and, since this fix,
    /// selectAudioTrack).
    func testUnresetOffsetLocksBlindClockPermanently() {
        var v = PTSValidator(frameDuration: 1.0 / 24.0)
        _ = v.validate(100.0)  // pre-switch baseline
        // Landing 6s behind (seek byte-estimate error) — every real packet is
        // ~6s below the synthesized prediction.
        var rewritten = 0
        for i in 0..<240 {
            let real = 94.0 + Double(i) / 24.0
            if abs(v.validate(real) - real) > 0.0005 { rewritten += 1 }
        }
        XCTAssertEqual(rewritten, 240, "offset-blind lock must rewrite every frame — the failure this guards against")
    }

    /// The same jump WITH a reset (what a physical-seek generation bump buys)
    /// passes through cleanly: the landing frame re-baselines the validator.
    func testResetAdoptsTheJumpedBaseline() {
        var v = PTSValidator(frameDuration: 1.0 / 24.0)
        _ = v.validate(100.0)
        v.reset()
        var rewritten = 0
        for i in 0..<240 {
            let real = 94.0 + Double(i) / 24.0
            if abs(v.validate(real) - real) > 0.0005 { rewritten += 1 }
        }
        XCTAssertEqual(rewritten, 0, "after reset the jumped timeline is the new truth")
    }
}
