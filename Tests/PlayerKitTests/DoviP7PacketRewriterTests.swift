import XCTest
import CFFmpeg
@testable import PlayerKit

/// Task 5 / R1 接线:mp4 length-prefix 域的 P7 逐包改写(剥 unspec63 EL、
/// unspec62 RPU 转换替换、其余透传)+ RPU 校验窗口统计(R2)。
final class DoviP7PacketRewriterTests: XCTestCase {

    // P7 RPU 帧 0(extract-rpu 输出:起始码 + 裸 RBSP,19 开头)。
    private let p7Frame0Hex =
        "000000011908090840613650AF003FF801FFC00FFC001FFFA000001000000D00000300800000680000040000030000400000" +
        "20000020000003000400000302000003020000030000400000200000200000344ACC00006BD44ACDF3F9D6384ACC89940000" +
        "03020000030010000003001000000300386C4486030C14BC611C0A28000003034C7CB5FFFE0000030000030000030000C040" +
        "1F01C2A280300800410999810100000300040280000003011408A0090603E80001014D00532289227E80"

    // MARK: - 向量工具

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

    /// 裸 P7 RPU RBSP(19 开头,去起始码)。
    private var p7RpuRbsp: [UInt8] { Array(bytes(p7Frame0Hex).dropFirst(4)) }

    /// mp4 域的 RPU NAL:unspec62 NAL header(7C 01)+ RBSP。
    private var p7RpuNal: [UInt8] { [0x7C, 0x01] + p7RpuRbsp }

    private func lengthPrefixed(_ nal: [UInt8]) -> [UInt8] {
        let n = nal.count
        return [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + nal
    }

    /// 组装 mp4 packet(逐 NAL 4 字节长度前缀)。
    private func packet(_ nals: [[UInt8]]) -> Data {
        Data(nals.flatMap { lengthPrefixed($0) })
    }

    /// 解析 mp4 packet → [(type, header, payload)];nil = 非法。
    private func parseNals(_ data: Data) -> [(type: Int, nal: [UInt8])]? {
        let b = [UInt8](data)
        var out: [(Int, [UInt8])] = []
        var i = 0
        while i < b.count {
            guard i + 4 <= b.count else { return nil }
            let n = (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
            let hdr = i + 4
            guard n >= 2, hdr + n <= b.count else { return nil }
            out.append((Int((b[hdr] >> 1) & 0x3F), Array(b[hdr..<(hdr+n)])))
            i = hdr + n
        }
        return out
    }

    // MARK: - 改写行为

    func testRewriteStripsELAndReplacesRPU() throws {
        let aud: [UInt8] = [0x46, 0x01, 0x10]                        // t35 AUD
        let vcl: [UInt8] = [0x02, 0x01, 0xAA, 0xBB, 0xCC, 0xDD]      // t1 TRAIL_R
        let el: [UInt8]  = [0x7E, 0x01, 0x11, 0x22]                  // t63 EL 分片
        let src = packet([aud, vcl, el, p7RpuNal])

        let rewriter = DoviP7PacketRewriter()
        let out = try XCTUnwrap(rewriter.rewrite(src), "合法 mp4 P7 packet 不应返回 nil")

        let nals = try XCTUnwrap(parseNals(out))
        XCTAssertEqual(nals.count, 3, "EL 应被剥除,剩 AUD/VCL/RPU")
        XCTAssertEqual(nals[0].type, 35)
        XCTAssertEqual(nals[0].nal, aud, "AUD 逐字节透传")
        XCTAssertEqual(nals[1].type, 1)
        XCTAssertEqual(nals[1].nal, vcl, "VCL 逐字节透传")
        XCTAssertEqual(nals[2].type, 62, "替换后的 RPU 仍是 unspec62")
        // RPU 内容 == convertNAL 输出的 RBSP(以 19 rpu_nal_prefix 开头)。
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7RpuNal))
        let convertedRbsp = Array(converted.dropFirst(4)) // 剥 convertNAL 输出的起始码
        XCTAssertEqual(Array(nals[2].nal.dropFirst(2)), convertedRbsp, "RPU RBSP 应与 convertNAL 输出一致")
        XCTAssertEqual(Array(nals[2].nal.prefix(2)), [0x7C, 0x01], "mp4 域 RPU NAL header = 7C 01")
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.checked, 1)
        XCTAssertEqual(snap.valid, 1)
    }

    func testRewriteDropsRpuWhenConversionFails() {
        let vcl: [UInt8] = [0x02, 0x01, 0xAA]
        let badRpu: [UInt8] = [0x7C, 0x01, 0x00, 0x99, 0x99] // 非 25 前缀,convertNAL 必失败
        let el: [UInt8]  = [0x7E, 0x01, 0x33]
        let src = packet([vcl, el, badRpu])

        let rewriter = DoviP7PacketRewriter()
        let out = try? rewriter.rewrite(src)
        XCTAssertNotNil(out, "RPU 畸形仍应输出 BL-only packet(该帧降级)")
        let nals = parseNals(out!)!
        XCTAssertEqual(nals.map(\.type), [1], "EL 与畸形 RPU 都应被剥除,只剩 VCL")
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.checked, 1)
        XCTAssertEqual(snap.valid, 0)
    }

    func testRewriteReturnsNilForAnnexbPacket() {
        // annexb packet(起始码 + VCL):mp4 解析必失败 → nil(原包透传)
        let annexb = Data([0, 0, 0, 1, 0x02, 0x01, 0xAA, 0xBB,
                           0, 0, 0, 1, 0x40, 0x01, 0x00])
        let rewriter = DoviP7PacketRewriter()
        XCTAssertNil(rewriter.rewrite(annexb))
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.checked, 0, "nil 包不计入帧数")
        XCTAssertEqual(snap.valid, 0, "nil 包不计入帧数")
    }

    func testRewriteReturnsNilForTruncatedPacket() {
        // 长度前缀越界:声称 64KB 实际只有几字节
        let truncated = Data([0x00, 0xFF, 0xFF, 0xFF, 0x7C, 0x01, 0x19])
        let rewriter = DoviP7PacketRewriter()
        XCTAssertNil(rewriter.rewrite(truncated))
    }

    func testRewriteKeepsParamSetsAndSei() {
        let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]              // t32
        let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01]              // t33
        let pps: [UInt8] = [0x44, 0x01, 0xC0]                    // t34
        let sei: [UInt8] = [0x4E, 0x01, 0x05, 0x28]              // t39
        let src = packet([vps, sps, pps, sei, p7RpuNal])
        let rewriter = DoviP7PacketRewriter()
        let out = try! rewriter.rewrite(src)
        let nals = parseNals(out!)!
        XCTAssertEqual(nals.map(\.type), [32, 33, 34, 39, 62])
        XCTAssertEqual(nals[0].nal, vps); XCTAssertEqual(nals[1].nal, sps)
        XCTAssertEqual(nals[2].nal, pps); XCTAssertEqual(nals[3].nal, sei)
    }

    // MARK: - R2 校验窗口

    func testValidationWindowFallsBackAfterEightInvalidFrames() {
        let vcl: [UInt8] = [0x02, 0x01, 0xAA]
        let badRpu: [UInt8] = [0x7C, 0x01, 0x00, 0x99]
        let rewriter = DoviP7PacketRewriter()
        for frame in 1...8 {
            _ = rewriter.rewrite(packet([vcl, badRpu]))
            XCTAssertEqual(rewriter.shouldFallbackToSoftware(),
                           frame == 8,
                           "第 \(frame) 帧:checked=\(frame) 全 invalid,仅第 8 帧触发")
        }
    }

    func testValidationWindowHoldsWhenAnyFrameValid() {
        let rewriter = DoviP7PacketRewriter()
        for _ in 0..<7 { _ = rewriter.rewrite(packet([[0x02, 0x01, 0xAA], [0x7C, 0x01, 0x00]])) }
        _ = rewriter.rewrite(packet([[0x02, 0x01, 0xAA], p7RpuNal])) // 第 8 帧有效
        XCTAssertFalse(rewriter.shouldFallbackToSoftware(),
                       "8 帧内有 1 帧有效 RPU → 不回退")
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.checked, 8)
        XCTAssertEqual(snap.valid, 1)
    }

    // MARK: - V1b: MPEG-TS / M2TS annexb → 4 字节长度前缀改写

    func testAnnexBModeStripsELAndOutputsLengthPrefixedP81() throws {
        let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]              // t32
        let vcl: [UInt8] = [0x26, 0x01, 0xAA, 0xBB, 0xCC]        // t19 IDR
        let el: [UInt8]  = [0x7E, 0x01, 0x11, 0x22]              // t63 EL
        let cfg62: [UInt8] = [0x7C, 0x01, 0x02, 0x01, 0x00]      // t62 el_type=0x02 config (非 RPU)
        var annexb: [UInt8] = []
        annexb += [0, 0, 0, 1] + vps
        annexb += [0, 0, 1] + vcl
        annexb += [0, 0, 0, 1] + el
        annexb += [0, 0, 0, 1] + cfg62
        annexb += [0, 0, 0, 1] + p7RpuNal

        let rewriter = DoviP7PacketRewriter(inputFormat: .annexB)
        let out = try XCTUnwrap(rewriter.rewrite(Data(annexb)), "合法 annexb P7 包应改写为长度前缀")
        let nals = try XCTUnwrap(parseNals(out), "输出应为合法 4 字节长度前缀 NAL 序列")
        XCTAssertEqual(nals.map(\.type), [32, 19, 62], "应剥除 EL(t63) 与非 RPU t62 配置,保留 VPS/VCL/转换态 RPU")
        XCTAssertEqual(nals[0].nal, vps)
        XCTAssertEqual(nals[1].nal, vcl)
        XCTAssertEqual(Array(nals[2].nal.prefix(2)), [0x7C, 0x01])
        let converted = try XCTUnwrap(DoviRpuP7ToP81.convertNAL(p7RpuNal))
        XCTAssertEqual(Array(nals[2].nal.dropFirst(2)), Array(converted.dropFirst(4)))
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.checked, 1)
        XCTAssertEqual(snap.valid, 1)
    }

    func testAnnexBModeFallsBackWhenDualTrackHasNoInBandRPU() {
        let blOnly = Data([0, 0, 0, 1, 0x02, 0x01, 0xAA, 0xBB])
        let rewriter = DoviP7PacketRewriter(inputFormat: .annexB)
        for frame in 1...8 {
            let out = rewriter.rewrite(blOnly)
            XCTAssertNotNil(out)
            XCTAssertEqual(rewriter.shouldFallbackToSoftware(), frame == 8,
                           "双轨 M2TS BL PID 无带内 RPU 时,第 8 帧必须触发回退软解")
        }
    }

    // MARK: - 真实样本端到端(本地,无样本 skip)

    /// Twisters P7 MKV:matroskadec 产出的 mp4 域 packet 直接喂 rewriter。
    /// 断言:每包改写成功、RPU 全部转换成功、EL 全部剥除、其余 NAL 逐字节透传。
    func testRealMkvP7PacketsRewriteEndToEnd() throws {
        guard let path = ProcessInfo.processInfo.environment["P7_SAMPLE_MKV"] else {
            throw XCTSkip("P7_SAMPLE_MKV 未设置(本地样本)")
        }
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, path, nil, nil) == 0, let ctx = fmt else {
            XCTFail("open failed"); return
        }
        defer { avformat_close_input(&fmt) }
        guard avformat_find_stream_info(ctx, nil) == 0 else { XCTFail("stream info failed"); return }
        let vsIdx = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard pkt != nil else { XCTFail("no video"); return }

        let rewriter = DoviP7PacketRewriter()
        var videoPackets = 0
        var elSeen = false
        var rpuSeen = false
        while videoPackets < 30, av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard let p = pkt, p.pointee.stream_index == vsIdx, let data = p.pointee.data else { continue }
            let raw = Data(bytes: data, count: Int(p.pointee.size))
            let srcNals = try XCTUnwrap(parseNals(raw), "MKV video packet 应为 mp4 length-prefixed")
            let types = srcNals.map(\.type)
            if types.contains(62) { rpuSeen = true }
            if types.contains(63) { elSeen = true }

            let out = try XCTUnwrap(rewriter.rewrite(raw))
            let outNals = try XCTUnwrap(parseNals(out))
            XCTAssertFalse(outNals.contains { $0.type == 63 }, "EL 必须剥除")
            for nal in outNals where nal.type == 62 {
                XCTAssertEqual(Array(nal.nal.prefix(2)), [0x7C, 0x01], "替换 RPU 的 NAL header")
            }
            // 非 62/63 NAL 逐字节透传
            let srcKeep = srcNals.filter { $0.type != 62 && $0.type != 63 }.map(\.nal)
            let outKeep = outNals.filter { $0.type != 62 }.map(\.nal)
            XCTAssertEqual(srcKeep, outKeep)
            videoPackets += 1
        }
        XCTAssertGreaterThanOrEqual(videoPackets, 10)
        XCTAssertTrue(rpuSeen, "样本前 30 包应含带内 RPU(实测 matroskadec 已合并)")
        XCTAssertTrue(elSeen, "样本前 30 包应含 unspec63 EL 分片")
        let snap = rewriter.validationSnapshot()
        XCTAssertEqual(snap.valid, snap.checked, "真实 P7 RPU 每帧都应转换成功")
        XCTAssertFalse(rewriter.shouldFallbackToSoftware())
    }
}
