import XCTest
@testable import PlayerKit

/// 设计 2026-11-16 §4.3: P7 × 平台/模式 × 免费/Pro 路由矩阵。
final class P7RoutingMatrixTests: XCTestCase {

    private let edr = DisplayCapability(supportsEDR: true, targetPeakNits: 1000,
                                        supports10Bit: true, supportsHLGOOTF: true)
    private let sdr = DisplayCapability(supportsEDR: false, targetPeakNits: 100,
                                        supports10Bit: false, supportsHLGOOTF: false)
    private let sysAvailable = SystemDVCapability(isAvailable: true)
    private let sysUnavailable = SystemDVCapability.unavailable

    private func stream(profile: UInt8, compat: UInt8 = 0,
                        converted: UInt8? = nil) -> VideoStreamAttributes {
        VideoStreamAttributes(width: 3840, height: 2160, codecID: 173,
                              colorMatrix: .bt2020, transfer: .pq, range: .limited,
                              isDolbyVision: true, doviProfile: profile,
                              blSignalCompatibilityId: compat,
                              doviConvertedCompatId: converted)
    }

    private func decide(_ s: VideoStreamAttributes, edrCapable: Bool = true,
                        doviEnabled: Bool = true,
                        system: SystemDVCapability? = nil,
                        output: DolbyVisionOutputPreference = .system) -> RendererStrategy {
        decideRendererStrategy(stream: s,
                               prefersTenBit: edrCapable,
                               display: edrCapable ? edr : sdr,
                               doviEnabled: doviEnabled,
                               systemDolbyVision: system ?? sysAvailable,
                               dolbyVisionOutput: output)
    }

    // MARK: P7 原始(未转换)

    func testRawP7NeverEntersSystemPath() {
        XCTAssertEqual(decide(stream(profile: 7)), .degradedHDR10)
        XCTAssertEqual(decide(stream(profile: 7), output: .software), .degradedHDR10)
        XCTAssertEqual(decide(stream(profile: 7), output: .hardwareHDR10), .degradedHDR10)
        XCTAssertEqual(decide(stream(profile: 7), edrCapable: false), .degradedHDR10)
    }

    // MARK: P7 转换态(compat 1)

    func testConvertedP7EntersSystemPathOnMacOSEDRPro() {
        XCTAssertEqual(decide(stream(profile: 7, converted: 1)), .doviSystem)
    }

    func testConvertedP7FallsBackWhenSystemUnavailable() {
        XCTAssertEqual(decide(stream(profile: 7, converted: 1), system: sysUnavailable),
                       .doviProfile8(tonemapCompat: true))
    }

    func testConvertedP7SoftwareQualityGetsDynamicTrim() {
        XCTAssertEqual(decide(stream(profile: 7, converted: 1), output: .software),
                       .doviProfile8(tonemapCompat: true))
    }

    func testConvertedP7HardwareModeStaysDegradedHDR10() {
        XCTAssertEqual(decide(stream(profile: 7, converted: 1), output: .hardwareHDR10),
                       .degradedHDR10)
    }

    func testConvertedP7NonEDRStaysDegraded() {
        XCTAssertEqual(decide(stream(profile: 7, converted: 1), edrCapable: false),
                       .degradedHDR10)
    }

    func testFreeTierGuardUnchangedForConvertedP7() {
        // 免费版必须在系统路径判断之前就被拦下(D3:guard 位置不动)。
        XCTAssertEqual(decide(stream(profile: 7, converted: 1), doviEnabled: false),
                       .hdr10Static(peakNits: 1000))
    }

    // MARK: 现有路径逐位回归

    func testExistingP5P8PathsUnchanged() {
        XCTAssertEqual(decide(stream(profile: 5)), .doviSystem)
        XCTAssertEqual(decide(stream(profile: 8, compat: 1)), .doviSystem)
        XCTAssertEqual(decide(stream(profile: 8, compat: 1), doviEnabled: false),
                       .hdr10Static(peakNits: 1000))
        XCTAssertEqual(decide(stream(profile: 8, compat: 1), edrCapable: false),
                       .degradedHDR10)
        XCTAssertEqual(decide(stream(profile: 8, compat: 4)),
                       .doviProfile8(tonemapCompat: false))
    }

    // MARK: 准入纯函数

    func testEligibilityMatrix() {
        XCTAssertFalse(SystemDVPolicy.isEligible(profile: 7, compatId: 0))
        XCTAssertTrue(SystemDVPolicy.isEligible(profile: 7, compatId: 0, convertedP7CompatId: 1))
        XCTAssertFalse(SystemDVPolicy.isEligible(profile: 7, compatId: 0, convertedP7CompatId: 2))
        XCTAssertTrue(SystemDVPolicy.isEligible(profile: 5, compatId: 0))
        XCTAssertTrue(SystemDVPolicy.isEligible(profile: 8, compatId: 1))
        XCTAssertFalse(SystemDVPolicy.isEligible(profile: 8, compatId: 4))
    }

    func testRpuValidationThreshold() {
        XCTAssertFalse(SystemDVPolicy.shouldFallbackAfterRpuValidation(validFrames: 0, checkedFrames: 7))
        XCTAssertTrue(SystemDVPolicy.shouldFallbackAfterRpuValidation(validFrames: 0, checkedFrames: 8))
        XCTAssertFalse(SystemDVPolicy.shouldFallbackAfterRpuValidation(validFrames: 1, checkedFrames: 8))
    }
}
