import XCTest
import VideoToolbox
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// zyno#114 harness: in-band parameter-set init (streams whose container
/// lost the extradata record) and the zero-output fast fallback.
///
/// - Control/in-band tests feed inband_high_1080p.ts (H.264 High 1080p with
///   B-frames) through VTVideoDecoder directly; `stripExtradata` empties
///   codecpar.extradata before construction to force the in-band init path.
/// - The fail-fast test feeds non-AnnexB garbage into a codecpar-initialized
///   session (MP4 avcC fixture): every attempt errors with zero frames ever
///   emitted, and the zero-output fast path must trip long before the old
///   200-attempt aggregate heuristic.
final class VTInBandDiagnosticsTests: XCTestCase {

    private func runDecode(resource: String, ext: String = "ts",
                           stripExtradata: Bool, maxPackets: Int = 400)
        throws -> (packets: Int, frames: Int, fallbackAtPacket: Int?) {
        let url = Bundle.module.url(forResource: resource, withExtension: ext,
                                    subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        guard let vs = demuxer.videoStream else {
            XCTFail("fixture has no video stream")
            return (0, 0, nil)
        }
        if stripExtradata {
            var ptr = vs.pointee.codecpar.pointee.extradata
            av_freep(&ptr)
            vs.pointee.codecpar.pointee.extradata = nil
            vs.pointee.codecpar.pointee.extradata_size = 0
        }
        let dec = try XCTUnwrap(VTVideoDecoder(stream: vs))
        if stripExtradata {
            XCTAssertTrue(dec.needsParamSetInit,
                          "empty extradata must walk the in-band init path")
        }

        var packets = 0
        var frames = 0
        var fallbackAt: Int? = nil
        while let (streamIndex, packetIn, _) = demuxer.readPacket() {
            var packet: UnsafeMutablePointer<AVPacket>? = packetIn
            defer { av_packet_free(&packet) }
            guard streamIndex == demuxer.videoStreamIndex else { continue }
            packets += 1
            if let packet, dec.decode(packet: packet) != nil { frames += 1 }
            if fallbackAt == nil && dec.needsSoftwareFallback { fallbackAt = packets }
            if packets >= maxPackets { break }
        }
        print("diag: \(resource) packets=\(packets) frames=\(frames) fallbackAt=\(fallbackAt.map(String.init) ?? "never") stripExtradata=\(stripExtradata)")
        return (packets, frames, fallbackAt)
    }

    /// Control: codecpar path must decode (regression guard for the fix).
    func testCodecparPathDecodes() throws {
        let r = try runDecode(resource: "inband_high_1080p", stripExtradata: false)
        XCTAssertGreaterThan(r.frames, 0, "codecpar path must produce frames")
        XCTAssertNil(r.fallbackAtPacket, "healthy path must not trip fallback")
    }

    /// The zyno#114 scenario: in-band init path must decode the very packets
    /// its parameter sets came from — no silent failure, no fallback.
    func testInBandPathDecodes() throws {
        let r = try runDecode(resource: "inband_high_1080p", stripExtradata: true)
        XCTAssertGreaterThan(r.frames, 0,
                             "in-band init must produce frames — silence here is the zyno#114 bug")
        XCTAssertNil(r.fallbackAtPacket,
                     "in-band path must not need software fallback on healthy content")
    }

    /// Zero-output fast fallback (zyno#114): a session that accepts decode
    /// attempts but never emits a frame must trip `needsSoftwareFallback` at
    /// 30 attempts. The MP4 fixture gives the decoder a real avcC extradata
    /// (codecpar init path, session exists); the garbage payloads are then
    /// non-AnnexB (pass straight to VT as AVCC) with no valid NALU framing,
    /// so every attempt errors and no frame can ever come out — without
    /// depending on any codec the host VT happens to support.
    func testZeroOutputFastFallbackOnUndecodableInput() throws {
        let url = Bundle.module.url(forResource: "inband_high_1080p", withExtension: "mp4",
                                    subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let vs = try XCTUnwrap(demuxer.videoStream)
        let dec = try XCTUnwrap(VTVideoDecoder(stream: vs))
        XCTAssertFalse(dec.needsParamSetInit,
                       "MP4 avcC must walk the codecpar init path")
        XCTAssertFalse(dec.needsSoftwareFallback, "fresh session must be healthy")

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        for i in 1...40 {
            XCTAssertEqual(av_new_packet(pkt, 512), 0)
            if let data = pkt!.pointee.data {
                for b in 0..<512 { data[b] = 0xA5 }  // no start codes, no NALU framing
            }
            pkt!.pointee.pts = Int64(i)
            pkt!.pointee.dts = Int64(i)
            _ = dec.decode(packet: pkt!)
            av_packet_unref(pkt)
            if i >= 30 && dec.needsSoftwareFallback { return }  // fired in time
        }
        XCTFail("zero-output fast fallback must fire by attempt 30")
    }

    /// zyno#107: AV1 is probe-gated. On devices with AV1 hardware decode
    /// (A17 Pro / M3+) the decoder must produce frames from both MP4 and MKV
    /// fixtures; on devices without it (M1/M2 and earlier) init must return
    /// nil so NativeBackend falls back to FFmpeg software decode — never a
    /// silently dead session (the exact failure mode the codec guard exists
    /// to prevent). Both branches keep this test green on any device.
    func testAV1ProbeGatedBehavior() throws {
        let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        for ext in ["mp4", "mkv"] {
            let url = Bundle.module.url(forResource: "av1_sdr_720p", withExtension: ext,
                                        subdirectory: "Fixtures")!
            let demuxer = FFmpegDemuxer()
            try demuxer.open(url: url, headers: [:])
            let vs = try XCTUnwrap(demuxer.videoStream)
            XCTAssertEqual(vs.pointee.codecpar.pointee.codec_id, AV_CODEC_ID_AV1,
                           "\(ext) fixture must actually be AV1")
            if supported {
                let dec = try XCTUnwrap(VTVideoDecoder(stream: vs),
                                        "device reports AV1 hw support — init must succeed")
                var frames = 0
                while let (streamIndex, packetIn, _) = demuxer.readPacket() {
                    var packet: UnsafeMutablePointer<AVPacket>? = packetIn
                    defer { av_packet_free(&packet) }
                    guard streamIndex == demuxer.videoStreamIndex else { continue }
                    if let packet, dec.decode(packet: packet) != nil { frames += 1 }
                    if frames >= 10 { break }
                }
                XCTAssertGreaterThan(frames, 0,
                                     "AV1 hw decode must produce frames on supported devices (\(ext))")
            } else {
                XCTAssertNil(VTVideoDecoder(stream: vs),
                             "without AV1 hardware, init must return nil for software fallback (\(ext))")
            }
        }
    }
}
