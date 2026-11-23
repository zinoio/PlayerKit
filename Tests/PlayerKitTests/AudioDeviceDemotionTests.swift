import XCTest
import AudioToolbox
@testable import PlayerKitNative

/// #608 回归:音频输出设备异常停机(kAudioDevicePropertyIOStoppedAbnormally,
/// 真机 2026-11-23:LG UltraFine DP 音频起播 10s 后停机)后,AudioQueueStart
/// 恒被 HAL 拒绝('stop'),starved-rebuild 每 10s 重建同样失败,音频主导的
/// 主时钟冻结 → 视频以 0~0.7fps 爬行 → UI 永远「正在缓冲」,无任何提示。
///
/// 修复语义:连续 AudioQueueStart 失败越过阈值 → **降级**
/// (`AudioDeviceHealth` 纯逻辑,CI 无设备可测):
/// - 降级期 enqueue 丢帧、resume 不再 Start(零打扰,不给 HAL 喂锤);
/// - 降级期 starvation-rebuild 变为按 `probeInterval` 节流的探测;
/// - **真实回调**(设备 IO 复活的唯一铁证)→ 复位 + 恢复边沿,
///   backend 收到后重校准时钟回切音频同步。
final class AudioDeviceDemotionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AudioUnitOutput.startImpl = { AudioQueueStart($0, nil) }
    }

    override func tearDown() {
        AudioUnitOutput.startImpl = { AudioQueueStart($0, nil) }
        super.tearDown()
    }

    // MARK: - AudioDeviceHealth(纯逻辑)

    func testConsecutiveFailuresCrossingThresholdDemoteOnce() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 4
        XCTAssertFalse(h.isDemoted)
        for i in 1...3 {
            let edge = h.recordStartFailure(now: Double(i))
            XCTAssertFalse(h.isDemoted, "第\(i)次失败不应降级")
            XCTAssertFalse(edge)
        }
        let edge = h.recordStartFailure(now: 4)
        XCTAssertTrue(h.isDemoted, "第 4 次连续失败必须降级")
        XCTAssertTrue(edge, "降级边沿必须上报一次(backend 据此切时钟)")
        XCTAssertEqual(h.demotionCount, 1)
        // 降级后的继续失败不再重复触发边沿
        for i in 5...8 {
            XCTAssertFalse(h.recordStartFailure(now: Double(i)), "已降级,不得重复边沿")
        }
        XCTAssertEqual(h.demotionCount, 1)
    }

    func testCallbackResetsFailureCountStartSuccessDoesNot() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 4
        // Start 成功不证明设备活着(半死态:队列能 start 但不出声),不得复位
        for _ in 1...3 { _ = h.recordStartFailure(now: 1) }
        h.recordStartSuccess()
        XCTAssertTrue(h.recordStartFailure(now: 2),
                      "Start 成功不得复位计数:紧接的第 4 次失败仍必须降级")
        XCTAssertEqual(h.demotionCount, 1)
        // 真实回调才是铁证:降级中的回调 = 恢复边沿(并复位计数)
        XCTAssertTrue(h.recordDeviceAlive(now: 3), "降级中回调必须报恢复边沿")
        XCTAssertFalse(h.isDemoted)
        XCTAssertFalse(h.recordDeviceAlive(now: 3.1), "恢复后的重复回调不构成边沿")
        // 复位后再来一轮完整失败才降级
        for i in 4...6 {
            XCTAssertFalse(h.recordStartFailure(now: Double(i)))
        }
        XCTAssertTrue(h.recordStartFailure(now: 7), "复位后需重新积累 4 次失败")
        XCTAssertEqual(h.demotionCount, 2)
    }

    func testRecoveryEdgeOnCallbackWhileDemoted() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 2
        _ = h.recordStartFailure(now: 1)
        XCTAssertTrue(h.recordStartFailure(now: 2), "阈值 2:第二次失败降级")
        XCTAssertTrue(h.isDemoted)
        // 降级探测期设备复活:回调 = 恢复边沿
        XCTAssertTrue(h.recordDeviceAlive(now: 10), "降级中回调必须上报恢复边沿")
        XCTAssertFalse(h.isDemoted, "恢复后退出降级")
        // 恢复后重复回调不是边沿
        XCTAssertFalse(h.recordDeviceAlive(now: 11))
        XCTAssertEqual(h.demotionCount, 1)
    }

    func testProbeGatingOnlyWhenDemoted() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 1
        h.probeInterval = 10
        // 未降级:恒可探测(starvation rebuild 语义不变)
        XCTAssertTrue(h.shouldProbe(now: 0))
        XCTAssertTrue(h.shouldProbe(now: 1))
        _ = h.recordStartFailure(now: 2)
        XCTAssertTrue(h.isDemoted)
        // 降级后:首次到点即可探测,间隔内不再探测
        XCTAssertTrue(h.shouldProbe(now: 2), "降级后第一次探测立即放行")
        h.recordProbedAt(now: 2)
        XCTAssertFalse(h.shouldProbe(now: 7), "间隔 10s 内不得重复探测(不打扰 HAL)")
        XCTAssertTrue(h.shouldProbe(now: 12.1), "到点后放行下一次探测")
    }

    // MARK: - AudioUnitOutput 接线

    /// 降级后 resume() 不得再调 AudioQueueStart(零打扰),降级边沿回调上报。
    func testDemotedResumeSkipsStartCalls() throws {
        let output = AudioUnitOutput(clock: AudioClock(), delaySecs: 0)
        output.start(sampleRate: 48000, channels: 2)
        guard output.hasQueueForTesting else {
            throw XCTSkip("无音频设备环境(CI):接线行为由设备在机时验证")
        }
        // 本机音频设备活跃时,真实回调会按设计把降级标记复活
        // (recordDeviceAlive),接线断言天然不确定——语义由纯逻辑测试
        // 确定性覆盖,此处仅在「无回调环境」(CI 虚拟设备)下运行。
        usleep(300_000)
        try XCTSkipIf(output.drainQueueDiag().callbackCount > 0,
                      "本机音频设备活跃:真实回调按设计复活队列")
        let health = output.deviceHealthForTesting
        health.demoteThreshold = 1
        var startCalls = 0
        var demotedNotified = false
        AudioUnitOutput.startImpl = { _ in startCalls += 1; return 1937010544 }
        output.onDeviceDemoted = { demotedNotified = true }
        output.resume()
        // controlQueue 异步,等落地
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !demotedNotified { usleep(10_000) }
        XCTAssertTrue(demotedNotified, "Start 失败越过阈值必须上报降级边沿")
        XCTAssertTrue(health.isDemoted)
        let callsAfterDemotion = startCalls
        output.resume()
        output.resume()
        usleep(200_000)
        XCTAssertEqual(startCalls, callsAfterDemotion, "降级后 resume 不得再 Start(不给 HAL 喂锤)")
    }

    /// 降级后 enqueue 直接丢帧:不进队列、不计数、不触发 Start。
    func testDemotedEnqueueDropsFramesWithoutStart() throws {
        let output = AudioUnitOutput(clock: AudioClock(), delaySecs: 0)
        output.start(sampleRate: 48000, channels: 2)
        guard output.hasQueueForTesting else {
            throw XCTSkip("无音频设备环境(CI):接线行为由设备在机时验证")
        }
        usleep(300_000)
        try XCTSkipIf(output.drainQueueDiag().callbackCount > 0,
                      "本机音频设备活跃:真实回调按设计复活队列")
        let health = output.deviceHealthForTesting
        health.demoteThreshold = 1
        var startCalls = 0
        AudioUnitOutput.startImpl = { _ in startCalls += 1; return 1937010544 }
        output.onDeviceDemoted = {}
        output.resume()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !health.isDemoted { usleep(10_000) }
        XCTAssertTrue(health.isDemoted)

        let enqueuesBefore = output.drainQueueDiag().enqueues
        let frame = PCMFrame(data: Data(repeating: 0, count: 1024 * 2 * 4),
                             pts: 1.0, sampleCount: 1024)
        output.enqueue(frame, contentPts: 1.0)
        usleep(100_000)
        XCTAssertEqual(output.drainQueueDiag().enqueues, enqueuesBefore, "降级期入队必须被丢弃")
        let calls = startCalls
        output.enqueue(frame, contentPts: 2.0)
        usleep(100_000)
        XCTAssertEqual(startCalls, calls, "降级期入队不得触发 Start")
    }
}
