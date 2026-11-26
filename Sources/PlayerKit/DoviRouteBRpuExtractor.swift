import Foundation

/// Phase 2 route b(iOS / tvOS 原生 DV):从 4 字节长度前缀 HEVC packet 中提取
/// unspec62 RPU RBSP(去 2 字节 NAL header 留 EPB,以 `0x19` 开头),供
/// `ASBDLRenderer` 挂载到 VT 解码后的 `CVPixelBuffer` 附件(`DolbyVisionRPUData`)。
///
/// - P8.1:直接剥离 2 字节 NAL header(`7C 01`)透传原始 RPU RBSP。
/// - P7:复用一期 `DoviRpuP7ToP81.convertNAL` 转为 P8.1 RPU RBSP(含 FEL `remove_mapping`)。
/// - 任何解析/转换失败返回 `nil`,该帧不挂 RPU 附件(退化为 HDR10 帧,不黑屏不崩溃)。
public enum DoviRouteBRpuExtractor {

    /// 扫描 4 字节大端长度前缀 HEVC packet,提取首条有效 RPU RBSP(`0x19 ... 0x80`,含 EPB)。
    public static func extractFromLengthPrefixed(_ packet: Data, isProfile7: Bool) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 8 else { return nil }
        var i = 0
        while i + 4 <= bytes.count {
            let nalLen = (Int(bytes[i]) << 24)
                | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8)
                | Int(bytes[i + 3])
            let hdr = i + 4
            guard nalLen >= 2, hdr + nalLen <= bytes.count else { return nil }
            let nalType = Int((bytes[hdr] >> 1) & 0x3F)
            if nalType == 62 {
                let nalSlice = Array(bytes[hdr..<(hdr + nalLen)])
                if isProfile7 {
                    if let converted = DoviRpuP7ToP81.convertNAL(nalSlice) {
                        let rbsp = (converted.count > 4 && Array(converted[0...3]) == [0, 0, 0, 1])
                            ? Array(converted[4...]) : converted
                        if rbsp.first == 0x19 {
                            return Data(rbsp)
                        }
                    }
                } else if nalLen > 3, bytes[hdr + 2] == 0x19 {
                    return Data(bytes[(hdr + 2)..<(hdr + nalLen)])
                }
            }
            i = hdr + nalLen
        }
        return nil
    }
}

/// VT B-frame 重排期间按解码输入 PTS 暂存 RPU RBSP,在 VT 输出对应显示序
/// `outPTS` 时取出配对。固定容量上限防止异常流无界增长,`flush()` 全清。
public final class DoviRpuPtsCache {
    private let capacity: Int
    private var entries: [(pts: Int64, rpu: Data)] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public func store(pts: Int64, rpu: Data) {
        if let idx = entries.firstIndex(where: { $0.pts == pts }) {
            entries[idx].rpu = rpu
            return
        }
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append((pts: pts, rpu: rpu))
    }

    public func take(pts: Int64) -> Data? {
        guard let idx = entries.firstIndex(where: { $0.pts == pts }) else { return nil }
        return entries.remove(at: idx).rpu
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    public var count: Int { entries.count }
}
