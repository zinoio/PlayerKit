import Foundation

/// 从 annexb 参数集合成 HEVCDecoderConfigurationRecord(`hvcC`)。
///
/// 原盘 M2TS/ISO 的 `AVStream.codecpar` 没有 extradata,`SystemDVSampleBuilder`
/// init 依赖 hvcC 会直接失败(现状 open 阶段回软路径)。本类型只做字节级
/// 拼装:P7 的 BL 参数集(VPS/SPS/PPS)在码流里都有,取前 N 帧内的参数集即可。
///
/// - 纯 Swift,无 CFFmpeg 依赖(开源边界)。
/// - 只解析 SPS 的 profile_tier_level 前 12 字节(profile/tier/compat/constraint/
///   level);P7 的 chroma/bit depth 由调用方给出(规范上固定 4:2:0 / 10-bit)。
/// - 任何参数集缺失/过短 → `nil`(调用方保持现状回软路径)。
public enum HevcHvcCBuilder {

    /// 扫描 annexb 流,取第一个 VPS/SPS/PPS。
    public struct ParameterSets: Sendable, Equatable {
        public var vps: Data
        public var sps: Data
        public var pps: Data
        public init(vps: Data, sps: Data, pps: Data) {
            self.vps = vps
            self.sps = sps
            self.pps = pps
        }
    }

    /// 扫描 annexb 字节流(3/4 字节起始码),收集 NAL 32/33/34。
    public static func extractParameterSets(from data: Data) -> ParameterSets? {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        let bytes = [UInt8](data)
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
            let nalType = (bytes[start] >> 1) & 0x3F
            // 找下一个起始码;到流末尾没有下一个起始码时取到末尾,不能停在
            // count-3(否则最后一个 NAL 会丢尾部字节)。
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
            let nal = Data(bytes[start..<end])
            switch nalType {
            case 32: if vps == nil { vps = nal }
            case 33: if sps == nil { sps = nal }
            case 34: if pps == nil { pps = nal }
            default: break
            }
            if vps != nil, sps != nil, pps != nil { break }
            i = end > i ? end : i + 1
        }
        guard let v = vps, let s = sps, let p = pps else { return nil }
        return ParameterSets(vps: v, sps: s, pps: p)
    }

    /// 由参数集合成 hvcC。`chromaFormat`:1=4:2:0;bitDepth 传绝对值(10)。
    public static func build(_ sets: ParameterSets,
                             chromaFormat: UInt8 = 1,
                             bitDepthLuma: UInt8 = 10,
                             bitDepthChroma: UInt8 = 10) -> Data? {
        guard sets.vps.count > 2, sets.sps.count >= 14, sets.pps.count > 2 else { return nil }
        let rbsp = stripEmulationPrevention(Array(sets.sps[2...])) // 去 2 字节 NAL header
        guard rbsp.count >= 12 else { return nil }
        let profileSpace = (rbsp[0] >> 6) & 0x03
        let tierFlag = (rbsp[0] >> 5) & 0x01
        let profileIdc = rbsp[0] & 0x1F
        let compat = UInt32(rbsp[1]) << 24 | UInt32(rbsp[2]) << 16 | UInt32(rbsp[3]) << 8 | UInt32(rbsp[4])
        var constraint: UInt64 = 0
        for b in rbsp[5..<11] { constraint = (constraint << 8) | UInt64(b) }
        let levelIdc = rbsp[11]

        var out = [UInt8]()
        out.append(1) // configurationVersion
        out.append((profileSpace << 6) | (tierFlag << 5) | profileIdc)
        out.append(UInt8((compat >> 24) & 0xFF))
        out.append(UInt8((compat >> 16) & 0xFF))
        out.append(UInt8((compat >> 8) & 0xFF))
        out.append(UInt8(compat & 0xFF))
        for shift in stride(from: 40, through: 0, by: -8) {
            out.append(UInt8((constraint >> UInt64(shift)) & 0xFF))
        }
        out.append(levelIdc)
        // min_spatial_segmentation_idc = 0
        out.append(0xF0); out.append(0x00)
        // parallelismType = 0
        out.append(0xFC)
        // chromaFormat
        out.append(0xFC | (chromaFormat & 0x03))
        // bitDepthLumaMinus8 / bitDepthChromaMinus8
        out.append(0xF8 | ((bitDepthLuma - 8) & 0x07))
        out.append(0xF8 | ((bitDepthChroma - 8) & 0x07))
        // avgFrameRate = 0
        out.append(0x00); out.append(0x00)
        // constantFrameRate=0, numTemporalLayers=0, temporalIdNested=0, lengthSizeMinusOne=3
        out.append(0x03)
        out.append(3) // numOfArrays
        for (nalType, nal) in [(32, sets.vps), (33, sets.sps), (34, sets.pps)] {
            out.append(0x80 | UInt8(nalType)) // array_completeness=1
            out.append(0x00); out.append(0x01) // numNalus = 1
            out.append(UInt8((nal.count >> 8) & 0xFF))
            out.append(UInt8(nal.count & 0xFF))
            out.append(contentsOf: nal)
        }
        return Data(out)
    }

    /// 去掉 H.26x emulation prevention bytes(0x00 0x00 0x03 → 0x00 0x00)。
    private static func stripEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 3 {
                out.append(0); out.append(0)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
