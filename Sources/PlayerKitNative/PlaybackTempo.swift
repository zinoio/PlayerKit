import Foundation
import Accelerate

/// WSOLA-style audio time-stretch for playback rate (Issue zyno#99).
///
/// Sits between `FFmpegAudioDecoder` and `AudioUnitOutput.enqueue()` on the
/// audioDecodeQueue: PCM in (float32 interleaved), rate-scaled PCM out. The
/// output sample rate is unchanged — the AudioQueue and `AudioClock` are not
/// aware of tempo; the clock side converts consumed OUTPUT samples back to
/// CONTENT samples (see AudioUnitOutput._callbackConsumed / AudioClock.advance).
///
/// Algorithm: fixed-window overlap-add with similarity search (WSOLA).
/// Each output window crossfades its `overlap` head with the previous
/// window's tail, and the input read position is searched ±searchSamples
/// around the nominal position for the alignment whose head best matches that
/// tail (vDSP normalized cross-correlation). The nominal input advance per
/// output window is `hopOut × rate`, so rate>1 skips (compresses) content and
/// rate<1 repeats (stretches) it — pitch is preserved by construction.
///
/// Threading: `process`/`reset` run only on the audioDecodeQueue (serial).
/// `rate` is written from the main thread via `setRate`, guarded by a lock;
/// the stretch state itself needs no lock (single-queue ownership).
final class PlaybackTempoProcessor {

    private let lock = NSLock()
    private var _rate: Double = 1.0

    /// 30ms window / 50% overlap / ±8ms search — the classic WSOLA operating
    /// point for speech/film content in the 0.5–2.0 range.
    private static let windowSeconds: Double = 0.030
    private static let searchSeconds: Double = 0.008

    private var sampleRate: Int = 48000
    private var channels: Int = 2

    // Interleaved float buffers (sample counts include all channels).
    private var inputBuf: [Float] = []
    /// Absolute content index (in samples incl. channels) of inputBuf[0].
    private var inputBufStart: Int = 0
    /// Next nominal content read position (samples incl. channels), float to
    /// avoid fractional-advance drift at non-integer rates.
    private var nextInputPosF: Double = 0
    /// Tail of the previously emitted window (crossfade reference). Empty on
    /// a fresh/reset pipeline — the first window is copied without a fade.
    private var prevTail: [Float] = []
    private var pendingOut: [Float] = []

    private var windowSamples: Int {
        Int(Double(sampleRate) * Self.windowSeconds) * channels
    }
    private var overlapSamples: Int { windowSamples / 2 }
    private var searchSamples: Int {
        Int(Double(sampleRate) * Self.searchSeconds) * channels
    }
    private var hopOutSamples: Int { windowSamples - overlapSamples }
    /// Emit chunks of 1024 frames (matches the AAC decode frame size the
    /// AudioQueue buffers were sized around; DTS's 512-sample frames batch up).
    private let outFrameSize = 1024 * 2

    var rate: Double {
        lock.withLock { _rate }
    }

    /// Set the playback rate. Hot-swappable mid-stream: the next process()
    /// computes positions with the new rate; stretch state carries over (a
    /// WSOLA window boundary tolerates rate changes cleanly).
    func setRate(_ newRate: Double) {
        let clamped = min(4.0, max(0.25, newRate.isFinite ? newRate : 1.0))
        lock.withLock { _rate = clamped }
    }

    /// Full reset including stream format (open/selectTrack/stop paths).
    func reset(sampleRate sr: Int32, channels ch: Int32) {
        reset()
        if sr > 0 { sampleRate = Int(sr) }
        if ch > 0 { channels = Int(ch) }
    }

    /// Drop buffered input/output, keep stream format (flush on seek where
    /// the decoder is flushed but the stream continues).
    func reset() {
        inputBuf = []
        inputBufStart = 0
        nextInputPosF = 0
        prevTail = []
        pendingOut = []
    }

    /// Stretch one decoded PCM frame. Returns 0..n output frames (empty while
    /// the input is still inside the window pipeline). `rate == 1.0` bypasses
    /// the pipeline: 1x must be bit-transparent, and the regression tests pin
    /// exact 1x behaviour.
    func process(_ frame: PCMFrame) -> [PCMFrame] {
        let r = rate
        guard r > 0 else { return [] }
        if r == 1.0 {
            reset()
            return [frame]
        }
        let floats = frame.data.count / MemoryLayout<Float>.size
        guard floats > 0, floats % channels == 0 else { return [] }
        frame.data.withUnsafeBytes { raw in
            let src = raw.assumingMemoryBound(to: Float.self)
            inputBuf.reserveCapacity(inputBuf.count + floats)
            for i in 0..<floats { inputBuf.append(src[i]) }
        }
        return drain()
    }

    // MARK: - WSOLA pipeline (audioDecodeQueue only)

    private func drain() -> [PCMFrame] {
        var out: [PCMFrame] = []
        let win = windowSamples
        let overlap = overlapSamples
        let hop = hopOutSamples
        let search = searchSamples
        let r = rate

        // WSOLA window emission (textbook overlap structure):
        //   - output stream positions [k·hop, k·hop+win) hold window k;
        //   - its head `overlap` samples CROSSFADE-REPLACE the previous
        //     window's tail already in the output stream (search keeps the two
        //     versions similar), its remaining `hop` samples are new output;
        //   - the input cursor advances hop×r per window — consumed input /
        //     produced output = r at ANY rate, and every output sample is an
        //     unmodified input sample (or a blend of two similar ones), so
        //     pitch survives.
        // Implementation: append the full window, then drop the `overlap`
        // samples that the NEXT window's crossfade head will replace... no —
        // drop FIRST: the tail `overlap` samples of the PREVIOUS window are
        // exactly what this window's head crossfades over.
        while true {
            let nominal = Int(nextInputPosF) - inputBufStart
            // Worst-case read: nominal + search + win.
            guard nominal >= 0, inputBuf.count >= nominal + win + search else { break }

            let bestOffset = prevTail.isEmpty
                ? 0
                : bestAlignment(nominal: nominal, search: search,
                                overlap: overlap, reference: prevTail)
            let start = nominal + bestOffset

            var window = [Float](repeating: 0, count: win)
            inputBuf.withUnsafeBufferPointer { buf in
                let src = buf.baseAddress! + start
                if prevTail.count == overlap {
                    for i in 0..<overlap {
                        let t = Float(i) / Float(overlap)
                        window[i] = prevTail[i] * (1 - t) + src[i] * t
                    }
                    for i in overlap..<win { window[i] = src[i] }
                } else {
                    for i in 0..<win { window[i] = src[i] }
                }
            }

            // Remove the previous window's tail (overlapped by this head),
            // then append the whole crossfaded window. Net output growth per
            // window: win - overlap = hop. The window tail now at the end of
            // pendingOut is next iteration's prevTail.
            if pendingOut.count >= overlap {
                pendingOut.removeLast(overlap)
            } else {
                pendingOut.removeAll()
            }
            pendingOut.append(contentsOf: window)
            prevTail = Array(window[(win - overlap)..<win])
            nextInputPosF += Double(hop) * r

            // Emit completed chunks but keep the trailing `overlap` samples in
            // pendingOut — the next window's crossfade head replaces them.
            while pendingOut.count - overlap >= outFrameSize {
                let chunk = Array(pendingOut[0..<outFrameSize])
                pendingOut.removeFirst(outFrameSize)
                out.append(makeFrame(chunk))
            }
        }
        // Drop consumed input below the current read position to bound memory
        // (cheap variant: only when the buffer grows past 1 MiB of floats).
        if inputBuf.count > 1 << 19 {
            let nominal = Int(nextInputPosF) - inputBufStart
            if nominal > searchSamples + windowSamples {
                let drop = nominal - searchSamples - windowSamples
                inputBuf.removeFirst(drop)
                inputBufStart += drop
            }
        }
        return out
    }

    /// Normalized cross-correlation search: among candidate alignments
    /// `nominal + offset` (offset ∈ [-search, +search], stepping one frame),
    /// pick the one whose overlap-length head best matches the previous
    /// window's tail.
    private func bestAlignment(nominal: Int, search: Int, overlap: Int,
                               reference: [Float]) -> Int {
        var bestOffset = 0
        var bestScore: Float = -.infinity
        inputBuf.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let lo = max(-search, -nominal)
            let hi = min(search, inputBuf.count - nominal - overlap)
            guard hi >= lo else { return }
            reference.withUnsafeBufferPointer { refBuf in
                guard let ref = refBuf.baseAddress else { return }
                var offset = lo
                while offset <= hi {
                    let seg = base + nominal + offset
                    var dot: Float = 0
                    var energy: Float = 0
                    vDSP_dotpr(ref, 1, seg, 1, &dot, vDSP_Length(overlap))
                    vDSP_svesq(seg, 1, &energy, vDSP_Length(overlap))
                    let score = dot / (sqrt(energy) + 1e-9)
                    if score > bestScore {
                        bestScore = score
                        bestOffset = offset
                    }
                    offset += channels  // step by whole frames
                }
            }
        }
        return bestOffset
    }

    private func makeFrame(_ floats: [Float]) -> PCMFrame {
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        // The tempo output's PTS is not consumed by the AudioQueue (the clock
        // is sample-count based); .nan keeps the content tracker (test seam)
        // on its own end-of-played accounting.
        return PCMFrame(data: data, pts: .nan, sampleCount: floats.count / channels)
    }
}
