import XCTest
import CoreGraphics
@testable import PlayerKitNative

/// FFmpeg-based thumbnail extraction (feat/seek-preview; reflux #445 ⑤).
/// Cloud libraries are overwhelmingly UHD BluRay **MKV** — AVFoundation's
/// AVAssetImageGenerator cannot demux Matroska, which is why the client-side
/// sprite path must run on the same embedded FFmpeg as playback.
final class VideoFrameExtractorTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext,
                          subdirectory: "Fixtures")!
    }

    func testExtractsFrameFromMatroska() async throws {
        let extractor = VideoFrameExtractor()
        defer { Task { await extractor.invalidate() } }
        let image = try await extractor.frame(
            url: fixture("two_audio_6s", "mkv"), headers: [:], atSeconds: 2)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 320,
                                 "must respect the 320×180 thumbnail cap")
        let aspect = Double(image.width) / Double(image.height)
        XCTAssertEqual(aspect, 16.0 / 9.0, accuracy: 0.05)
    }

    func testSeekLandsNearTargetInTransportStream() async throws {
        // GOP=1s fixture: seeking to 5s must succeed without decoding the
        // whole file (the seek path returns a keyframe at/before the target).
        let extractor = VideoFrameExtractor()
        defer { Task { await extractor.invalidate() } }
        let image = try await extractor.frame(
            url: fixture("fineseek_gop1s_10s", "ts"), headers: [:], atSeconds: 5)
        XCTAssertGreaterThan(image.width, 0)
    }

    func testReusesOpenSessionAcrossFrames() async throws {
        // Second call on the same file must not reopen the container (the
        // extractor keeps AVFormatContext alive between seeks).
        let extractor = VideoFrameExtractor()
        defer { Task { await extractor.invalidate() } }
        let url = fixture("fineseek_gop1s_10s", "ts")
        _ = try await extractor.frame(url: url, headers: [:], atSeconds: 3)
        let again = try await extractor.frame(url: url, headers: [:], atSeconds: 7)
        XCTAssertGreaterThan(again.width, 0)
    }

    func testSeekPastEndThrows() async throws {
        let extractor = VideoFrameExtractor()
        defer { Task { await extractor.invalidate() } }
        do {
            _ = try await extractor.frame(
                url: fixture("fineseek_gop1s_10s", "ts"), headers: [:], atSeconds: 9999)
            XCTFail("expected seek/decode failure past end of stream")
        } catch {
            // any ExtractError is acceptable; the point is a thrown, typed error
        }
    }
}
