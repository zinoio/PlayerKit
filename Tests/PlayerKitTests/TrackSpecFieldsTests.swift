import XCTest
import PlayerKit
@testable import PlayerKitNative

/// Audio track spec fields reach the app layer (feat/player-reskin, reflux
/// #444 P1): the tuning panel shows "5.1 · 48 kHz · 24-bit · 1.5 Mbps" per
/// track, but NativeBackend used to drop everything except id/title/lang/
/// codec/disposition. These fixtures pin the demux-time plumbing.
final class TrackSpecFieldsTests: XCTestCase {

    private func openAndWait(_ name: String) async throws -> (backend: NativeBackend,
                                                              tracks: [TrackInfo]) {
        let url = Bundle.module.url(forResource: name, withExtension: "mkv",
                                    subdirectory: "Fixtures")!
        let backend = try await MainActor.run { try NativeBackend() }
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }
        var tracks: [TrackInfo] = []
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracks = await MainActor.run { backend.state.audioTracks }
            if !tracks.isEmpty { break }
        }
        return (backend, tracks)
    }

    func testDts51TrackCarriesChannelCountAndSampleRate() async throws {
        let (backend, tracks) = try await openAndWait("speed_dts48_51")
        defer { Task { @MainActor in backend.stop() } }

        XCTAssertEqual(tracks.count, 1)
        let t = try XCTUnwrap(tracks.first)
        XCTAssertEqual(t.channels, 6, "DTS 5.1 fixture must report 6 channels")
        XCTAssertEqual(t.sampleRate, 48_000, "DTS 48k fixture must report 48000 Hz")
    }

    func testAacStereoTrackCarriesChannelCountAndSampleRate() async throws {
        let url = Bundle.module.url(forResource: "speed_aac44_stereo",
                                    withExtension: "mp4", subdirectory: "Fixtures")!
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        var tracks: [TrackInfo] = []
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracks = await MainActor.run { backend.state.audioTracks }
            if !tracks.isEmpty { break }
        }
        XCTAssertFalse(tracks.isEmpty, "AAC fixture must expose an audio track")
        let t = try XCTUnwrap(tracks.first)
        // Despite the filename, ffprobe reports this fixture as MONO 44.1k —
        // the assertion pins the actual stream header, not the name.
        XCTAssertEqual(t.channels, 1, "AAC fixture is mono in its stream header")
        XCTAssertEqual(t.sampleRate, 44_100, "AAC 44.1k fixture must report 44100 Hz")
    }
}
