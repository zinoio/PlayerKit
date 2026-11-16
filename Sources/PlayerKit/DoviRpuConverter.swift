import Foundation

/// P7(BL+EL)→ P8.1(compat 1)转换语义(设计 2026-11-16 §4.2)。
///
/// 本类型只做**元数据级**转换:把 ffmpeg 每帧解析出的 P7 快照映射成
/// compat 1 的消费模型 —— 剥掉 NLQ / EL reshape,保留 DM(L1/L2/L3/L5/L6/L8)。
/// 码流级 RPU 重写(NAL 62 注入)由 `DoviNalRewriter` 在上游完成,两者共用
/// 这里的兼容性校验与字段裁剪规则。
///
/// 失败语义(设计 D7):任何一步不满足 → `nil`;调用方按"该帧无 RPU"处理,
/// 会话级 fallback 仍走 `degradedHDR10`,不在这里抛错。
public enum DoviRpuConverter {

    /// P7 每帧快照(由 FFmpegVideoDecoder 从 `AVDOVIMetadata` 抽取)。
    public struct P7Snapshot: Sendable, Equatable {
        /// 流级 DOVI_CONF 的 profile(必须 7)。
        public var dvProfile: UInt8
        /// 流级 DOVI_CONF 的 el_present_flag。
        public var elPresent: Bool
        /// RPU header 的 bl_bit_depth(compat 1 要求 ≥10)。
        public var blBitDepth: UInt8
        /// RPU header 的 el_bit_depth(仅诊断;转换后不再使用)。
        public var elBitDepth: UInt8
        /// RPU mapping 是否带 NLQ(P7 的 EL 逆量化)。
        public var hasNLQ: Bool
        /// RPU mapping 是否带可消费的 reshape 曲线(compat 1 转换后丢弃)。
        public var hasReshape: Bool
        /// 逐帧 DM(L1/L2/L3/L5/L6/L8);可为空。
        public var dm: DolbyVisionFrameMetadata

        public init(dvProfile: UInt8,
                    elPresent: Bool,
                    blBitDepth: UInt8,
                    elBitDepth: UInt8,
                    hasNLQ: Bool,
                    hasReshape: Bool,
                    dm: DolbyVisionFrameMetadata) {
            self.dvProfile = dvProfile
            self.elPresent = elPresent
            self.blBitDepth = blBitDepth
            self.elBitDepth = elBitDepth
            self.hasNLQ = hasNLQ
            self.hasReshape = hasReshape
            self.dm = dm
        }
    }

    /// compat 1 输出:与 `AVDOVIMetadata` 等价的消费模型。
    public struct ConvertedFrame: Sendable, Equatable {
        /// 固定 1(P8.1 的 bl_signal_compatibility_id)。
        public var compatId: UInt8
        /// BL 位深(10)。
        public var blBitDepth: UInt8
        /// DM 原样保留(转换不重算 trim);compat 1 无 reshape/NLQ。
        public var dm: DolbyVisionFrameMetadata

        public init(compatId: UInt8 = DoviRpuConverter.p81CompatId,
                    blBitDepth: UInt8,
                    dm: DolbyVisionFrameMetadata) {
            self.compatId = compatId
            self.blBitDepth = blBitDepth
            self.dm = dm
        }
    }

    /// P8.1 = profile 8 + bl_signal_compatibility_id 1。
    public static let p81CompatId: UInt8 = 1

    /// 转换一帧。不满足 P7 前提 → nil(调用方按无 RPU 帧降级)。
    public static func convert(_ input: P7Snapshot) -> ConvertedFrame? {
        guard input.dvProfile == 7 else { return nil }
        guard input.elPresent else { return nil }
        guard input.blBitDepth >= 10, input.blBitDepth <= 16 else { return nil }
        // compat 1 的语义就是"基础层直通":NLQ / reshape 不进入输出。
        // 这里显式丢弃,防止上层误消费 P7 专属映射。
        return ConvertedFrame(blBitDepth: input.blBitDepth, dm: input.dm)
    }

    /// 该帧转换后是否应当显示为 DV(compat 1 且 BL 位深合法)。
    /// 用于路由在 open 之后逐帧校验"RPU 是否仍有效"。
    public static func isValid(_ frame: ConvertedFrame) -> Bool {
        frame.compatId == p81CompatId && frame.blBitDepth >= 10
    }
}
