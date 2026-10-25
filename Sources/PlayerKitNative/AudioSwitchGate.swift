import Foundation

/// zyno#360: coordinates an audio-track switch with the demux loop, which
/// holds `demuxLock` across `demuxer.readPacket()` — a blocking network read
/// for cloud sources.
///
/// The switch marks the gate before it contends for `demuxLock`; the demux
/// loop stops starting new reads while the gate is pending and waits for the
/// switch to finish. Without this, the loop can re-acquire the (unfair) lock
/// between the interrupted read and the switch's lock() and add another whole
/// network read to the switch's wait (measured 8276.8 ms on a 115 BD).
///
/// The gate is a leaf lock: never take it while holding `demuxLock` on the
/// switch side, and the demux loop only queries it while holding `demuxLock`
/// (the loop releases that lock before waiting).
final class AudioSwitchGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = false

    /// Called on the switch queue before it interrupts the reader.
    func begin() {
        condition.lock()
        pending = true
        condition.unlock()
    }

    /// Called when the switch has released `demuxLock` and the loop may resume.
    func end() {
        condition.lock()
        pending = false
        condition.broadcast()
        condition.unlock()
    }

    var isPending: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pending
    }

    /// Blocks the demux loop until the switch ends.
    ///
    /// `cancelled` is polled every 0.2 s so `stop()` retires the loop without
    /// waiting out a switch; the 60 s cap is only a safety net — if a switch
    /// ever outlives it, the loop simply blocks on `demuxLock` as it did
    /// before this gate existed.
    func waitUntilSwitchFinishes(cancelled: () -> Bool) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 60)
        while pending && !cancelled() && Date() < deadline {
            // A timed wait (rather than a plain wait) re-checks `cancelled`
            // even when the switch never signals.
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
    }
}
