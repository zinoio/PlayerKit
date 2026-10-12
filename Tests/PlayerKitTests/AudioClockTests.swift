import XCTest
@testable import PlayerKitNative

final class AudioClockTests: XCTestCase {

    func testInitialAudioTimeIsZero() {
        let clock = AudioClock()
        XCTAssertEqual(clock.audioTime, 0.0)
    }

    func testAdvanceByOneSecond() {
        let clock = AudioClock()
        // 44100Hz, 2ch, float32: 1秒 = 44100 × 2 × 4 = 352800 bytes
        // maxAdvanceSeconds=0.2 的单次调用上限(AudioQueue 批量回调防跳变,见
        // AudioClock.advance 注释)是有意设计,分 5 次入账 1s。
        for _ in 0..<5 { clock.advance(byteCount: 352800 / 5, channels: 2) }
        XCTAssertEqual(clock.audioTime, 1.0, accuracy: 0.001)
    }

    func testPrimeDebtClampsToZero() {
        let clock = AudioClock()
        // 3个 primer buffer，每个 4096 bytes，2ch → 欠账 1536 样本
        clock.startPrimer(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        XCTAssertEqual(clock.audioTime, 0.0, "primer 债务期间 audioTime 应被夹到 0")
    }

    func testPrimeDebtPaidOff() {
        let clock = AudioClock()
        clock.startPrimer(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        // 消费 3 × 4096 bytes 的 primer 数据（偿清债务）
        clock.advance(byteCount: 3 * 4096, channels: 2)
        XCTAssertEqual(clock.audioTime, 0.0, accuracy: 0.001, "债务还清后 audioTime 应为 0")
    }

    func testResetToPosition() {
        let clock = AudioClock()
        clock.advance(byteCount: 352800, channels: 2) // 推进到 1.0s
        clock.reset(to: 10.5, sampleRate: 44100)
        XCTAssertEqual(clock.audioTime, 10.5, accuracy: 0.001)
    }

    func testResetWithDifferentSampleRate() {
        let clock = AudioClock()
        clock.reset(to: 5.0, sampleRate: 48000)
        XCTAssertEqual(clock.audioTime, 5.0, accuracy: 0.001)
        // 48000Hz, 2ch: 1秒 = 48000 × 2 × 4 = 384000 bytes(单次 0.2s 上限,分 5 次)
        for _ in 0..<5 { clock.advance(byteCount: 384000 / 5, channels: 2) }
        XCTAssertEqual(clock.audioTime, 6.0, accuracy: 0.001)
    }

    func testThreadSafety() {
        let clock = AudioClock()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            clock.advance(byteCount: 352, channels: 2)
            _ = clock.audioTime
        }
        XCTAssertGreaterThan(clock.audioTime, 0)
    }

    // MARK: - Playback rate (zyno#99)

    /// Tempo path: the queue reports OUTPUT samples (rate-scaled PCM); the
    /// clock tracks CONTENT time, so the count is scaled by rate. 2x → each
    /// consumed output sample is worth 2 content samples.
    func testAdvanceWithRate2xDoublesContentTime() {
        let clock = AudioClock()
        // 1s of OUTPUT audio at 44.1kHz 2ch float32, consumed at 2x
        // → 2s of CONTENT time (0.2s cap applies after scaling; 5 calls).
        for _ in 0..<5 { clock.advance(byteCount: 352800 / 5, channels: 2, rate: 2.0) }
        XCTAssertEqual(clock.audioTime, 2.0, accuracy: 0.001)
    }

    func testAdvanceWithRateHalfHalvesContentTime() {
        let clock = AudioClock()
        for _ in 0..<5 { clock.advance(byteCount: 352800 / 5, channels: 2, rate: 0.5) }
        XCTAssertEqual(clock.audioTime, 0.5, accuracy: 0.001)
    }

    /// The 0.2s cap is applied in the OUTPUT domain (batched callbacks report
    /// a wall-clock quantity), then scaled: 0.2s of output at 4x = 0.8s of
    /// content. Capping after scaling would discard content time and slow
    /// every rate above 1x.
    func testRateAdvanceCapsOutputDomainThenScales() {
        let clock = AudioClock()
        clock.advance(byteCount: 352800 * 10, channels: 2, rate: 4.0)
        XCTAssertEqual(clock.audioTime, 0.2 * 4.0, accuracy: 0.001,
                       "cap 0.2s output, then ×4 rate → 0.8s content")
    }

    /// Primer buffers are silent and carry no content time: their debt is
    /// recorded in OUTPUT samples and advancePrimer must NOT be rate-scaled,
    /// or the debt and its repayment stop cancelling exactly.
    func testPrimerDebtUnaffectedByAdvanceRate() {
        let clock = AudioClock()
        clock.startPrimer(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        // Repay via advancePrimer (what the callback actually calls)…
        clock.advancePrimer(byteCount: 3 * 4096, channels: 2)
        // …then a 2x content advance on top: 1s of output → 2s of content.
        for _ in 0..<5 { clock.advance(byteCount: 352800 / 5, channels: 2, rate: 2.0) }
        XCTAssertEqual(clock.audioTime, 2.0, accuracy: 0.001,
                       "primer debt must cancel exactly, independent of rate")
    }
}
