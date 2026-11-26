import XCTest
@testable import PlayerKit

/// P7 FEL 转换(dovi_tool mode 2 的 `remove_mapping` 分支)+ RPU 解析健壮性。
///
/// FEL 向量由 Twisters MEL 帧 0 改 NLQ 合成(真实 FEL 原盘 RPU 不入开源仓);
/// 金标准为本地 dovi_tool 2.3.4 `-m 2 extract-rpu` 对同一合成帧的输出。
final class DoviRpuFELTests: XCTestCase {

    // Twisters(MEL)P7 RPU 帧 0(起始码 + RBSP)。
    private let melFrame0Hex =
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000344ACC00006BD44ACDF3F9D6384ACC89940000" +
        "03020000030010000003001000000300386C4486030C14BC611C0A28000003034C7CB5FFFE0000030000030000030000C040" +
        "1F01C2A280300800410999810100000300040280000003011408A0090603E80001014D00532289227E80"

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

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

    /// 由 MEL 帧 0 合成 FEL 帧:NLQ 改为非恒等(真实 FEL 的典型形态:
    /// offset 非 0、vdr_in_max 非 1.0、deadzone 非 0)。
    private func makeFELFrame() throws -> [UInt8] {
        var f = try XCTUnwrap(DoviRpuP7ToP81.parse(bytes(melFrame0Hex)))
        var nlq = try XCTUnwrap(f.mapping.nlq)
        nlq.offset = [512, 512, 512]
        nlq.vdrInMaxInt = [0, 0, 0]
        nlq.vdrInMax = [0x40_0000, 0x40_0000, 0x40_0000]
        nlq.slope = [0x10_0000, 0x10_0000, 0x10_0000]
        nlq.threshold = [0x8_0000, 0x8_0000, 0x8_0000]
        f.mapping.nlq = nlq
        return try XCTUnwrap(DoviRpuP7ToP81.serialize(f))
    }

    // MARK: - 无损回写 / MEL·FEL 判定

    func testP7ParseSerializeIsLossless() throws {
        let src = bytes(melFrame0Hex)
        let f = try XCTUnwrap(DoviRpuP7ToP81.parse(src))
        XCTAssertNotNil(f.mapping.nlq, "P7 帧应解析出 NLQ 块")
        XCTAssertEqual(DoviRpuP7ToP81.serialize(f), src, "P7 解析→回写应逐字节无损")
    }

    func testTwistersFrameIsMEL() {
        XCTAssertEqual(DoviRpuP7ToP81.isFEL(bytes(melFrame0Hex)), false)
    }

    func testSynthesizedFrameIsFEL() throws {
        XCTAssertEqual(DoviRpuP7ToP81.isFEL(try makeFELFrame()), true)
    }

    // MARK: - FEL 转换

    func testFELConversionSetsIdentityMappingAndDropsResidual() throws {
        let out = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(try makeFELFrame()))
        let f = try XCTUnwrap(DoviRpuP7ToP81.parse(out))
        XCTAssertTrue(f.header.disableResidualFlag)
        XCTAssertFalse(f.header.elSpatialResamplingFilterFlag)
        XCTAssertNil(f.mapping.nlq)
        XCTAssertNil(f.mapping.nlqMethodIdc)
        XCTAssertEqual(f.mapping.curves.count, 3)
        for c in f.mapping.curves {
            XCTAssertEqual(c.pivots, [0, 1023], "10-bit BL 恒等曲线 pivots")
            XCTAssertEqual(c.mappingIdc, [0])
            XCTAssertEqual(c.poly.count, 1)
            XCTAssertEqual(c.poly[0].order, 0)
            XCTAssertEqual(c.poly[0].coefs.map(\.0), [0, 1], "y = 0 + 1·x")
            XCTAssertEqual(c.poly[0].coefs.map(\.1), [0, 0])
            XCTAssertTrue(c.mmr.isEmpty)
        }
        // DM 段(trim 元数据)必须原样保留
        let src = try XCTUnwrap(DoviRpuP7ToP81.parse(try makeFELFrame()))
        XCTAssertEqual(f.v29.blocks.map(\.level), src.v29.blocks.map(\.level))
        XCTAssertEqual(f.v29.blocks.map(\.payload), src.v29.blocks.map(\.payload))
    }

    func testMELConversionKeepsMapping() throws {
        let src = try XCTUnwrap(DoviRpuP7ToP81.parse(bytes(melFrame0Hex)))
        let out = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(bytes(melFrame0Hex)))
        let f = try XCTUnwrap(DoviRpuP7ToP81.parse(out))
        XCTAssertEqual(f.mapping.curves.map(\.pivots), src.mapping.curves.map(\.pivots),
                       "MEL 不得改 mapping(dovi_tool 对拍语义)")
    }

    // MARK: - 曲线写回(poly/mmr 混合 piece)

    func testMixedPolyMmrCurveWritesWithoutCrashAndRoundTrips() throws {
        var f = try XCTUnwrap(DoviRpuP7ToP81.parse(bytes(melFrame0Hex)))
        // 构造一条 [mmr, poly] 两段曲线:piece 下标与各自数组下标错开。
        let mmrCoefs: [(Int64, Int64)] = Array(repeating: (0, 0), count: 14) // order=0 → (0+2)*7 = 14 项
        let mmrPiece: (order: UInt8, constInt: Int64, constFixed: Int64, coefs: [(Int64, Int64)]) =
            (order: 0, constInt: 0, constFixed: 0, coefs: mmrCoefs)
        var c = DoviRpuMapping.Curve()
        c.numPivotsMinus2 = 1
        c.pivots = [0, 512, 511]
        c.mappingIdc = [1, 0]
        c.mmr = [mmrPiece]
        c.poly = [(order: 0, linear: false, coefs: [(0, 0), (1, 0)])]
        f.mapping.curves[1] = c
        let out = try XCTUnwrap(DoviRpuP7ToP81.serialize(f))
        let back = try XCTUnwrap(DoviRpuP7ToP81.parse(out))
        XCTAssertEqual(back.mapping.curves[1].mappingIdc, [1, 0])
        XCTAssertEqual(back.mapping.curves[1].pivots, [0, 512, 511])
        XCTAssertEqual(back.mapping.curves[1].mmr.count, 1)
        XCTAssertEqual(back.mapping.curves[1].poly.count, 1)
    }

    // MARK: - 健壮性(fallback 铁律:畸形 RPU 只降级该帧,不崩不卡)

    func testTruncatedFramesNeverCrashOrHang() {
        let src = bytes(melFrame0Hex)
        for n in 0..<src.count {
            _ = DoviRpuP7ToP81.convertNAL(Array(src.prefix(n)))
        }
    }

    func testGarbageAfterPrefixReturnsNil() {
        // 0x19 前缀后跟全 0:ue 前导零无上限会死循环(修复前)。
        let zeros: [UInt8] = [0, 0, 0, 1, 0x19] + [UInt8](repeating: 0, count: 64) + [0x80]
        XCTAssertNil(DoviRpuP7ToP81.convertNAL(zeros))
        // 伪随机字节(固定种子):只要求不崩不卡。
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<200 {
            var buf: [UInt8] = [0, 0, 0, 1, 0x19]
            for _ in 0..<120 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buf.append(UInt8(truncatingIfNeeded: seed >> 33))
            }
            buf.append(0x80)
            _ = DoviRpuP7ToP81.convertNAL(buf)
        }
    }

    func testFlippedBitsInRealFrameNeverCrash() {
        let src = bytes(melFrame0Hex)
        for i in 5..<src.count {
            var b = src
            b[i] ^= 0xFF
            _ = DoviRpuP7ToP81.convertNAL(b)
        }
    }

    // MARK: - 本地金标准夹具(dovi_tool 对拍;环境变量门控,CI 跳过)

    /// 写出合成 FEL 帧的 annexb HEVC(unspec62 NAL header 7C 01),供
    /// `dovi_tool -m 2 extract-rpu` 产金标准。
    func testEmitFELFixtureForDoviTool() throws {
        guard let out = ProcessInfo.processInfo.environment["P7_FEL_FIXTURE_OUT"] else {
            throw XCTSkip("P7_FEL_FIXTURE_OUT 未设置(本地生成 dovi_tool 夹具)")
        }
        let fel = try makeFELFrame()
        let rbsp = Array(fel.dropFirst(4))
        let nal: [UInt8] = [0, 0, 0, 1, 0x7C, 0x01] + rbsp
        try Data(nal).write(to: URL(fileURLWithPath: out))
        print("FEL_P7:", hex(fel))
        print("FEL_P81_OURS:", hex(try XCTUnwrap(DoviRpuP7ToP81.convertNAL(fel))))
    }
}
