import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// `videoStreamAttributes()` 是层 1 策略对账的输入入口:
/// NativeBackend 与语料 conformance 测试共用同一构造,防止双份漂移。
final class VideoStreamAttributesTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    func testHDR10StreamAttributes() throws {
        let url = corpusURL("c2_hdr10.mp4")
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let attrs = try XCTUnwrap(demuxer.videoStreamAttributes())
        XCTAssertEqual(attrs.transfer, .pq)
        XCTAssertEqual(attrs.colorMatrix, .bt2020)
        XCTAssertEqual(attrs.range, .limited)
        XCTAssertEqual(attrs.codecID, UInt32(AV_CODEC_ID_HEVC.rawValue))
        XCTAssertTrue(attrs.isHEVC10Bit)
        XCTAssertFalse(attrs.isDolbyVision)
        XCTAssertEqual(attrs.doviProfile, 0)
        XCTAssertFalse(attrs.hasHDR10Plus)
    }

    func testSDRStreamAttributes() throws {
        let url = corpusURL("c1_sdr_bt709.mp4")
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let attrs = try XCTUnwrap(demuxer.videoStreamAttributes())
        XCTAssertEqual(attrs.transfer, .sdr)
        XCTAssertEqual(attrs.colorMatrix, .bt709)
        XCTAssertFalse(attrs.isHEVC10Bit)
        XCTAssertFalse(attrs.isHEVC10BitSDRHint)
    }

    /// 2026-10-28 compat id 语义核实结论(ffmpeg dovi_meta.h 无值说明,一手对照:
    /// Chromium `media/formats/mp4/dolby_vision.h` 常量 + c5 ffprobe 金标准):
    /// 1 = HDR10 向后兼容,2 = SDR,4 = HLG,6 = UHD BD;
    /// 旧注释「1 = DV-Mel, 2 = DV-CT (HDR10 fallback)」是错的。
    /// P8.1(compat=1)BL 即 HDR10 → doviProfile8 的 tonemapCompat(=「DV 不可用
    /// 时按 HDR10 静态 tone map 播放」)必须为真。
    func testP81CompatIdIsHDR10Compatible() throws {
        let url = corpusURL("c5_dv_p81.mp4")
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let attrs = try XCTUnwrap(demuxer.videoStreamAttributes())
        XCTAssertEqual(attrs.doviProfile, 8)
        XCTAssertEqual(attrs.blSignalCompatibilityId, 1)
        let edr = decideRendererStrategy(stream: attrs, prefersTenBit: true,
                                         display: .macEDR, doviEnabled: true)
        XCTAssertEqual(edr, .doviProfile8(tonemapCompat: true))
    }

    func testReturnsNilWithoutVideoStream() {
        let demuxer = FFmpegDemuxer()
        XCTAssertNil(demuxer.videoStreamAttributes())
    }
}
