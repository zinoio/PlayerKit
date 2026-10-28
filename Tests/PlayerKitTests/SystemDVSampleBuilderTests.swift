import XCTest
import CoreMedia
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// Task 4:packet → CMSampleBuffer(dvh1 格式描述 + DV attachment 标记)。
/// 语料:c5_dv_p81.mp4(P8.1,长度前缀 hvcC extradata 齐全)。
final class SystemDVSampleBuilderTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    /// 打开 c5 并构造 builder;返回 demuxer 供读包(所有权在测试)。
    private func makeBuilder() throws -> (FFmpegDemuxer, SystemDVSampleBuilder) {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: corpusURL("c5_dv_p81.mp4"), headers: [:])
        let vs = try XCTUnwrap(demuxer.videoStream)
        let dovi = try XCTUnwrap(demuxer.doviConfiguration)
        let builder = try XCTUnwrap(SystemDVSampleBuilder(stream: vs, dovi: dovi),
                                    "c5 的 hvcC + DV record 齐全,builder 应构造成功")
        return (demuxer, builder)
    }

    /// 读下一个视频包;返回 (index, packet 指针, 时间基秒)。调用方负责 free。
    private func nextVideoPacket(_ demuxer: FFmpegDemuxer) throws
        -> (Int32, UnsafeMutablePointer<AVPacket>, Double)? {
        let vs = try XCTUnwrap(demuxer.videoStream)
        let tb = vs.pointee.time_base
        let tbSec = Double(tb.num) / Double(tb.den)
        while let p = demuxer.readPacket() {
            guard p.streamIndex == demuxer.videoStreamIndex else {
                var pp: UnsafeMutablePointer<AVPacket>? = p.packet
                av_packet_free(&pp)
                continue
            }
            return (p.streamIndex, p.packet, tbSec)
        }
        return nil
    }

    private func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Any? {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as NSArray).firstObject as? NSDictionary else { return nil }
        return dict[key]
    }

    /// attachment 布尔读法(CFBoolean → NSNumber → Bool)。
    private func boolAttachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let v = attachment(sample, key) else { return nil }
        return (v as? NSNumber)?.boolValue ?? (v as? Bool)
    }

    // MARK: - 用例

    func testFirstSampleIsSyncAndHasDVFormat() throws {
        let (demuxer, builder) = try makeBuilder()
        defer { demuxer.close() }
        let (_, pkt, tbSec) = try XCTUnwrap(nextVideoPacket(demuxer))
        var pp: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&pp) }

        XCTAssertTrue(pkt.pointee.flags & AV_PKT_FLAG_KEY != 0, "c5 首个视频包应为关键帧")
        let pts = Double(pkt.pointee.pts) * tbSec
        let sample = try XCTUnwrap(builder.makeSample(packet: pkt, pts: pts, doNotDisplay: false))

        let fd = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd), kCMVideoCodecType_DolbyVisionHEVC)
        // 关键帧:NotSync 应为 false(显式)或缺省
        XCTAssertNotEqual(boolAttachment(sample, kCMSampleAttachmentKey_NotSync), true,
                          "关键帧不应标记 NotSync")
        // pts 保持传入秒值
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                       pts, accuracy: 1e-4)
        // dts 非零场景应有效且 ≈ packet.dts × time_base
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sample)),
                       Double(pkt.pointee.dts) * tbSec, accuracy: 1e-4)
    }

    func testNonKeyframesMarkedNotSync() throws {
        let (demuxer, builder) = try makeBuilder()
        defer { demuxer.close() }
        var found = false
        // 逐包扫描直到遇到非关键帧(c5 帧数少,首帧之后即非关键帧)
        while let (_, pkt, tbSec) = try nextVideoPacket(demuxer) {
            defer { var pp: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&pp) }
            if pkt.pointee.flags & AV_PKT_FLAG_KEY == 0 {
                let sample = try XCTUnwrap(
                    builder.makeSample(packet: pkt, pts: Double(pkt.pointee.pts) * tbSec,
                                       doNotDisplay: false))
                XCTAssertEqual(boolAttachment(sample, kCMSampleAttachmentKey_NotSync), true,
                               "非关键帧必须标记 NotSync=true")
                found = true
                break
            }
        }
        XCTAssertTrue(found, "c5 应存在非关键帧")
    }

    func testDoNotDisplayAttachment() throws {
        let (demuxer, builder) = try makeBuilder()
        defer { demuxer.close() }
        let (_, pkt, tbSec) = try XCTUnwrap(nextVideoPacket(demuxer))
        defer { var pp: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&pp) }
        let sample = try XCTUnwrap(builder.makeSample(packet: pkt, pts: 0, doNotDisplay: true))
        XCTAssertEqual(boolAttachment(sample, kCMSampleAttachmentKey_DoNotDisplay), true,
                       "doNotDisplay=true 必须落到 DoNotDisplay attachment")
    }

    func testMissingDTSDoesNotCrash() throws {
        let (demuxer, builder) = try makeBuilder()
        defer { demuxer.close() }
        let (_, pkt, _) = try XCTUnwrap(nextVideoPacket(demuxer))
        defer { var pp: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&pp) }
        pkt.pointee.dts = Int64(bitPattern: 0x8000000000000000) // AV_NOPTS_VALUE(C 宏不进 Swift)
        let sample = try XCTUnwrap(builder.makeSample(packet: pkt, pts: 0.5, doNotDisplay: false),
                                   "dts 缺失不应崩溃也不应返回 nil")
        XCTAssertTrue(CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sample)).isNaN,
                      "dts 缺失 → decodeTimeStamp 为 invalid(NaN)")
    }

    func testSampleDataSurvivesPacketFree() throws {
        let (demuxer, builder) = try makeBuilder()
        defer { demuxer.close() }
        let (_, pkt, tbSec) = try XCTUnwrap(nextVideoPacket(demuxer))
        let size = Int(pkt.pointee.size)
        let original = Array(UnsafeBufferPointer(start: pkt.pointee.data, count: size))
        let sample = try XCTUnwrap(
            builder.makeSample(packet: pkt, pts: Double(pkt.pointee.pts) * tbSec,
                               doNotDisplay: false))
        // 释放后 sample 数据必须仍然可读且逐字节相等(不持有 AVPacket 指针)
        var pp: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&pp)

        let bb = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var totalLen = 0
        var ptr: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(bb, atOffset: 0,
                                                   lengthAtOffsetOut: nil,
                                                   totalLengthOut: &totalLen,
                                                   dataPointerOut: &ptr),
                       kCMBlockBufferNoErr)
        XCTAssertEqual(totalLen, size)
        let got = UnsafeBufferPointer(start: ptr, count: totalLen).map(UInt8.init)
        XCTAssertEqual(got, original, "释放 packet 后 sample 数据必须原样保留")
    }
}
