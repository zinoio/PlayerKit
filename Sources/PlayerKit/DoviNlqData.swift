import Foundation
import simd

/// Dolby Vision Profile 7 Non-Linear Inverse Quantization (NLQ) parameters
/// (ETSI GS CCM 001 / libplacebo `pl_dovi_nlq`).
///
/// Extracted per-frame from FFmpeg's `AVDOVIMetadata` (`AVDOVIDataMapping.nlq[0..2]`)
/// with fixed-point coefficients normalized identically to `DoviReshapingCurve`:
///   - `offset`:    `nlq_offset / ((1 << el_bit_depth) - 1)`
///   - `vdrInMax`:  `vdr_in_max / (1 << coef_log2_denom)`
///   - `slope`:     `linear_deadzone_slope / (1 << coef_log2_denom)`
///   - `threshold`: `linear_deadzone_threshold / (1 << coef_log2_denom)`
///
/// A `nil` value on `FrameMetadata.doviNlq` (or `isMEL == true`) means no
/// active FEL residual — renderers fall back bit-for-bit to the reshape chain.
public struct DoviNlqData: Sendable, Equatable {

    public struct Component: Sendable, Equatable {
        public var offset: Float
        public var vdrInMax: Float
        public var slope: Float
        public var threshold: Float

        public init(offset: Float, vdrInMax: Float, slope: Float, threshold: Float) {
            self.offset = offset
            self.vdrInMax = vdrInMax
            self.slope = slope
            self.threshold = threshold
        }
    }

    /// Exactly 3 components (Y/I, Cb/P, Cr/T).
    public var components: [Component]
    /// Enhancement layer bit depth (typically 10).
    public var elBitDepth: UInt8

    public init(components: [Component], elBitDepth: UInt8 = 10) {
        self.components = components
        self.elBitDepth = elBitDepth
    }

    /// Minimal Enhancement Layer (zero residual): offset, slope, and threshold
    /// are all zero across all 3 components.
    public var isMEL: Bool {
        components.count == 3 && components.allSatisfy {
            $0.offset == 0 && $0.slope == 0 && $0.threshold == 0
        }
    }
}

/// CPU reference mirror of libplacebo `pl_shader_dovi_nlq` (Linear Deadzone).
/// Used by unit tests and `PlayerKitPro.DoViNlqShaderTests` GPU e2e parity checks.
public enum DolbyVisionNlq {

    /// Single-component ETSI GS CCM 001 Linear Deadzone inverse quantization:
    /// - `r = el - offset`
    /// - `r == 0` → `0`
    /// - else → `clamp(sign(r) * (|r| * slope + threshold), -vdrInMax, vdrInMax)`
    public static func residual(_ el: Float, params: DoviNlqData.Component) -> Float {
        let r = el - params.offset
        if r == 0 { return 0 }
        let mag = abs(r) * params.slope + params.threshold
        let d = r > 0 ? mag : -mag
        return min(max(d, -params.vdrInMax), params.vdrInMax)
    }

    /// Combine reshaped BL signal with NLQ-dequantized EL signal, clamped to `[0, 1]`.
    /// Returns `blSignal` unchanged when `elSignal` is nil, `nlq` is MEL, or malformed.
    public static func combine(blSignal: SIMD3<Float>,
                               elSignal: SIMD3<Float>?,
                               nlq: DoviNlqData) -> SIMD3<Float> {
        guard let el = elSignal, nlq.components.count == 3, !nlq.isMEL else {
            return blSignal
        }
        return SIMD3(
            min(max(blSignal.x + residual(el.x, params: nlq.components[0]), 0), 1),
            min(max(blSignal.y + residual(el.y, params: nlq.components[1]), 0), 1),
            min(max(blSignal.z + residual(el.z, params: nlq.components[2]), 0), 1)
        )
    }
}
