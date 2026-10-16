import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

/// zyno#171:解复用循环把备选音轨的包缓存下来(切轨免 seek 的数据基础)。
private final class NullRenderer: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams,
                metadata: FrameMetadata, strategy: RendererStrategy?) {}
    func flush() {}
    func clear() {}
}

final class BackendAltAudioCacheTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!)
    }

    private func makeBackend() async throws -> NativeBackend {
        try await MainActor.run { try NativeBackend(renderer: NullRenderer(), audioOutput: nil) }
    }

    private func waitUntil(_ timeout: Double = 10, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testAlternateAudioPacketsAreCachedForTwoTrackFile() async throws {
        let backend = try await makeBackend()
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run {
            backend.play(reader: InMemoryReader(data: fixture("two_audio_60s", "mkv")),
                         seekTo: nil, knownDuration: .seconds(60))
        }
        let ok = await waitUntil { backend.altAudioCache.totalBytes > 0 }
        XCTAssertTrue(ok, "备选音轨包应进入缓存")
        XCTAssertEqual(backend.altAudioStreams.count, 1)
    }

    func testNoCacheForSingleAudioTrackFile() async throws {
        let backend = try await makeBackend()
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run {
            backend.play(reader: InMemoryReader(data: fixture("speed_aac44_stereo_60s", "mp4")),
                         seekTo: nil, knownDuration: .seconds(60))
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(backend.altAudioStreams.isEmpty)
        XCTAssertEqual(backend.altAudioCache.totalBytes, 0)
    }

    func testSeekClearsCacheOfOldPositionPackets() async throws {
        let backend = try await makeBackend()
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run {
            backend.play(reader: InMemoryReader(data: fixture("two_audio_60s", "mkv")),
                         seekTo: nil, knownDuration: .seconds(60))
        }
        _ = await waitUntil { !backend.altAudioStreams.isEmpty }
        let other = try XCTUnwrap(backend.altAudioStreams.first)
        _ = await waitUntil { backend.altAudioCache.covers(stream: other, at: 0.5, tolerance: 0.6) }
        await MainActor.run { backend.seek(to: .seconds(40)) }
        let gone = await waitUntil {
            let first = backend.altAudioCache.packets(stream: other, from: 0).first?.pts
            return first != nil && first! > 30
        }
        XCTAssertTrue(gone, "seek 之后缓存里不应留有旧位置(≈0s)的包")
    }

    func testStopClearsCache() async throws {
        let backend = try await makeBackend()
        await MainActor.run {
            backend.play(reader: InMemoryReader(data: fixture("two_audio_60s", "mkv")),
                         seekTo: nil, knownDuration: .seconds(60))
        }
        _ = await waitUntil { backend.altAudioCache.totalBytes > 0 }
        await MainActor.run { backend.stop() }
        XCTAssertEqual(backend.altAudioCache.totalBytes, 0)
        XCTAssertTrue(backend.altAudioStreams.isEmpty)
    }
}
