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
        AudioUnitOutput.startImpl = { AudioOutputUnitStart($0) }
    }

    override func tearDown() {
        AudioUnitOutput.startImpl = { AudioOutputUnitStart($0) }
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
        XCTAssertTrue(h.isDemoted, "第 4 次失败必须降级")
        XCTAssertTrue(edge, "降级边沿必须上报一次(backend 据此切时钟)")
        XCTAssertEqual(h.demotionCount, 1)
        // 降级后的继续失败不再重复触发边沿
        for i in 5...8 {
            XCTAssertFalse(h.recordStartFailure(now: Double(i)), "已降级,不得重复边沿")
        }
        XCTAssertEqual(h.demotionCount, 1)
    }

    /// 2026-11-23 真机第二轮:半死设备会偶发回一个孤立回调再彻底停转——
    /// 严格「连续」计数被孤立回调清零,失败在 10s 间隔下永远凑不满 4 次,
    /// 降级永不触发(真机 5 次失败无一次降级)。改为**滑动窗口**计数:
    /// 孤立回调不再清零;窗口(120s)内的失败累计够阈值即降级。
    func testStrayCallbackDoesNotResetFailureWindow() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 4
        _ = h.recordStartFailure(now: 1)
        _ = h.recordStartFailure(now: 11)
        // 孤立回调(半死设备的残余回跳)夹在失败之间:不得清零窗口
        XCTAssertFalse(h.recordDeviceAlive(now: 15), "未降级时的回调不构成恢复边沿")
        XCTAssertFalse(h.isDemoted)
        _ = h.recordStartFailure(now: 21)
        XCTAssertTrue(h.recordStartFailure(now: 31),
                      "4 次失败(120s 窗口内)必须降级,孤立回调不得清零")
        XCTAssertEqual(h.demotionCount, 1)
        // 降级中的回调 = 恢复边沿(并清空窗口)
        XCTAssertTrue(h.recordDeviceAlive(now: 35), "降级中回调必须报恢复边沿")
        XCTAssertFalse(h.isDemoted)
        XCTAssertFalse(h.recordDeviceAlive(now: 35.1), "恢复后的重复回调不构成边沿")
        // 恢复后从头积累(旧失败已被恢复清空)
        for i in 40...42 {
            XCTAssertFalse(h.recordStartFailure(now: Double(i)))
        }
        XCTAssertTrue(h.recordStartFailure(now: 43), "恢复后需重新积累 4 次失败")
        XCTAssertEqual(h.demotionCount, 2)
    }

    /// 失败超出窗口不算数:旧失败滑出窗口后,剩余次数不足不降级。
    func testFailuresOutsideWindowExpire() {
        let h = AudioDeviceHealth()
        h.demoteThreshold = 4
        h.failureWindow = 60
        _ = h.recordStartFailure(now: 0)
        _ = h.recordStartFailure(now: 10)
        _ = h.recordStartFailure(now: 20)
        // 到 100s 时前三次已滑出 60s 窗口:第 4 次失败 = 窗口内第 1 次
        XCTAssertFalse(h.recordStartFailure(now: 100), "滑出窗口的旧失败不得累计")
        XCTAssertFalse(h.isDemoted)
        _ = h.recordStartFailure(now: 110)
        _ = h.recordStartFailure(now: 120)
        XCTAssertTrue(h.recordStartFailure(now: 130), "窗口内第 4 次失败必须降级")
        XCTAssertEqual(h.demotionCount, 1)
    }

    /// 音频时钟停转看门狗(纯逻辑):设备半死时偶发孤立回调,连续失败计数
    /// 不可靠——真正的判据是「音频时钟是否在真实推进」。3s 窗口内推进
    /// < 0.1s ⇒ 判定停转;正常 1x 推进不误报;停顿后窗口重置可再次判定。
    func testStallWatchdogDetectsFrozenClock() {
        var wd = AudioStallWatchdog()
        // 正常推进:每 0.5s 采样,1x 时钟 → 永不判停
        var t = 0.0
        var a = 100.0
        while t < 10 {
            XCTAssertFalse(wd.note(now: t, audioTime: a), "1x 时钟不得误报停顿 t=\(t)")
            t += 0.5; a += 0.5
        }
        // 设备停转:重置基线后时钟冻结
        wd.reset()
        let frozen = a
        XCTAssertFalse(wd.note(now: t, audioTime: frozen), "基线采样")
        XCTAssertFalse(wd.note(now: t + 2.0, audioTime: frozen), "窗口未满不判")
        XCTAssertTrue(wd.note(now: t + 3.5, audioTime: frozen),
                      "3s 窗口内零推进必须判定停转")
        // 判定后窗口重置:继续冻结,再 3s 再判
        XCTAssertFalse(wd.note(now: t + 5.0, audioTime: frozen), "重置后窗口未满")
        XCTAssertTrue(wd.note(now: t + 7.0, audioTime: frozen),
                      "窗口重置后持续冻结需再次判定")
    }

    /// 偶发孤立回调(半死设备回跳 23ms 然后再次冻结)依然判定停转。
    func testStallWatchdogSeesThroughStrayCallbacks() {
        var wd = AudioStallWatchdog()
        var t = 0.0
        var a = 50.0
        // 建立正常窗口
        while t < 4 { _ = wd.note(now: t, audioTime: a); t += 0.5; a += 0.5 }
        // 冻结 + 每 2s 一个 23ms 孤立回跳:3s 窗口推进 0.023~0.046s < 0.1s → 判停
        let base = a
        var jump = 0.0
        var detected = false
        while t < 16 {
            if Int(t * 2) % 4 == 0 { jump += 0.023 }
            if wd.note(now: t, audioTime: base + jump) { detected = true; break }
            t += 0.5
        }
        XCTAssertTrue(detected, "孤立回跳不得骗过停转判定")
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
        if ProcessInfo.processInfo.environment["PLAYERKIT_CI_SKIP_AV_DEVICE_TESTS"] == "1" {
            throw XCTSkip("CI 无真实音频设备,跳过接线行为用例")
        }
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
        if ProcessInfo.processInfo.environment["PLAYERKIT_CI_SKIP_AV_DEVICE_TESTS"] == "1" {
            throw XCTSkip("CI 无真实音频设备,跳过接线行为用例")
        }
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
