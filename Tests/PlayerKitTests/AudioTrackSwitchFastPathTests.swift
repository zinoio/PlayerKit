import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

/// zyno#171:备选音轨缓存命中时切音轨走快路径——不 seek(physicalSeekGeneration 不变)、
/// 视频不被打断;未命中走慢路径,结果同样正确。
private final class CountingRenderer: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams,
                metadata: FrameMetadata, strategy: RendererStrategy?) { lock.withLock { _count += 1 } }
    func flush() {}
    func clear() {}
}

final class AudioTrackSwitchFastPathTests: XCTestCase {
    private func fixture() -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: "two_audio_60s", withExtension: "mkv", subdirectory: "Fixtures")!)
    }
    private func waitUntil(_ timeout: Double = 10, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
    private func start() async throws -> (NativeBackend, CountingRenderer) {
        let r = CountingRenderer()
        let b = try await MainActor.run { try NativeBackend(renderer: r, audioOutput: nil) }
        await MainActor.run { b.play(reader: InMemoryReader(data: fixture()), seekTo: nil, knownDuration: .seconds(60)) }
        return (b, r)
    }

    func testCacheHitSwitchesWithoutSeekAndKeepsVideoRunning() async throws {
        let (backend, renderer) = try await start()
        defer { Task { @MainActor in backend.stop() } }
        let rendering = await waitUntil { renderer.count > 5 }
        XCTAssertTrue(rendering)
        _ = await waitUntil { !backend.altAudioStreams.isEmpty && backend.altAudioCache.totalBytes > 0 }
        let other = try XCTUnwrap(backend.altAudioStreams.first)
        try await Task.sleep(nanoseconds: 600_000_000)         // 让缓存覆盖当前位置

        let gen = backend.physicalSeekGeneration
        let framesBefore = renderer.count
        await MainActor.run { backend.selectAudioTrack(id: String(other)) }

        let switched = await waitUntil { backend.lastAudioSwitchPath != nil }
        XCTAssertTrue(switched)
        XCTAssertEqual(backend.lastAudioSwitchPath, "fast", "缓存命中应走快路径")
        XCTAssertEqual(backend.physicalSeekGeneration, gen, "快路径不 seek,不得递增 physicalSeekGeneration")
        let selected = await MainActor.run { backend.state.selectedAudioTrackId }
        XCTAssertEqual(selected, Int(other))
        let stillRendering = await waitUntil { renderer.count > framesBefore + 5 }
        XCTAssertTrue(stillRendering, "快路径不应打断视频渲染")
        XCTAssertTrue(backend.altAudioStreams.contains(where: { $0 != other }), "旧轨应变成备选")
    }

    func testSwitchBackAndForthKeepsWorking() async throws {
        let (backend, renderer) = try await start()
        defer { Task { @MainActor in backend.stop() } }
        _ = await waitUntil { renderer.count > 5 && backend.altAudioCache.totalBytes > 0 }
        let first = backend.altAudioStreams.first!
        try await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run { backend.selectAudioTrack(id: String(first)) }
        _ = await waitUntil { backend.lastAudioSwitchPath != nil }
        // 旧轨刚变成备选,缓存要重新积累一会儿才能再次命中;不论走哪条路径结果都应正确。
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let original = backend.altAudioStreams.first!
        await MainActor.run { backend.selectAudioTrack(id: String(original)) }
        let deadline = Date().addingTimeInterval(10)
        var selected: Int?
        while Date() < deadline {
            selected = await MainActor.run { backend.state.selectedAudioTrackId }
            if selected == Int(original) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(selected, Int(original))
    }
}
