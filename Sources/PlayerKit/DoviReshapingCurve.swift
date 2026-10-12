import Foundation
import simd

/// P5/P8 Dolby Vision RPU reshaping curve (CTA-861.3 / ST 2082-10 §H.13.4).
///
/// Copied per-frame from FFmpeg's `AVDOVIMetadata.mapping` by
/// `FFmpegVideoDecoder`, with the fixed-point coefficients converted to float
/// exactly like libplacebo's `pl_map_dovi_metadata`:
///
///   - pivots:  `p / ((1 << bl_bit_depth) - 1)`   (normalized to [0, 1])
///   - coeffs:  `v / (1 << coef_log2_denom)`      (signed fixed-point)
///
/// A `nil` value on `FrameMetadata.doviReshape` means "no usable reshape
/// data" — consumers must fall back to the existing IPT geometric
/// approximation chain (DolbyVisionColorSignal).
public struct DoviReshapingCurve: Sendable, Equatable {

    /// One mapping piece, spanning `[pivots[i], pivots[i+1])` of component *c*.
    public struct Piece: Sendable, Equatable {
        /// `mapping_idc == 1` (matrix mapping); `false` = polynomial.
        public var isMMR: Bool
        /// Polynomial coefficients `(c0, c1, c2)`: `s = (c2·s + c1)·s + c0`.
        /// `polyOrder == 1` leaves `c2 = 0`.
        public var polyCoef: SIMD3<Float>
        /// MMR order (1...3). Unused for polynomial pieces.
        public var mmrOrder: Int
        /// MMR constant term. Unused for polynomial pieces.
        public var mmrConstant: Float
        /// MMR coefficients `[order][7]`: `k = 0..2` weight the linear terms
        /// `(sx, sy, sz)`, `k = 3..6` weight the cross terms
        /// `(sx·sy, sx·sz, sy·sz, sx·sy·sz)`. Unused for polynomial pieces.
        public var mmrCoef: [[Float]]

        public init(isMMR: Bool,
                    polyCoef: SIMD3<Float> = .zero,
                    mmrOrder: Int = 0,
                    mmrConstant: Float = 0,
                    mmrCoef: [[Float]] = []) {
            self.isMMR = isMMR
            self.polyCoef = polyCoef
            self.mmrOrder = mmrOrder
            self.mmrConstant = mmrConstant
            self.mmrCoef = mmrCoef
        }
    }

    /// Per-component curve: ascending pivots (normalized [0, 1]) and
    /// `pivots.count - 1` mapping pieces.
    public struct Component: Sendable, Equatable {
        public var pivots: [Float]
        public var pieces: [Piece]

        public init(pivots: [Float], pieces: [Piece]) {
            self.pivots = pivots
            self.pieces = pieces
        }
    }

    /// Exactly 3 entries (I / P / T).
    public var components: [Component]
    /// `rgb_to_lms_matrix` from the RPU color ext block (row-major 3×3).
    /// The reshape output decodes through `hpeLms2rgb × rgbToLms` — not a
    /// pure constant (see DolbyVisionReshape.decodeShaped).
    public var rgbToLms: [[Float]]?

    public init(components: [Component], rgbToLms: [[Float]]?) {
        self.components = components
        self.rgbToLms = rgbToLms
    }
}
