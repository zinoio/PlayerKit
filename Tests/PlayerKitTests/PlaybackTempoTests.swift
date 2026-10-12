import XCTest
@testable import PlayerKitNative

/// WSOLA tempo processor tests (zyno#99 playback rate).
///
/// Contract under test:
///   - rate == 1.0 is BIT-TRANSPARENT: frames pass through untouched (the
///     regression tests pin exact 1x behaviour; AudioQueue output must not
///     change when the user never touches the speed control).
///   - rate != 1.0 scales DURATION only — pitch must survive (zero-crossing
///     frequency of a sine stays put) and the output/content ratio must
///     track the rate within WSOLA's window granularity.
final class PlaybackTempoTests: XCTestCase {

    private let sampleRate: Int32 = 48000
    private let channels: Int32 = 2

    private func makeProcessor(rate: Double) -> PlaybackTempoProcessor {
        let p = PlaybackTempoProcessor()
        p.setRate(rate)
        p.reset(sampleRate: sampleRate, channels: channels)
        return p
    }

    /// One decoded frame of `framesPerBuffer` frames (interleaved float32).
    private func frame(_ generator: (Int) -> Float, framesPerBuffer: Int, pts: Double) -> PCMFrame {
        let floats = framesPerBuffer * Int(channels)
        var data = Data(count: floats * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<framesPerBuffer {
                for ch in 0..<Int(channels) {
                    dst[i * Int(channels) + ch] = generator(i * Int(channels) + ch)
                }
            }
        }
        return PCMFrame(data: data, pts: pts, sampleCount: framesPerBuffer)
    }

    private func sineFrame(phase: Double, framesPerBuffer: Int, freq: Double = 440,
                           amp: Float = 0.5) -> PCMFrame {
        // Same tone on both channels — the generator here works in FRAMES,
        // not interleaved sample indices (an interleaved index would double
        // the frequency on ch0 and fool the zero-crossing pitch check).
        let floats = framesPerBuffer * Int(channels)
        var data = Data(count: floats * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<framesPerBuffer {
                let t = phase + Double(i) / Double(sampleRate)
                let v = amp * Float(sin(2.0 * .pi * freq * t))
                dst[i * Int(channels)] = v
                dst[i * Int(channels) + 1] = v
            }
        }
        return PCMFrame(data: data, pts: phase, sampleCount: framesPerBuffer)
    }

    // MARK: - 1x bit transparency

    /// rate == 1.0 must bypass the pipeline: identical bytes, no latency, and
    /// consuming frames must not leave stretch state behind.
    func testRateOneIsBitTransparent() {
        let p = makeProcessor(rate: 1.0)
        let inputs: [PCMFrame] = (0..<20).map { sineFrame(phase: Double($0) * 0.02, framesPerBuffer: 1024) }
        for input in inputs {
            let out = p.process(input)
            XCTAssertEqual(out.count, 1, "1x must emit exactly one frame per input")
            XCTAssertEqual(out[0].data, input.data, "1x output must be byte-identical")
            XCTAssertEqual(out[0].sampleCount, input.sampleCount)
        }
    }

    /// Patterned (non-sine) input too — transparency is not waveform-specific.
    func testRateOneTransparentForNoise() {
        let p = makeProcessor(rate: 1.0)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(seed >> 11) / Double(1 << 53)) * 2 - 1
        }
        for _ in 0..<10 {
            let input = frame({ _ in rnd() }, framesPerBuffer: 512, pts: 0)
            let out = p.process(input)
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out[0].data, input.data)
        }
    }

    // MARK: - Duration scaling

    /// Feed `seconds` of content at `rate`, return total output duration.
    private func stretch(seconds: Double, rate: Double, framesPerBuffer: Int = 1024) -> Double {
        let p = makeProcessor(rate: rate)
        let totalFrames = Int(seconds * Double(sampleRate))
        var emittedFrames = 0
        var fed = 0
        let ptsStep = Double(framesPerBuffer) / Double(sampleRate)
        var pts = 0.0
        while fed < totalFrames {
            let n = min(framesPerBuffer, totalFrames - fed)
            let out = p.process(sineFrame(phase: pts, framesPerBuffer: n))
            for o in out { emittedFrames += o.sampleCount }
            fed += n
            pts += ptsStep
        }
        return Double(emittedFrames) / Double(sampleRate)
    }

    /// 2x: one second of content becomes ~0.5s of output. The tail inside the
    /// WSOLA window pipeline (≤ window+search of input) is never flushed, so
    /// the bound is one-sided and slightly loose.
    func testRateTwoHalvesDuration() {
        let out = stretch(seconds: 4.0, rate: 2.0)
        XCTAssertEqual(out / 4.0, 0.5, accuracy: 0.02,
                       "2x must halve output duration (got \(out)s from 4s)")
    }

    /// 0.5x: one second of content becomes ~2s of output.
    func testRateHalfDoublesDuration() {
        let out = stretch(seconds: 4.0, rate: 0.5)
        XCTAssertEqual(out / 4.0, 2.0, accuracy: 0.05,
                       "0.5x must double output duration (got \(out)s from 4s)")
    }

    /// 1.25x, the most common "slightly faster" preset.
    func testRate125ScalesDurationProportionally() {
        let out = stretch(seconds: 4.0, rate: 1.25)
        XCTAssertEqual(out / 4.0, 0.8, accuracy: 0.03,
                       "1.25x must yield 0.8x duration (got \(out)s from 4s)")
    }

    // MARK: - Pitch preservation

    /// A 440 Hz sine stretched at 2x must still be a 440 Hz sine: count
    /// positive-going zero crossings of channel 0 over the emitted duration.
    func testRateTwoPreservesPitch() {
        let p = makeProcessor(rate: 2.0)
        var samples: [Float] = []
        let totalFrames = Int(2.0 * Double(sampleRate))
        var fed = 0
        var pts = 0.0
        // Skip the first 0.2s of output: window ramp-in + crossfade edge effects.
        var warmup = Int(0.2 * Double(sampleRate))
        while fed < totalFrames {
            let n = 1024
            for o in p.process(sineFrame(phase: pts, framesPerBuffer: n)) {
                o.data.withUnsafeBytes { raw in
                    let src = raw.assumingMemoryBound(to: Float.self)
                    var i = 0
                    while i < o.sampleCount {
                        if warmup > 0 { warmup -= 1 } else {
                            samples.append(src[i * Int(channels)])
                        }
                        i += 1
                    }
                }
            }
            fed += n
            pts += Double(n) / Double(sampleRate)
        }
        XCTAssertGreaterThan(samples.count, 30000,
                             "not enough output to measure pitch (2s content @2x ≈ 48k, minus warmup)")
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 {
            crossings += 1
        }
        let measuredFreq = Double(crossings) / (Double(samples.count) / Double(sampleRate))
        XCTAssertEqual(measuredFreq, 440.0, accuracy: 440.0 * 0.05,
                       "2x must preserve pitch; measured \(measuredFreq) Hz (WSOLA drift?)")
    }

    // MARK: - Rate clamping & hot-swap

    func testRateClampedToSupportedRange() {
        let p = PlaybackTempoProcessor()
        p.setRate(10.0)
        XCTAssertEqual(p.rate, 4.0)
        p.setRate(0.01)
        XCTAssertEqual(p.rate, 0.25)
        p.setRate(.nan)
        XCTAssertEqual(p.rate, 1.0, "non-finite rate must fall back to 1x")
    }

    /// Reset clears stretch state: re-processing identical input after a reset
    /// must reproduce the identical output (no cross-RESET crossfade residue).
    func testResetProducesDeterministicOutput() {
        let p = makeProcessor(rate: 2.0)
        let inputs: [PCMFrame] = (0..<40).map { sineFrame(phase: Double($0) * 0.02, framesPerBuffer: 1024) }

        var first: [Data] = []
        for input in inputs { first.append(contentsOf: p.process(input).map(\.data)) }

        p.reset()
        var second: [Data] = []
        for input in inputs { second.append(contentsOf: p.process(input).map(\.data)) }

        XCTAssertEqual(first, second, "output after reset must match a fresh pipeline")
    }

    /// Hot-swap mid-stream (rate changed between process calls) must not
    /// corrupt the stream: output stays finite and duration tracks the mix.
    func testMidStreamRateChangeStaysSane() {
        let p = makeProcessor(rate: 1.5)
        var emitted = 0
        var pts = 0.0
        for i in 0..<80 {
            p.setRate(i < 40 ? 1.5 : 0.75)
            for o in p.process(sineFrame(phase: pts, framesPerBuffer: 1024)) {
                emitted += o.sampleCount
                // Output sample values must stay in [-1, 1]: a channel-count or
                // overlap bug shows up as out-of-range / garbage samples.
                o.data.withUnsafeBytes { raw in
                    let src = raw.assumingMemoryBound(to: Float.self)
                    for j in 0..<(o.data.count / 4) {
                        XCTAssertTrue(src[j].isFinite, "non-finite sample at index \(j)")
                        XCTAssertLessThanOrEqual(abs(src[j]), 1.0, "sample out of range at index \(j)")
                    }
                }
            }
            pts += Double(1024) / Double(sampleRate)
        }
        let inSeconds = 80.0 * 1024.0 / Double(sampleRate)
        let expected = (40.0 * 1024.0 / 48000.0) / 1.5 + (40.0 * 1024.0 / 48000.0) / 0.75
        // Loose bound: pipeline carries ≤ one window of latency across the swap.
        let outSeconds = Double(emitted) / Double(sampleRate)
        XCTAssertEqual(outSeconds, expected, accuracy: expected * 0.25,
                       "mixed-rate stream duration \(outSeconds)s, expected ≈\(expected)s")
    }
}
