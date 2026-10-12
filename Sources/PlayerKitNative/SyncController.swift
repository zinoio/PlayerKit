import Foundation

/// ffplay-style frame_timer + low-pass A/V sync.
///
/// Threading (P2 display-off-main): check()/advance() run on the display-link
/// thread — video presentation no longer waits for the main thread — while
/// reset() arrives from main-thread lifecycle paths (seek/resume/stop/open).
/// All mutable state is therefore guarded by `lock`.
final class SyncController {

    private let lock = NSLock()

    let alpha: Double = 0.15
    let maxDelay: Double = 0.5

    /// Display pipeline latency compensation. ASBDLRenderer.enqueue() is
    /// async — the frame appears on screen ~1-2 vsync intervals after enqueue.
    /// Without compensation, sync thinks video is on-time but the user sees
    /// audio/subtitles ahead of video. This offset makes sync treat video as
    /// slightly behind audio, so it speeds up video to compensate.
    /// 50ms ≈ 2 frames at 24fps — covers ASBDL's HDR tone mapping + vsync wait.
    let displayLatencyCompensation: Double = 0.05

    private var frameTimer: Double = 0
    private var frameTimerSerial: Int64 = -1
    private var lastDisplayedPTS: Double = -1
    private var lastDuration: Double = 0.04

    /// Whether at least one frame has been displayed since creation or reset.
    /// Used by display loop to gate freeze/skip — first post-seek frame always shows.
    var hasDisplayedFrame: Bool {
        lock.withLock { lastDisplayedPTS >= 0 }
    }

    /// Call every display tick. Returns (shouldDisplay, computedDelay).
    /// Pass the returned delay to advance() when displaying.
    /// `rate` is the playback rate (1.0 default): the pacing target becomes
    /// nominal/rate wall-clock per content frame, with the low-pass diff
    /// normalized the same way — see computeDelay.
    func check(nextPTS: Double,
               followingPTS: Double?,
               audioTime: Double,
               now: Double,
               serial: Int64,
               rate: Double = 1.0) -> (Bool, Double) {

        lock.lock(); defer { lock.unlock() }

        if frameTimerSerial != serial {
            frameTimer = now
            frameTimerSerial = serial
        }

        // First frame after start/seek: display immediately, delay=0 so advance()
        // leaves frameTimer at 'now', and subsequent checks use nominal delay from there.
        if lastDisplayedPTS < 0 { return (true, 0) }

        let nominalDelay = nominalFrameDurationLocked(nextPTS: nextPTS, followingPTS: followingPTS)
        let delay = computeDelay(nominalDelay: nominalDelay, nextPTS: nextPTS, audioTime: audioTime, rate: rate)
        return (now >= frameTimer + delay, delay)
    }

    /// Call after confirming a frame will be displayed.
    /// Uses the delay returned from check() — not the nominal duration — so A/V corrections
    /// actually affect when the next frame is shown.
    func advance(delay: Double, pts: Double, followingPTS: Double?, audioTime: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        frameTimer += delay
        // AV_SYNC_FRAMEDUP_THRESHOLD: reset on system stall (e.g., app backgrounded)
        if now > frameTimer + 0.1 { frameTimer = now }
        lastDisplayedPTS = pts
        lastDuration = nominalFrameDurationLocked(nextPTS: pts, followingPTS: followingPTS)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        frameTimer = 0
        frameTimerSerial = -1
        lastDisplayedPTS = -1
        lastDuration = 0.04
    }

    /// Window (seconds of content time) for the display loop's freeze-ahead /
    /// skip-behind guard.
    ///
    /// The guard is a SAFETY NET — it catches real desync after a stall, seek
    /// or drop-out — and must not double as the pacing mechanism: pacing is
    /// check()/advance()'s job. A fixed 60ms window did not respect that: in
    /// steady state the front frame rides at displayLatencyCompensation
    /// (50ms) plus up to one frame duration of pacing jitter, so normal
    /// operation grazed the freeze threshold and any supply hiccup of a few
    /// ms froze the picture — measured on device as 18-24fps against
    /// 23.976fps content (2026-10-12, 晃动/过几秒卡一次).
    ///
    /// Window = compensation + 2 frame durations: compensation (what sync
    /// deliberately holds the front at), one frame for the frame being
    /// displayed, one frame of supply/pacing slack. Scaled by max(1, rate),
    /// the same floor the old fixed window used, because comp×r grows with the
    /// rate (at 2x the front legitimately rides 100ms ahead in content time)
    /// while at rates below 1x supply jitter stays wall-clock sized and the
    /// window must not shrink into it.
    ///
    /// 24fps @1x: 50 + 2×41.7 ≈ 133ms (old: 60ms).
    func guardWindow(rate: Double = 1.0) -> Double {
        let frame = lock.withLock { lastDuration > 0 ? lastDuration : 0.04 }
        return (displayLatencyCompensation + 2 * frame) * max(1.0, rate)
    }

    // MARK: - Private (call only under lock)

    private func nominalFrameDurationLocked(nextPTS: Double, followingPTS: Double?) -> Double {
        if let f = followingPTS, f > nextPTS { return f - nextPTS }
        return lastDuration > 0 ? lastDuration : 0.04
    }

    private func computeDelay(nominalDelay: Double, nextPTS: Double, audioTime: Double, rate: Double) -> Double {
        // Rate normalization (zyno#99): both the pacing target and the
        // low-pass gain are divided by r, so the steady state at any rate is
        // exactly the 1x steady state expressed on the wall clock —
        // delay* = nominal/r and diff* = latencyComp×r (the compensation is a
        // wall-clock display delay, which is comp×r of CONTENT time).
        // Without the /r gain, the fixed-α correction leaves a constant
        // −(1−r)·nominal/α content-time offset: at 2x/α=0.15 that is ~133ms
        // of permanent lip-flap.
        //
        // Continuous low-pass correction: delay = nominal/r + (α/r)·diff, no
        // hard threshold. The previous `if abs(diff) >= syncThreshold` gate
        // made the correction kick in/out across consecutive frames as diff
        // hovered near the threshold, causing delay to oscillate between
        // nominalDelay and nominalDelay + α·diff → frame pacing jitter / 来回拉扯.
        // With α=0.15 and typical diff in ±50ms, correction is ±5ms per frame
        // at 1x — well below one-frame duration (~33ms) and imperceptible,
        // but still pulls video toward audio continuously.
        //
        // displayLatencyCompensation: ASBDLRenderer.enqueue() is async, so the
        // frame actually appears on screen 1-2 vsyncs after we call enqueue.
        // Without this, sync thinks video is on-time but the user perceives
        // audio/subtitles ahead of video. Subtracting the compensation from
        // diff makes sync think video is slightly behind, speeding it up.
        let r = max(0.25, min(4.0, rate))
        let diff = nextPTS - audioTime - displayLatencyCompensation * r
        let delay = nominalDelay / r + (alpha / r) * diff
        return max(0, min(delay, maxDelay))
    }
}
