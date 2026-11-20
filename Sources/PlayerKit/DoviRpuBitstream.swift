import Foundation

/// RPU 位流基础 + P7/P8.1 header 解析/写回(设计 2026-11-16 Task 2b)。
///
/// 语法与字节布局对齐 libdovi(MIT)的 `rpu/dovi_rpu.rs` / `rpu_data_header.rs`:
/// - 帧数据(去起始码后)以 `0x19`(`rpu_nal_prefix`)开头;
/// - header 为 MSB-first 位域,含普通位、2/3/4/6 位定长字段与 `ue(v)`;
/// - 帧尾为 4 字节 CRC-32/MPEG-2 + `0x80` 终止字节;
/// - HEVC 层需 clear/restore emulation-prevention `00 00 03`。
///
/// Task 2b 的 writer 以本文件为基础:解析 header → 按 compat 1 改旗标 →
/// 原样复制 header 之后的位(mapping/DM/CRC 由后续步骤重建)。
struct DoviBitReader {
    private let bytes: [UInt8]
    private(set) var bitPos: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var bitsRemaining: Int { bytes.count * 8 - bitPos }
    var isByteAligned: Bool { bitPos % 8 == 0 }

    mutating func read(_ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<count {
            // 越界读:结构解析已错,返回 0 让上层校验(CRC/边界)兜底,
            // 不在这里 crash。
            guard bitPos < bytes.count * 8 else { bitPos += 1; continue }
            let byte = bytes[bitPos >> 3]
            let bit = (byte >> (7 - (bitPos & 7))) & 1
            v = (v << 1) | UInt64(bit)
            bitPos += 1
        }
        return v
    }

    mutating func readBit() -> Bool { read(1) == 1 }

    /// Exp-Golomb `ue(v)`.
    mutating func readUE() -> UInt64 {
        var zeros = 0
        while read(1) == 0 { zeros += 1 }
        guard zeros > 0 else { return 0 }
        let suffix = read(zeros)
        return (1 << zeros) - 1 + suffix
    }

    mutating func skip(_ count: Int) { bitPos += count }

    /// 回滚到指定位位置(V40 组探测失败时用)。
    mutating func rewind(to pos: Int) { bitPos = pos }
}

/// 连续三个 ue(v)(压缩 DM 头)。
private func rThreeUEs(_ r: inout DoviBitReader) -> (UInt64, UInt64, UInt64) {
    (r.readUE(), r.readUE(), r.readUE())
}

struct DoviBitWriter {
    private var bits: [Bool] = []

    mutating func write(_ value: UInt64, _ count: Int) {
        guard count > 0 else { return }
        for i in stride(from: count - 1, through: 0, by: -1) {
            bits.append((value >> UInt64(i)) & 1 == 1)
        }
    }

    mutating func writeBit(_ v: Bool) { bits.append(v) }

    mutating func writeUE(_ value: UInt64) {
        let v = value + 1
        let width = 64 - v.leadingZeroBitCount
        for _ in 0..<(width - 1) { bits.append(false) }
        write(v, width)
    }

    mutating func writeBits(_ src: [Bool]) { bits.append(contentsOf: src) }

    mutating func byteAlign() {
        while bits.count % 8 != 0 { bits.append(false) }
    }

    var bitCount: Int { bits.count }

    func data() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b {
            out[i >> 3] |= 1 << (7 - (i & 7))
        }
        return out
    }
}

// MARK: - CRC-32/MPEG-2

enum DoviCrc32 {
    /// CRC-32/MPEG-2:poly 0x04C11DB7,init 0xFFFFFFFF,不反射、无 xorout。
    /// 与 libdovi(`CRC_32_MPEG_2`)一致。
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
        }
        return crc
    }
}

// MARK: - HEVC emulation prevention

enum DoviEmulationPrevention {
    static func clear(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 3 {
                out.append(0); out.append(0)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    static func add(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}

// MARK: - RPU header

/// P7/P8.1 共用的 RPU header(字段与 libdovi `RpuDataHeader` 一致)。
struct DoviRpuHeader: Equatable {
    var rpuType: UInt8 = 0
    var rpuFormat: UInt16 = 0
    var vdrRpuProfile: UInt8 = 0
    var vdrRpuLevel: UInt8 = 0
    var vdrSeqInfoPresentFlag = false
    var chromaResamplingExplicitFilterFlag = false
    var coefficientDataType: UInt8 = 0
    var coefficientLog2Denom: UInt64 = 0
    var vdrRpuNormalizedIdc: UInt8 = 0
    var blVideoFullRangeFlag = false
    var blBitDepthMinus8: UInt64 = 0
    var elBitDepthMinus8: UInt64 = 0
    var extMappingIdc0_4: UInt8 = 0
    var extMappingIdc5_7: UInt8 = 0
    var vdrBitDepthMinus8: UInt64 = 0
    var spatialResamplingFilterFlag = false
    var reservedZero3Bits: UInt8 = 0
    var elSpatialResamplingFilterFlag = false
    var disableResidualFlag = false
    var vdrDmMetadataPresentFlag = false
    var usePrevVdrRpuFlag = false
    var prevVdrRpuId: UInt64 = 0

    static func parse(_ r: inout DoviBitReader) -> DoviRpuHeader {
        var h = DoviRpuHeader()
        h.rpuType = UInt8(r.read(6))
        h.rpuFormat = UInt16(r.read(11))
        h.vdrRpuProfile = UInt8(r.read(4))
        h.vdrRpuLevel = UInt8(r.read(4))
        h.vdrSeqInfoPresentFlag = r.readBit()
        if h.vdrSeqInfoPresentFlag {
            h.chromaResamplingExplicitFilterFlag = r.readBit()
            h.coefficientDataType = UInt8(r.read(2))
            if h.coefficientDataType == 0 {
                h.coefficientLog2Denom = r.readUE()
            }
            h.vdrRpuNormalizedIdc = UInt8(r.read(2))
            h.blVideoFullRangeFlag = r.readBit()
            if h.rpuFormat & 0x700 == 0 {
                h.blBitDepthMinus8 = r.readUE()
                let el = r.readUE()
                h.elBitDepthMinus8 = el & 0xFF
                let ext = UInt8((el >> 8) & 0xFF)
                h.extMappingIdc0_4 = ext & 0x1F
                h.extMappingIdc5_7 = ext >> 5
                h.vdrBitDepthMinus8 = r.readUE()
                h.spatialResamplingFilterFlag = r.readBit()
                h.reservedZero3Bits = UInt8(r.read(3))
                h.elSpatialResamplingFilterFlag = r.readBit()
                h.disableResidualFlag = r.readBit()
            }
        }
        h.vdrDmMetadataPresentFlag = r.readBit()
        h.usePrevVdrRpuFlag = r.readBit()
        if h.usePrevVdrRpuFlag {
            h.prevVdrRpuId = r.readUE()
        }
        return h
    }

    func write(_ w: inout DoviBitWriter) {
        w.write(UInt64(rpuType), 6)
        w.write(UInt64(rpuFormat), 11)
        w.write(UInt64(vdrRpuProfile), 4)
        w.write(UInt64(vdrRpuLevel), 4)
        w.writeBit(vdrSeqInfoPresentFlag)
        if vdrSeqInfoPresentFlag {
            w.writeBit(chromaResamplingExplicitFilterFlag)
            w.write(UInt64(coefficientDataType), 2)
            if coefficientDataType == 0 { w.writeUE(coefficientLog2Denom) }
            w.write(UInt64(vdrRpuNormalizedIdc), 2)
            w.writeBit(blVideoFullRangeFlag)
            if rpuFormat & 0x700 == 0 {
                w.writeUE(blBitDepthMinus8)
                let ext = (UInt64(extMappingIdc5_7) << 5) | UInt64(extMappingIdc0_4)
                w.writeUE((ext << 8) | elBitDepthMinus8)
                w.writeUE(vdrBitDepthMinus8)
                w.writeBit(spatialResamplingFilterFlag)
                w.write(UInt64(reservedZero3Bits), 3)
                w.writeBit(elSpatialResamplingFilterFlag)
                w.writeBit(disableResidualFlag)
            }
        }
        w.writeBit(vdrDmMetadataPresentFlag)
        w.writeBit(usePrevVdrRpuFlag)
        if usePrevVdrRpuFlag { w.writeUE(prevVdrRpuId) }
    }
}

// MARK: - 帧级解析

/// 一个 RPU 帧:header + header 之后的原始位(mapping/DM/CRC 原样保留)。
struct DoviRpuFrame {
    var header: DoviRpuHeader
    /// header 结束后的全部位(含 mapping、DM、CRC、终止字节);Task 2b
    /// 第一阶段原样复制,后续步骤再替换 mapping/CRC。
    var tailBits: [Bool]
    /// 原始数据(去起始码、去 EPB),便于对拍/调试。
    var rawBytes: [UInt8]
}

enum DoviRpuFrameCodec {
    /// 去掉起始码/NAL header,得到以 0x19 开头的 RPU 数据(对齐 libdovi
    /// `validated_trimmed_data`)。
    static func trim(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 5 else { return nil }
        let drop: Int?
        if data[0...3] == [0, 0, 0, 1], data[4] == 25 {
            drop = 4
        } else if data[0...2] == [0, 0, 1], data[3] == 25 {
            drop = 3
        } else if (data[0] == 0 && data[1] == 1) || (data[0] == 124 && data[1] == 1) {
            drop = data[2] == 25 ? 2 : nil
        } else if data[0] == 1, data[1] == 25 {
            drop = 1
        } else if data[0] == 25 {
            drop = 0
        } else {
            drop = nil
        }
        guard let d = drop else { return nil }
        return Array(data[d...])
    }

    static func parse(_ data: [UInt8]) -> DoviRpuFrame? {
        guard let trimmed = trim(data) else { return nil }
        let cleared = DoviEmulationPrevention.clear(trimmed)
        var reader = DoviBitReader(cleared)
        guard reader.read(8) == 25 else { return nil } // rpu_nal_prefix
        let header = DoviRpuHeader.parse(&reader)
        // tail: 剩余全部位
        var tail: [Bool] = []
        while reader.bitsRemaining > 0 { tail.append(reader.readBit()) }
        return DoviRpuFrame(header: header, tailBits: tail, rawBytes: cleared)
    }

    /// 写回(第一阶段:header 原样/可改,其余位原样复制)。
    static func encode(_ frame: DoviRpuFrame) -> [UInt8] {
        var w = DoviBitWriter()
        w.write(25, 8)
        frame.header.write(&w)
        w.writeBits(frame.tailBits)
        w.byteAlign()
        return DoviEmulationPrevention.add(w.data())
    }
}

// MARK: - RPU mapping(设计 Task 2b 第二阶段)

/// `rpu_data_mapping` 段(语法对齐 libdovi `RpuDataMapping`)。
/// 系数定点值为「符号位 + 幅度」编码(`var(denomLen)`);`*_int` 为 `se(v)`。
struct DoviRpuMapping {
    struct Curve {
        var numPivotsMinus2: UInt64 = 0
        var pivots: [UInt64] = []
        /// 每 piece:`mappingIdc`(0=poly,1=mmr)
        var mappingIdc: [UInt64] = []
        /// polynomial:每 piece 为 (polyOrderMinus1, linearInterpFlag,
        /// [(coefInt, coefFixed)];coef 数 = order+2)
        var poly: [(order: UInt64, linear: Bool, coefs: [(Int64, Int64)])] = []
        /// mmr:每 piece 为 (orderMinus1, constInt, constFixed, coefs)
        var mmr: [(order: UInt8, constInt: Int64, constFixed: Int64, coefs: [(Int64, Int64)])] = []
    }

    var vdrRpuId: UInt64 = 0
    var mappingColorSpace: UInt64 = 0
    var mappingChromaFormatIdc: UInt64 = 0
    var curves: [Curve] = []
    var nlqMethodIdc: UInt8?
    var nlqPredPivotValue: [UInt64] = []
    var numXPartitionsMinus1: UInt64 = 0
    var numYPartitionsMinus1: UInt64 = 0

    static func parse(_ r: inout DoviBitReader, header: DoviRpuHeader) -> DoviRpuMapping {
        var m = DoviRpuMapping()
        m.vdrRpuId = r.readUE()
        m.mappingColorSpace = r.readUE()
        m.mappingChromaFormatIdc = r.readUE()
        let blBitDepth = Int(header.blBitDepthMinus8) + 8

        for _ in 0..<3 {
            var c = Curve()
            c.numPivotsMinus2 = r.readUE()
            let numPivots = Int(c.numPivotsMinus2) + 2
            for _ in 0..<numPivots { c.pivots.append(r.read(blBitDepth)) }
            m.curves.append(c)
        }

        // P7 NLQ(rpu_format & 0x700 == 0 且未 disable residual)
        if header.rpuFormat & 0x700 == 0 && !header.disableResidualFlag {
            m.nlqMethodIdc = UInt8(r.read(3))
            for _ in 0..<2 { m.nlqPredPivotValue.append(r.read(blBitDepth)) }
        }

        m.numXPartitionsMinus1 = r.readUE()
        m.numYPartitionsMinus1 = r.readUE()

        let denomLen = Int(header.coefficientLog2Denom)
        // 定点系数:bitstream-io write_signed_counted = 符号 1 位 + (N-1) 位
        // 幅度,总长 N 位(denomLen)。不是 N+1!(2026-11-16 对拍定位)
        let magLen = denomLen - 1
        func readSignedFixed() -> Int64 {
            let neg = r.readBit()
            let mag = Int64(r.read(magLen))
            return neg ? -mag : mag
        }
        func readSE() -> Int64 {
            let se = r.readUE()
            return se % 2 == 0 ? -(Int64(se) >> 1) : (Int64(se) >> 1) + 1
        }
        for ci in 0..<3 {
            let numPieces = Int(m.curves[ci].numPivotsMinus2) + 1
            for _ in 0..<numPieces {
                let idc = r.readUE()
                m.curves[ci].mappingIdc.append(idc)
                if idc == 0 {
                    // polynomial
                    let order = r.readUE()
                    var linear = false
                    if order == 0 { linear = r.readBit() }
                    var coefs: [(Int64, Int64)] = []
                    if order == 0 && linear {
                        // 线性插值(pred_linear_interp_value):样本中不出现。
                        for _ in 0..<2 {
                            coefs.append((readSE(), readSignedFixed()))
                        }
                    } else {
                        let count = Int(order) + 1
                        for _ in 0...count {
                            coefs.append((readSE(), readSignedFixed()))
                        }
                    }
                    m.curves[ci].poly.append((order, linear, coefs))
                } else {
                    // mmr
                    let order = UInt8(r.read(2))
                    let constV = readSE()
                    let constFixed = readSignedFixed()
                    var coefs: [(Int64, Int64)] = []
                    for _ in 0...(Int(order) + 1) {
                        for _ in 0..<7 {
                            coefs.append((readSE(), readSignedFixed()))
                        }
                    }
                    m.curves[ci].mmr.append((order, constV, constFixed, coefs))
                }
            }
        }

        // NLQ 数据块(P7 mapping 尾部,libdovi `RpuDataNlq::parse`):
        // 每 component:nlq_offset(el 位深,无符号)+ vdr_in_max(int ue +
        // 符号定点)+ LinearDeadzone(slope int/定点 + threshold int/定点)。
        // 转换丢弃,但必须消费这些位,否则 DM 段起点错位。
        if m.nlqMethodIdc != nil {
            let elBits = Int(header.elBitDepthMinus8) + 8
            for _ in 0..<3 {
                _ = r.read(elBits)
                _ = r.readUE()
                _ = readSignedFixed()
                _ = r.readUE()
                _ = readSignedFixed()
                _ = r.readUE()
                _ = readSignedFixed()
            }
        }
        return m
    }

    func write(_ w: inout DoviBitWriter, header: DoviRpuHeader) {
        w.writeUE(vdrRpuId)
        w.writeUE(mappingColorSpace)
        w.writeUE(mappingChromaFormatIdc)
        let blBitDepth = Int(header.blBitDepthMinus8) + 8

        for c in curves {
            w.writeUE(c.numPivotsMinus2)
            for p in c.pivots { w.write(p, blBitDepth) }
        }

        // P8.1 转换态:disableResidualFlag = true → 不写 NLQ(规范分支)。

        w.writeUE(numXPartitionsMinus1)
        w.writeUE(numYPartitionsMinus1)

        let denomLen = Int(header.coefficientLog2Denom)
        let magLen = denomLen - 1
        func writeSignedFixed(_ v: Int64) {
            // 符号 1 位 + (denomLen-1) 位幅度 = 总长 denomLen 位
            // (bitstream-io write_signed_counted 语义,对齐 readSignedFixed)
            let neg = v < 0
            w.writeBit(neg)
            let mag = neg ? -v : v
            w.write(UInt64(mag), magLen)
        }
        func writeSE(_ v: Int64) {
            let code = v <= 0 ? UInt64(-v) << 1 : UInt64(v) << 1 - 1
            // H.264 se(v):k>0 → 2k-1;k≤0 → -2k
            let codeNum = v > 0 ? UInt64(v) * 2 - 1 : UInt64(-v) * 2
            _ = code
            w.writeUE(codeNum)
        }

        for ci in 0..<3 {
            let c = curves[ci]
            let numPieces = Int(c.numPivotsMinus2) + 1
            for i in 0..<numPieces {
                w.writeUE(c.mappingIdc[i])
                if c.mappingIdc[i] == 0 {
                    let p = c.poly[i]
                    w.writeUE(p.0)
                    if p.0 == 0 { w.writeBit(p.1) }
                    for coef in p.2 {
                        writeSE(coef.0)
                        writeSignedFixed(coef.1)
                    }
                } else {
                    let p = c.mmr[i]
                    w.write(UInt64(p.0), 2)
                    writeSE(p.1)
                    writeSignedFixed(p.2)
                    for coef in p.3 {
                        writeSE(coef.0)
                        writeSignedFixed(coef.1)
                    }
                }
            }
        }
    }
}

// MARK: - DM 固定头(VdrDmData 非压缩分支)

/// DM 固定头字段(对齐 libdovi `VdrDmData` parse/write 顺序)。
/// 块组(v29/v40)由上层单独处理。字段值重写时除 `applyP81Coeffs`
/// 替换的矩阵与 signal_color_space 外全部原样。
struct DoviRpuDmFixed {
    var affectedDmMetadataId: UInt64 = 0
    var currentDmMetadataId: UInt64 = 0
    var sceneRefreshFlag: UInt64 = 0
    var yccToRgbCoef: [Int64] = []      // 9 × 16 位有符号
    var yccToRgbOffset: [UInt64] = []   // 3 × 32 位
    var rgbToLmsCoef: [Int64] = []      // 9 × 16 位有符号
    var signalEotf: UInt64 = 0
    var signalEotfParam0: UInt64 = 0
    var signalEotfParam1: UInt64 = 0
    var signalEotfParam2: UInt64 = 0
    var signalBitDepth: UInt64 = 0
    var signalColorSpace: UInt64 = 0
    var signalChromaFormat: UInt64 = 0
    var signalFullRangeFlag: UInt64 = 0
    var sourceMinPq: UInt64 = 0
    var sourceMaxPq: UInt64 = 0
    var sourceDiagonal: UInt64 = 0

    static func parse(_ r: inout DoviBitReader) -> DoviRpuDmFixed {
        var d = DoviRpuDmFixed()
        d.affectedDmMetadataId = r.readUE()
        d.currentDmMetadataId = r.readUE()
        d.sceneRefreshFlag = r.readUE()
        for _ in 0..<9 { d.yccToRgbCoef.append(Int64(bitPattern: r.read(16))) }
        for _ in 0..<3 { d.yccToRgbOffset.append(r.read(32)) }
        for _ in 0..<9 { d.rgbToLmsCoef.append(Int64(bitPattern: r.read(16))) }
        d.signalEotf = r.read(16)
        d.signalEotfParam0 = r.read(16)
        d.signalEotfParam1 = r.read(16)
        d.signalEotfParam2 = r.read(32)
        d.signalBitDepth = r.read(5)
        d.signalColorSpace = r.read(2)
        d.signalChromaFormat = r.read(2)
        d.signalFullRangeFlag = r.read(2)
        d.sourceMinPq = r.read(12)
        d.sourceMaxPq = r.read(12)
        d.sourceDiagonal = r.read(10)
        return d
    }

    /// libdovi `set_p81_coeffs`:矩阵替换为 P8.1 标准,signal_color_space 归零。
    mutating func applyP81Coeffs() {
        yccToRgbCoef = [9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0]
        yccToRgbOffset = [16_777_216, 134_217_728, 134_217_728]
        rgbToLmsCoef = [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962]
        signalColorSpace = 0
    }

    func write(_ w: inout DoviBitWriter) {
        w.writeUE(affectedDmMetadataId)
        w.writeUE(currentDmMetadataId)
        w.writeUE(sceneRefreshFlag)
        for c in yccToRgbCoef { w.write(UInt64(bitPattern: Int64(UInt16(bitPattern: Int16(clamping: c)))), 16) }
        for o in yccToRgbOffset { w.write(o, 32) }
        for c in rgbToLmsCoef { w.write(UInt64(bitPattern: Int64(UInt16(bitPattern: Int16(clamping: c)))), 16) }
        w.write(signalEotf, 16)
        w.write(signalEotfParam0, 16)
        w.write(signalEotfParam1, 16)
        w.write(signalEotfParam2, 32)
        w.write(signalBitDepth, 5)
        w.write(signalColorSpace, 2)
        w.write(signalChromaFormat, 2)
        w.write(signalFullRangeFlag, 2)
        w.write(sourceMinPq, 12)
        w.write(sourceMaxPq, 12)
        w.write(sourceDiagonal, 10)
    }
}

// MARK: - P7 → P8.1 转换(dovi_tool mode 2,MEL 路径)

public enum DoviRpuP7ToP81 {

    /// 转换一个 P7 RPU NAL(输入含/不含起始码均可,内部 trim)。
    /// 返回完整 NAL 字节(不含起始码,含 EPB 处理);失败返回 nil。
    public static func convertNAL(_ nal: [UInt8]) -> [UInt8]? {
        guard let trimmed = DoviRpuFrameCodec.trim(nal) else { return nil }
        let cleared = DoviEmulationPrevention.clear(trimmed)

        // 尾部 0 与终止字节(对齐 libdovi parse)
        var trailingZeros = 0
        var end = cleared.count
        while end > 0, cleared[end - 1] == 0 { trailingZeros += 1; end -= 1 }
        guard end >= 7, cleared[end - 1] == 0x80 else { return nil }

        var reader = DoviBitReader(Array(cleared[0..<end]))
        guard reader.read(8) == 25 else { return nil }
        var header = DoviRpuHeader.parse(&reader)
        guard header.rpuType == 2 else { return nil }
        // P7 特征:profile 由 vdr_rpu_profile=1 + NLQ/EL 旗标体现;宽松校验。
        guard !header.usePrevVdrRpuFlag else { return nil }

        let mapping = DoviRpuMapping.parse(&reader, header: header)

        // DM:结构化解析(设计 Task 2b)。固定头 + v29 块组(+ v40 块组)。
        // 块组**必须解析成结构再重写**而不是照搬位:P7 帧里组后 align padding
        // 是相对源位流的(实测 6 位),重写后位置不同,照搬会多出 padding 位
        // (2026-11-16 对拍:ours 比 dovi_tool 输出多 1 字节)。
        // 每块 = 块长 ue + level 8 位 + 块长×8 位 payload(块内容不解析,原样)。
        // trimmed 末尾:… align | crc32(32) | 0x80(8)
        let crcStartBit = (end - 5) * 8

        // —— DM 固定头(VdrDmData::parse;边读边记录字段值供重写)——
        var dmFixed = DoviRpuDmFixed()
        if header.reservedZero3Bits == 1 {
            // 压缩 DM:仅 3 个 ue,后接块组(重写时固定头只写这 3 个 ue)
            let u = rThreeUEs(&reader)
            dmFixed.affectedDmMetadataId = u.0
            dmFixed.currentDmMetadataId = u.1
            dmFixed.sceneRefreshFlag = u.2
        } else {
            dmFixed = DoviRpuDmFixed.parse(&reader)
        }

        // —— DM 扩展块组解析 ——
        struct DmBlockGroup {
            var numBlocks: UInt64
            var blocks: [(len: UInt64, level: UInt64, payload: [Bool])]
        }
        func parseBlockGroup() -> DmBlockGroup? {
            let startPos = reader.bitPos
            guard reader.bitsRemaining >= 8 else { return nil }
            let numBlocks = reader.readUE()
            guard numBlocks >= 1, numBlocks <= 64 else {
                reader.rewind(to: startPos); return nil
            }
            var blocks: [(UInt64, UInt64, [Bool])] = []
            // dm_alignment_zero_bit
            while !reader.isByteAligned {
                guard reader.bitsRemaining > 0, reader.readBit() == false else {
                    reader.rewind(to: startPos); return nil
                }
            }
            for _ in 0..<numBlocks {
                guard reader.bitsRemaining >= 8 else {
                    reader.rewind(to: startPos); return nil
                }
                let blockLen = reader.readUE()
                let level = reader.read(8)
                guard blockLen >= 1, blockLen <= 256,
                      reader.bitsRemaining >= Int(blockLen) * 8 else {
                    reader.rewind(to: startPos); return nil
                }
                var payload: [Bool] = []
                for _ in 0..<(Int(blockLen) * 8) { payload.append(reader.readBit()) }
                blocks.append((blockLen, level, payload))
            }
            return DmBlockGroup(numBlocks: numBlocks, blocks: blocks)
        }

        // V29 组(必须存在)
        guard let v29 = parseBlockGroup() else { return nil }

        // V40 组(存在则保留;探测失败回滚到组起点,视为不存在)
        var v40: DmBlockGroup?
        if reader.bitsRemaining >= 56 {
            v40 = parseBlockGroup()
        }

        // —— 转换(dovi_tool convert_to_p81)——
        header.elSpatialResamplingFilterFlag = false
        header.disableResidualFlag = true
        var outMapping = mapping
        outMapping.nlqMethodIdc = nil
        outMapping.nlqPredPivotValue = []
        outMapping.numXPartitionsMinus1 = 0
        outMapping.numYPartitionsMinus1 = 0

        // —— 重写:固定头 → v29 → v40 → align → CRC(全部重新序列化)——
        var w = DoviBitWriter()
        w.write(25, 8)
        header.write(&w)
        outMapping.write(&w, header: header)

        // DM 固定头:set_p81_coeffs 替换矩阵
        dmFixed.applyP81Coeffs()
        dmFixed.write(&w)

        func writeGroup(_ g: DmBlockGroup) {
            w.writeUE(g.numBlocks)
            w.byteAlign()
            for b in g.blocks {
                w.writeUE(b.len)
                w.write(b.level, 8)
                w.writeBits(b.payload)
            }
        }
        writeGroup(v29)
        if let g40 = v40 { writeGroup(g40) }

        w.byteAlign()
        var payload = w.data()
        guard payload.count > 1 else { return nil }
        let crc = DoviCrc32.checksum(Array(payload[1...]))
        payload.append(UInt8((crc >> 24) & 0xFF))
        payload.append(UInt8((crc >> 16) & 0xFF))
        payload.append(UInt8((crc >> 8) & 0xFF))
        payload.append(UInt8(crc & 0xFF))
        payload.append(0x80)
        for _ in 0..<trailingZeros { payload.append(0) }

        // annexb NAL:起始码 + EPB(与 dovi_tool 输出格式一致)
        var nal: [UInt8] = [0, 0, 0, 1]
        nal.append(contentsOf: DoviEmulationPrevention.add(payload))
        return nal
    }
}
