import XCTest
@testable import PlayerKitNative

/// Regression tests for zyno#361: after a network stall the demux refills at
/// many × real time and the AudioQueue *takes* that recovery burst immediately
/// (its buffer callback means "finished taking data from a buffer"). The
/// callback-driven AudioClock then advanced 2–3× while the queue's own played
/// timebase kept 1× — clock and picture jumped ~7 s ahead of the sound,
/// flickering and desyncing.
///
/// The fix bounds TAKEN-but-unplayed audio (maxPlayingLeadSeconds) by blocking
/// the decode path instead of feeding the overrun. These tests pin both halves:
/// a burst must be paced by playback, and a normal 1× feed must not be delayed.
final class AudioUnitOutputRecoveryTests: XCTestCase {

    private let sampleRate: Int32 = 48000
    private let samplesPerFrame = 512  // one DTS core frame — the size the app enqueues

    /// A silent stereo float32 frame (no sound is produced by these tests).
    private func silentFrame() -> PCMFrame {
        PCMFrame(data: Data(count: samplesPerFrame * 2 * 4), pts: 0, sampleCount: samplesPerFrame)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// The playing back-pressure: an enqueue must wait when the queue has
    /// taken more audio than playback can have consumed. Uses the injected-lead
    /// seam so the assertion does not depend on the audio thread's take timing
    /// (the real queue's post-stall take burst is timing-dependent; zyno#361).
    func testEnqueueWaitsWhenTakenAudioLeadsPlayback() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.maxPlayingLeadSeconds = 0.4
        output.starvationRebuildSeconds = 60
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        // 1 s of TAKEN audio with nothing played: the wait must hold the enqueue
        // until the wall clock has consumed all but maxPlayingLeadSeconds
        // (≈ 0.6 s). Without the wait the enqueue returns in microseconds.
        output.injectPlaybackLeadForTesting(takenSeconds: 1.0)
        let started = Date()
        output.enqueue(silentFrame())
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(elapsed, 0.3,
            "enqueue must wait for the taken-but-unplayed lead to drain "
            + "(waited \(String(format: "%.3f", elapsed))s)")
        XCTAssertLessThan(elapsed, 8.0, "pacing must not wedge the decode path")
    }

    /// A queue starved for seconds must be rebuilt before it is fed again.
    /// zyno#361: after a 25 s reader stall the old queue kept consuming buffers
    /// (~1×, so the sample clock looked healthy) while the device output stayed
    /// at digital silence for minutes — it never played them. Rebuilding is the
    /// same stop()/start() a seek performs, which measurably restored sound.
    /// Uses the simulated-starvation seam: CI's virtual audio device does not
    /// deliver callbacks reliably enough to build a real 3 s gap.
    func testQueueIsRebuiltAfterALongStarvation() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.starvationRebuildSeconds = 0.5
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }
        XCTAssertEqual(output.queueRebuildCountForTesting(), 0)

        output.simulateStarvationForTesting(seconds: 3.0)
        output.enqueue(silentFrame())
        XCTAssertEqual(output.queueRebuildCountForTesting(), 1,
                       "the first post-starvation enqueue must rebuild the queue")

        // A normally fed queue must never be rebuilt.
        output.starvationRebuildSeconds = 60
        output.enqueue(silentFrame())
        XCTAssertEqual(output.queueRebuildCountForTesting(), 1)
    }

    /// Healthy playback feeds at ~1×; the lead back-pressure must be invisible
    /// on that path. Measures the enqueue calls themselves, not the loop wall
    /// time: CI runners stretch 10.7 ms sleeps to ~38 ms, which says nothing
    /// about whether the enqueue blocked.
    func testNormalRateFeedIsNotDelayedByTheLeadCap() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.starvationRebuildSeconds = 60  // a slow runner is not a starvation
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        var enqueueSeconds = 0.0
        for _ in 0..<60 {  // 0.64 s of audio at the natural cadence
            let t = Date()
            output.enqueue(silentFrame())
            enqueueSeconds += Date().timeIntervalSince(t)
            Thread.sleep(forTimeInterval: Double(samplesPerFrame) / Double(sampleRate))
        }
        XCTAssertLessThan(enqueueSeconds, 0.5,
            "enqueue must not block on a normal feed (spent "
            + "\(String(format: "%.3f", enqueueSeconds))s in 60 enqueues)")
    }
}
