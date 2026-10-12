import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// Unit tests for `FFmpegVideoDecoder.parseDoviReshapingCurve` — hand-built
/// C structs, no demux/decode involved.
///
/// Conversion semantics must match libplacebo's `pl_map_dovi_metadata`
/// (libav_internal.h): pivots `p / ((1 << bl_bit_depth) - 1)`, coefficients
/// `v / (1 << coef_log2_denom)`. Only valid slots may be copied.
final class DoviReshapeParseTests: XCTestCase {

    // MARK: - C tuple-field helpers

    /// C fixed-size arrays import to Swift tuples — mutate them through
    /// their (guaranteed contiguous) memory layout.
    private func withCurves(_ mapping: inout AVDOVIDataMapping,
                            _ body: (UnsafeMutableBufferPointer<AVDOVIReshapingCurve>) -> Void) {
        withUnsafeMutableBytes(of: &mapping.curves) { raw in
            body(UnsafeMutableRawBufferPointer(raw).bindMemory(to: AVDOVIReshapingCurve.self))
        }
    }

    private func setPivots(_ curve: inout AVDOVIReshapingCurve, _ values: [UInt16]) {
        withUnsafeMutableBytes(of: &curve.pivots) { raw in
            let buf = UnsafeMutableRawBufferPointer(raw).bindMemory(to: UInt16.self)
            for (i, v) in values.enumerated() { buf[i] = v }
        }
    }

    private func setMappingIDC(_ curve: inout AVDOVIReshapingCurve, _ piece: Int,
                               _ value: AVDOVIMappingMethod) {
        withUnsafeMutableBytes(of: &curve.mapping_idc) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: AVDOVIMappingMethod.self)[piece] = value
        }
    }


    private func setPolyOrder(_ curve: inout AVDOVIReshapingCurve, _ piece: Int, _ v: UInt8) {
        withUnsafeMutableBytes(of: &curve.poly_order) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: UInt8.self)[piece] = v
        }
    }

    private func setMMROrder(_ curve: inout AVDOVIReshapingCurve, _ piece: Int, _ v: UInt8) {
        withUnsafeMutableBytes(of: &curve.mmr_order) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: UInt8.self)[piece] = v
        }
    }

    private func setMMRConstant(_ curve: inout AVDOVIReshapingCurve, _ piece: Int, _ v: Int64) {
        withUnsafeMutableBytes(of: &curve.mmr_constant) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: Int64.self)[piece] = v
        }
    }

    private func setPolyCoef(_ curve: inout AVDOVIReshapingCurve, _ piece: Int,
                             _ k: Int, _ v: Int64) {
        withUnsafeMutableBytes(of: &curve.poly_coef) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: Int64.self)[piece * 3 + k] = v
        }
    }

    private func setMMRCoef(_ curve: inout AVDOVIReshapingCurve, _ piece: Int,
                            _ order: Int, _ k: Int, _ v: Int64) {
        withUnsafeMutableBytes(of: &curve.mmr_coef) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: Int64.self)[(piece * 3 + order) * 7 + k] = v
        }
    }

    private func setRGBToLms(_ color: inout AVDOVIColorMetadata, _ index: Int,
                             num: Int32, den: Int32) {
        withUnsafeMutableBytes(of: &color.rgb_to_lms_matrix) { raw in
            UnsafeMutableRawBufferPointer(raw).bindMemory(to: AVRational.self)[index]
                = AVRational(num: num, den: den)
        }
    }

    // MARK: - Fixture builder

    /// Builds an AVDOVIMetadata-shaped memory block (header | mapping | color)
    /// the same way `av_dovi_metadata_alloc` lays it out, runs the parser and
    /// frees the block. Returns the parsed curve.
    private func parse(_ configure: (inout AVDOVIRpuDataHeader,
                                     inout AVDOVIDataMapping,
                                     inout AVDOVIColorMetadata) -> Void) -> DoviReshapingCurve? {
        var hdr = AVDOVIRpuDataHeader()
        var mapping = AVDOVIDataMapping()
        var color = AVDOVIColorMetadata()
        configure(&hdr, &mapping, &color)

        let metaSize = MemoryLayout<AVDOVIMetadata>.stride
        let hdrSize = MemoryLayout<AVDOVIRpuDataHeader>.stride
        let mapSize = MemoryLayout<AVDOVIDataMapping>.stride
        let colSize = MemoryLayout<AVDOVIColorMetadata>.stride
        let alignment = MemoryLayout<AVDOVIMetadata>.alignment
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: metaSize + hdrSize + mapSize + colSize,
                                                      alignment: alignment)
        defer { buffer.deallocate() }

        // av_dovi_metadata_alloc layout: the metadata struct comes first and
        // its offset fields are relative to the struct itself.
        var meta = AVDOVIMetadata()
        meta.header_offset = metaSize
        meta.mapping_offset = metaSize + hdrSize
        meta.color_offset = metaSize + hdrSize + mapSize

        buffer.copyMemory(from: &meta, byteCount: metaSize)
        buffer.advanced(by: metaSize).copyMemory(from: &hdr, byteCount: hdrSize)
        buffer.advanced(by: metaSize + hdrSize).copyMemory(from: &mapping, byteCount: mapSize)
        buffer.advanced(by: metaSize + hdrSize + mapSize).copyMemory(from: &color, byteCount: colSize)

        return FFmpegVideoDecoder.parseDoviReshapingCurve(
            buffer.assumingMemoryBound(to: AVDOVIMetadata.self))
    }

    /// Default header: 12-bit base layer, Q13 fixed-point coefficients
    /// (coef_log2_denom = 13 → scale 1/8192), like real-world P5 RPUs.
    private func defaultHeader(_ hdr: inout AVDOVIRpuDataHeader) {
        hdr.bl_bit_depth = 12
        hdr.coef_log2_denom = 13
    }

    /// Wire every component with a single polynomial piece `s' = 1·s`
    /// (identity) and `n` pivots — the minimal well-formed mapping.
    private func identityPolyMapping(_ mapping: inout AVDOVIDataMapping, pivots: [UInt16]) {
        withCurves(&mapping) { curves in
            for c in 0..<3 {
                curves[c].num_pivots = UInt8(pivots.count)
                setPivots(&curves[c], pivots)
                setMappingIDC(&curves[c], 0, AV_DOVI_MAPPING_POLYNOMIAL)
                setPolyOrder(&curves[c], 0, 1)
                setPolyCoef(&curves[c], 0, 0, 0)
                setPolyCoef(&curves[c], 0, 1, 8192)
                setPolyCoef(&curves[c], 0, 2, 0)
            }
        }
    }

    // MARK: - Conversion

    func testPivotNormalizationUsesBLBitDepth() throws {
        var hdr = AVDOVIRpuDataHeader()
        var mapping = AVDOVIDataMapping()
        var color = AVDOVIColorMetadata()
        defaultHeader(&hdr)
        withCurves(&mapping) { curves in
            curves[0].num_pivots = 2
            setPivots(&curves[0], [0, 4095])
            curves[1].num_pivots = 2
            setPivots(&curves[1], [2048, 4095])
            curves[2].num_pivots = 2
            setPivots(&curves[2], [0, 4095])
            for c in 0..<3 {
                setMappingIDC(&curves[c], 0, AV_DOVI_MAPPING_POLYNOMIAL)
                setPolyOrder(&curves[c], 0, 1)
                setPolyCoef(&curves[c], 0, 1, 8192)
            }
        }
        for i in 0..<9 { setRGBToLms(&color, i, num: Int32(i % 4 == 0 ? 1 : 0), den: 1) }

        let curve = try XCTUnwrap(parse { h, m, c in h = hdr; m = mapping; c = color })
        XCTAssertEqual(curve.components[0].pivots, [0, 1])
        XCTAssertEqual(curve.components[1].pivots[0], 2048.0 / 4095.0, accuracy: 1e-6)
    }

    func testPolynomialCoefficientConversion() throws {
        var hdr = AVDOVIRpuDataHeader()
        var mapping = AVDOVIDataMapping()
        var color = AVDOVIColorMetadata()
        defaultHeader(&hdr)
        withCurves(&mapping) { curves in
            for c in 0..<3 {
                curves[c].num_pivots = 2
                setPivots(&curves[c], [0, 4095])
                setMappingIDC(&curves[c], 0, AV_DOVI_MAPPING_POLYNOMIAL)
                setPolyOrder(&curves[c], 0, 2)
                // Q13: 8192 → 1.0 → coefficients (0, 0.5, 1.0).
                setPolyCoef(&curves[c], 0, 0, 0)
                setPolyCoef(&curves[c], 0, 1, 4096)
                setPolyCoef(&curves[c], 0, 2, 8192)
            }
        }
        for i in 0..<9 { setRGBToLms(&color, i, num: Int32(i % 4 == 0 ? 1 : 0), den: 1) }

        let curve = try XCTUnwrap(parse { h, m, c in h = hdr; m = mapping; c = color })
        for c in 0..<3 {
            let piece = try XCTUnwrap(curve.components[c].pieces.first)
            XCTAssertFalse(piece.isMMR)
            XCTAssertEqual(piece.polyCoef.x, 0, accuracy: 1e-6)
            XCTAssertEqual(piece.polyCoef.y, 0.5, accuracy: 1e-6)
            XCTAssertEqual(piece.polyCoef.z, 1.0, accuracy: 1e-6)
        }
    }

    func testMMRCoefficientConversionWithConstant() throws {
        var hdr = AVDOVIRpuDataHeader()
        var mapping = AVDOVIDataMapping()
        var color = AVDOVIColorMetadata()
        defaultHeader(&hdr)
        withCurves(&mapping) { curves in
            for c in 0..<3 {
                curves[c].num_pivots = 2
                setPivots(&curves[c], [0, 4095])
                setMappingIDC(&curves[c], 0, AV_DOVI_MAPPING_MMR)
                setMMROrder(&curves[c], 0, 2)
                setMMRConstant(&curves[c], 0, 8192)                // Q13 → 1.0
                setMMRCoef(&curves[c], 0, 0, c, 4096)            // Q13 → 0.5
                setMMRCoef(&curves[c], 0, 1, 0, 2048)            // Q13 → 0.25
            }
        }
        for i in 0..<9 { setRGBToLms(&color, i, num: Int32(i % 4 == 0 ? 1 : 0), den: 1) }

        let curve = try XCTUnwrap(parse { h, m, c in h = hdr; m = mapping; c = color })
        for c in 0..<3 {
            let piece = try XCTUnwrap(curve.components[c].pieces.first)
            XCTAssertTrue(piece.isMMR)
            XCTAssertEqual(piece.mmrOrder, 2)
            XCTAssertEqual(piece.mmrConstant, 1.0, accuracy: 1e-6)
            XCTAssertEqual(piece.mmrCoef[0][c], 0.5, accuracy: 1e-6)
            XCTAssertEqual(piece.mmrCoef[1][0], 0.25, accuracy: 1e-6)
        }
    }

    func testRGBToLmsMatrixFromColorBlock() throws {
        var hdr = AVDOVIRpuDataHeader()
        var mapping = AVDOVIDataMapping()
        var color = AVDOVIColorMetadata()
        defaultHeader(&hdr)
        identityPolyMapping(&mapping, pivots: [0, 4095])
        // Diagonal 0.5 (1/2 rationals).
        for i in 0..<9 { setRGBToLms(&color, i, num: Int32(i % 4 == 0 ? 1 : 0), den: 2) }

        let curve = try XCTUnwrap(parse { h, m, c in h = hdr; m = mapping; c = color })
        let m = try XCTUnwrap(curve.rgbToLms)
        XCTAssertEqual(m[0][0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(m[1][1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(m[0][1], 0, accuracy: 1e-9)
    }

    func testAllZeroColorBlockYieldsNil() {
        // No color ext block (all-zero matrix): the reshape decode chain is
        // undefined — the parser must refuse so the frame stays on the
        // geometric approximation path.
        let curve = parse { hdr, mapping, _ in
            defaultHeader(&hdr)
            identityPolyMapping(&mapping, pivots: [0, 4095])
        }
        XCTAssertNil(curve)
    }

    func testMappingWithoutPiecesYieldsNil() {
        // num_pivots = 0 on every component: nothing to reshape.
        let curve = parse { hdr, _, _ in
            defaultHeader(&hdr)
        }
        XCTAssertNil(curve)
    }
}
