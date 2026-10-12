import XCTest
import CFFmpeg
import CoreVideo
@testable import PlayerKitNative

/// Decisive pairing experiment: each frame's luma encodes its frame index
/// (luma = 16 * (N mod 16)). If VT returns a pixel buffer whose content
/// disagrees with the PTS it is labelled with, the pipeline is mispairing
/// frames — sorted-FIFO display then shows displaced images every GOP
/// (user-visible picture shake).
final class VTPairingRegressionTests: XCTestCase {

    func testPixelContentMatchesLabelledPTS() throws {
        let url = Bundle.module.url(forResource: "luma_pairtest_30fps", withExtension: "mp4",
                                    subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let vs = try XCTUnwrap(demuxer.videoStream)
        let dec = try XCTUnwrap(VTVideoDecoder(stream: vs))

        var mismatches: [String] = []
        var checked = 0
        while let (streamIndex, packetIn, _) = demuxer.readPacket() {
            var packet: UnsafeMutablePointer<AVPacket>? = packetIn
            defer { av_packet_free(&packet) }
            guard streamIndex == demuxer.videoStreamIndex else { continue }
            if let frame = dec.decode(packet: packet!), let pts = frame.pts {
                let expectedN = Int((pts * 30.0).rounded())
                let expectedLuma = 16 * (expectedN % 16)
                let actualLuma = Self.lumaOf(frame.pixelBuffer)
                checked += 1
                if actualLuma != expectedLuma {
                    mismatches.append(
                        String(format: "pts=%.3f (N=%d) want luma %d, got %d",
                               pts, expectedN, expectedLuma, actualLuma))
                }
            }
            if checked >= 40 { break }
        }

        print("diag: checked=\(checked) mismatches=\(mismatches.count)")
        for m in mismatches.prefix(12) { print("diag: MISMATCH \(m)") }
        XCTAssertTrue(mismatches.isEmpty,
            "pixel content must match the PTS VT labels it with")
    }

    /// Mean luma of the Y plane rounded to the nearest encoded level.
    private static func lumaOf(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return -1 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Sample the centre 16x16 to dodge edge effects; fold to the encoded
        // level set (multiples of 16 up to 240).
        var sum = 0
        for y in (h / 2 - 8)..<(h / 2 + 8) {
            for x in (w / 2 - 8)..<(w / 2 + 8) {
                sum += Int(ptr[y * stride + x])
            }
        }
        let mean = Double(sum) / 256.0
        return Int((mean / 16).rounded()) * 16
    }
}
