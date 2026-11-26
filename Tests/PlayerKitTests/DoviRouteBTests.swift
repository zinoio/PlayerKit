import XCTest
import CoreVideo
@testable import PlayerKit

/// Phase 2 route b(iOS / tvOS):VT 硬解基础层 + 逐帧 RPU 附件。
/// 覆盖:RPU 提取(P8.1 透传 / P7 转换)、B 帧 PTS 配对缓存、策略路由矩阵、
/// ASBDLRenderer CVPixelBuffer 附件挂载与池复用清理。
final class DoviRouteBTests: XCTestCase {

    // Twisters(MEL)P7 RPU 帧 0(含 4 字节起始码)。
    private let p7Frame0Hex =
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000344ACC00006BD44ACDF3F9D6384ACC89940000" +
        "03020000030010000003001000000300386C4486030C14BC611C0A28000003034C7CB5FFFE0000030000030000030000C040" +
        "1F01C2A280300800410999810100000300040280000003011408A0090603E80001014D00532289227E80"

    private let p81Frame0Hex =
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301A2566000035EA2" +
        "566F9FCEB1C256644CA00000100000030080000003008000000301C36224301860A5E308E0514000001A63E5AFFFF0000003" +
        "00000300000300060200F80E1514300800410999810100000300040280000003011408A0090603E80001014D0053BCE06ABA" +
        "80"

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func lengthPrefixedPacket(_ nals: [[UInt8]]) -> Data {
        var out: [UInt8] = []
        for nal in nals {
            let n = nal.count
            out.append(contentsOf: [
                UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF),
            ])
            out.append(contentsOf: nal)
        }
        return Data(out)
    }

    // MARK: - RPU Extractor

    func testExtractP81PassthroughStripsTwoByteHeader() throws {
        let p81Rbsp = Array(bytes(p81Frame0Hex).dropFirst(4))
        let pkt = lengthPrefixedPacket([
            [0x02, 0x01, 0xAA, 0xBB],          // VCL
            [0x7C, 0x01] + p81Rbsp,            // unspec62 P8.1 RPU
        ])
        let rpu = try XCTUnwrap(DoviRouteBRpuExtractor.extractFromLengthPrefixed(pkt, isProfile7: false))
        XCTAssertEqual([UInt8](rpu), p81Rbsp)
        XCTAssertEqual(rpu.first, 0x19)
    }

    func testExtractP7ConvertsToP81Rbsp() throws {
        let p7Rbsp = Array(bytes(p7Frame0Hex).dropFirst(4))
        let expectedP81Rbsp = Array(bytes(p81Frame0Hex).dropFirst(4))
        let pkt = lengthPrefixedPacket([
            [0x02, 0x01, 0xAA, 0xBB],          // BL VCL
            [0x7E, 0x01, 0x11, 0x22],          // t63 EL
            [0x7C, 0x01] + p7Rbsp,             // t62 P7 RPU
        ])
        let rpu = try XCTUnwrap(DoviRouteBRpuExtractor.extractFromLengthPrefixed(pkt, isProfile7: true))
        XCTAssertEqual([UInt8](rpu), expectedP81Rbsp)
    }

    func testExtractReturnsNilOnMalformedOrNonRpuConfig() {
        let cfgOnly = lengthPrefixedPacket([[0x7C, 0x01, 0x02, 0x01, 0x00]])
        XCTAssertNil(DoviRouteBRpuExtractor.extractFromLengthPrefixed(cfgOnly, isProfile7: false))
        XCTAssertNil(DoviRouteBRpuExtractor.extractFromLengthPrefixed(cfgOnly, isProfile7: true))
        XCTAssertNil(DoviRouteBRpuExtractor.extractFromLengthPrefixed(Data([0, 0, 0, 99, 1, 2]), isProfile7: false))
    }

    // MARK: - PTS Pairing Cache

    func testPtsCacheHandlesBFrameReorderAndFlush() {
        let cache = DoviRpuPtsCache(capacity: 4)
        // Decode order: 0, 3, 1, 2
        cache.store(pts: 0, rpu: Data([0x19, 0]))
        cache.store(pts: 3, rpu: Data([0x19, 3]))
        cache.store(pts: 1, rpu: Data([0x19, 1]))
        cache.store(pts: 2, rpu: Data([0x19, 2]))
        // Display order: 0, 1, 2, 3
        XCTAssertEqual(cache.take(pts: 0), Data([0x19, 0]))
        XCTAssertEqual(cache.take(pts: 1), Data([0x19, 1]))
        XCTAssertEqual(cache.take(pts: 2), Data([0x19, 2]))
        XCTAssertEqual(cache.take(pts: 3), Data([0x19, 3]))
        XCTAssertNil(cache.take(pts: 3))

        // Capacity eviction
        for i: Int64 in 10..<16 {
            cache.store(pts: i, rpu: Data([0x19, UInt8(i)]))
        }
        XCTAssertEqual(cache.count, 4)
        XCTAssertNil(cache.take(pts: 10))
        XCTAssertEqual(cache.take(pts: 15), Data([0x19, 15]))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Routing Matrix

    private func makeStream(profile: UInt8, compat: UInt8, converted: UInt8? = nil) -> VideoStreamAttributes {
        VideoStreamAttributes(
            width: 3840, height: 2160, codecID: 173,
            colorMatrix: .bt2020, transfer: .pq, range: .limited,
            isDolbyVision: true, doviProfile: profile,
            blSignalCompatibilityId: compat, doviConvertedCompatId: converted,
            hasHDR10Plus: false, isHEVC10Bit: true
        )
    }

    func testRouteBRoutingMatrix() {
        let routeBCap = SystemDVCapability(isAvailable: false, supportsRouteB: true)
        let macCap = SystemDVCapability(isAvailable: true, supportsRouteB: false)

        // P8.1 on iOS/tvOS EDR → doviRouteB
        let s81 = decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .system)
        XCTAssertEqual(s81, .doviRouteB)
        XCTAssertEqual(s81.videoPipeline, .decodedFrames)
        XCTAssertEqual(s81.decoderPreference, .vtHW)
        XCTAssertTrue(s81.pixelFormat10Bit)
        XCTAssertEqual(s81.toneMapAlgorithm, .passthroughSDR)

        // Converted P7 on iOS/tvOS EDR → doviRouteB
        let s7c = decideRendererStrategy(
            stream: makeStream(profile: 7, compat: 6, converted: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .system)
        XCTAssertEqual(s7c, .doviRouteB)

        // Unconverted P7 → degradedHDR10
        let s7raw = decideRendererStrategy(
            stream: makeStream(profile: 7, compat: 6, converted: nil),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .system)
        XCTAssertEqual(s7raw, .degradedHDR10)

        // P5 stays on software IPT path (no HDR10 base layer)
        let s5 = decideRendererStrategy(
            stream: makeStream(profile: 5, compat: 0),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .system)
        XCTAssertEqual(s5, .doviProfile5)

        // Free tier guard untouched
        let free81 = decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: false, systemDolbyVision: routeBCap, dolbyVisionOutput: .system)
        XCTAssertEqual(free81, .hdr10Static(peakNits: 1000))

        // Preference .software & .hardwareHDR10 honored
        XCTAssertEqual(decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .software),
            .doviProfile8(tonemapCompat: true))
        XCTAssertEqual(decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .hardwareHDR10),
            .hdr10Static(peakNits: 1000))

        // Non-EDR never selects route b
        XCTAssertEqual(decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macSDR,
            doviEnabled: true, systemDolbyVision: routeBCap, dolbyVisionOutput: .system),
            .degradedHDR10)

        // macOS compressed passthrough unchanged
        XCTAssertEqual(decideRendererStrategy(
            stream: makeStream(profile: 8, compat: 1),
            prefersTenBit: true, display: .macEDR,
            doviEnabled: true, systemDolbyVision: macCap, dolbyVisionOutput: .system),
            .doviSystem)
    }

    // MARK: - ASBDLRenderer CVPixelBuffer Attachments

    func testASBDLRouteBAttachmentsSetAndClearedOnPoolReuse() throws {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            nil, &pb)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)

        let payload = Data([0x19, 0x08, 0x09, 0x80])
        ASBDLRenderer.applyRouteBAttachments(buffer, rpuData: payload)

        let gotRpu = CVBufferCopyAttachment(buffer, ASBDLRenderer.doviRpuAttachmentKey, nil) as? Data
        let gotCompat = CVBufferCopyAttachment(buffer, ASBDLRenderer.doviCompatIdAttachmentKey, nil) as? String
        XCTAssertEqual(gotRpu, payload)
        XCTAssertEqual(gotCompat, "1")

        // Subsequent frame without RPU must clear both attachments
        ASBDLRenderer.applyRouteBAttachments(buffer, rpuData: nil)
        XCTAssertNil(CVBufferCopyAttachment(buffer, ASBDLRenderer.doviRpuAttachmentKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(buffer, ASBDLRenderer.doviCompatIdAttachmentKey, nil))
    }
}
