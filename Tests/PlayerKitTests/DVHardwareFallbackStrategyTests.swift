import XCTest
import CFFmpeg
import PlayerKit

/// DV 流畅优先(2026-11-07 设计):VT 硬解基础层 + 兼容层显示。
/// P5 无 HDR10 基础层,必须保持软件路径;P8 按 compat 落到 HDR10/HLG/SDR。
final class DVHardwareFallbackStrategyTests: XCTestCase {
    private let hevcID = UInt32(AV_CODEC_ID_HEVC.rawValue)
    private let edr = DisplayCapability.macEDR
    private let sdr = DisplayCapability.macSDR

    private func dv(profile: UInt8, compat: UInt8 = 0) -> VideoStreamAttributes {
        VideoStreamAttributes(width: 3840, height: 2160, codecID: hevcID,
                              colorMatrix: .bt2020, transfer: .pq, range: .limited,
                              isDolbyVision: true, doviProfile: profile,
                              blSignalCompatibilityId: compat)
    }

    private func decide(_ stream: VideoStreamAttributes, display: DisplayCapability,
                        output: DolbyVisionOutputPreference) -> RendererStrategy {
        decideRendererStrategy(stream: stream, prefersTenBit: true, display: display,
                               doviEnabled: true,
                               systemDolbyVision: SystemDVCapability(isAvailable: false),
                               dolbyVisionOutput: output)
    }

    func testP81UsesHDR10Hardware() {
        let s = decide(dv(profile: 8, compat: 1), display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .hdr10Static(peakNits: 1000))
        XCTAssertEqual(s.decoderPreference, .ffmpegHW)
    }

    func testP84UsesHLGHardware() {
        let s = decide(dv(profile: 8, compat: 4), display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .hlgOOTF)
        XCTAssertEqual(s.decoderPreference, .ffmpegHW)
    }

    func testP82UsesSDR10BitHardware() {
        let s = decide(dv(profile: 8, compat: 2), display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .sdr10Bit)
        XCTAssertEqual(s.decoderPreference, .vtHW)
    }

    func testP7StaysDegradedHDR10() {
        let s = decide(dv(profile: 7), display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .degradedHDR10)
        XCTAssertEqual(s.decoderPreference, .ffmpegHW)
    }

    /// P5 没有 HDR10 兼容基础层,硬解会偏色 —— 必须留在软件 DV 路径。
    func testP5StaysOnSoftwarePath() {
        let s = decide(dv(profile: 5), display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .doviProfile5)
        XCTAssertEqual(s.decoderPreference, .ffmpegSW)
    }

    func testNonEDRFallsBackToSDR() {
        let s = decide(dv(profile: 8, compat: 1), display: sdr, output: .hardwareHDR10)
        XCTAssertEqual(s, .sdr8Bit(matrix: .bt2020))
    }

    func testSoftwarePreferenceUnchanged() {
        let s = decide(dv(profile: 8, compat: 1), display: edr, output: .software)
        XCTAssertEqual(s, .doviProfile8(tonemapCompat: true))
        XCTAssertEqual(s.decoderPreference, .ffmpegSW)
    }

    func testNonDVStreamUnaffected() {
        let stream = VideoStreamAttributes(width: 3840, height: 2160, codecID: hevcID,
                                           colorMatrix: .bt2020, transfer: .pq, range: .limited)
        let s = decide(stream, display: edr, output: .hardwareHDR10)
        XCTAssertEqual(s, .hdr10Static(peakNits: 1000))
        XCTAssertEqual(s.decoderPreference, .ffmpegHW)
    }
}
