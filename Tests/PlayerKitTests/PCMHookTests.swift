import AVFoundation
import XCTest
@testable import PlayerKit
import PlayerKitNative

/// 被动解码音频旁路(#470 P3):协议要求、facade 转发与 NativeBackend 实现。
@MainActor
final class PCMHookTests: XCTestCase {
    /// 最小 Playable 桩:不触碰音频硬件,只验证协议要求与 facade 转发。
    private final class StubBackend: Playable {
        var state = PlayerState()
        var onStateChange: ((PlayerState) -> Void)?
        var onDecodedAudio: ((_ pcm: Data, _ channels: Int, _ sampleRate: Double, _ pts: Double) -> Void)?

        func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration?) {}
        func play(reader: any MediaRandomAccessReader, seekTo: Duration?, knownDuration: Duration?) {}
        func play(concatURLs: [URL], headers: [String: String],
                  seekTo: Duration?, knownDuration: Duration?) {}
        func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
                  seekTo: Duration?, knownDuration: Duration?) {}
        func pause() {}
        func resume() {}
        func seek(to position: Duration) {}
        func stop() {}
        func setVolume(_ volume: Double) {}
        func setRate(_ rate: Double) {}
        func selectAudioTrack(id: String) {}
        func selectSubtitle(id: String?) {}
    }

    func testPlayerFacadeForwardsToBackend() {
        let backend = StubBackend()
        let player = Player(backend: backend)

        XCTAssertNil(player.onDecodedAudio)
        var received: (Data, Int, Double, Double)?
        player.onDecodedAudio = { pcm, channels, rate, pts in
            received = (pcm, channels, rate, pts)
        }
        XCTAssertNotNil(backend.onDecodedAudio, "facade set must reach the backend")

        backend.onDecodedAudio?(Data([1, 2]), 2, 48_000, 1.5)
        XCTAssertEqual(received?.1, 2)
        XCTAssertEqual(received?.2, 48_000)
        XCTAssertEqual(received?.3 ?? -1, 1.5, accuracy: 1e-9)

        player.onDecodedAudio = nil
        XCTAssertNil(backend.onDecodedAudio)
    }

    func testNativeBackendRoundTrip() throws {
        let backend: NativeBackend
        do {
            backend = try NativeBackend(renderer: nil, audioOutput: nil)
        } catch {
            throw XCTSkip("NativeBackend unavailable in this environment: \(error)")
        }
        XCTAssertNil(backend.onDecodedAudio, "default should be nil")

        var received: (channels: Int, sampleRate: Double, pts: Double)?
        backend.onDecodedAudio = { _, channels, sampleRate, pts in
            received = (channels, sampleRate, pts)
        }
        XCTAssertNotNil(backend.onDecodedAudio)
        backend.onDecodedAudio?(Data(repeating: 0, count: 64), 2, 48_000, 1.5)
        XCTAssertEqual(received?.channels, 2)
        XCTAssertEqual(received?.sampleRate, 48_000)
        XCTAssertEqual(received?.pts ?? -1, 1.5, accuracy: 1e-9)

        backend.onDecodedAudio = nil
        XCTAssertNil(backend.onDecodedAudio)
    }
}
