import Foundation
import os

/// Sample-count–based audio position clock. Thread-safe.
/// The single source of truth for current audio playback position.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "clock")

    // [diag] zyno#361: a 14 s audio-clock advance in 5 s of wall time cannot
    // come from real-time consumption of a 1× queue — it must be a reset/
    // calibration jump or a burst of oversized callbacks. Log those, gated by
    // PLAYERKIT_DIAG, so a freeze-recovery log can distinguish a dropped-span
    // jump from a clock re-anchor.
    private static var diagEnabled: Bool { NativeBackend.diagLoggingEnabled }
    private var _consumedSamples: Int64 = 0
    private(set) var sampleRate: Int32 = 44100

    /// Tracks how many primer-buffer samples have not yet fired their callbacks.
    /// Used by calibrate() to re-apply the exact remaining debt so that upcoming
    /// primer callbacks cancel out rather than spuriously advancing audioTime.
    private var _primerPendingSamples: Int64 = 0

    // MARK: - Audio delay (zyno#104)

    /// User-facing audio delay in CONTENT seconds, signed. d<0 (audio earlier)
    /// is a pure clock offset — sync delays the video to `audioTime` (mpv
    /// semantics), no content is touched. d>0 is physically implemented by the
    /// output-side delay line, whose LIVE held amount is reported back here via
    /// setExternalHold(). Guarded by lock.
    private var _delaySecs: Double = 0

    /// Seconds of decoded audio currently held by the output delay line
    /// (always ≥ 0; 0 when d ≤ 0 — no line). Reported live by the line's pump
    /// so the clock reads the shift actually in effect, not the target: during
    /// the line's initial fill the hold grows gradually and sync pulls the
    /// picture along smoothly instead of jumping. Guarded by lock.
    private var _externalHoldSecs: Double = 0

    /// Apply a user audio delay. Call together with AudioUnitOutput's
    /// setDelayTarget() (which owns the physical hold for d>0). Safe mid-play.
    func setDelay(_ secs: Double) {
        let v = secs.isFinite ? secs : 0
        lock.withLock { _delaySecs = v }
    }

    /// Called by the delay line whenever its held amount changes (push/drain/
    /// flush). `secs` is CONTENT-domain hold (the line reports wall seconds,
    /// AudioUnitOutput scales by the playback rate before calling).
    func setExternalHold(_ secs: Double) {
        lock.withLock { _externalHoldSecs = max(0, secs.isFinite ? secs : 0) }
    }

    /// Negative part of the delay (min(0, d)) — PCM-path semantic twin of
    /// fullDelay. Kept for callers that want the legacy negative-only offset.
    var negativeHold: Double {
        lock.withLock { min(0, _delaySecs) }
    }

    /// Full signed delay (zyno#127) for the passthrough master-clock read
    /// sites. The PRO renderer schedules output by packet PTS, so no
    /// entry-side hold can shift what is audible there — the shift lives
    /// entirely in the clock: sync locks the picture to `playbackTime + d`,
    /// which makes the picture run d ahead (d>0, sound audibly lags) or
    /// behind (d<0, sound leads). Positive and negative are symmetric here,
    /// unlike the PCM path where d>0 needs the output-side delay line.
    var fullDelay: Double {
        lock.withLock { _delaySecs }
    }

    /// Whether any real (non-primer) output has been consumed. The display
    /// loop's clock-ready test must use this — with d<0 audioTime starts at
    /// −|d| and would never cross the old `audioTime > 0.001` test until |d|
    /// seconds had actually played.
    var hasConsumedOutput: Bool {
        lock.withLock { _consumedSamples > Int64(0.001 * Double(sampleRate)) }
    }

    /// Current playback position in seconds. Safe to call from any thread.
    ///
    /// zyno#104: `consumed` always tracks the position being HEARD (AudioQueue
    /// callbacks). The user-facing position must be the FEED (picture) side:
    /// d>0's delay line holds |d| between heard and feed — the live hold is
    /// added back so sync locks the picture to the feed while sound lags it;
    /// d<0 subtracts |d| so sync delays the picture behind the heard audio.
    /// A static offset baked in at reset() cannot express this: an output-side
    /// hold cancelled by a clock subtraction would leave sync pulling the
    /// picture back to the heard position (feedback loop), i.e. no relative
    /// shift at all.
    var audioTime: Double {
        lock.withLock {
            Double(max(0, _consumedSamples)) / Double(sampleRate)
                + _externalHoldSecs
                + min(0, _delaySecs)
        }
    }

    /// Single-callback advance cap. AudioQueue normally fires one callback per
    /// enqueued buffer (~23ms for AAC), but batch callbacks can fire when:
    ///   - AudioQueueStop(immediate: true) drains all queued buffers at once
    ///   - the system is under load and AudioQueue's internal thread batches
    ///     multiple buffer completions into one callback
    /// A single outsized advance would let audioTime jump ~1s, which propagates
    /// to the display loop's skip-behind guard (guardWindow=60ms) and causes it
    /// to drop 5-10 consecutive video frames → the user-visible "1s 花屏" right
    /// after seek.  Cap each advance to 0.2s of samples — bounded enough that
    /// the skip-behind guard only pops at most 2-3 frames before audioTime
    /// re-converges with video PTS.
    private let maxAdvanceSeconds: Double = 0.2

    /// Called by AudioQueue callback when a real (non-primer) buffer is consumed.
    /// `rate` is the playback rate: the callback reports OUTPUT samples
    /// (tempo-scaled PCM), while this clock tracks CONTENT time — so the
    /// sample count is scaled by `rate` before accumulating. The 0.2s cap is
    /// applied BEFORE the scaling, in the OUTPUT domain: batched callbacks
    /// report consumed OUTPUT audio (a wall-clock quantity — capping it
    /// bounds how far audioTime can jump in one callback and keeps the
    /// skip-behind guard from popping a frame avalanche). Capping after
    /// scaling instead would silently DISCARD content time at rate>1 (a
    /// normal 23ms buffer becomes 46ms of content and hits the cap) — the
    /// clock falls behind the audio actually heard and every rate above 1x
    /// plays slow.
    func advance(byteCount: Int, channels: Int32, rate: Double = 1.0) {
        let bytesPerSample = Int(channels) * 4  // float32 interleaved
        guard bytesPerSample > 0, sampleRate > 0 else { return }
        let maxPerCall = Int64(Double(sampleRate) * maxAdvanceSeconds)
        let outputSamples = min(Int64(byteCount / bytesPerSample), maxPerCall)
        let clampedRate = max(0.25, min(4.0, rate))
        lock.withLock {
            // [diag] callback granularity distribution (晃动 localization):
            // a healthy queue fires ~23ms AAC buffers steadily; batched /
            // stalled callbacks show up as a wide max/min or a large maxJump.
            advanceDiag.record(Double(outputSamples))
            _consumedSamples += Int64(Double(outputSamples) * clampedRate)
        }
        // [diag] zyno#361: a single callback consuming >100ms of content means
        // either a batched/draining queue (catches up in bursts) or rate>1
        // scaling — both can move the clock multiple seconds within one 5s
        // diag window without any content actually being skipped.
        if Self.diagEnabled {
            let sr = Double(sampleRate)
            let contentSeconds = Double(outputSamples) * clampedRate / sr
            if contentSeconds > 0.1 {
                logger.info("[diag] clock.advance burst out=\(String(format: "%.3f", Double(outputSamples) / sr), privacy: .public)s content=\(String(format: "%.3f", contentSeconds), privacy: .public)s rate=\(String(format: "%.2f", clampedRate), privacy: .public)")
            }
        }
    }

    /// [diag] Per-callback consumed-output-sample distribution since the last
    /// drain (see SyncDiagStats). Returns and resets atomically.
    func drainAdvanceDiag() -> SyncDiagStats {
        lock.withLock {
            let s = advanceDiag
            advanceDiag.reset()
            return s
        }
    }

    private var advanceDiag = SyncDiagStats()

    /// Called by AudioQueue callback when a primer (silence) buffer is consumed.
    /// Identical to advance() but also decrements _primerPendingSamples so that
    /// calibrate() always sees the correct remaining primer debt.
    func advancePrimer(byteCount: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4
        guard bytesPerSample > 0, sampleRate > 0 else { return }
        let samples = Int64(byteCount / bytesPerSample)
        let maxPerCall = Int64(Double(sampleRate) * maxAdvanceSeconds)
        let clamped = min(samples, maxPerCall)
        lock.withLock {
            _consumedSamples += clamped
            _primerPendingSamples -= min(clamped, _primerPendingSamples)
        }
    }

    /// Register a primer sequence and apply the corresponding negative debt.
    /// Call before enqueueing primer silence buffers into the AudioQueue.
    /// Replaces primeDebt(); also records _primerPendingSamples so calibrate()
    /// can re-apply the exact remaining debt after a position reset.
    func startPrimer(bufferCount: Int, bytesPerBuffer: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4
        guard bytesPerSample > 0 else { return }
        let samples = Int64(bufferCount * bytesPerBuffer / bytesPerSample)
        lock.withLock {
            _primerPendingSamples = samples
            _consumedSamples -= samples
        }
    }

    /// Hard reset to a specific position. Clears all primer tracking.
    /// Use for stop() and the initial seek() call — situations where the audio
    /// queue is fully disposed and rebuilt from scratch with fresh primers.
    func reset(to time: Double, sampleRate: Int32) {
        let sr = sampleRate > 0 ? sampleRate : 44100
        let old = audioTime
        lock.withLock {
            self.sampleRate = sr
            _consumedSamples = Int64(time * Double(sr))
            _primerPendingSamples = 0
        }
        logJump("reset", old: old)
    }

    /// Calibration reset: atomically move the playback position to `time`
    /// while re-applying the remaining primer debt.
    ///
    /// After a seek, AudioUnitOutput enqueues 3 silence primer buffers before
    /// real audio, then needsClockCalibration fires to align the clock to the
    /// first decoded video frame.  A plain reset() wipes the primer debt, so
    /// when the still-pending primer callbacks fire they push audioTime past
    /// the calibration target by up to 32ms — the user-visible AV desync.
    ///
    /// calibrate() fixes this by reading _primerPendingSamples atomically and
    /// subtracting it from the new position.  Any primer callback that fires
    /// before this call already decremented _primerPendingSamples (via
    /// advancePrimer), so only the truly remaining debt is re-applied.  After
    /// all pending primers complete, audioTime converges exactly to `time`.
    func calibrate(to time: Double, sampleRate: Int32) {
        let sr = sampleRate > 0 ? sampleRate : 44100
        let old = audioTime
        lock.withLock {
            self.sampleRate = sr
            _consumedSamples = Int64(time * Double(sr)) - _primerPendingSamples
        }
        logJump("calibrate", old: old)
    }

    /// [diag] zyno#361: log any reset/calibrate that moves the clock by more
    /// than 100 ms. A freeze-recovery clock jump would land here; the observed
    /// one did not, it came from the AudioQueue callbacks instead.
    private func logJump(_ kind: String, old: Double) {
        guard Self.diagEnabled else { return }
        let new = audioTime
        guard abs(new - old) > 0.1 else { return }
        logger.info("[diag] clock.\(kind, privacy: .public) old=\(String(format: "%.3f", old), privacy: .public)s new=\(String(format: "%.3f", new), privacy: .public)s delta=\(String(format: "%+.3f", new - old), privacy: .public)s")
    }
}
