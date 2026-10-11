import XCTest
import PlayerKit
@testable import PlayerKitNative

/// Reader error propagation: before the fix, AVIOBridge.doRead swallowed a
/// thrown reader error into a bare -1, and FFmpegDemuxer.readPacket merged
/// every failure into the same nil as natural EOF — NativeBackend's demux
/// loop then treated a risk-control blackhole as "played to end" with no
/// error surfaced to the UI (2026-10-11 115 stall session: picture froze
/// silently, `demux EOF after N packets` in the log). After the fix the
/// bridge records the thrown error and returns AVERROR_EXTERNAL, and the
/// demuxer exposes lastDemuxError (nil for genuine EOF) through
/// PacketDemuxing so the backend can tell the two apart.
final class DemuxErrorPropagationTests: XCTestCase {
    private func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// Reads normally inside bounds; at/after the end it THROWS instead of
    /// returning 0 — modeling Cloud115StreamReader raising its semantic
    /// NSError after retry exhaustion. Same fixture, two readers:
    /// InMemoryReader exercises the clean-EOF path, this one the error path.
    private final class ThrowingAtEndReader: MediaRandomAccessReader, @unchecked Sendable {
        static let brokenCode = 1152
        private let data: Data
        private let error = NSError(
            domain: "io.reflex.PlayerKitTests.reader",
            code: ThrowingAtEndReader.brokenCode,
            userInfo: [NSLocalizedDescriptionKey: "reader broken (simulated risk-control blackhole)"])
        init(data: Data) { self.data = data }
        var totalSize: Int64 { Int64(data.count) }
        func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            guard offset < data.count else { throw error }
            let end = min(Int(offset) + length, data.count)
            let n = end - Int(offset)
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: Int(offset)..<end)
            return n
        }
        func close() {}
    }

    private func demuxToCompletion(_ demuxer: PacketDemuxing, file: StaticString = #filePath, line: UInt = #line) {
        var reads = 0
        while demuxer.readPacket() != nil {
            reads += 1
            if reads > 20_000 {
                XCTFail("readPacket never terminated", file: file, line: line)
                return
            }
        }
    }

    // MARK: - FFmpegDemuxer (single file)

    func testCleanEOFDemuxErrorStaysNil() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: loadFixture("clip0_5s")))
        defer { demuxer.close() }
        demuxToCompletion(demuxer)
        XCTAssertNil(demuxer.lastDemuxError, "natural EOF must not be flagged as an error")
    }

    func testReaderThrowSurfacesAsDemuxError() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: ThrowingAtEndReader(data: loadFixture("clip0_5s")))
        defer { demuxer.close() }
        demuxToCompletion(demuxer)
        let err = try XCTUnwrap(
            demuxer.lastDemuxError,
            "a thrown reader error must surface via lastDemuxError, not masquerade as EOF")
        XCTAssertEqual((err as NSError).code, ThrowingAtEndReader.brokenCode)
    }

    // MARK: - MultiClipDemuxer

    func testMultiClipSwitchToBrokenClipSurfacesError() throws {
        // clip0 is a valid TS; clip1's data can never open. Reading clip0 to
        // its natural EOF triggers switchTo(1), whose open throws — that
        // failure must surface through lastDemuxError too: it is a real
        // media error (disc sector gone, cloud file deleted), not the end
        // of the presentation.
        let multi = MultiClipDemuxer(clips: [
            (reader: InMemoryReader(data: loadFixture("clip0_5s")) as any MediaRandomAccessReader, durationSecs: 5.0),
            (reader: InMemoryReader(data: Data(count: 4096)) as any MediaRandomAccessReader, durationSecs: 5.0),
        ])
        let demuxer = try XCTUnwrap(multi)
        try demuxer.open()
        defer { demuxer.close() }
        demuxToCompletion(demuxer)
        XCTAssertNotNil(
            demuxer.lastDemuxError,
            "a failed clip-switch open must surface as an error, not a silent presentation end")
    }

    func testMultiClipCleanEOFAfterLastClipStaysNil() throws {
        let multi = MultiClipDemuxer(clips: [
            (reader: InMemoryReader(data: loadFixture("clip0_5s")) as any MediaRandomAccessReader, durationSecs: 5.0),
            (reader: InMemoryReader(data: loadFixture("clip1_5s")) as any MediaRandomAccessReader, durationSecs: 5.0),
        ])
        let demuxer = try XCTUnwrap(multi)
        try demuxer.open()
        defer { demuxer.close() }
        demuxToCompletion(demuxer)
        XCTAssertNil(demuxer.lastDemuxError, "natural end of the last clip must not be flagged as an error")
    }
}
