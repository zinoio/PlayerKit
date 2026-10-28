import XCTest
import AVFoundation
import CoreMedia
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// Task 5:入队/背压/timebase/释放。重点:
/// - 创建-销毁-创建循环(spike 的 -12910 场景,design §6.5);
/// - calibrate 小漂移不动、大漂移重设;
/// - 暂停/倍速 timebase 行为。
final class SystemDVRendererTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    /// 从 c5 读出真实 DV 样本(pts 已换算为全局秒)。
    private func loadSamples(maxCount: Int = 100) throws -> [CMSampleBuffer] {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: corpusURL("c5_dv_p81.mp4"), headers: [:])
        defer { demuxer.close() }
        let vs = try XCTUnwrap(demuxer.videoStream)
        let tb = vs.pointee.time_base
        let tbSec = Double(tb.num) / Double(tb.den)
        let builder = try XCTUnwrap(SystemDVSampleBuilder(
            stream: vs, dovi: try XCTUnwrap(demuxer.doviConfiguration)))
        var samples: [CMSampleBuffer] = []
        while samples.count < maxCount, let p = demuxer.readPacket() {
            guard p.streamIndex == demuxer.videoStreamIndex else {
                var pp: UnsafeMutablePointer<AVPacket>? = p.packet
                av_packet_free(&pp)
                continue
            }
            let pts = Double(p.packet.pointee.pts) * tbSec
            if let sb = builder.makeSample(packet: p.packet, pts: pts, doNotDisplay: false) {
                samples.append(sb)
            }
            var pp: UnsafeMutablePointer<AVPacket>? = p.packet
            av_packet_free(&pp)
        }
        XCTAssertFalse(samples.isEmpty)
        return samples
    }

    private func pollUntil(timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return cond()
    }

    // MARK: - 用例

    func testEnqueueDoesNotFail() throws {
        let layer = AVSampleBufferDisplayLayer()
        let renderer = SystemDVRenderer(displayLayer: layer)
        var failure: Error?
        renderer.onFailure = { failure = $0 }
        let samples = try loadSamples()

        renderer.start(at: 0, rate: 1)
        for s in samples { renderer.enqueue(s) }
        // 有窗口/渲染 sink 时样本会全部交给层并随 timebase 呈现(headless CI
        // 上层可能迟迟不报 ready,样本合理滞留 pending)——这里只断言核心契约:
        // 入队期间层不失败、不触发 onFailure。
        _ = pollUntil { renderer.pendingSampleCount == 0 }
        renderer.stop()
        XCTAssertNil(failure)
        XCTAssertNotEqual(layer.status, .failed, "入队不应触发层失败")
    }

    /// design §6.5:连续 stop→play 必须不报 -12910。同一 layer 复用与每次新 layer
    /// 两种形态都要过。结论固化在 SystemDVRenderer.stop() 的注释。
    func testCreateStopCreateLoopDoesNotFail() throws {
        let samples = try loadSamples(maxCount: 6)
        let sharedLayer = AVSampleBufferDisplayLayer()
        for i in 0..<10 {
            let layer = i % 2 == 0 ? sharedLayer : AVSampleBufferDisplayLayer()
            let renderer = SystemDVRenderer(displayLayer: layer)
            var failure: Error?
            renderer.onFailure = { failure = $0 }
            renderer.start(at: 0, rate: 1)
            for s in samples { renderer.enqueue(s) }
            Thread.sleep(forTimeInterval: 0.1)
            renderer.stop()
            XCTAssertNil(failure, "第 \(i) 轮不应触发失败")
            XCTAssertNotEqual(layer.status, .failed, "第 \(i) 轮层不应 failed")
        }
        // 循环结束后第 11 次:同一 layer 再开一轮,老会话未释放才会在这报错。
        let renderer = SystemDVRenderer(displayLayer: sharedLayer)
        var failure: Error?
        renderer.onFailure = { failure = $0 }
        renderer.start(at: 0, rate: 1)
        for s in samples { renderer.enqueue(s) }
        Thread.sleep(forTimeInterval: 0.2)
        renderer.stop()
        XCTAssertNil(failure, "复用 layer 的第 11 轮不应失败(-12910 场景)")
        XCTAssertNotEqual(sharedLayer.status, .failed)
    }

    func testCalibrateIgnoresSmallDriftAndResetsLargeDrift() throws {
        let layer = AVSampleBufferDisplayLayer()
        let renderer = SystemDVRenderer(displayLayer: layer)
        renderer.start(at: 10.0, rate: 0)   // rate 0:timebase 冻结,便于断言
        Thread.sleep(forTimeInterval: 0.05)

        // 小漂移(0.02 s < 0.08 s 阈值)不动
        renderer.calibrate(toAudioTime: 10.02)
        Thread.sleep(forTimeInterval: 0.05)
        let afterSmall = try XCTUnwrap(renderer.currentTime)
        XCTAssertEqual(afterSmall, 10.0, accuracy: 0.01, "小漂移不应重设 timebase")

        // 大漂移重设到目标
        renderer.calibrate(toAudioTime: 12.0)
        Thread.sleep(forTimeInterval: 0.05)
        let afterLarge = try XCTUnwrap(renderer.currentTime)
        XCTAssertEqual(afterLarge, 12.0, accuracy: 0.05, "大漂移应重设到音频时钟")
        renderer.stop()
    }

    func testPauseAndRate() throws {
        let layer = AVSampleBufferDisplayLayer()
        let renderer = SystemDVRenderer(displayLayer: layer)
        renderer.start(at: 0, rate: 1)
        Thread.sleep(forTimeInterval: 0.3)
        let t1 = try XCTUnwrap(renderer.currentTime)
        XCTAssertGreaterThan(t1, 0.1, "rate 1 下 timebase 应前进")

        // 暂停:冻结
        renderer.setRate(0)
        Thread.sleep(forTimeInterval: 0.2)
        let t2 = try XCTUnwrap(renderer.currentTime)
        XCTAssertEqual(t2, t1, accuracy: 0.05, "rate 0 后 timebase 不应前进")

        // 倍速:~2×
        renderer.setRate(2)
        Thread.sleep(forTimeInterval: 0.5)
        let t3 = try XCTUnwrap(renderer.currentTime)
        XCTAssertEqual(t3 - t2, 1.0, accuracy: 0.3, "rate 2 应约两倍速")
        renderer.stop()
    }

    func testFlushResetsTime() throws {
        let layer = AVSampleBufferDisplayLayer()
        let renderer = SystemDVRenderer(displayLayer: layer)
        renderer.start(at: 0, rate: 1)
        Thread.sleep(forTimeInterval: 0.2)
        renderer.flush(at: 100.0)
        Thread.sleep(forTimeInterval: 0.05)
        let t = try XCTUnwrap(renderer.currentTime)
        // flush 后 timebase 以 rate 1 继续前进,读数 = 100 + 消耗的墙钟
        XCTAssertEqual(t, 100.0, accuracy: 0.25, "flush 后 time 应重设")
        XCTAssertEqual(renderer.pendingSampleCount, 0, "flush 应清空待入队样本")
        XCTAssertEqual(renderer.bufferedSeconds, 0, accuracy: 0.001)
        renderer.stop()
    }
}
