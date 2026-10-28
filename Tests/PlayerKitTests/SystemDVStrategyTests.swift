import XCTest
import CFFmpeg
import PlayerKit

/// Task 2 决策表:`.doviSystem` 放行条件(design §5.1)与「软件路径逐位不动」
/// 反目标守门。不放行格统一用 `assertUnchanged` 同时断言两次调用(带/不带
/// 新参)结果相等,保证新增尾部默认参数不改变既有调用点的行为。
final class SystemDVStrategyTests: XCTestCase {
    private let hevcID = UInt32(AV_CODEC_ID_HEVC.rawValue)
    private let edr = DisplayCapability.macEDR
    private let sdr = DisplayCapability.macSDR
    private let sysDV = SystemDVCapability(isAvailable: true)

    private func dv(profile: UInt8, compat: UInt8 = 0) -> VideoStreamAttributes {
        VideoStreamAttributes(width: 256, height: 144, codecID: hevcID,
                              colorMatrix: .bt2020, transfer: .pq, range: .limited,
                              isDolbyVision: true, doviProfile: profile,
                              blSignalCompatibilityId: compat)
    }

    private func nonDV(transfer: VideoColorParams.TransferFunc,
                       matrix: VideoColorParams.ColorMatrix = .bt2020,
                       hasHDR10Plus: Bool = false) -> VideoStreamAttributes {
        VideoStreamAttributes(width: 256, height: 144, codecID: hevcID,
                              colorMatrix: matrix, transfer: transfer, range: .limited,
                              hasHDR10Plus: hasHDR10Plus)
    }

    private func decide(_ stream: VideoStreamAttributes, display: DisplayCapability,
                        doviEnabled: Bool = true,
                        systemDolbyVision: SystemDVCapability = SystemDVCapability(isAvailable: true),
                        dolbyVisionOutput: DolbyVisionOutputPreference = .system
    ) -> RendererStrategy {
        decideRendererStrategy(stream: stream, prefersTenBit: true, display: display,
                               doviEnabled: doviEnabled,
                               systemDolbyVision: systemDolbyVision,
                               dolbyVisionOutput: dolbyVisionOutput)
    }

    /// 未满足放行条件的新参组合(能力不可用 / 用户偏好 software)下,带新参的
    /// 调用必须与不带新参的既有调用点**逐位一致**——软件路径逐位不动的守门。
    private func assertUnchanged(_ stream: VideoStreamAttributes, display: DisplayCapability,
                                 doviEnabled: Bool = true,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let baseline = decideRendererStrategy(stream: stream, prefersTenBit: true,
                                              display: display, doviEnabled: doviEnabled)
        let variants: [(SystemDVCapability, DolbyVisionOutputPreference)] = [
            (.unavailable, .system),
            (sysDV, .software),
        ]
        for (cap, pref) in variants {
            let withNew = decideRendererStrategy(stream: stream, prefersTenBit: true,
                                                 display: display, doviEnabled: doviEnabled,
                                                 systemDolbyVision: cap,
                                                 dolbyVisionOutput: pref)
            XCTAssertEqual(withNew, baseline,
                           "cap=\(cap.isAvailable) pref=\(pref) 应与既有行为一致",
                           file: file, line: line)
        }
    }

    // MARK: - 放行格

    func testP5SystemPathSelected() {
        XCTAssertEqual(decide(dv(profile: 5), display: edr), .doviSystem)
    }

    func testP81SystemPathSelected() {
        XCTAssertEqual(decide(dv(profile: 8, compat: 1), display: edr), .doviSystem)
    }

    // MARK: - P8 其他 compat 不放行(v1 只放行 compat=1,见 SystemDVPolicy)

    func testP8OtherCompatIdsStaySoftware() {
        for compat: UInt8 in [2, 4, 6] {
            XCTAssertEqual(decide(dv(profile: 8, compat: compat), display: edr),
                           .doviProfile8(tonemapCompat: false), "compat \(compat)")
            assertUnchanged(dv(profile: 8, compat: compat), display: edr)
        }
    }

    // MARK: - 不放行格(软件路径逐位不动)

    func testSoftwarePreferenceKeepsSoftwarePath() {
        XCTAssertEqual(
            decideRendererStrategy(stream: dv(profile: 5), prefersTenBit: true,
                                   display: edr, doviEnabled: true,
                                   systemDolbyVision: sysDV,
                                   dolbyVisionOutput: .software),
            .doviProfile5)
        XCTAssertEqual(
            decideRendererStrategy(stream: dv(profile: 8, compat: 1), prefersTenBit: true,
                                   display: edr, doviEnabled: true,
                                   systemDolbyVision: sysDV,
                                   dolbyVisionOutput: .software),
            .doviProfile8(tonemapCompat: true))
    }

    func testUnavailableCapabilityKeepsSoftwarePath() {
        for stream in [dv(profile: 5), dv(profile: 8, compat: 1)] {
            XCTAssertEqual(
                decideRendererStrategy(stream: stream, prefersTenBit: true,
                                       display: edr, doviEnabled: true,
                                       systemDolbyVision: .unavailable,
                                       dolbyVisionOutput: .system),
                stream.doviProfile == 5 ? .doviProfile5 : .doviProfile8(tonemapCompat: true))
            assertUnchanged(stream, display: edr)
        }
    }

    func testDoviDisabledIgnoresSystemPath() {
        // doviEnabled=false(非免费期):保持 HDR10 基础层,与系统路径无关。
        for stream in [dv(profile: 5), dv(profile: 8, compat: 1)] {
            XCTAssertEqual(
                decideRendererStrategy(stream: stream, prefersTenBit: true,
                                       display: edr, doviEnabled: false,
                                       systemDolbyVision: sysDV,
                                       dolbyVisionOutput: .system),
                .hdr10Static(peakNits: 1000))
            assertUnchanged(stream, display: edr, doviEnabled: false)
        }
    }

    func testP7AndUnknownProfileNeverSystemPath() {
        XCTAssertEqual(decide(dv(profile: 7), display: edr), .degradedHDR10)
        XCTAssertEqual(decide(dv(profile: 9), display: edr), .degradedHDR10)
        assertUnchanged(dv(profile: 7), display: edr)
        assertUnchanged(dv(profile: 9), display: edr)
    }

    func testNonEDRDisplayNeverSystemPath() {
        XCTAssertEqual(decide(dv(profile: 5), display: sdr), .degradedHDR10)
        XCTAssertEqual(decide(dv(profile: 8, compat: 1), display: sdr), .degradedHDR10)
        assertUnchanged(dv(profile: 5), display: sdr)
        assertUnchanged(dv(profile: 8, compat: 1), display: sdr)
    }

    func testNonTenBitRendererNeverSystemPath() {
        for stream in [dv(profile: 5), dv(profile: 8, compat: 1)] {
            let got = decideRendererStrategy(stream: stream, prefersTenBit: false,
                                             display: edr, doviEnabled: true,
                                             systemDolbyVision: sysDV,
                                             dolbyVisionOutput: .system)
            XCTAssertEqual(got, .degradedHDR10)
        }
    }

    // MARK: - 非 DV 流在任何新参组合下不变

    func testNonDVStreamsUnaffectedByNewParams() {
        let streams: [VideoStreamAttributes] = [
            nonDV(transfer: .sdr, matrix: .bt709),                 // c1 SDR
            nonDV(transfer: .pq),                                  // c2 HDR10
            nonDV(transfer: .pq, hasHDR10Plus: true),              // c3 HDR10+
            nonDV(transfer: .hlg),                                 // c4 HLG
        ]
        for stream in streams {
            assertUnchanged(stream, display: edr)
            assertUnchanged(stream, display: sdr)
        }
    }

    // MARK: - videoPipeline 维度

    func testVideoPipelineDimension() {
        XCTAssertEqual(RendererStrategy.doviSystem.videoPipeline, .compressedPassthrough)
        for s: RendererStrategy in [.sdr8Bit(matrix: .bt709), .sdr10Bit, .hdr10Static(peakNits: 1000),
                                    .hdr10Plus, .doviProfile5, .doviProfile8(tonemapCompat: true),
                                    .hlgOOTF, .degradedHDR10] {
            XCTAssertEqual(s.videoPipeline, .decodedFrames, "\(s)")
        }
    }

    // MARK: - 能力探测与放行集合

    func testCapabilityProbeFollowsDisplayEDR() {
        #if os(macOS)
        XCTAssertTrue(SystemDVCapability.probe(display: .macEDR).isAvailable)
        XCTAssertFalse(SystemDVCapability.probe(display: .macSDR).isAvailable)
        #else
        XCTAssertEqual(SystemDVCapability.probe(display: .macEDR), .unavailable)
        #endif
        XCTAssertEqual(SystemDVCapability.unavailable.isAvailable, false)
    }

    func testEligibleP8CompatIdsV1IsOnlyOne() {
        XCTAssertEqual(SystemDVPolicy.eligibleP8CompatIds, [1])
    }
}
