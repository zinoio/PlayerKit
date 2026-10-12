import XCTest
import PlayerKit
@testable import PlayerKitNative

/// Container chapters must be reachable by the app layer after open
/// (zyno#101): NativeBackend exposes them from the live demuxer's format
/// context — no separate probe pass — and stop() clears them (per-session
/// data). Fixture: chapters_mk_30s.mkv carries two titled chapters (0-10s,
/// 10-30s).
final class ChapterExposureTests: XCTestCase {

    func testContainerChaptersExposedAfterOpenAndClearedOnStop() async throws {
        let url = Bundle.module.url(forResource: "chapters_mk_30s", withExtension: "mkv",
                                    subdirectory: "Fixtures")!
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }

        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        // Poll until the open pipeline finished (_finishOpen parses chapters).
        var chapters: [ChapterInfo] = []
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            chapters = await MainActor.run { backend.chapters }
            if !chapters.isEmpty { break }
        }

        XCTAssertEqual(chapters.count, 2, "fixture carries exactly two chapters")
        XCTAssertEqual(chapters.first?.title, "Intro")
        XCTAssertEqual(chapters.first?.startDuration ?? -1, 0.0, accuracy: 0.01)
        XCTAssertEqual(chapters.last?.title, "Main Part")
        XCTAssertEqual(chapters.last?.startDuration ?? -1, 10.0, accuracy: 0.01)

        await MainActor.run { backend.stop() }
        let after = await MainActor.run { backend.chapters }
        XCTAssertTrue(after.isEmpty, "stop() must clear chapters — they are per-session")
    }
}
