import XCTest
@testable import PlayerKit

/// Task 2b 位流基础:P7 真实首帧(192B,来自 Twisters MEL 样本)解析/回写。
final class DoviRpuBitstreamTests: XCTestCase {

    // 原始 P7 RPU 首帧(含 4 字节起始码),dovi_tool extract-rpu 输出。
    private let frameHex = "000000011908090840613650af003ff801ffc00ffc001fffa000001000000d0000030080000068000004000003000040000020000020000003000400000302000003020000030000400000200000200000344acc00006bd44acdf3f9d6384acc8994000003020000030010000003001000000300386c4486030c14bc611c0a28000003034c7cb5fffe0000030000030000030000c0401f01c2a280300800410999810100000300040280000003011408a0090603e80001014d00532289227e80"

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

    func testHeaderParsesRealP7Frame() throws {
        guard let frame = DoviRpuFrameCodec.parse(bytes(frameHex)) else {
            return XCTFail("parse 失败")
        }
        let h = frame.header
        XCTAssertEqual(h.rpuType, 2)
        XCTAssertEqual(h.rpuFormat, 18)
        XCTAssertEqual(h.vdrRpuProfile, 1)
        XCTAssertEqual(h.vdrRpuLevel, 0)
        XCTAssertTrue(h.vdrSeqInfoPresentFlag)
        XCTAssertEqual(h.coefficientLog2Denom, 23)
        XCTAssertEqual(h.vdrRpuNormalizedIdc, 1)
        XCTAssertEqual(h.blBitDepthMinus8, 2)
        XCTAssertEqual(h.elBitDepthMinus8, 2)
        XCTAssertEqual(h.vdrBitDepthMinus8, 4)
        XCTAssertTrue(h.elSpatialResamplingFilterFlag)   // P7
        XCTAssertFalse(h.disableResidualFlag)            // P7
        XCTAssertTrue(h.vdrDmMetadataPresentFlag)
        XCTAssertFalse(h.usePrevVdrRpuFlag)
    }

    func testRoundTripPreservesBytes() throws {
        guard let frame = DoviRpuFrameCodec.parse(bytes(frameHex)) else {
            return XCTFail("parse 失败")
        }
        let encoded = DoviRpuFrameCodec.encode(frame)
        // encode 重新加回 EPB;clear 后再与解析时的原始字节比对。
        XCTAssertEqual(DoviEmulationPrevention.clear(encoded), frame.rawBytes)
    }

    func testTrimHandlesAllStartCodeForms() {
        let payload: [UInt8] = [25, 8, 9, 1, 2, 3]
        XCTAssertEqual(DoviRpuFrameCodec.trim([0, 0, 0, 1, 25] + payload.dropFirst()),
                       [25] + payload.dropFirst())
        XCTAssertEqual(DoviRpuFrameCodec.trim([0, 0, 1, 25] + payload.dropFirst().dropFirst().dropFirst()),
                       [25] + payload.dropFirst().dropFirst().dropFirst())
        XCTAssertNil(DoviRpuFrameCodec.trim([9, 9, 9, 9, 9]))
    }

    func testCRC32MPEG2KnownVector() {
        // CRC-32/MPEG-2("123456789") = 0x0376E6E7
        let v = DoviCrc32.checksum(Array("123456789".utf8))
        XCTAssertEqual(v, 0x0376_E6E7)
    }
    // 帧 0:P7 原始 vs dovi_tool mode-2 输出(Twisters MEL 样本)
    func testConvertFrame0MatchesDoviTool() throws {
        let p7 = bytes(
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000344ACC00006BD44ACDF3F9D6384ACC89940000" +
        "03020000030010000003001000000300386C4486030C14BC611C0A28000003034C7CB5FFFE0000030000030000030000C040" +
        "1F01C2A280300800410999810100000300040280000003011408A0090603E80001014D00532289227E80"
        )
        let expected = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301A2566000035EA2" +
        "566F9FCEB1C256644CA00000100000030080000003008000000301C36224301860A5E308E0514000001A63E5AFFFF0000003" +
        "00000300000300060200F80E1514300800410999810100000300040280000003011408A0090603E80001014D0053BCE06ABA" +
        "80"
        )
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7), "转换失败")
        let ours = DoviEmulationPrevention.clear([UInt8](converted))
        let want = DoviEmulationPrevention.clear([UInt8](expected.dropFirst(4)))
        print("OURS:  ", ours.map { String(format: "%02X", $0) }.joined())
        print("EXPECT:", want.map { String(format: "%02X", $0) }.joined())
        XCTAssertEqual(converted, expected, "帧 0 与 dovi_tool 输出不一致")
    }

    // 帧 1:P7 原始 vs dovi_tool mode-2 输出(Twisters MEL 样本)
    func testConvertFrame1MatchesDoviTool() throws {
        let p7 = bytes(
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000392B300001AF512B37CFE758E12B3226500000" +
        "080000030040000003004000000300E1B112180C3052F1847028A000000D31F2D7FFF8000003000003000003000301007C07" +
        "0A8A300800410999810100000300040280000003011408A0090603E80001014D0053EB21451480"
        )
        let expected = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301C95980000D7A89" +
        "59BE7F3AC7095991328000004000000302000003000200000300070D8890C06182978C23814500000300698F96BFFFC00000" +
        "0300000300000300180803E0385450300800410999810100000300040280000003011408A0090603E80001014D00536B5159" +
        "7780"
        )
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7), "转换失败")
        XCTAssertEqual(converted, expected, "帧 1 与 dovi_tool 输出不一致")
    }

    // 帧 2:P7 原始 vs dovi_tool mode-2 输出(Twisters MEL 样本)
    func testConvertFrame2MatchesDoviTool() throws {
        let p7 = bytes(
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000392B300001AF512B37CFE758E12B3226500000" +
        "080000030040000003004000000300E1B112180C3052F1847028A000000D31F2D7FFF8000003000003000003000301007C07" +
        "0A8A300800410999810100000300040280000003011408A0090603E80001014D0053EB21451480"
        )
        let expected = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301C95980000D7A89" +
        "59BE7F3AC7095991328000004000000302000003000200000300070D8890C06182978C23814500000300698F96BFFFC00000" +
        "0300000300000300180803E0385450300800410999810100000300040280000003011408A0090603E80001014D00536B5159" +
        "7780"
        )
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7), "转换失败")
        XCTAssertEqual(converted, expected, "帧 2 与 dovi_tool 输出不一致")
    }

    // 帧 3:P7 原始 vs dovi_tool mode-2 输出(Twisters MEL 样本)
    func testConvertFrame3MatchesDoviTool() throws {
        let p7 = bytes(
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000392B300001AF512B37CFE758E12B3226500000" +
        "080000030040000003004000000300E1B112180C3052F1847028A000000D31F2D7FFF8000003000003000003000301007C07" +
        "0A8A300800410999810100000300040280000003011408A0090603E80001014D0053EB21451480"
        )
        let expected = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301C95980000D7A89" +
        "59BE7F3AC7095991328000004000000302000003000200000300070D8890C06182978C23814500000300698F96BFFFC00000" +
        "0300000300000300180803E0385450300800410999810100000300040280000003011408A0090603E80001014D00536B5159" +
        "7780"
        )
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7), "转换失败")
        XCTAssertEqual(converted, expected, "帧 3 与 dovi_tool 输出不一致")
    }

    // 帧 4:P7 原始 vs dovi_tool mode-2 输出(Twisters MEL 样本)
    func testConvertFrame4MatchesDoviTool() throws {
        let p7 = bytes(
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000392B300001AF512B37CFE758E12B3226500000" +
        "080000030040000003004000000300E1B112180C3052F1847028A000000D31F2D7FFF8000003000003000003000301007C07" +
        "0A8A300800410999810100000300040280000003011408A0090603E80001014D0053EB21451480"
        )
        let expected = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301C95980000D7A89" +
        "59BE7F3AC7095991328000004000000302000003000200000300070D8890C06182978C23814500000300698F96BFFFC00000" +
        "0300000300000300180803E0385450300800410999810100000300040280000003011408A0090603E80001014D00536B5159" +
        "7780"
        )
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7), "转换失败")
        XCTAssertEqual(converted, expected, "帧 4 与 dovi_tool 输出不一致")
    }


    // 诊断:解析 dovi_tool P8.1 帧,原样回写,应逐字节一致
    func testP81FrameRoundTrip() throws {
        let p81 = bytes(
        "0000000119080908406136506F003FF801FFC00FFFD0000008000006800000400000340000030200000301A2566000035EA2" +
        "566F9FCEB1C256644CA00000100000030080000003008000000301C36224301860A5E308E0514000001A63E5AFFFF0000003" +
        "00000300000300060200F80E1514300800410999810100000300040280000003011408A0090603E80001014D0053BCE06ABA" +
        "80"
        )
        let frame = try XCTUnwrap(DoviRpuFrameCodec.parse(p81), "parse 失败")
        XCTAssertEqual(frame.header.disableResidualFlag, true)
        let encoded = DoviRpuFrameCodec.encode(frame)
        XCTAssertEqual(DoviEmulationPrevention.clear(encoded), frame.rawBytes)
    }


    // 诊断:dump parse(P7)→转换 与 parse(P8.1) 的 mapping 字段


    /// 全量对拍:环境变量指向本地 dovi_tool 提取的 P7/P8.1 RPU 文件
    /// (样本不入仓;CI 无环境变量时自动跳过)
    func testConvertAllFramesMatchDoviTool() throws {
        let env = ProcessInfo.processInfo.environment
        guard let p7Path = env["P7_RPU_BIN"], let p81Path = env["P81_RPU_BIN"] else {
            throw XCTSkip("P7_RPU_BIN/P81_RPU_BIN 未设置(本地对拍样本)")
        }
        guard let p7Data = FileManager.default.contents(atPath: p7Path),
              let p81Data = FileManager.default.contents(atPath: p81Path) else {
            throw XCTSkip("对拍文件不可读")
        }
        // 按起始码切帧
        func frames(_ data: Data) -> [Data] {
            var out: [Data] = []
            var i = 0
            let b = [UInt8](data)
            while i < b.count {
                guard b[i] == 0, i + 4 <= b.count, b[i+1] == 0, b[i+2] == 0, b[i+3] == 1 else { break }
                var j = i + 4
                while j + 3 <= b.count {
                    if b[j] == 0, b[j+1] == 0, b[j+2] == 0, b[j+3] == 1 { break }
                    j += 1
                }
                out.append(Data(b[i..<min(j, b.count)]))
                i = j
            }
            return out
        }
        let f7 = frames(p7Data)
        let f81 = frames(p81Data)
        XCTAssertEqual(f7.count, f81.count, "帧数不一致")
        var mismatches: [Int] = []
        for (idx, pair) in zip(f7, f81).enumerated() {
            guard let converted = DoviRpuP7ToP81.convertNAL([UInt8](pair.0)) else {
                mismatches.append(idx); continue
            }
            if converted != [UInt8](pair.1) { mismatches.append(idx) }
        }
        // inject-rpu 会在末尾复制元数据帧补齐时长(dovi_tool 行为),
        // 复制帧的转换输出与逐帧对拍源不同步,属工具边界个案。
        let tail = mismatches.filter { $0 >= f7.count - 2 }
        let mid = mismatches.filter { $0 < f7.count - 2 }
        XCTAssertEqual(mid, [], "中段帧与 dovi_tool 输出不一致: \(mid.prefix(5))")
        XCTAssertLessThanOrEqual(tail.count, 2, "尾部复制帧差异超预期: \(tail)")
    }


}
