import XCTest
@testable import PlayerKit

final class DoviRpuConverterTests: XCTestCase {

    private func sampleDM() -> DolbyVisionFrameMetadata {
        var dm = DolbyVisionFrameMetadata(profile: 7, blSignalCompatibilityId: 0)
        dm.level1 = .init(minPq: 0x0100, maxPq: 0xF000, avgPq: 0x8000)
        dm.level2 = .init(targetMaxPq: 2081, trimSlope: 1.05, trimOffset: -0.02,
                          trimPower: 0.98, trimChromaWeight: 1.0,
                          trimSaturationGain: 1.1, msWeight: 2048)
        dm.level3 = .init(minPqOffset: 0.01, maxPqOffset: -0.01, avgPqOffset: 0)
        dm.level6 = .init(maxLuminance: 4000, minLuminance: 50, maxCll: 1000, maxFall: 400)
        return dm
    }

    private func p7(nlq: Bool = true, reshape: Bool = true,
                    dm: DolbyVisionFrameMetadata? = nil) -> DoviRpuConverter.P7Snapshot {
        .init(dvProfile: 7, elPresent: true, blBitDepth: 10, elBitDepth: 10,
              hasNLQ: nlq, hasReshape: reshape, dm: dm ?? sampleDM())
    }

    func testConvertsP7ToCompat1AndKeepsDM() {
        guard let out = DoviRpuConverter.convert(p7()) else {
            return XCTFail("P7 应转换成功")
        }
        XCTAssertEqual(out.compatId, 1)
        XCTAssertEqual(out.blBitDepth, 10)
        // DM 原样保留(L1/L2/L3/L6)
        XCTAssertEqual(out.dm.level1?.maxPq, 0xF000)
        XCTAssertEqual(out.dm.level2?.targetMaxPq, 2081)
        XCTAssertEqual(out.dm.level6?.maxLuminance, 4000)
        XCTAssertTrue(DoviRpuConverter.isValid(out))
    }

    func testDropsNLQAndReshapeSemantics() {
        // 输入带 NLQ/reshape,输出模型只有 compat 1 + DM —— 不携带任何
        // reshape/NLQ 字段,等价于"BL 直通"。
        let out = DoviRpuConverter.convert(p7(nlq: true, reshape: true))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.compatId, 1)
    }

    func testRejectsNonP7() {
        var input = p7()
        input.dvProfile = 8
        XCTAssertNil(DoviRpuConverter.convert(input))
        input.dvProfile = 5
        XCTAssertNil(DoviRpuConverter.convert(input))
    }

    func testRejectsMissingEL() {
        var input = p7()
        input.elPresent = false
        XCTAssertNil(DoviRpuConverter.convert(input))
    }

    func testRejectsLowBitDepth() {
        var input = p7()
        input.blBitDepth = 8
        XCTAssertNil(DoviRpuConverter.convert(input))
    }

    func testKeepsEmptyDMAsValidFrame() {
        let empty = DolbyVisionFrameMetadata(profile: 7, blSignalCompatibilityId: 0)
        let out = DoviRpuConverter.convert(p7(dm: empty))
        XCTAssertNotNil(out)
        XCTAssertNil(out?.dm.level1)
    }
}
