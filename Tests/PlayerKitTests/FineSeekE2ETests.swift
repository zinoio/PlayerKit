import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

/// zyno#142 end-to-end: on an indexless MPEG-TS (the BDMV clip shape) a byte-
/// domain seek physically lands short of the requested target (measured
/// landing 5.32 for a 6.1 request on fineseek_gop1s_10s.ts — the byte-domain
/// probe resyncs ~0.8s before the target on this fixture). NativeBackend must
/// arm discard-until-target from `lastSeekLandedPTS` and drop everything
/// between the landing and the target — video through the display loop, audio
/// at demux — so the FIRST DISPLAYED frame sits at the target. That first
/// frame is exactly what a user perceives as "seek landed where I asked";
/// the historical behavior (first frame = landing, ±2s away on real BDMV
/// sources) is the offset this fix removes.
///
/// These tests run with `audioOutput: nil` (no audio device in the test
/// process). That's fine for the video assertions: the display loop free-runs
/// via the pre-clock bypass until the audio clock starts.
private final class FramePTSRecorder: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    private let lock = NSLock()
    private var _pts: [Double] = []
    var renderedPTS: [Double] { lock.withLock { _pts } }
    var firstPTS: Double? { lock.withLock { _pts.first } }

    func render(pixelBuffer: CVPixelBuffer,
                pts: Double,
                colorParams: VideoColorParams,
                metadata: FrameMetadata,
                strategy: RendererStrategy?) {
        lock.withLock { _pts.append(pts) }
    }
    func flush() {}
    func clear() {}
}

private enum FirstFrameError: Error { case errored, timedOut }

final class FineSeekE2ETests: XCTestCase {
    private func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// Polls until the display loop renders its first frame (demux/decode run
    /// on background threads after play() returns), with a playback-error guard.
    private func waitForFirstFrame(_ recorder: FramePTSRecorder,
                                   backend: NativeBackend,
                                   timeoutSecs: Double = 15) async throws -> Double {
        let deadline = Date().addingTimeInterval(timeoutSecs)
        while Date() < deadline {
            if let err = await MainActor.run(body: { backend.state.error }) {
                XCTFail("playback errored before first frame: \(err)")
                throw FirstFrameError.errored
            }
            if let p = recorder.firstPTS { return p }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("no frame rendered within \(timeoutSecs)s")
        throw FirstFrameError.timedOut
    }

    /// The headline case: play(reader:seekTo: 6.1) on the multi-GOP fixture.
    /// The demuxer's byte-domain probe lands ≈5.32 (0.78s short of the target,
    /// > discardArmGap 0.5) → discard-until-target arms → the first displayed
    /// frame must sit at ≈6.1, NOT at the 5.32 landing. The landing itself is
    /// re-measured live (same seek, demuxer level) so the test tracks the
    /// fixture instead of hardcoding 5.32.
    func testSeekDisplaysFirstFrameAtTargetNotAtLanding() async throws {
        // Precondition, demuxer level: this seek's landing really is >0.5s
        // short of the target (otherwise discard wouldn't arm and the case
        // proves nothing).
        let probe = FFmpegDemuxer()
        try probe.open(reader: InMemoryReader(data: loadFixture("fineseek_gop1s_10s")))
        XCTAssertTrue(probe.seek(to: 6.1))
        let landing = try XCTUnwrap(probe.lastSeekLandedPTS, "byte-domain seek must report its landing")
        XCTAssertGreaterThan(6.1 - landing, 0.5,
            "fixture precondition: landing \(landing)s should be >discardArmGap short of 6.1")

        let recorder = FramePTSRecorder()
        let backend = try await MainActor.run { try NativeBackend(renderer: recorder, audioOutput: nil) }
        defer { Task { @MainActor in backend.stop() } }

        await MainActor.run {
            backend.play(reader: InMemoryReader(data: loadFixture("fineseek_gop1s_10s")),
                         seekTo: .seconds(6.1), knownDuration: .seconds(11.5))
        }
        let first = try await waitForFirstFrame(recorder, backend: backend)

        XCTAssertGreaterThanOrEqual(first, 6.1 - 0.05,
            "first displayed frame \(first)s fell back toward the landing \(landing)s — discard-until-target did not run")
        XCTAssertLessThanOrEqual(first, 6.1 + 0.34,
            "first displayed frame \(first)s overshot the target 6.1s — discard threw away too much")
    }

    /// Regression guard for the no-seek path: arm/discard state must be inert
    /// when the open carried no seekTo (flags stay nil), and playback must
    /// render the fixture from its start as before the fine-seek change.
    func testReaderPlaybackWithoutSeekRendersFromStart() async throws {
        let recorder = FramePTSRecorder()
        let backend = try await MainActor.run { try NativeBackend(renderer: recorder, audioOutput: nil) }
        defer { Task { @MainActor in backend.stop() } }

        await MainActor.run {
            backend.play(reader: InMemoryReader(data: loadFixture("fineseek_gop1s_10s")),
                         seekTo: nil, knownDuration: .seconds(11.5))
        }
        let first = try await waitForFirstFrame(recorder, backend: backend)

        XCTAssertLessThanOrEqual(first, 1.6,
            "no seekTo — first frame must come from the stream start (pts domain starts ≈1.48), got \(first)")
    }
}
