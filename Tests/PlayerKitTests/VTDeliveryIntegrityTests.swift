import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// Delivery-integrity regression guards for the VT decode path.
///
/// VT emits frames in DECODE order (one output per submitted packet, B-frames
/// ahead of their display position) — that is by design: VideoJitterBuffer
/// append() inserts PTS-sorted so pop() always yields the next display frame.
/// What must NEVER happen is silent loss, duplication, or a pixel buffer
/// labelled with the wrong PTS — any of those scrambles the sorted buffer and
/// shakes the picture (zyno#117 follow-up).
final class VTDeliveryIntegrityTests: XCTestCase {

    /// Every submitted packet must come back exactly once: emitted PTS values
    /// must be a lossless permutation of the submitted ones (decode order is
    /// fine and expected — loss/duplication is not).
    func testDecodeOrderEmissionLosesNoFrames() throws {
        let url = Bundle.module.url(forResource: "inband_high_1080p", withExtension: "mp4",
                                    subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let vs = try XCTUnwrap(demuxer.videoStream)
        let dec = try XCTUnwrap(VTVideoDecoder(stream: vs))

        var submitted: [Double] = []
        var emitted: [Double] = []
        while let (streamIndex, packetIn, _) = demuxer.readPacket() {
            var packet: UnsafeMutablePointer<AVPacket>? = packetIn
            defer { av_packet_free(&packet) }
            guard streamIndex == demuxer.videoStreamIndex else { continue }
            let noPTS = Int64(bitPattern: 0x8000000000000000)
            let tb = vs.pointee.time_base
            if packet!.pointee.pts != noPTS {
                submitted.append(Double(packet!.pointee.pts) / Double(tb.den))
            }
            if let frame = dec.decode(packet: packet!), let pts = frame.pts {
                emitted.append(pts)
            }
            if submitted.count >= 60 { break }
        }

        XCTAssertEqual(emitted.count, submitted.count,
                       "every submitted packet must produce exactly one frame")
        XCTAssertEqual(emitted.sorted(), submitted.sorted(),
                       "emitted PTS set must equal the submitted PTS set — no loss, no duplication")
    }
}
