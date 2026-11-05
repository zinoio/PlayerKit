import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// VT 硬解 HEVC Main10 session 级回归(iPhone 10-bit VT 失败的本地复现载体)。
///
/// 背景(2026-11-05 真机,iPhone 15 Pro Max / iOS 26,#466 VT 设计稿):4K HEVC
/// Main10 文件 session 创建成功但逐帧零输出(30 次 → needsSoftwareFallback →
/// `VT→SW fallback`),H.264 SDR VT 正常。fixture 用 ffmpeg 合成(testsrc2 →
/// libx265 Main10 720p,mp4+mkv 双容器):macOS host 上若本测试失败 = 复现
/// (可本地迭代修复);通过 = iOS 专属路径,需真机 `[vt-probe]` 错误码定位。
final class VTHEVCSessionTests: XCTestCase {

    private func runDecoder(resource: String, ext: String, prefer10Bit: Bool) throws
        -> (submitted: Int, outputs: Int) {
        let url = Bundle.module.url(forResource: resource, withExtension: ext,
                                    subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let vs = try XCTUnwrap(demuxer.videoStream)
        let dec = try XCTUnwrap(VTVideoDecoder(stream: vs, prefer10Bit: prefer10Bit))
        var submitted = 0
        var outputs = 0
        while let (streamIndex, packetIn, _) = demuxer.readPacket() {
            var packet: UnsafeMutablePointer<AVPacket>? = packetIn
            defer { av_packet_free(&packet) }
            guard streamIndex == demuxer.videoStreamIndex else { continue }
            submitted += 1
            if dec.decode(packet: packet!) != nil {
                outputs += 1
            }
            if submitted >= 90 { break }
        }
        return (submitted, outputs)
    }

    private func assertVTDHEVCMaint10(_ ext: String) throws {
        let r = try runDecoder(resource: "VT_HEVC_Main10", ext: ext, prefer10Bit: true)
        XCTAssertGreaterThan(r.submitted, 30, "语料应有足够视频包(实际 \(r.submitted))")
        XCTAssertGreaterThan(r.outputs, 10,
            "VT 硬解 HEVC Main10 必须有逐帧输出(真机 iOS 失败形态:session OK / 逐帧零输出;实际 outputs=\(r.outputs)/\(r.submitted))")
    }

    func testHEVCMaint10MP4DecodesWithVT() throws {
        try assertVTDHEVCMaint10("mp4")
    }

    func testHEVCMaint10MKVDecodesWithVT() throws {
        try assertVTDHEVCMaint10("mkv")
    }
}
