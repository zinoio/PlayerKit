import XCTest
@testable import PlayerKitNative

/// zyno#104 音频延迟:AudioClock 折叠(d<0 时钟偏移 + 延迟线 hold 读回)与
/// AudioDelayLine 泵规则。
///
/// 语义模型(勿按设计文档 §4.1 的统一式实现——那是错的):sync 是反馈环,
/// 纯输出侧持流若不被时钟读回,画面会被拉回 heard 位置,相对偏移被完全抵消。
/// 正确式:audioTime = consumed/sr + lineHold + min(0, d);锚点(reset/calibrate)
/// 保持 consumed ≡ t·sr 不变。
final class AudioDelayTests: XCTestCase {

    private func makeFrame(seconds: Double, sr: Int32 = 48000, pts: Double = 0) -> PCMFrame {
        let samples = Int(seconds * Double(sr))
        return PCMFrame(data: Data(count: samples * 8), pts: pts, sampleCount: samples)
    }

    // MARK: - AudioClock

    func testNegativeDelayShiftsClockWithoutContent() {
        let clock = AudioClock()
        clock.setDelay(-0.5)
        // 未消费任何输出:audioTime 合法地为负(画面由 sync 延后,音频未出声)。
        XCTAssertEqual(clock.audioTime, -0.5, accuracy: 0.0001)
        // 锚点不变:reset 仍按 consumed ≡ t·sr 落,读数 = t + min(0,d)。
        clock.reset(to: 10.0, sampleRate: 44100)
        XCTAssertEqual(clock.audioTime, 9.5, accuracy: 0.001)
        // 消费推进后保持 −|d| 偏移。
        for _ in 0..<5 { clock.advance(byteCount: 44100 * 8 / 5, channels: 2) }
        XCTAssertEqual(clock.audioTime, 10.5, accuracy: 0.001)
    }

    func testPositiveDelayNeedsLineHoldReported() {
        let clock = AudioClock()
        clock.setDelay(2.0)
        // d>0 的物理持流在延迟线里;时钟自身零变化(无 hold 读回时读数不动)。
        XCTAssertEqual(clock.audioTime, 0.0, accuracy: 0.0001)
        clock.reset(to: 5.0, sampleRate: 48000)
        XCTAssertEqual(clock.audioTime, 5.0, accuracy: 0.001, "锚点不被 d>0 偏移")
        // 延迟线回报 hold 后,时钟读 feed 侧:consumed 仍从锚点起算。
        clock.setExternalHold(2.0)
        XCTAssertEqual(clock.audioTime, 7.0, accuracy: 0.001)
    }

    func testCalibrateAnchorUnchangedWithNegativeDelay() {
        let clock = AudioClock()
        clock.setDelay(-3.0)
        clock.startPrimer(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        // calibrate 到 t:consumed ≡ t·sr − primer 债(与无延迟时完全一致),
        // 读数再叠 min(0,d)。
        clock.calibrate(to: 100.0, sampleRate: 44100)
        let withoutDelay = AudioClock()
        withoutDelay.startPrimer(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        withoutDelay.calibrate(to: 100.0, sampleRate: 44100)
        XCTAssertEqual(clock.audioTime, withoutDelay.audioTime - 3.0, accuracy: 0.0001,
                       "锚点公式与延迟无关,只差 min(0,d) 偏移")
    }

    func testHasConsumedOutputIgnoresNegativeOffset() {
        let clock = AudioClock()
        clock.setDelay(-5.0)
        XCTAssertFalse(clock.hasConsumedOutput, "d<0 下 audioTime 为负,ready 测试必须看 consumed")
        // 消费 ≥ 1ms 即 ready(primer 债还清前 consumed 为负,同样不算)。
        clock.advance(byteCount: 48000 * 8 / 100, channels: 2) // 10ms
        XCTAssertTrue(clock.hasConsumedOutput)
    }

    func testNegativeHoldExposesOnlyNegativePart() {
        let clock = AudioClock()
        clock.setDelay(1.5)
        XCTAssertEqual(clock.negativeHold, 0.0)
        clock.setDelay(-0.7)
        XCTAssertEqual(clock.negativeHold, -0.7, accuracy: 0.0001)
    }

    // MARK: - AudioDelayLine 泵规则

    func testZeroTargetIsPassThrough() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        let due = line.push(makeFrame(seconds: 0.02), contentPts: 1.0)
        XCTAssertEqual(due.count, 1, "target=0 逐帧直通")
        XCTAssertEqual(line.heldSeconds, 0.0, accuracy: 0.0001)
    }

    func testHoldFillsBeforeReleasing() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        line.setTarget(0.5)
        // 0.3s:不足 target(弹出后剩 0 < 0.5),全留。
        var due = line.push(makeFrame(seconds: 0.3), contentPts: 1.0)
        XCTAssertEqual(due.count, 0)
        XCTAssertEqual(line.heldSeconds, 0.3, accuracy: 0.001)
        // 再入 0.3s:held 0.6,弹出头部后剩 0.3 < 0.5 → 仍不出。
        due = line.push(makeFrame(seconds: 0.3), contentPts: 2.0)
        XCTAssertEqual(due.count, 0)
        // 第三帧:held 0.9,弹出头部后剩 0.6 ≥ 0.5 → 出 1 帧后停。
        due = line.push(makeFrame(seconds: 0.3), contentPts: 3.0)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.contentPts, 1.0, "按入队序出队")
        XCTAssertEqual(line.heldSeconds, 0.6, accuracy: 0.001,
                       "稳态 held ∈ [target, target+head)")
    }

    func testRaiseTargetStarvesPump() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        line.setTarget(0.1)
        // 0.15s:弹出后剩 0 < 0.1 → 不出,held 0.15。
        _ = line.push(makeFrame(seconds: 0.15), contentPts: 1.0)
        XCTAssertEqual(line.heldSeconds, 0.15, accuracy: 0.001)
        line.setTarget(0.5)
        _ = line.push(makeFrame(seconds: 0.3), contentPts: 2.0)
        XCTAssertEqual(line.heldSeconds, 0.45, accuracy: 0.001,
                       "调大 target:不足新目标不释放(出声侧=静音间隙)")
        _ = line.push(makeFrame(seconds: 0.3), contentPts: 3.0)
        XCTAssertGreaterThanOrEqual(line.heldSeconds, 0.5 - 0.001,
                                    "达到 target 后恢复出队")
    }

    func testLowerTargetDrainsImmediately() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        line.setTarget(0.5)
        _ = line.push(makeFrame(seconds: 0.4), contentPts: 1.0)
        _ = line.push(makeFrame(seconds: 0.4), contentPts: 2.0)
        XCTAssertEqual(line.heldSeconds, 0.8, accuracy: 0.001,
                       "0.8−0.4=0.4 < 0.5,两帧都留")
        // 调小到 0.05:头部因低目标变 due,立即排到不变式成立(丢头部=一次跳变)。
        let due = line.setTarget(0.05)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.contentPts, 1.0)
        XCTAssertEqual(line.heldSeconds, 0.4, accuracy: 0.001)
    }

    func testFlushDropsEverything() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        line.setTarget(1.0)
        _ = line.push(makeFrame(seconds: 0.5), contentPts: 1.0)
        line.flush()
        XCTAssertEqual(line.heldSeconds, 0.0, accuracy: 0.0001)
        // flush 后恢复正常推入。
        let due = line.push(makeFrame(seconds: 0.2), contentPts: 2.0)
        XCTAssertEqual(due.count, 0)
        XCTAssertEqual(line.heldSeconds, 0.2, accuracy: 0.001)
    }

    func testHoldChangeNotifiedWithFinalValue() {
        let line = AudioDelayLine()
        line.configure(sampleRate: 48000)
        var holds: [Double] = []
        line.onHoldChange = { holds.append($0) }
        line.setTarget(0.4)
        _ = line.push(makeFrame(seconds: 0.25), contentPts: 1.0)
        _ = line.push(makeFrame(seconds: 0.25), contentPts: 2.0)
        line.flush()
        XCTAssertEqual(holds.last ?? -1, 0.0, accuracy: 0.0001, "flush 后回报 0")
        XCTAssertTrue(holds.contains { abs($0 - 0.25) < 0.002 }
                      && holds.contains { abs($0 - 0.5) < 0.002 },
                      "填池期 hold 增长必须逐次回报(时钟渐进前移的依据)")
    }

    // MARK: - AudioUnitOutput 集成(content↔wall 换算)

    func testOutputScalesTargetByRate() {
        let clock = AudioClock()
        let out = AudioUnitOutput(clock: clock, delaySecs: 0)
        // 构造时不带延迟 = 直通;运行时设置后按 rate 换算 wall target。
        out.setDelayTarget(contentSecs: 0.8)
        out.setPlaybackRate(2.0) // wall target = 0.4s
        // 直接推 line 域:0.3s wall 不足 0.4s → 无 due(经 enqueue 入口)。
        // enqueue 无活跃 AudioQueue 时 enqueueDirect 丢帧,但延迟线照常工作,
        // 可用 hasPendingOutput/held 侧写。用 AudioDelayLine 语义等价验证:
        // 这里只验证 setDelayTarget/rate 组合后时钟 hold 读数为 content 域。
        out.enqueue(makeFrame(seconds: 0.3), contentPts: 1.0)
        // hold = held(wall) × rate = 0.3 × 2 = 0.6 content 秒(d>0 部分叠加)。
        XCTAssertEqual(clock.audioTime, 0.6, accuracy: 0.001,
                       "时钟 hold 读数 = wall held × rate(content 域)")
        out.setDelayTarget(contentSecs: 0)
        XCTAssertEqual(clock.audioTime, 0.0, accuracy: 0.001,
                       "target 归零:排空 due 后 hold 回 0(无队列时 due 被丢弃)")
    }

    func testOutputHasPendingOutputReflectsLineAndQueue() {
        let clock = AudioClock()
        let out = AudioUnitOutput(clock: clock, delaySecs: 1.0)
        XCTAssertFalse(out.hasPendingOutput)
        out.enqueue(makeFrame(seconds: 0.2), contentPts: 1.0)
        XCTAssertTrue(out.hasPendingOutput, "帧停在延迟线里 = 仍有待播输出")
    }
}
