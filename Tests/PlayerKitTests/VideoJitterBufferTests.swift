import XCTest
import CoreVideo
import PlayerKit
@testable import PlayerKitNative

final class VideoJitterBufferTests: XCTestCase {

    private func makeFrame(pts: Double) -> VideoJitterBuffer.Frame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return VideoJitterBuffer.Frame(pixelBuffer: pixelBuffer!, pts: pts, metadata: FrameMetadata())
    }

    func testInitialStateIsBuffering() {
        let buf = VideoJitterBuffer()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(buf.duration, 0.0)
    }

    func testDurationIsZeroWithOneFrame() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        XCTAssertEqual(buf.duration, 0.0, "单帧无法计算时长")
    }

    func testDurationWithMultipleFrames() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        buf.append(makeFrame(pts: 3.0))
        XCTAssertEqual(buf.duration, 2.0, accuracy: 0.001)
    }

    func testTransitionsToPlayingWhenResumeDurationReached() {
        let buf = VideoJitterBuffer()
        var receivedState: VideoJitterBuffer.State?
        let exp = expectation(description: "state change to playing")
        buf.onStateChange = { state in
            receivedState = state
            exp.fulfill()
        }
        // resumeDuration = 2.0s：添加 pts=0 和 pts=2.0 的帧
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedState, .playing)
        XCTAssertEqual(buf.state, .playing)
    }

    // MARK: - 实际断粮驱动(方案 B:低水位只是预警,真正无帧才 rebuffer)

    func testLowDurationWithFramesDoesNotRebuffer() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        var bufferingCallbacks = 0
        buf.onStateChange = { state in
            if state == .buffering { bufferingCallbacks += 1 }
        }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop()                                   // 剩 1 帧,dur = 0:低水位预警
        fakeNow += 5.0
        buf.pollStarvation()                        // 有帧可显示:不得回缓冲
        XCTAssertEqual(buf.state, .playing)
        XCTAssertEqual(bufferingCallbacks, 0,
            "低水位但有帧时不得回缓冲,更不得触发任何 buffering 回调")
    }

    func testStarvationRequiresDebounce() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        var bufferingCallbacks = 0
        buf.onStateChange = { state in
            if state == .buffering { bufferingCallbacks += 1 }
        }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()                        // 真空
        fakeNow = 0.11
        buf.pollStarvation()                        // 防抖窗口内:仍 playing
        XCTAssertEqual(buf.state, .playing)
        XCTAssertEqual(bufferingCallbacks, 0)

        fakeNow = 0.13                              // 连续真空 ≥ 0.12s
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(bufferingCallbacks, 1, "真断粮只应触发一次 buffering 回调")
    }

    func testAppendWithinStarvationDebounceAvoidsBuffering() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        var bufferingCallbacks = 0
        buf.onStateChange = { state in
            if state == .buffering { bufferingCallbacks += 1 }
        }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()                        // 真空,防抖开始
        fakeNow = 0.05
        buf.append(makeFrame(pts: 1.042))           // 单帧涓流不足以恢复
        buf.append(makeFrame(pts: 1.084))
        buf.append(makeFrame(pts: 1.126))           // 恢复深度(3 帧)才清防抖
        fakeNow = 0.10
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .playing)
        XCTAssertEqual(bufferingCallbacks, 0,
            "防抖窗口内恢复到足够深度不得 rebuffer")
    }

    func testTrickleAppendDoesNotResetStarvationDebounce() {
        // 2026-11-21 真机实锤:供给一次一帧(~18fps)时,append 每次都清掉
        // starvingSince,pop 又立刻打空——防抖永远凑不满,音频超前画面 1.2s、
        // 画面冻住且无缓冲卡。单帧涓流不得重置防抖计时。
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        var bufferingCallbacks = 0
        buf.onStateChange = { state in
            if state == .buffering { bufferingCallbacks += 1 }
        }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()                        // 真空,防抖 t=0
        fakeNow = 0.05
        buf.append(makeFrame(pts: 1.042))           // 涓流一帧:count=1 < 恢复深度
        buf.pop()                                   // 立刻被显示打空(同 tick)
        fakeNow = 0.13
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering,
            "涓流单帧不得重置防抖;真断粮必须按时进入缓冲")
        XCTAssertEqual(bufferingCallbacks, 1)
    }

    func testStarvationClearsOnlyAfterRecoveryDepth() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        var bufferingCallbacks = 0
        buf.onStateChange = { state in
            if state == .buffering { bufferingCallbacks += 1 }
        }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()                        // 真空,防抖 t=0
        fakeNow = 0.05
        buf.append(makeFrame(pts: 1.042))           // 1 帧:不清
        fakeNow = 0.20
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(bufferingCallbacks, 1)

        // 已在 .buffering:即使补 1 帧,也要攒到 resume 水位/宽限才放行。
        fakeNow = 0.30
        buf.append(makeFrame(pts: 1.084))
        XCTAssertEqual(buf.state, .buffering)
    }

    func testStarvedBufferRecoversOnlyAtResumeDuration() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))             // 2.0 ≥ resume(1.5)→ 放行

        buf.pop(); buf.pop()
        fakeNow = 0.13
        buf.pollStarvation()                        // 真断粮 → buffering
        XCTAssertEqual(buf.state, .buffering)

        buf.append(makeFrame(pts: 1.042))           // span 0:远低于 resume
        XCTAssertEqual(buf.state, .buffering)
        buf.append(makeFrame(pts: 2.5))             // span 2.5−1.042=1.458s:仍低于 resume(1.5)
        XCTAssertEqual(buf.state, .buffering)
        buf.append(makeFrame(pts: 3.542))           // span 2.5s ≥ resume → 放行
        XCTAssertEqual(buf.state, .playing)
    }

    /// 放行水位加深 1.0s → 1.5s(2026-11-21 探针轮 F/G 定案):4K VBR 高码率
    /// 场景遇通道到达率缺口(~0.8×)时,0.86s 的开放水位每 4.5s 必然触底;
    /// 容量允许 1.64s,水位加深到 1.5s 让缓冲吸收 CDN 突发间隙,周期拉长一倍。
    func testResumeWatermarkRequiresOneAndAHalfSeconds() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))             // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()
        fakeNow = 0.13
        buf.pollStarvation()                        // 真断粮 → buffering
        XCTAssertEqual(buf.state, .buffering)

        buf.append(makeFrame(pts: 1.0))             // 队尾基准(二进制精确值)
        buf.append(makeFrame(pts: 2.25))            // 1.25s:旧水位(1.0s)在此已放行,新水位不得放行
        XCTAssertEqual(buf.state, .buffering,
            "1.25s 不足以放行——水位加深到 1.5s 抗供给缺口")
        buf.append(makeFrame(pts: 2.5))             // 1.5s(2.5−1.0 精确)≥ 新水位 → 放行
        XCTAssertEqual(buf.state, .playing)
    }

    func testEOFEmptyBufferDoesNotRebuffer() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 1.0))
        buf.markEOF()
        XCTAssertEqual(buf.state, .playing)

        buf.pop(); buf.pop()                        // 末尾帧放完,队列空
        fakeNow = 1.0
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .playing,
            "EOF 后排空是正常结束,不得回缓冲")
    }

    func testPeekAtIndex() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        buf.append(makeFrame(pts: 2.0))
        buf.append(makeFrame(pts: 3.0))
        XCTAssertEqual(buf.peek(at: 0)?.pts, 1.0)
        XCTAssertEqual(buf.peek(at: 1)?.pts, 2.0)
        XCTAssertNil(buf.peek(at: 10))
    }

    func testFlushResetsToBuffering() {
        let buf = VideoJitterBuffer()
        let exp = expectation(description: "playing")
        buf.onStateChange = { _ in exp.fulfill() }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
        wait(for: [exp], timeout: 1.0)

        buf.flush()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(buf.count, 0)
    }

    func testSortedInsertionKeepsPTSOrder() {
        let buf = VideoJitterBuffer()
        // B-frame decode order: 0.000, 0.080, 0.040 (simulates VT decoder output)
        buf.append(makeFrame(pts: 0.000))
        buf.append(makeFrame(pts: 0.080))
        buf.append(makeFrame(pts: 0.040))
        // After sorted insertion, peek order must be 0.000, 0.040, 0.080
        XCTAssertEqual(buf.peek(at: 0)?.pts ?? -1, 0.000, accuracy: 0.001)
        XCTAssertEqual(buf.peek(at: 1)?.pts ?? -1, 0.040, accuracy: 0.001)
        XCTAssertEqual(buf.peek(at: 2)?.pts ?? -1, 0.080, accuracy: 0.001)
    }

    func testMaxFrameCountCapDropsOldest() {
        let buf = VideoJitterBuffer()
        for i in 0...(buf.maxFrameCount) {
            buf.append(makeFrame(pts: Double(i) * 0.04))
        }
        XCTAssertLessThanOrEqual(buf.count, buf.maxFrameCount)
    }

    // MARK: - 高帧率回归(120fps 冻结 bug)
    //
    // 根因:旧的 maxFrameCount 是固定 60(注释"≈2.5s at 24fps"),对 120fps 内容只等于
    // 0.5s 时长——同时低于开播门槛 resumeDuration(1.0s)。缓冲区永远攒不到能开播的量,
    // 只能靠 4 秒慢速兜底硬开;开出来又立即耗尽,肉眼看是卡死。
    // 实测片源(4K HDR 120fps HEVC)60 秒内仅推进一次,与此机制吻合。

    func testUnconfiguredFrameRateCannotReachResumeDurationAt120fps() {
        // 未调用 configureFrameRate 时按旧行为(隐含假设低帧率内容)：以 120fps 的节奏喂帧,
        // 固定 60 帧的上限只能攒到 0.5s,永远达不到 1.0s 的开播门槛——这就是冻结的直接成因。
        let buf = VideoJitterBuffer()
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
        }
        XCTAssertLessThan(buf.duration, buf.resumeDuration,
                          "不配置帧率时,120fps 内容的缓冲区应该(错误地)攒不到开播门槛——复现冻结")
    }

    func testConfiguredFrameRateReachesResumeDurationAt120fps() {
        // 修复:告知实际帧率后,上限按帧率换算,120fps 内容能正常攒够并开播。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        var receivedState: VideoJitterBuffer.State?
        let exp = expectation(description: "state change to playing")
        buf.onStateChange = { state in
            receivedState = state
            exp.fulfill()
        }
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
            if buf.state == .playing { break }
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedState, .playing)
        XCTAssertGreaterThanOrEqual(buf.duration, buf.resumeDuration)
    }

    func testConfiguredFrameRateSurvivesOnePopWithoutImmediatelyRebuffering() {
        // 修复的第二层:光能开播不够——弹出一帧后剩余时长仍应远高于开播门槛,继续播放。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
            if buf.state == .playing { break }
        }
        XCTAssertEqual(buf.state, .playing)
        buf.pop()
        XCTAssertEqual(buf.state, .playing,
                       "120fps 下弹出一帧不应该回缓冲")
    }

    func testLowFrameRateCapIsUnchanged() {
        // 向后兼容:24fps(及默认未配置)时上限仍是 60,不因为这次修复放大内存占用。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(24)
        XCTAssertEqual(buf.maxFrameCount, 60)
    }

    func testZeroOrNegativeFrameRateIsIgnored() {
        // 防御:非法帧率(0、负数、非有限值)不应该把上限改小或崩溃,保留原有安全值。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(0)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(-30)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(.nan)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(.infinity)
        XCTAssertEqual(buf.maxFrameCount, 60)
    }

    // MARK: - Memory budget (2026-09-30)
    //
    // The frame cap was fps × 2 s = 240 frames at 120 fps, with no regard for frame
    // size. A 4K 10-bit HDR frame is ~18.5 MB, so 240 frames is ~4.4 GB: on the
    // phone the app got a memory warning ~1 s after the first frame (q=113) and was
    // SIGKILLed. The buffer must bound its bytes, and its playing/buffering
    // thresholds must scale with what it can hold or it never starts playing.

    private func makeBigFrame(pts: Double) -> VideoJitterBuffer.Frame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return VideoJitterBuffer.Frame(pixelBuffer: pixelBuffer!, pts: pts, metadata: FrameMetadata())
    }

    private var bigFrameBytes: Int {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pb)
        return CVPixelBufferGetDataSize(pb!)
    }

    func testByteBudgetBoundsBufferedBytes() {
        let budget = 40 << 20
        let buf = VideoJitterBuffer(memoryBudgetBytes: budget)
        buf.configureFrameRate(120)
        for i in 0..<300 { buf.append(makeBigFrame(pts: Double(i) / 120.0)) }
        // Measure independently of the buffer's own accounting: sum what is really held.
        var actual = 0
        for i in 0..<buf.count { actual += CVPixelBufferGetDataSize(buf.peek(at: i)!.pixelBuffer) }
        XCTAssertLessThanOrEqual(actual, budget + 8 * bigFrameBytes,   // 8 = in-flight decoder slack
            "decoded frames must stay within the byte budget (plus a little in-flight slack), not fps x 2 s frames; held \(actual / (1 << 20)) MB in \(buf.count) frames")
        XCTAssertEqual(buf.bufferedBytes, actual, "the buffer's own byte accounting must match what it holds")
    }

    func testByteBudgetedBufferStillStartsPlayingAndSurvivesAPop() {
        // Bounding the bytes must not recreate the "start, show one frame, freeze"
        // loop: the thresholds have to shrink with the capacity.
        let buf = VideoJitterBuffer(memoryBudgetBytes: 40 << 20)
        buf.configureFrameRate(120)
        for i in 0..<300 {
            buf.append(makeBigFrame(pts: Double(i) / 120.0))
            if buf.state == .playing { break }
        }
        XCTAssertEqual(buf.state, .playing, "a byte-bounded buffer must still reach the playing threshold")
        buf.pop()
        XCTAssertEqual(buf.state, .playing, "popping one frame must not immediately drop back to buffering")
    }

    func testIsFullWhenBudgetReachedAndClearsAfterPops() {
        let buf = VideoJitterBuffer(memoryBudgetBytes: 40 << 20)
        buf.configureFrameRate(120)
        XCTAssertFalse(buf.isFull)
        for i in 0..<300 {
            buf.append(makeBigFrame(pts: Double(i) / 120.0))
            if buf.isFull { break }
        }
        XCTAssertTrue(buf.isFull, "the demux loop needs a signal to stop decoding once the budget is used")
        for _ in 0..<5 { buf.pop() }
        XCTAssertFalse(buf.isFull, "room freed by showing frames must lift the back-pressure")
    }

    func testFlushResetsBufferedBytes() {
        let buf = VideoJitterBuffer(memoryBudgetBytes: 40 << 20)
        for i in 0..<5 { buf.append(makeBigFrame(pts: Double(i) / 30.0)) }
        XCTAssertGreaterThan(buf.bufferedBytes, 0)
        buf.flush()
        XCTAssertEqual(buf.bufferedBytes, 0)
    }

    func testSmallFramesAreNotAffectedByTheDefaultBudget() {
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        for i in 0..<300 { buf.append(makeFrame(pts: Double(i) / 120.0)) }
        XCTAssertFalse(buf.isFull)
        XCTAssertEqual(buf.count, 240, "tiny frames keep the fps x 2 s cap: existing behaviour unchanged")
    }

    // MARK: - Read-ahead vs capacity (2026-10-23)
    //
    // The demux loop read up to 2 s ahead of the audio clock regardless of how many
    // frames the byte budget holds. For 4K 10-bit HDR that is ~48 frames into a
    // buffer of 28: append() refused the rest permanently and the display loop
    // showed every ~1.6th frame (14.7 fps against 23.976).

    func testReadAheadIsUnchangedForSmallFrames() {
        let buf = VideoJitterBuffer()
        XCTAssertEqual(buf.readAheadSeconds, buf.maxDuration, "no frame seen yet: the flat window")
        buf.configureFrameRate(24)
        for i in 0..<30 { buf.append(makeFrame(pts: Double(i) / 24.0)) }
        XCTAssertEqual(buf.readAheadSeconds, buf.maxDuration, "small frames: the budget never binds, 2 s as before")
    }

    func testReadAheadFramesFitInTheBufferForLargeFrames() {
        let buf = VideoJitterBuffer(memoryBudgetBytes: 40 << 20)
        buf.configureFrameRate(24)
        buf.append(makeBigFrame(pts: 0))
        let window = buf.readAheadSeconds
        XCTAssertLessThan(window, buf.maxDuration, "a byte-bound buffer must shorten the read-ahead")
        XCTAssertLessThanOrEqual(window * 24.0, Double(buf.maxFrameCount),
            "a read-ahead window of \(window) s is more frames than the buffer holds (\(buf.maxFrameCount)): the overflow would be refused")
    }

    func testReadAheadStillLetsAByteBoundBufferStartPlaying() {
        let buf = VideoJitterBuffer(memoryBudgetBytes: 40 << 20)
        buf.configureFrameRate(24)
        buf.append(makeBigFrame(pts: 0))
        let window = buf.readAheadSeconds
        var i = 1
        while Double(i) / 24.0 <= window && buf.state == .buffering {
            buf.append(makeBigFrame(pts: Double(i) / 24.0))
            i += 1
        }
        XCTAssertEqual(buf.state, .playing,
            "filling the read-ahead window (\(window) s) must reach the playing threshold, or playback never starts")
    }

    // MARK: - Read-ahead vs in-flight slack at high frame rates (2026-11-19)
    //
    // The demux decodes inline — reading ahead means decoding ahead — and the
    // decoder still has a few frames in flight when the throttle trips. A window
    // that exactly fills the frame cap therefore overflows it: append() refuses
    // the overflow for good and punches PTS holes that the display loop skips
    // while audio (independent clock) stays perfect (device 2026-11-19: q pinned
    // at the 60-frame cap, 50–200 frames refused per 5 s, show interval mean
    // 41.7 → 191 ms, fps 21.6 → 3.7). At 120 fps the flat 2 s window IS the whole
    // 240-frame cap, so the window must stop short of it.

    func testReadAheadLeavesInFlightSlackBelowTheFrameCap() {
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        let window = buf.readAheadSeconds
        XCTAssertLessThan(window, buf.maxDuration,
            "the flat \(buf.maxDuration) s window is the entire \(buf.maxFrameCount)-frame cap at 120 fps")
        XCTAssertLessThan(window * 120.0, Double(buf.maxFrameCount),
            "a \(window) s window leaves no room for the frames already in flight in the decoder")
    }

    // MARK: - 缓冲宽限起点(#75 语义保留:真断粮转缓冲时必须重置 bufferingStart,
    // 否则播放 4s 后 stalled 恒真,resume 水位迟滞从未生效。方案 B 中「回缓冲」
    // 事件从 pop 低水位迁到 pollStarvation 真空防抖,重置语义随之迁移。)

    func testReturningToBufferingResetsTheGraceWindow() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        fakeNow = 5.0
        buf.pop(); buf.pop()                        // 真空
        fakeNow = 5.13
        buf.pollStarvation()                        // 真断粮 → buffering,宽限起点 5.13
        XCTAssertEqual(buf.state, .buffering)

        // 缺陷版:bufferingStart 仍是旧时刻,stalled = 5.13−旧 > 4 恒真,append 一帧立即
        // 回 playing。修复版:转缓冲已把宽限起点重置为 5.13,水位(0s)未满必须
        // 停在 buffering——迟滞真正生效。
        buf.append(makeFrame(pts: 1.042))
        XCTAssertEqual(buf.state, .buffering,
            "回缓冲后宽限期必须重新计时;水位未满不得立即回 playing")
    }

    func testGraceWindowStillOpensPlaybackAfterReset() {
        // 修复后的另一半:重置后的 4s 内攒不满水位,仍要有帧就开播——慢解
        // 兜底语义不得因重置而丢失。
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        fakeNow = 5.0
        buf.pop(); buf.pop()
        fakeNow = 5.13
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering)

        fakeNow = 9.3                               // 9.3 − 5.13 > 4 → stalled 兜底
        buf.append(makeFrame(pts: 1.042))
        XCTAssertEqual(buf.state, .playing,
            "slowDecoderGrace 到期且有帧,仍应兜底开播")
    }

    // MARK: - 缓冲宽限恒定 4s(2026-11-21 真机裁定:降级 0.5s 闩在供给不足时
    // 反作用——缓冲刚开始攒就被强开,dur=0/q=1,形成 0.5-1.5s 微循环。恒定
    // 4s 让涓流真正攒到水位或宽限再开门,播段长、循环少。)

    func testGraceIsAlwaysFullFourSeconds() {
        var fakeNow: TimeInterval = 0
        let buf = VideoJitterBuffer(now: { fakeNow })
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))            // dur 2.0 ≥ resume(1.5)→ playing
        XCTAssertEqual(buf.state, .playing)

        // 第一次真断粮:3s 不放行,4s 放行。
        fakeNow = 5.0
        buf.pop(); buf.pop()
        fakeNow = 5.13
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering)
        fakeNow = 8.1
        buf.append(makeFrame(pts: 1.042))
        XCTAssertEqual(buf.state, .buffering, "3s < 4s:不得提前放行")
        fakeNow = 9.2
        buf.append(makeFrame(pts: 1.084))
        XCTAssertEqual(buf.state, .playing, "4s 宽限到期且有帧:放行")

        // 第二次真断粮:宽限不降级,同样要等满 4s(供给不足时提前开门
        // 只会开出 q=1 的空缓冲,立即再断粮)。
        fakeNow = 10.0
        buf.pop(); buf.pop()
        fakeNow = 10.13
        buf.pollStarvation()
        XCTAssertEqual(buf.state, .buffering)
        fakeNow = 13.0
        buf.append(makeFrame(pts: 1.126))
        XCTAssertEqual(buf.state, .buffering, "宽限恒定 4s:2.9s 不得放行")
        fakeNow = 14.2
        buf.append(makeFrame(pts: 1.168))
        XCTAssertEqual(buf.state, .playing)
    }
}
