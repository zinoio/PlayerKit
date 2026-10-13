import Foundation

/// Output-side audio delay line (zyno#104): physically holds decoded PCM for
/// d>0 seconds so sound lags the picture (audio-delay adjustment).
///
/// Sits between the decode path and the real AudioQueue: frames are pushed in
/// and only released once at least `target` seconds are held. The pump rule is
/// a single invariant — pop the head while what remains after popping still
/// covers the target (`heldAfterPop >= target`):
///   - target = 0 → every frame is due immediately (bit-transparent
///     pass-through; the line is bypassed entirely at this level);
///   - target raised mid-play → pump starves until the new target is covered;
///     the queue drains to silence for the difference — the audible gap IS the
///     feedback that the delay took effect;
///   - target lowered mid-play → heads become due and play out immediately —
///     the content jump forward, one audible skip, same trade-off as every
///     commercial player;
///   - flush() (seek / stop / track switch, via AudioUnitOutput's dispose
///     path) drops everything; the hold refills from the new position.
///
/// The line never reorders and never resamples; it only delays. Its held
/// amount is reported to the AudioClock via `onHoldChange` — the clock adds it
/// to audioTime so sync locks the picture to the FEED side while the sound
/// plays `held` seconds behind (a clock offset baked at reset could not express
/// this: sync's feedback loop would cancel an output-side hold that the clock
/// didn't read back).
///
/// Targets here are WALL-clock seconds. AudioUnitOutput owns the content↔wall
/// conversion (rate) — see its setDelayTarget().
///
/// Threading: push() runs on the audio decode queue; setTarget()/flush() from
/// the main thread; all state is guarded by `lock`. `onHoldChange` fires
/// outside the lock (it takes the AudioClock's lock — no reverse edge exists).
final class AudioDelayLine: @unchecked Sendable {
    private let lock = NSLock()

    /// Frames held back, in arrival order, with the content PTS they were
    /// enqueued with (diagnostic tracking, passed through untouched).
    private var _buffer: [(frame: PCMFrame, contentPts: Double)] = []
    private var _heldSamples: Int64 = 0
    /// Release threshold in WALL seconds. 0 = pass-through.
    private var _targetSecs: Double = 0
    /// Output sample rate, set by the owner at start(); only used to express
    /// the held amount in seconds.
    private var _sampleRate: Int32 = 48000

    /// Called whenever the held amount changes. Delivered outside the lock.
    var onHoldChange: ((Double) -> Void)?

    func configure(sampleRate: Int32) {
        lock.withLock { _sampleRate = sampleRate > 0 ? sampleRate : 48000 }
    }

    /// Seconds of audio currently held (wall domain).
    var heldSeconds: Double {
        lock.withLock { Self.samplesToSecs(_heldSamples, _sampleRate) }
    }

    /// Push a decoded frame; returns the frames now due for the real queue.
    func push(_ frame: PCMFrame, contentPts: Double) -> [(frame: PCMFrame, contentPts: Double)] {
        lock.lock()
        let prevHold = Self.samplesToSecs(_heldSamples, _sampleRate)
        _buffer.append((frame, contentPts))
        _heldSamples += Int64(frame.sampleCount)
        let due = _pumpLocked()
        let hold = Self.samplesToSecs(_heldSamples, _sampleRate)
        lock.unlock()
        if hold != prevHold { onHoldChange?(hold) }
        return due
    }

    /// Change the release threshold; returns frames the lower target made due.
    func setTarget(_ wallSecs: Double) -> [(frame: PCMFrame, contentPts: Double)] {
        lock.lock()
        _targetSecs = max(0, wallSecs.isFinite ? wallSecs : 0)
        let prevHold = Self.samplesToSecs(_heldSamples, _sampleRate)
        let due = _pumpLocked()
        let hold = Self.samplesToSecs(_heldSamples, _sampleRate)
        lock.unlock()
        if hold != prevHold { onHoldChange?(hold) }
        return due
    }

    /// Drop everything (seek/stop). Hold returns to 0 and the clock is told.
    func flush() {
        lock.lock()
        guard !_buffer.isEmpty || _heldSamples > 0 else {
            lock.unlock()
            return
        }
        _buffer.removeAll()
        _heldSamples = 0
        lock.unlock()
        onHoldChange?(0)
    }

    /// Single pump invariant: pop the head while what REMAINS still covers the
    /// target. Bounds the steady-state hold to [target, target + head) — the
    /// line always keeps at least the target (once reached) and overshoots by
    /// at most one frame (~23 ms; inaudible). While starving (held < target)
    /// nothing is released: the audible silence gap IS the feedback.
    private func _pumpLocked() -> [(frame: PCMFrame, contentPts: Double)] {
        let targetSamples = Self.secsToSamples(_targetSecs, _sampleRate)
        var due: [(frame: PCMFrame, contentPts: Double)] = []
        while let head = _buffer.first,
              _heldSamples - Int64(head.frame.sampleCount) >= targetSamples {
            _buffer.removeFirst()
            _heldSamples -= Int64(head.frame.sampleCount)
            due.append(head)
        }
        return due
    }

    private static func samplesToSecs(_ samples: Int64, _ sr: Int32) -> Double {
        guard sr > 0 else { return 0 }
        return Double(samples) / Double(sr)
    }

    private static func secsToSamples(_ secs: Double, _ sr: Int32) -> Int64 {
        guard sr > 0 else { return 0 }
        return Int64(secs * Double(sr))
    }
}
