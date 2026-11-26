import Foundation

/// P7 转换态的 **mp4/length-prefixed 域**逐包改写(设计 2026-11-16 D6,一期实测定案)。
///
/// 与 `DoviNalRewriter`(annexb 域,为 ISO/M2TS 的 V1b 预留)不同:MKV/WebM 的
/// HEVC 在 extradata 为 hvcC 时,FFmpeg matroskadec 输出的 packet 是 **mp4 风格
/// 4 字节长度前缀** NAL 序列(2026-11-16 实测,FFmpeg 8.1.2 + Twisters P7):
///
///     AUD(t35) | VPS/SPS/PPS | SEI(t39) | BL VCL(t0-21) | EL unspec63 ×N | RPU unspec62
///
/// matroskadec 已把 BlockAdditional 的 RPU 合并成 unspec62 NAL 追加在 packet
/// 末尾(带内自带);EL 是 **unspec63** 分片(不是 62——62 是 RPU)。本改写器:
///   - unspec63(EL)→ 剥除
///   - unspec62(RPU)→ `DoviRpuP7ToP81.convertNAL` 转换后原位替换;
///     转换失败 → 剥除(该帧按无 RPU 帧降级,设计 D7)
///   - 其余 NAL(VPS/SPS/PPS/SEI/VCL/AUD)逐字节透传
///
/// 输出仍是 length-prefixed,可直接进 `SystemDVSampleBuilder`(hvcC FD 的
/// CMSampleBuffer 契约)。解析失败/非 mp4 格式返回 nil,调用方原包透传。
public final class DoviP7PacketRewriter: @unchecked Sendable {

    public enum InputFormat: Sendable {
        /// MKV/MP4 容器(extradata 为 hvcC):输入 packet 为 4 字节大端长度前缀 NAL。
        case lengthPrefixed
        /// MPEG-TS / M2TS(ISO 原盘):输入 packet 为 annexb(3/4 字节起始码),
        /// 改写后统一输出 4 字节长度前缀以匹配合成 hvcC 的 CMSampleBuffer 契约。
        case annexB
    }

    public let inputFormat: InputFormat

    /// RPU 校验窗口统计(R2):checked = 已消费帧数,valid = RPU 转换成功帧数。
    private var checkedFrames = 0
    private var validRpuFrames = 0
    private let stateLock = NSLock()

    public init(inputFormat: InputFormat = .lengthPrefixed) {
        self.inputFormat = inputFormat
    }

    /// 改写一个 P7 packet(按 `inputFormat` 解析 mp4 长度前缀或 annexb 起始码),
    /// 统一输出 4 字节长度前缀以喂给 hvcC `SystemDVSampleBuilder`。
    /// nil = 无法按指定格式解析(格式不匹配/截断)——调用方原样透传(设计 D7)。
    @discardableResult
    public func rewrite(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 6 else { return nil }

        struct NalRef { let off: Int; let len: Int } // off 指向 NAL header,len 含 header
        var nals: [NalRef] = []

        switch inputFormat {
        case .lengthPrefixed:
            guard bytes.count >= 8 else { return nil }
            var i = 0
            while i < bytes.count {
                guard i + 4 <= bytes.count else { return nil }
                let b0 = Int(bytes[i]); let b1 = Int(bytes[i+1]); let b2 = Int(bytes[i+2]); let b3 = Int(bytes[i+3])
                let nalLen = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                let hdr = i + 4
                guard nalLen >= 2, hdr + nalLen <= bytes.count else { return nil }
                nals.append(NalRef(off: hdr, len: nalLen))
                i = hdr + nalLen
            }
        case .annexB:
            var i = 0
            while i + 3 < bytes.count {
                let scLen: Int
                if i + 4 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    scLen = 4
                } else if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
                    scLen = 3
                } else {
                    i += 1
                    continue
                }
                let start = i + scLen
                guard start < bytes.count else { break }
                var end = start + 1
                var foundNext = false
                while end + 3 <= bytes.count {
                    if bytes[end] == 0, bytes[end+1] == 0,
                       (bytes[end+2] == 1 || (end + 3 < bytes.count && bytes[end+2] == 0 && bytes[end+3] == 1)) {
                        foundNext = true
                        break
                    }
                    end += 1
                }
                if !foundNext { end = bytes.count }
                if end - start >= 2 {
                    nals.append(NalRef(off: start, len: end - start))
                }
                i = end
            }
        }
        guard !nals.isEmpty else { return nil }

        // 第二遍:分类改写。
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var validThisPacket = false
        for nal in nals {
            let nalType = Int((bytes[nal.off] >> 1) & 0x3F)
            switch nalType {
            case 63:
                break // EL 分片:剥除
            case 62:
                let rpu = Array(bytes[nal.off..<(nal.off + nal.len)])
                if let converted = DoviRpuP7ToP81.convertNAL(rpu) {
                    // convertNAL 输出是 annexb(00000001 + 裸 RBSP,与 dovi_tool
                    // convert 输出一致);mp4 域的 RPU NAL 需要 unspec62 NAL
                    // header(7C 01)+ RBSP——换头后替换,格式与 matroskadec
                    // 带内 RPU 一致(VideoToolbox 按 NAL header 识别 RPU)。
                    let rbsp = (converted.count > 4 && Array(converted[0...3]) == [0, 0, 0, 1])
                        ? Array(converted[4...]) : Array(converted)
                    appendLengthPrefixed(&out, [0x7C, 0x01] + rbsp)
                    validThisPacket = true
                } // 转换失败:剥除,该帧无 RPU
            default:
                appendLengthPrefixed(&out, Array(bytes[nal.off..<(nal.off + nal.len)]))
            }
        }

        stateLock.lock()
        checkedFrames += 1
        if validThisPacket { validRpuFrames += 1 }
        stateLock.unlock()
        return Data(out)
    }

    /// RPU 校验窗口快照(R2)。
    public func validationSnapshot() -> (checked: Int, valid: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (checkedFrames, validRpuFrames)
    }

    /// 开头 N 帧全无有效 RPU → 路由失误,会话应回 `degradedHDR10`
    /// (复用 `SystemDVPolicy.shouldFallbackAfterRpuValidation` 的阈值语义)。
    public func shouldFallbackToSoftware() -> Bool {
        let (checked, valid) = validationSnapshot()
        return SystemDVPolicy.shouldFallbackAfterRpuValidation(validFrames: valid,
                                                               checkedFrames: checked)
    }

    // MARK: - Private

    private func appendLengthPrefixed(_ out: inout [UInt8], _ nal: [UInt8]) {
        let n = nal.count
        out.append(UInt8((n >> 24) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
        out.append(contentsOf: nal)
    }
}
