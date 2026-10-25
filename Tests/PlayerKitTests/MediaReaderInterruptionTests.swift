import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// zyno#360: an audio-track switch interrupts the demux loop's in-flight
/// network read so it can take `demuxLock` without waiting out the read (the
/// 115 case measured 8276.8 ms). The interruption must never surface as a
/// demux error and never as EOF — and the demuxer must keep working after the
/// switch's resume + seek, which is the real sequence the backend runs.
final class MediaReaderInterruptionTests: XCTestCase {

    private func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// Serves fixture bytes until armed; after that every `read` throws the
    /// marker — the contract Cloud115StreamReader implements (zyno#360).
    private final class InterruptibleReader: MediaRandomAccessReader, @unchecked Sendable {
        private let data: Data
        private let lock = NSLock()
        private var armed = false
        private var generation: UInt64 = 0

        init(data: Data) { self.data = data }

        var totalSize: Int64 { Int64(data.count) }

        func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            lock.lock()
            let isArmed = armed
            let gen = generation
            lock.unlock()
            if isArmed { throw MediaReadInterrupted() }
            guard offset < data.count else { return 0 }
            let end = min(Int(offset) + length, data.count)
            let n = end - Int(offset)
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: Int(offset)..<end)
            return n
        }

        func interruptPendingReads() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            generation += 1
            armed = true
            return generation
        }

        func resumeReads(after token: UInt64) {
            lock.lock(); defer { lock.unlock() }
            if token == generation { armed = false }
        }

        func close() {}
    }

    /// Reads until the demuxer reports a failure/EOF; returns whether it did.
    private func drainUntilNil(_ demuxer: PacketDemuxing, limit: Int = 5000) -> Bool {
        for _ in 0..<limit {
            if demuxer.readPacket() == nil { return true }
        }
        return false
    }

    func testInterruptedReadIsAPauseNotAnError() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InterruptibleReader(data: loadFixture("clip0_5s")))
        defer { demuxer.close() }

        let token = demuxer.interruptPendingReads()
        XCTAssertNotEqual(token, 0, "the reader's interruption must reach the demuxer")

        XCTAssertTrue(drainUntilNil(demuxer),
                      "an armed reader must fail the next refill instead of spinning")
        XCTAssertTrue(demuxer.lastDemuxInterrupted,
                      "an interruption must be distinguishable from a real I/O failure")
        XCTAssertNil(demuxer.lastDemuxError,
                     "an interruption must not surface as a demux I/O error")

        // The switch's real sequence: resume, seek, then the loop reads on.
        demuxer.resumeReads(after: token)
        XCTAssertTrue(demuxer.seek(to: 1.0))
        var packet: UnsafeMutablePointer<AVPacket>? = demuxer.readPacket()?.packet
        XCTAssertNotNil(packet, "reads must recover after resume + seek")
        XCTAssertFalse(demuxer.lastDemuxInterrupted)
        XCTAssertNil(demuxer.lastDemuxError)
        av_packet_free(&packet)
    }

    func testReaderWithoutInterruptionSupportIsANoOp() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: loadFixture("clip0_5s")))
        defer { demuxer.close() }

        XCTAssertEqual(demuxer.interruptPendingReads(), 0,
                       "readers without interruption support must keep the old behavior")
        demuxer.resumeReads(after: 0)
        var packet: UnsafeMutablePointer<AVPacket>? = demuxer.readPacket()?.packet
        XCTAssertNotNil(packet)
        av_packet_free(&packet)
    }

    func testMultiClipForwardsInterruptionWithoutAdvancingClips() throws {
        // 6.4 s is the fixture's real duration — the byte-domain TS seek uses
        // the declared duration for its byte-ratio target, and a wrong value
        // makes the seek fail for reasons unrelated to this test.
        let multi = try XCTUnwrap(MultiClipDemuxer(clips: [
            (reader: InterruptibleReader(data: loadFixture("clip0_5s")) as any MediaRandomAccessReader,
             durationSecs: 6.4),
            (reader: InterruptibleReader(data: loadFixture("clip1_5s")) as any MediaRandomAccessReader,
             durationSecs: 6.4),
        ]))
        try multi.open()
        defer { multi.close() }

        let token = multi.interruptPendingReads()
        XCTAssertNotEqual(token, 0, "the interruption must reach the active clip's reader")

        XCTAssertTrue(drainUntilNil(multi))
        XCTAssertTrue(multi.lastDemuxInterrupted,
                      "a clip read interrupted for a switch must not look like clip EOF")
        XCTAssertNil(multi.lastDemuxError)

        multi.resumeReads(after: token)
        XCTAssertTrue(multi.seek(to: 1.0))
        var packet: UnsafeMutablePointer<AVPacket>? = multi.readPacket()?.packet
        XCTAssertNotNil(packet, "the interrupted clip must stay current and keep serving reads")
        av_packet_free(&packet)
    }
}
