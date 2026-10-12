import XCTest
@testable import PlayerKitNative

/// [diag] A/V offset jitter measurement at 1.0x (晃动 localization, 2026-10-12).
///
/// Plays a real fixture through the full pipeline (FFmpeg demux/decode +
/// AudioUnitOutput audio clock + SyncController pacing) and collects the
/// per-displayed-frame `pts - audioTime` distribution — the same data the
/// production `[diag] av[...]` log line carries, read here via the test
/// drains. The 5s-cadence single sample cannot show an oscillating offset;
/// this window can.
///
/// Reading the numbers (10s window, ~240-300 frames):
///   - healthy pacing: sd ≲ 15ms, maxJump below one frame (~40ms), few flips
///     (the offset sits at the display-latency compensation, ~+50ms)
///   - 晃动 signature: elevated sd AND large maxJump with flips ≈ n/2
///     (offset swinging ±amplitude every frame)
///
/// Gates are deliberately loose (CI/load must not flake this): they only catch
/// catastrophic pacing breaks. The printed distributions ARE the deliverable
/// — A/B runs across revisions (main vs pre-#15 vs pre-P2) compare them.
final class AVSyncJitterMeasurementTests: XCTestCase {

    private func fixtureURL(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }

    /// Plays `url` for `wallSeconds`, merging the offset windows drained every
    /// 0.5s (the production logSync may also drain at 5s marks — merge keeps
    /// the totals complete). Returns (offset window, AudioQueue granularity).
    private func measure(url: URL, wallSeconds: Double) async throws
        -> (offsets: SyncDiagStats, queue: SyncDiagStats) {
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        var merged = SyncDiagStats()
        var tickTotal = NativeBackend.TickDiag()
        let start = Date()
        while Date().timeIntervalSince(start) < wallSeconds {
            try await Task.sleep(nanoseconds: 500_000_000)
            let chunk: SyncDiagStats = await MainActor.run { backend.drainDiagAvOffset() }
            merged.merge(chunk)
            let tick: NativeBackend.TickDiag = await MainActor.run { backend.drainTickDiag() }
            tickTotal.drainLag += tick.drainLag
            tickTotal.stallAhead += tick.stallAhead
            tickTotal.checkDeny += tick.checkDeny
            tickTotal.noFrame += tick.noFrame
            tickTotal.guardSkip += tick.guardSkip
            tickTotal.appends += tick.appends
            tickTotal.drainDepth.merge(tick.drainDepth)
            let qd = await MainActor.run { backend.drainOutputQueueDiag() }
            print(String(format: "[tick@%.1fs] drain=%d stall=%d deny=%d noFrame=%d guardSkip=%d appends=%d depth[n=%d mean=%.0fms max=%.0fms] | q: enq=%d start=%d pause=%d resume=%d paused=%d bufMs=%.0f",
                         Date().timeIntervalSince(start), tick.drainLag, tick.stallAhead,
                         tick.checkDeny, tick.noFrame, tick.guardSkip, tick.appends,
                         tick.drainDepth.count,
                         tick.drainDepth.mean * 1000, tick.drainDepth.max * 1000,
                         qd.enqueues, qd.starts, qd.pauses, qd.resumes,
                         qd.pausedNow ? 1 : 0,
                         Double(qd.bufferedSamplesNow) / 44100.0 * 1000))
        }
        let queue: SyncDiagStats = await MainActor.run { backend.drainAudioQueueDiag() }
        print("[av-jitter] av[n=\(merged.count) mean=\(String(format: "%+.1f", merged.mean * 1000))ms "
            + "sd=\(String(format: "%.1f", merged.stddev * 1000))ms "
            + "min=\(String(format: "%+.1f", merged.min * 1000))ms "
            + "max=\(String(format: "%+.1f", merged.max * 1000))ms "
            + "jump=\(String(format: "%.1f", merged.maxJump * 1000))ms "
            + "flips=\(merged.signFlips)] "
            + "aq[n=\(queue.count) mean=\(String(format: "%.0f", queue.mean)) "
            + "min=\(String(format: "%.0f", queue.min)) max=\(String(format: "%.0f", queue.max)) "
            + "jump=\(String(format: "%.0f", queue.maxJump))] "
            + "tick[drain=\(tickTotal.drainLag) stall=\(tickTotal.stallAhead) "
            + "deny=\(tickTotal.checkDeny) appends=\(tickTotal.appends)]")
        return (merged, queue)
    }

    private func assertSanePacing(_ name: String, _ s: SyncDiagStats,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard s.count > 100 else {
            XCTFail("\(name): only \(s.count) frames displayed — playback never paced",
                    file: file, line: line)
            return
        }
        XCTAssertLessThan(s.stddev, 0.120,
            "\(name): per-frame offset sd \(String(format: "%.1f", s.stddev * 1000))ms — pacing badly unstable",
            file: file, line: line)
        XCTAssertLessThan(abs(s.mean), 0.300,
            "\(name): mean offset \(String(format: "%+.1f", s.mean * 1000))ms — video pinned far from audio",
            file: file, line: line)
    }

    func testAAC_MP4_OffsetDistributionAt1x() async throws {
        let (offsets, _) = try await measure(
            url: fixtureURL("speed_aac44_stereo", "mp4"), wallSeconds: 10.0)
        assertSanePacing("AAC/MP4@1x", offsets)
    }

    func testDTS_MKV_OffsetDistributionAt1x() async throws {
        let (offsets, _) = try await measure(
            url: fixtureURL("speed_dts48_51", "mkv"), wallSeconds: 10.0)
        assertSanePacing("DTS/MKV@1x", offsets)
    }
}
