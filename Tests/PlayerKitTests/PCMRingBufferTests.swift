import XCTest
@testable import PlayerKitNative

final class PCMRingBufferTests: XCTestCase {

    func testWriteReadWrapAroundPreservesExactBytes() {
        let rb = PCMRingBuffer(capacity: 4096, maxCapacity: 4096)
        // Fill 3000 bytes, read 2000 bytes (head=2000, tail=3000, count=1000)
        let chunkA = Data((0..<3000).map { UInt8($0 & 0xFF) })
        XCTAssertEqual(rb.write(chunkA), 3000)
        XCTAssertEqual(rb.readableBytes, 3000)

        var outA = Data(count: 2000)
        let r1 = outA.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, count: 2000) }
        XCTAssertEqual(r1, 2000)
        XCTAssertEqual(outA, chunkA.prefix(2000))
        XCTAssertEqual(rb.readableBytes, 1000)

        // Write 2500 bytes → wraps past 4096 boundary
        let chunkB = Data((0..<2500).map { UInt8(($0 + 73) & 0xFF) })
        XCTAssertEqual(rb.write(chunkB), 2500)
        XCTAssertEqual(rb.readableBytes, 3500)

        // Read all 3500 bytes and verify exact sequence
        var outAll = Data(count: 3500)
        let r2 = outAll.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, count: 3500) }
        XCTAssertEqual(r2, 3500)
        XCTAssertEqual(rb.readableBytes, 0)
        XCTAssertEqual(outAll, chunkA.suffix(1000) + chunkB)
    }

    func testAutoGrowPreservesWrappedData() {
        let rb = PCMRingBuffer(capacity: 4096, maxCapacity: 32768)
        let first = Data(repeating: 0xAA, count: 3000)
        XCTAssertEqual(rb.write(first), 3000)
        var scratch = Data(count: 2500)
        _ = scratch.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, count: 2500) }
        // Remaining 500 bytes of 0xAA at [2500..3000)
        let second = Data(repeating: 0x55, count: 5000)
        XCTAssertEqual(rb.write(second), 5000)
        XCTAssertGreaterThanOrEqual(rb.capacity, 5500)
        XCTAssertEqual(rb.readableBytes, 5500)

        var out = Data(count: 5500)
        let n = out.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, count: 5500) }
        XCTAssertEqual(n, 5500)
        XCTAssertEqual(out, Data(repeating: 0xAA, count: 500) + second)
    }

    func testHighRateTrueHDEnqueueThroughput() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: 48000)
        let output = AudioUnitOutput(clock: clock)
        AudioUnitOutput.mutedForTesting = true
        defer { AudioUnitOutput.mutedForTesting = false; output.stop() }
        output.start(sampleRate: 48000, channels: 2)
        output.pause()

        // 2,400 TrueHD-sized 40-sample frames (2 seconds of audio) must enqueue in < 50ms
        let frame = PCMFrame(data: Data(count: 40 * 2 * 4), pts: 0, sampleCount: 40)
        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2400 {
            output.enqueue(frame)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        XCTAssertLessThan(elapsed, 0.05, "2400 TrueHD frames took \(elapsed)s — must be lock-only memcpy")
        XCTAssertEqual(output.bufferedDuration, 2.0, accuracy: 0.01)
    }
}
