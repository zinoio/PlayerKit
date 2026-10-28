#if os(macOS)
import XCTest
import AVFoundation
import QuartzCore
import CoreVideo
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// Task 6 集成测试:NativeBackend 系统路径分流、回退、位置/EOF 接管。
/// 语料:c5_dv_p81.mp4(纯视频 P8.1)+ systemdv_p81_av.mp4(同视频 + AAC 音轨,
/// 验证音频主时钟路径)。macOS only(SystemDVCapability 平台白名单)。
final class NativeBackendSystemDVTests: XCTestCase {

    private var savedMute = false

    override func setUp() {
        savedMute = AudioUnitOutput.mutedForTesting
        AudioUnitOutput.mutedForTesting = true   // 静音:不骚扰开发机
    }
    override func tearDown() {
        AudioUnitOutput.mutedForTesting = savedMute
    }

    // MARK: - 工具

    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    private func fixtureURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")!
    }

    /// 生产契约:displayCapability 由应用层在 init 后设置(reflux
    /// PlayerController)。测试同样显式设置,镜像真实用法。
    private func makeBackend(renderer: VideoRenderer? = nil,
                             display: DisplayCapability = .macEDR) async -> NativeBackend {
        let r = renderer ?? ASBDLRenderer(displayCapability: display)
        return await MainActor.run {
            let b = try! NativeBackend(renderer: r, audioOutput: nil)
            b.displayCapability = display
            return b
        }
    }

    private func play(_ backend: NativeBackend, _ url: URL) async {
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }
    }

    private func waitUntil(timeout: TimeInterval = 6, _ cond: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await cond()
    }

    /// 非 ASBDL 渲染器替身(系统路径必须视为不可用)。
    private final class StubRenderer: VideoRenderer {
        let layer = CALayer()
        var prefersTenBit: Bool { true }
        var displayCapability: DisplayCapability = .macEDR
        func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams,
                    metadata: FrameMetadata, strategy: RendererStrategy?) {}
        func flush() {}
        func clear() {}
        func configure(codedSize: CGSize, sampleAspectRatio: Double) {}
    }

    // MARK: - 分流决策表

    func testSystemPipelineSelectedForP81() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .doviSystem
                    && backend.activeVideoPipeline == .compressedPassthrough
            }
        }
        XCTAssertTrue(ok, "P8.1 + EDR + .system 偏好应选系统路径")
    }

    func testSystemPipelineSelectedForP5() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, corpusURL("c10_dv_p5_ipt.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .doviSystem
                    && backend.activeVideoPipeline == .compressedPassthrough
            }
        }
        XCTAssertTrue(ok, "P5(IPT)+ EDR + .system 偏好应选系统路径")
    }

    func testSoftwarePreferenceKeepsDecodedFrames() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await MainActor.run { backend.dolbyVisionOutput = .software }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .doviProfile8(tonemapCompat: true)
                    && backend.activeVideoPipeline == .decodedFrames
            }
        }
        if !ok {
            let s = await MainActor.run { String(describing: backend.rendererStrategy) }
            let p2 = await MainActor.run { backend.activeVideoPipeline }
            XCTFail("actual strategy=\(s) pipeline=\(p2)")
        }
        XCTAssertTrue(ok, ".software 偏好应保持软解路径(doviProfile8,compat=1)")
    }

    func testDoviDisabledKeepsHDR10Base() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await MainActor.run { backend.doviEnabled = false }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .hdr10Static(peakNits: 1000)
                    && backend.activeVideoPipeline == .decodedFrames
            }
        }
        XCTAssertTrue(ok, "doviEnabled=false(非免费期)保持 HDR10 基础层,与系统路径无关")
    }

    func testNonEDRDisplayUsesSoftware() async throws {
        let backend = await makeBackend(display: .macSDR)
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .degradedHDR10
                    && backend.activeVideoPipeline == .decodedFrames
            }
        }
        XCTAssertTrue(ok, "非 EDR 屏保守走软件路径(design V2 未出结论前)")
    }

    func testNonASBDLRendererUsesSoftware() async throws {
        let backend = await makeBackend(renderer: StubRenderer())
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        let ok = await waitUntil {
            await MainActor.run {
                backend.rendererStrategy == .doviProfile8(tonemapCompat: true)
                    && backend.activeVideoPipeline == .decodedFrames
            }
        }
        XCTAssertTrue(ok, "非 ASBDLRenderer(系统路径复用其 displayLayer)视为能力不可用")
    }

    // MARK: - 会话释放 / 回退

    func testStopThenPlayLoopNoFailure() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        let actor = SystemDVCallbackProbe()
        await MainActor.run { backend.onSystemDVFallback = { actor.fallbackCount += 1 } }
        for i in 0..<8 {
            await play(backend, corpusURL("c5_dv_p81.mp4"))
            let selected = await waitUntil {
                await MainActor.run { backend.activeVideoPipeline == .compressedPassthrough }
            }
            XCTAssertTrue(selected, "第 \(i) 轮应选中系统路径")
            try await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run { backend.stop() }
        }
        let count = await actor.count()
        XCTAssertEqual(count, 0, "连续 stop→play 8 轮不应触发回退(-12910 场景)")
    }

    func testFallbackOnInjectedFailure() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        let probe = SystemDVCallbackProbe()
        await MainActor.run { backend.onSystemDVFallback = { probe.fallbackCount += 1 } }
        let fakeBox = FakeRendererBox()
        await MainActor.run {
            backend.systemDVRendererFactory = { layer in
                let f = SystemDVRenderer(displayLayer: layer)
                fakeBox.renderer = f
                return f
            }
        }
        await play(backend, fixtureURL("systemdv_p81_av6s.mp4"))
        _ = await waitUntil {
            await MainActor.run { backend.activeVideoPipeline == .compressedPassthrough }
        }
        guard let fake = fakeBox.renderer else {
            return XCTFail("factory 未被调用")
        }

        // 注入失败 → 回退一次
        fake.reportFailureForTesting(NSError(domain: "test", code: -12910))
        let fell = await waitUntil {
            await MainActor.run { backend.activeVideoPipeline == .decodedFrames }
        }
        XCTAssertTrue(fell, "注入失败后应回退到软解路径")
        let count1 = await probe.count()
        XCTAssertEqual(count1, 1, "回退回调应恰好一次")

        // 播放位置继续前进(不回到 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let pos1 = await MainActor.run { backend.state.position }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let pos2 = await MainActor.run { backend.state.position }
        XCTAssertGreaterThan(pos2, pos1, "回退后播放应继续前进")
        XCTAssertGreaterThan(pos2, .zero, "回退后不应回到 0")

        // 再次注入失败:不再回退/重试(会话内只回退一次)
        fake.reportFailureForTesting(NSError(domain: "test", code: -1))
        try await Task.sleep(nanoseconds: 400_000_000)
        let count2 = await probe.count()
        XCTAssertEqual(count2, 1, "第二次失败不应再次回退")
    }

    func testFirstFrameTimeoutFallsBack() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        let probe = SystemDVCallbackProbe()
        await MainActor.run {
            backend.onSystemDVFallback = { probe.fallbackCount += 1 }
            backend.systemDVFirstFrameTimeout = 0.5
            backend.systemDVRendererFactory = { layer in
                HiddenFirstFrameRenderer(displayLayer: layer)
            }
        }
        await play(backend, corpusURL("c5_dv_p81.mp4"))
        _ = await waitUntil {
            await MainActor.run { backend.activeVideoPipeline == .compressedPassthrough }
        }
        let fell = await waitUntil(timeout: 8) {
            await MainActor.run { backend.activeVideoPipeline == .decodedFrames }
        }
        XCTAssertTrue(fell, "首帧超时应回退而不是永远黑屏")
        let count = await probe.count()
        XCTAssertEqual(count, 1)
    }

    // MARK: - 位置 / EOF / seek / 暂停

    func testPositionAdvancesAndEOFReached() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        let probe = SystemDVCallbackProbe()
        await MainActor.run { backend.onSystemDVFallback = { probe.fallbackCount += 1 } }
        await play(backend, fixtureURL("systemdv_p81_av.mp4"))
        // 位置前进
        _ = await waitUntil {
            await MainActor.run { backend.state.position > .milliseconds(300) }
        }
        let reached = await waitUntil(timeout: 12) {
            await MainActor.run {
                backend.state.position >= backend.state.duration - .milliseconds(600)
                    && backend.state.duration > .zero
            }
        }
        XCTAssertTrue(reached, "短片应播到 ≈ 时长(demux 读尽 && 缓冲耗尽 && 音频播完)")
        let count = await probe.count()
        XCTAssertEqual(count, 0, "正常播完不应触发回退")
    }

    func testSeekRealignsTimebase() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, fixtureURL("systemdv_p81_av6s.mp4"))
        _ = await waitUntil {
            await MainActor.run { backend.activeVideoPipeline == .compressedPassthrough }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run { backend.seek(to: .milliseconds(4000)) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let gap = await MainActor.run { backend.systemDVClockGapForTesting() }
        XCTAssertTrue(gap.isFinite, "seek 后层 timebase 应存在")
        XCTAssertLessThan(abs(gap), 0.2, "seek 后画面 pts 与音频时钟差应 < 0.2s,gap=\(gap)")
    }

    func testPauseResumeHoldsPicture() async throws {
        let backend = await makeBackend()
        defer { Task { await MainActor.run { backend.stop() } } }
        await play(backend, fixtureURL("systemdv_p81_av6s.mp4"))
        _ = await waitUntil {
            await MainActor.run { backend.activeVideoPipeline == .compressedPassthrough }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run { backend.pause() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t1 = await MainActor.run { backend.systemDVRendererTimeForTesting() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let t2 = await MainActor.run { backend.systemDVRendererTimeForTesting() }
        XCTAssertNotNil(t1)
        XCTAssertEqual(t2 ?? -1, t1 ?? -2, accuracy: 0.1, "暂停后层 timebase 不应前进")

        await MainActor.run { backend.resume() }
        try await Task.sleep(nanoseconds: 800_000_000)
        let t3 = await MainActor.run { backend.systemDVRendererTimeForTesting() }
        XCTAssertNotNil(t3)
        XCTAssertGreaterThan(t3 ?? 0, t2 ?? 0, "恢复后层 timebase 应继续前进")
    }
}

// MARK: - 测试辅助

/// 挂到 MainActor 之外的回调计数器(onSystemDVFallback 在任意线程触发)。
private final class SystemDVCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var fallbackCount: Int {
        get { lock.withLock { _count } }
        set { lock.withLock { _count = newValue } }
    }
    func count() async -> Int { fallbackCount }
}

/// factory 闭包到测试体的 renderer 传递(@unchecked Sendable 装箱)。
private final class FakeRendererBox: @unchecked Sendable {
    var renderer: SystemDVRenderer?
}

/// hasPresentedFirstFrame 恒 false(首帧超时回退测试用)。
private final class HiddenFirstFrameRenderer: SystemDVRenderer {
    override var hasPresentedFirstFrame: Bool { false }
    override init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init(displayLayer: displayLayer)
    }
}
#endif
