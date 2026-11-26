import Foundation

/// 逐包码流级改写(设计 2026-11-16 §4.4 / D6)。
///
/// `SystemDVSampleBuilder` 把 AVPacket 字节原样拷进 CMSampleBuffer,不读
/// `FrameMetadata`。要走到系统 DV 解码,必须在字节层:
///   - 剥掉 unspec62(NAL type 62,EL/RPU NAL)
///   - 在原 RPU 位置(或首个 VCL 前)注入转换后的 P8.1 RPU NAL
///   - 其余 NAL(参数集/VCL/SEI/AUD)逐字节透传
///
/// 纯 Swift、无 CFFmpeg 依赖;任何解析异常都返回原包(该帧退化为无 RPU 帧,
/// 设计 D7 的 per-frame fallback)。
public enum DoviNalRewriter {

    /// 改写一个 annexb packet。
    /// - Parameters:
    ///   - packet: 原始 annexb 字节(一帧)
    ///   - rpuNAL: 完整的 P8.1 RPU NAL(type 62,含 2 字节 NAL header);nil = 只剥不注入
    public static func rewrite(packet: Data, injecting rpuNAL: Data?) -> Data {
        let bytes = [UInt8](packet)
        guard bytes.count > 4 else { return packet }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        var injected = false
        var sawUnspec62 = false

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
            guard end > start else { break }
            let nalType = Int((bytes[start] >> 1) & 0x3F)

            if nalType == 62 {
                sawUnspec62 = true
                // 剥 EL/RPU;在原位置注入转换态 RPU(只注入一次)。
                if let rpu = rpuNAL, !injected {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(contentsOf: rpu)
                    injected = true
                }
            } else {
                // 首个 VCL 前若还没注入(源里没有 RPU NAL 或顺序异常),
                // 补注入,保证系统路径仍拿到转换态 RPU。
                // VCL NAL 类型 0–31(IDR 为 19/20,不是 0–9)。
                if !injected, nalType <= 31, let rpu = rpuNAL {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(contentsOf: rpu)
                    injected = true
                }
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(contentsOf: bytes[start..<end])
            }
            i = end
        }

        // 一个 NAL 都没解析出来 = 非 annexb/畸形包:原样透传。
        if out.isEmpty { return packet }
        _ = sawUnspec62
        return Data(out)
    }
}
