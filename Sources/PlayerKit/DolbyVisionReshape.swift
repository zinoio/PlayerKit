import Foundation
import simd

/// Dolby Vision RPU reshaping — CPU reference implementation.
///
/// `apply(_:)` is a line-by-line transposition of libplacebo's
/// `pl_shader_dovi_reshape` (shaders/colorspace.c), the only large-scale
/// validated runtime consumer of the RPU reshape. Semantics that are easy to
/// get wrong (all verified against the libplacebo source, verbatim):
///
///   - `sig = clamp(rgb, 0, 1)` is computed **once** and never updated during
///     the component loop — MMR cross terms always see the raw code-domain
///     channels, *not* the reshaped values of previous components.
///   - Piece selection: piece *i* covers `[pivots[i], pivots[i+1])`, i.e. the
///     largest *i* with `s >= pivots[i+1]` (libplacebo does this branchlessly
///     with a 1e9 sentinel pivot; a loop is equivalent for ≤8 pieces).
///   - Polynomial: `s = (c2·s + c1)·s + c0`.
///   - MMR: `sigX = (sx·sy, sx·sz, sy·sz, sx·sy·sz)`; per order *j* two packed
///     dot products — linear terms against `sig`, cross terms against `sigX`;
///     higher orders square the term vectors (`sig²`, `sigX²`, `sig²·sig`,
///     `sigX²·sigX`).
///   - Output clamps to `[pivots.first, pivots.last]` per component.
///   - A component with no pieces passes through untouched.
///
/// `decodeShaped(_:)` mirrors libplacebo's `PL_COLOR_SYSTEM_DOLBYVISION`
/// decode case: PQ EOTF → (`hpeLms2rgb × rgbToLms`) matrix → PQ OETF,
/// yielding a BT.2020-PQ-encoded signal that feeds the regular tone-map
/// pipeline. The matrix is the product of the hard-coded HPE LMS→RGB constant
/// and the per-stream `rgb_to_lms_matrix` carried in the RPU color block —
/// not a pure constant.
///
/// This type is pure color science, no rendering dependencies: it is the unit
/// test baseline and the mirror the GPU shaders (PlayerKitPro) assert against.
public enum DolbyVisionReshape {

    /// Evaluate the reshape curves for one pixel. `signal` is the IPTPQc2
    /// code-domain triplet normalized to [0, 1].
    public static func apply(_ curve: DoviReshapingCurve,
                             signal: SIMD3<Float>) -> SIMD3<Float> {
        let one = SIMD3<Float>(repeating: 1)
        let sig = simd_clamp(signal, .zero, one)
        var out = signal

        for c in 0..<min(3, curve.components.count) {
            let comp = curve.components[c]
            guard !comp.pieces.isEmpty else { continue }   // num_pivots == 0: passthrough
            var s = sig[c]

            var idx = 0
            for i in 0..<(comp.pieces.count - 1) where s >= comp.pivots[i + 1] {
                idx = i + 1
            }
            let piece = comp.pieces[idx]

            if piece.isMMR {
                let sx = sig.x, sy = sig.y, sz = sig.z
                let sigX = SIMD4<Float>(sx * sy, sx * sz, sy * sz, sx * sy * sz)
                let coefs = piece.mmrCoef
                s = piece.mmrConstant
                // Order 1: linear + cross terms against the raw signal.
                s += coefs[0][0] * sx + coefs[0][1] * sy + coefs[0][2] * sz
                s += coefs[0][3] * sigX.x + coefs[0][4] * sigX.y
                     + coefs[0][5] * sigX.z + coefs[0][6] * sigX.w
                if piece.mmrOrder >= 2 {
                    let sig2 = sig * sig
                    let sigX2 = sigX * sigX
                    s += coefs[1][0] * sig2.x + coefs[1][1] * sig2.y + coefs[1][2] * sig2.z
                    s += coefs[1][3] * sigX2.x + coefs[1][4] * sigX2.y
                         + coefs[1][5] * sigX2.z + coefs[1][6] * sigX2.w
                }
                if piece.mmrOrder >= 3 {
                    let sig2 = sig * sig
                    let sigX2 = sigX * sigX
                    s += coefs[2][0] * sig2.x * sx + coefs[2][1] * sig2.y * sy
                         + coefs[2][2] * sig2.z * sz
                    s += coefs[2][3] * sigX2.x * sigX.x + coefs[2][4] * sigX2.y * sigX.y
                         + coefs[2][5] * sigX2.z * sigX.z + coefs[2][6] * sigX2.w * sigX.w
                }
            } else {
                let c0 = piece.polyCoef
                s = (c0.z * s + c0.y) * s + c0.x
            }

            out[c] = min(max(s, comp.pivots[0]), comp.pivots[comp.pivots.count - 1])
        }
        return out
    }

    /// Decode reshaped signal (normalized [0, 1]) to a BT.2020-PQ-encoded
    /// triplet, mirroring libplacebo's DOVI decode case (with the deliberate
    /// PQ round-trip so downstream tone-map chains stay untouched).
    /// `rgbToLms` is the row-major matrix from the RPU color block.
    public static func decodeShaped(_ shaped: SIMD3<Float>,
                                    rgbToLms: [[Float]]) -> SIMD3<Float> {
        let lin = SIMD3<Float>(pqEotf(shaped.x), pqEotf(shaped.y), pqEotf(shaped.z))
        // Row-major → column-major for simd_float3x3. 分步构造:旧工具链对
        // 内联三维字面量表达式会 type-check 超时(CI 实测)。
        let r = rgbToLms
        let rlCol0 = SIMD3<Float>(r[0][0], r[1][0], r[2][0])
        let rlCol1 = SIMD3<Float>(r[0][1], r[1][1], r[2][1])
        let rlCol2 = SIMD3<Float>(r[0][2], r[1][2], r[2][2])
        let rgbToLmsM = simd_float3x3(rlCol0, rlCol1, rlCol2)
        let hpeCol0 = SIMD3<Float>(3.06441879, -0.65612108, 0.01736321)
        let hpeCol1 = SIMD3<Float>(-2.16597676, 1.78554118, -0.04725154)
        let hpeCol2 = SIMD3<Float>(0.10155818, -0.12943749, 1.03004253)
        let hpeLms2rgb = simd_float3x3(hpeCol0, hpeCol1, hpeCol2)
        let rgb = hpeLms2rgb * (rgbToLmsM * lin)
        return SIMD3<Float>(pqOetf(rgb.x), pqOetf(rgb.y), pqOetf(rgb.z))
    }

    /// Hard-coded HPE LMS→BT.2020 matrix as row-major arrays (libplacebo
    /// `dovi_lms2rgb` verbatim — "Dolby Vision always outputs BT.2020-referred
    /// HPE LMS"). Exposed so the shader side (PlayerKitPro) mirrors constants.
    public static let hpeLms2rgbRowMajor: [[Double]] = [
        [3.06441879, -2.16597676, 0.10155818],
        [-0.65612108, 1.78554118, -0.12943749],
        [0.01736321, -0.04725154, 1.03004253],
    ]

    // MARK: - PQ (SMPTE ST 2084), Float precision, [0,1] ↔ [0,1] (1.0 = 10000 nits)

    private static func pqEotf(_ x: Float) -> Float {
        let m1 = Float(2610.0 / 16384.0)
        let m2 = Float(2523.0 / 4096.0 * 128.0)
        let c1 = Float(3424.0 / 4096.0)
        let c2 = Float(2413.0 / 4096.0 * 32.0)
        let c3 = Float(2392.0 / 4096.0 * 32.0)
        let xp = pow(max(x, 0), 1 / m2)
        return pow(max(xp - c1, 0) / (c2 - c3 * xp), 1 / m1)
    }

    private static func pqOetf(_ x: Float) -> Float {
        let m1 = Float(2610.0 / 16384.0)
        let m2 = Float(2523.0 / 4096.0 * 128.0)
        let c1 = Float(3424.0 / 4096.0)
        let c2 = Float(2413.0 / 4096.0 * 32.0)
        let c3 = Float(2392.0 / 4096.0 * 32.0)
        let yp = pow(max(x, 0), m1)
        return pow((c1 + c2 * yp) / (1 + c3 * yp), m2)
    }
}
