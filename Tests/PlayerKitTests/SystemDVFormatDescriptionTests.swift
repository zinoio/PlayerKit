import XCTest
import CoreMedia
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// Task 3:DV 配置 box 序列化与 dvh1 格式描述构造。
/// 位布局金标准 = patch_dvcc.py(= ffmpeg `ff_isom_put_dvcc_dvvc` 的
/// libavformat/dovi_isom.c 布局)。
final class SystemDVFormatDescriptionTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    private func makeRecord(profile: UInt8, level: UInt8 = 0,
                            rpu: UInt8 = 1, el: UInt8 = 0, bl: UInt8 = 1,
                            compat: UInt8 = 1,
                            mdCompression: UInt8 = UInt8(AV_DOVI_COMPRESSION_LIMITED.rawValue)
    ) -> AVDOVIDecoderConfigurationRecord {
        var r = AVDOVIDecoderConfigurationRecord()
        r.dv_version_major = 1
        r.dv_version_minor = 0
        r.dv_profile = profile
        r.dv_level = level
        r.rpu_present_flag = rpu
        r.el_present_flag = el
        r.bl_present_flag = bl
        r.dv_bl_signal_compatibility_id = compat
        r.dv_md_compression = mdCompression
        return r
    }

    // MARK: - configBox

    func testConfigBoxProfile5UsesDvcC() {
        let (type, payload) = SystemDVFormatDescription.configBox(makeRecord(profile: 5))
        XCTAssertEqual(type, "dvcC")
        XCTAssertEqual(payload.count, 24)
        XCTAssertEqual([UInt8](payload.prefix(2)), [1, 0], "version major=1 minor=0")
    }

    func testConfigBoxProfile8UsesDvvC() {
        let (type, _) = SystemDVFormatDescription.configBox(makeRecord(profile: 8))
        XCTAssertEqual(type, "dvvC")
    }

    /// 与 patch_dvcc.py 的 DVCC_PAYLOAD 对同一 (profile, level, compat) 逐字节
    /// 对账。c5 的 ffprobe 金标准:profile=8, level=0, rpu=1, el=0, bl=1,
    /// compat=1, md_compression=limited(1)。
    func testConfigBoxRoundTripAgainstFFprobe() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: corpusURL("c5_dv_p81.mp4"), headers: [:])
        defer { demuxer.close() }
        let record = try XCTUnwrap(demuxer.doviConfiguration, "c5 应有 DOVI_CONF")
        XCTAssertEqual(record.dv_profile, 8)
        XCTAssertEqual(record.dv_bl_signal_compatibility_id, 1)

        let (type, payload) = SystemDVFormatDescription.configBox(record)
        // profile > 7 → dvvC(ffmpeg movenc ff_isom_put_dvcc_dvvc 同此判定;
        // patch_dvcc.py 对 profile 8 写 dvcC 系该脚本自身的取舍,系统两种均接受,
        // 本仓实现按设计 §5.2 / ffmpeg movenc 取 dvvC)。
        XCTAssertEqual(type, "dvvC")

        // patch_dvcc.py 位布局公式:word = (profile<<9)|(level<<3)|(rpu<<2)|(el<<1)|bl;
        // c5 数值下 = (8<<9)|(0<<3)|0b101 = 0x1005;byte4 = (compat<<4)|(md<<2) = 0x14。
        let word = (UInt16(record.dv_profile) << 9) | (UInt16(record.dv_level) << 3)
                 | (UInt16(record.rpu_present_flag) << 2)
                 | (UInt16(record.el_present_flag) << 1) | UInt16(record.bl_present_flag)
        var expected = [UInt8]([UInt8(word >> 8), UInt8(word & 0xFF)])
        expected = [0x01, 0x00] + expected
            + [ (record.dv_bl_signal_compatibility_id << 4) | (record.dv_md_compression << 2) ]
            + [UInt8](repeating: 0, count: 19)
        XCTAssertEqual([UInt8](payload), expected, "须与 patch_dvcc.py DVCC_PAYLOAD 位布局逐字节一致")
        // 具体数值锚点(脚本硬编码值,防公式写错):
        XCTAssertEqual([UInt8](payload.prefix(5)), [0x01, 0x00, 0x10, 0x05, 0x14])
    }

    // MARK: - make

    func testFormatDescriptionCarriesDolbyVisionCodecType() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: corpusURL("c5_dv_p81.mp4"), headers: [:])
        defer { demuxer.close() }
        let vs = try XCTUnwrap(demuxer.videoStream)
        let cp = vs.pointee.codecpar.pointee
        let hvcC = try XCTUnwrap(VTVideoDecoder.realExtradata(cp), "c5 extradata 应为 hvcC")
        let dovi = try XCTUnwrap(demuxer.doviConfiguration)

        let desc = try XCTUnwrap(SystemDVFormatDescription.make(
            hvcC: hvcC, width: cp.width, height: cp.height, dovi: dovi))

        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(desc),
                       kCMVideoCodecType_DolbyVisionHEVC, "codecType 必须是 dvh1")
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let atoms = try XCTUnwrap(
            ext?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                as? [String: Any], "extensions 应含 SampleDescriptionExtensionAtoms")
        XCTAssertTrue(atoms["hvcC"] != nil, "atoms 应含 hvcC")
        XCTAssertTrue(atoms["dvvC"] != nil, "atoms 应含 dvvC(profile 8 > 7)")
    }
}
