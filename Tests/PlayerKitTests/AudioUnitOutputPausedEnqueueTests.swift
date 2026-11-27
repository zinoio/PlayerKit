import XCTest
@testable import PlayerKitNative

/// Regression tests for the 2026-09-21 audio-loss bug.
///
/// `AudioUnitOutput.enqueue` used to silently DISCARD every decoded frame that
/// arrived while the queue was paused and already held 60 buffers (~0.64 s).
/// The pipeline pauses the audio queue whenever it (re)starts playback and the
/// video jitter buffer is still filling (~1.2 s on a 720p stream), while demux
/// and audio decode keep running — so ~0.55 s of audio was thrown away on every
/// start and another 0.6–0.7 s after every pause → resume. The audio clock and
/// the video carried on from before the dropped span, the audible content
/// jumped ahead: sound permanently ~0.6–1 s ahead of the picture.
///
/// Measured on the real movie (audio content position vs. the audio clock):
/// 52 dropped frames (0.555 s) ⇔ a +0.561 s audio-vs-clock step.
final class AudioUnitOutputPausedEnqueueTests: XCTestCase {

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

    /// Polls until `clock.audioTime` has not moved for `quiet` seconds.
    ///
    /// Do not wait for `hasPendingOutput == false` here: with a finite feed the
    /// AudioQueue can keep its last 1–2 buffers checked out on CI and never
    /// fire their callbacks, even after 30 s. The ±50 ms assertion below
    /// tolerates that normal tail while still failing the old 60-buffer cap
    /// (which loses ~40 frames).
    private func waitUntilClockSettles(timeout: TimeInterval,
                                       quiet: TimeInterval = 1.0,
                                       clock: AudioClock) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = clock.audioTime
        var lastMove = Date()
        while Date() < deadline {
            let now = clock.audioTime
            if abs(now - last) > 0.0005 {
                last = now
                lastMove = Date()
            }
            if Date().timeIntervalSince(lastMove) > quiet { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Waits until the clock has at least reached `minimum`, then until it
    /// stops moving. The first wait prevents a delayed AudioQueueStart (common
    /// on CI) from looking like a settled clock at 0; the second lets the tail
    /// callbacks land before the final assertion.
    private func waitUntilSettled(atLeast minimum: Double,
                                  timeout: TimeInterval = 30.0,
                                  clock: AudioClock) -> Bool {
        guard waitUntil(timeout: timeout, { clock.audioTime >= minimum }) else { return false }
        return waitUntilClockSettles(timeout: 5.0, clock: clock)
    }

    private func drainDescription(_ output: AudioUnitOutput, clock: AudioClock) -> String {
        let d = output.drainQueueDiag()
        let bufferedSeconds = Double(d.bufferedSamplesNow) / Double(max(1, d.sampleRateNow))
        return "buffered=\(d.bufferedSamplesNow) samples "
            + "(\(String(format: "%.3f", bufferedSeconds))s), "
            + "frames=\(d.bufferedFramesNow), callbacks=\(d.callbackCount), "
            + "paused=\(d.pausedNow), clock=\(String(format: "%.3f", clock.audioTime))s"
    }

    /// Every frame handed to a paused queue must still be played after resume() as
    /// long as it stays within the paused cap (5 s): the audio clock (which counts
    /// consumed samples) has to reach the total duration enqueued, not stop at the
    /// 60 buffers (0.64 s of DTS) the old buffer-count cap allowed.
    func testFramesEnqueuedWhilePausedAndFullAreNotDiscarded() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        let total = 100  // 1.07 s: more than the old 60-buffer cap, far below the 5 s cap
        for _ in 0..<total { output.enqueue(silentFrame()) }
        output.resume()

        let expected = Double(total * samplesPerFrame) / Double(sampleRate)  // 1.0667 s
        // 等时钟停走再断言终值:CI 的有限喂入结束后,AudioQueue 可能把最后
        // 1~2 个 buffer 留在队列里不再回调,不能用 hasPendingOutput == false
        // 当排空判据。±50ms 容差覆盖这个正常尾部;旧 60-buffer cap 会丢约
        // 40 帧(0.64s),仍然会红。
        XCTAssertTrue(waitUntilSettled(atLeast: expected - 0.05, clock: clock),
            "audio clock never reached/settled: \(drainDescription(output, clock: clock))")
        XCTAssertEqual(clock.audioTime, expected, accuracy: 0.05,
            "frames were lost: enqueued \(total) frames (=\(String(format: "%.3f", expected))s), "
            + "clock settled at \(String(format: "%.3f", clock.audioTime))s "
            + "(\(Int(((expected - clock.audioTime) * Double(sampleRate)) / Double(samplesPerFrame))) frames lost)")
    }

    /// The protection the old cap existed for must survive: demux reads far
    /// faster than real time while the queue is paused (buffering), so the queue
    /// may not accumulate audio without bound. Beyond `maxPausedBufferSeconds`
    /// new frames are still discarded.
    func testPausedQueueStillHasABoundOnHowMuchAudioItAccumulates() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.maxPausedBufferSeconds = 0.5
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        for _ in 0..<200 { output.enqueue(silentFrame()) }  // 2.13 s offered, 0.5 s allowed
        output.resume()

        // 固定 1.6s 既受 CI 虚拟设备回调节奏影响,也会把 primer 记账缺口
        // 误判成「没播够」。等时钟至少到达下限后再停走;最后 1~2 个 buffer
        // 留在 AudioQueue 属于正常尾部。
        let cap = 0.5
        XCTAssertTrue(waitUntilSettled(atLeast: cap - 0.06, clock: clock),
            "audio clock never reached/settled: \(drainDescription(output, clock: clock))")
        XCTAssertGreaterThan(clock.audioTime, cap - 0.06, "the allowed 0.5 s must be played")
        // Upper margin must clear scheduler-timing overshoot: the cap check
        // runs before each enqueue, so the kept total can legitimately exceed
        // cap by several frames depending on when the count snapshot lands —
        // on loaded CI runners observed at cap + 6 frames (0.5653 s) and once
        // at cap + 10 frames (0.608 s, Nightly, also on main; zyno#111).  The
        // margin stays far below any real cap breakage: a broken cap plays the
        // offered 2.13 s, 2.8× beyond cap + 0.25.
        XCTAssertLessThan(clock.audioTime, cap + 0.25,
                          "audio beyond maxPausedBufferSeconds must be dropped, not accumulated")
    }

    /// Frames held back while paused belong to the timeline that was in flight
    /// when flush() was called (seek / pause→resume rebuild): they must be
    /// discarded with it, never played after the next start().
    func testFlushDiscardsFramesHeldBackWhilePaused() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        for _ in 0..<100 { output.enqueue(silentFrame()) }  // 40 of them are held back

        output.flush()                                       // old timeline ends here
        clock.reset(to: 0, sampleRate: sampleRate)
        output.start(sampleRate: sampleRate, channels: 2)    // new queue, new timeline
        let fresh = 10
        for _ in 0..<fresh { output.enqueue(silentFrame()) }

        let expected = Double(fresh * samplesPerFrame) / Double(sampleRate)  // 0.1067 s
        XCTAssertTrue(waitUntil(timeout: 3.0) { abs(clock.audioTime - expected) < 0.02 },
                      "new timeline must play exactly its own \(fresh) frames")
        // and nothing stale trickles in afterwards
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(clock.audioTime, expected, accuracy: 0.02,
                       "frames from the flushed timeline must not be played")
    }
}
