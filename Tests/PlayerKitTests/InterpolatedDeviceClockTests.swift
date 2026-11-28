import AudioToolbox
import XCTest
@testable import PlayerKitNative

/// #72 主时钟插值缓存的决策单元。
///
/// 不变量(修复「displayNextFrame 每帧同步 XPC 查 AudioQueueGetCurrentTime
/// → XPC 延迟抖动注入视频时钟 → A/V 失步追猎 + 渲染空档」):
/// - 播放中 freshWindow(0.1s ⇒ ≥10Hz 重锚)内零设备查询,热路径纯外推;
/// - 暂停期锚点冻结,不随墙钟前进(AudioQueue sampleTime 暂停时不变);
/// - 锚点失效(建队/seek/resume)或过期才计划真实查询;
/// - 查询失败在 staleGrace(0.5s)内兜底外推,超过即 nil(交 guardWindow)。
final class InterpolatedDeviceClockTests: XCTestCase {

    private let sr = 48000.0

    func testFirstReadPlansQueryThenCommitAnchors() {
        var c = InterpolatedDeviceClock()
        XCTAssertEqual(c.plan(paused: false, now: 0, sampleRate: sr), .query)
        c.commit(sample: 4800, now: 0)
        XCTAssertEqual(c.plan(paused: false, now: 0, sampleRate: sr), .extrapolate(4800))
    }

    func testFreshWindowExtrapolatesFromAnchor() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1)
        c.commit(sample: 4800, now: 0)
        // 0.05s 后仍在窗内:4800 + 0.05 × 48000 = 7200,零设备查询
        XCTAssertEqual(c.plan(paused: false, now: 0.05, sampleRate: sr), .extrapolate(7200))
    }

    func testBeyondFreshWindowPlansQuery() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1)
        c.commit(sample: 4800, now: 0)
        XCTAssertEqual(c.plan(paused: false, now: 0.15, sampleRate: sr), .query)
    }

    func testPausedFreezesAtAnchorRegardlessOfWall() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1)
        c.commit(sample: 4800, now: 0)
        XCTAssertEqual(c.plan(paused: true, now: 0.3, sampleRate: sr), .frozen(4800))
    }

    func testPausedWithoutAnchorPlansQueryOnce() {
        var c = InterpolatedDeviceClock()
        XCTAssertEqual(c.plan(paused: true, now: 0, sampleRate: sr), .query)
        c.commit(sample: 9600, now: 0.01)
        // 暂停期间墙钟再走也不前进、不再查询
        XCTAssertEqual(c.plan(paused: true, now: 0.4, sampleRate: sr), .frozen(9600))
    }

    func testInvalidateForcesQuery() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1)
        c.commit(sample: 4800, now: 0)
        c.invalidate()
        XCTAssertEqual(c.plan(paused: false, now: 0.01, sampleRate: sr), .query)
    }

    func testCommitReanchorsAndExtrapolatesFromNewAnchor() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1)
        c.commit(sample: 4800, now: 0)
        XCTAssertEqual(c.plan(paused: false, now: 0.15, sampleRate: sr), .query)
        c.commit(sample: 12000, now: 0.15)
        XCTAssertEqual(c.plan(paused: false, now: 0.20, sampleRate: sr),
                       .extrapolate(12000 + 0.05 * sr))
    }

    func testFailedQueryWithinGraceFallsBackToExtrapolation() {
        var c = InterpolatedDeviceClock(freshWindow: 0.1, staleGrace: 0.5)
        c.commit(sample: 4800, now: 0)
        // 超窗查询失败:grace 内按锚点外推兜底
        XCTAssertEqual(c.fallbackAfterFailedQuery(now: 0.15, sampleRate: sr),
                       4800 + 0.15 * sr)
        XCTAssertEqual(c.fallbackAfterFailedQuery(now: 0.4, sampleRate: sr),
                       4800 + 0.4 * sr)
        // 超过 grace:返回 nil,让上层 guardWindow 语义接管
        XCTAssertNil(c.fallbackAfterFailedQuery(now: 0.6, sampleRate: sr))
    }

    func testFallbackWithoutAnchorReturnsNil() {
        var c = InterpolatedDeviceClock()
        XCTAssertNil(c.fallbackAfterFailedQuery(now: 0.01, sampleRate: sr))
    }
}

final class CounterBox {
    var value = 0
}

/// #72 接线测试:`AudioUnitOutput.devicePlaybackTime` 的缓存行为。
/// 窗口经 `clockFreshWindowForTesting` 放大/缩小,断言确定性:
/// 窗内零设备查询(暖机锚点外推)、超窗恰一次查询、暂停冻结在真实暂停点。
final class MasterClockCacheWiringTests: XCTestCase {

    private let sampleRate: Int32 = 48000
    private var savedMute = false
    private var savedFreshWindow: TimeInterval?
    private var savedGetCurrentTime: ((AudioComponentInstance) -> (sampleTime: Double, valid: Bool))?

    override func setUp() {
        super.setUp()
        savedMute = AudioUnitOutput.mutedForTesting
        AudioUnitOutput.mutedForTesting = true
        savedFreshWindow = AudioUnitOutput.clockFreshWindowForTesting
        savedGetCurrentTime = AudioUnitOutput.getCurrentTimeImpl
    }

    override func tearDown() {
        AudioUnitOutput.mutedForTesting = savedMute
        AudioUnitOutput.clockFreshWindowForTesting = savedFreshWindow
        AudioUnitOutput.getCurrentTimeImpl = savedGetCurrentTime
        super.tearDown()
    }

    /// 暖机:轮询到设备时间可读。
    private func warmUp(_ output: AudioUnitOutput) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if output.devicePlaybackTime != nil { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func makeStartedOutput(freshWindow: TimeInterval) -> AudioUnitOutput {
        AudioUnitOutput.clockFreshWindowForTesting = freshWindow
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        return output
    }

    private func countingGetCurrentTime(_ counter: CounterBox)
        -> (AudioComponentInstance) -> (sampleTime: Double, valid: Bool) {
        return { _ in
            counter.value += 1
            return (Double(counter.value * 480), true)
        }
    }

    func testDevicePlaybackTimeWithinFreshWindowDoesNotQueryDevice() {
        let output = makeStartedOutput(freshWindow: 5.0)
        defer { output.stop() }
        XCTAssertTrue(warmUp(output))

        let counter = CounterBox()
        AudioUnitOutput.getCurrentTimeImpl = countingGetCurrentTime(counter)
        _ = output.devicePlaybackTime
        _ = output.devicePlaybackTime
        XCTAssertEqual(counter.value, 0, "窗内重复读取应零设备查询(暖机锚点外推)")
    }

    func testDevicePlaybackTimeBeyondFreshWindowRequeriesOnce() {
        let output = makeStartedOutput(freshWindow: 0.001)
        defer { output.stop() }
        XCTAssertTrue(warmUp(output))
        Thread.sleep(forTimeInterval: 0.05)  // 必超窗(0.001s)

        let counter = CounterBox()
        AudioUnitOutput.getCurrentTimeImpl = countingGetCurrentTime(counter)
        _ = output.devicePlaybackTime
        XCTAssertEqual(counter.value, 1, "超窗单次读取应恰一次设备查询")
    }

    func testPausedPositionFreezesAtTruePausePoint() {
        let output = makeStartedOutput(freshWindow: 0.10)
        defer { output.stop() }
        XCTAssertTrue(warmUp(output))

        output.pause()
        // 暂停锚点由 controlQueue 异步落地(pauseImpl 之后钉到真实冻结点);
        // 轮询到两次读取稳定相等再断言,不猜落地时刻。
        var v1 = output.devicePlaybackTime
        var v2 = output.devicePlaybackTime
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, v1 == nil || v1 != v2 {
            Thread.sleep(forTimeInterval: 0.02)
            v1 = output.devicePlaybackTime
            v2 = output.devicePlaybackTime
        }
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1, v2)
    }
}
