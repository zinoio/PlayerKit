import XCTest
@testable import PlayerKit
@testable import PlayerKitNative
import CFFmpeg

final class HevcHvcCBuilderTests: XCTestCase {

    // 由 ffmpeg/libx265 生成的 10-bit 4:2:0 参数集(320x240 测试图),
    // 作为合成向量内嵌;真实 P7 样本不入仓。
    private let vpsHex = "40010c01ffff0408000003009da800000300003cba0240"
    private let spsHex = "4201010408000003009da800000300003ca00a080f1365ba924caf016808000003000800000300c040"
    private let ppsHex = "4401c172b06240"

    private func data(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return Data(out)
    }

    private func annexB() -> Data {
        var d = Data()
        for h in [vpsHex, spsHex, ppsHex] {
            d.append(contentsOf: [0, 0, 0, 1])
            d.append(data(h))
        }
        return d
    }

    func testExtractsParameterSets() {
        let sets = HevcHvcCBuilder.extractParameterSets(from: annexB())
        XCTAssertNotNil(sets)
        XCTAssertEqual(sets?.vps, data(vpsHex))
        XCTAssertEqual(sets?.sps, data(spsHex))
        XCTAssertEqual(sets?.pps, data(ppsHex))
    }

    func testBuildsHvcC() {
        guard let sets = HevcHvcCBuilder.extractParameterSets(from: annexB()),
              let hvcC = HevcHvcCBuilder.build(sets) else {
            return XCTFail("hvcC 应构建成功")
        }
        XCTAssertEqual(hvcC[0], 1, "configurationVersion")
        // general_profile_space(2)|tier(1)|profile_idc(5)
        XCTAssertEqual(hvcC[1] & 0x1F, 1, "profile_idc 来自 SPS")
        // numOfArrays 位于 record 偏移 22
        XCTAssertEqual(hvcC[22], 3)
        // 三个参数集字节都在 record 里
        XCTAssertTrue(hvcC.range(of: data(vpsHex)) != nil)
        XCTAssertTrue(hvcC.range(of: data(spsHex)) != nil)
        XCTAssertTrue(hvcC.range(of: data(ppsHex)) != nil)
    }

    func testMissingParameterSetReturnsNil() {
        XCTAssertNil(HevcHvcCBuilder.extractParameterSets(from: data(spsHex)))
    }

    func testSystemDVFormatDescriptionAcceptsSyntheticHvcC() {
        guard let sets = HevcHvcCBuilder.extractParameterSets(from: annexB()),
              let hvcC = HevcHvcCBuilder.build(sets) else {
            return XCTFail("hvcC 构建失败")
        }
        var dovi = AVDOVIDecoderConfigurationRecord()
        dovi.dv_version_major = 1
        dovi.dv_version_minor = 0
        dovi.dv_profile = 7
        dovi.dv_level = 6
        dovi.rpu_present_flag = 1
        dovi.el_present_flag = 1
        dovi.bl_present_flag = 1
        dovi.dv_bl_signal_compatibility_id = 1
        let fd = SystemDVFormatDescription.make(hvcC: [UInt8](hvcC),
                                                width: 3840, height: 2160,
                                                dovi: dovi)
        XCTAssertNotNil(fd, "合成 hvcC + P7 转换态声明应能被 CoreMedia 接受")
    }
}
