import Foundation

/// User preference for how Dolby Vision streams reach the screen.
///
/// `.system` (default): when the platform/display/strategy allows it, the
/// compressed HEVC bitstream is handed to the system decoder via
/// `AVSampleBufferDisplayLayer`, and the system's display management performs
/// the DV mapping (design §5.1). `.software`: the legacy pipeline — FFmpeg
/// software decode + in-app tone-map — is used unconditionally for DV.
///
/// Changing the preference requires reopening the playback chain; the player
/// surface decides when to rebuild (see reflux `PlayerController`).
public enum DolbyVisionOutputPreference: Sendable, Equatable {
    /// Native system DV passthrough (macOS EDR; iOS currently unavailable).
    case system
    /// Software decode + DV RPU rendering (quality first; current Pro path).
    case software
    /// Smoothness first (2026-11-07): VT hardware-decodes the base layer and
    /// the renderer shows the compatibility layer (HDR10/HLG/SDR), dropping DV
    /// dynamic metadata. P5 has no HDR10-compatible base layer and deliberately
    /// stays on the software path. See
    /// `docs/superpowers/specs/2026-11-07-dv-hardware-fallback-design.md`.
    case hardwareHDR10
}

/// Which pipeline carries video to the renderer.
///
/// `.decodedFrames` — the classic pipeline: decoder produces `CVPixelBuffer`s,
/// frames travel through the jitter buffer to a `VideoRenderer`.
/// `.compressedPassthrough` — the native DV system path: no in-app decode at
/// all; compressed samples go straight to `AVSampleBufferDisplayLayer` and the
/// system owns decoding and display management.
public enum VideoPipeline: Sendable, Equatable {
    case decodedFrames
    case compressedPassthrough
}

/// Policy constants for the native DV system path. Kept in one place so the
/// eligibility rules have a single reviewable home (design §5.1, §9).
public enum SystemDVPolicy {

    /// P8 compat ids allowed onto the system path in v1. **Decision**: only
    /// compat id 1 (backward-compatible HDR10 base, P8.1) — the 2026-10-27
    /// spike validated exactly this shape. 8.4 (HLG, id 4) and 8.2 (SDR, id 2)
    /// await real-world samples and their own verification (design V7).
    public static let eligibleP8CompatIds: Set<UInt8> = [1]

    /// Whether a DV stream (profile, P8 compat id) is eligible for the system
    /// path at all — independent of display/preference conditions, which the
    /// strategy layer checks separately.
    ///
    /// - Parameter convertedP7CompatId: 非 nil = 该 P7 已被数据管线转换为该
    ///   compat id(一期固定 1,设计 D6)。只有转换态 P7 才允许进系统路径;
    ///   未转换 P7 维持 `degradedHDR10`(D7)。
    public static func isEligible(profile: UInt8, compatId: UInt8,
                                  convertedP7CompatId: UInt8? = nil) -> Bool {
        if profile == 7 {
            return convertedP7CompatId.map { eligibleP8CompatIds.contains($0) } ?? false
        }
        switch profile {
        case 5:  return true
        case 8:  return eligibleP8CompatIds.contains(compatId)
        default: return false
        }
    }

    /// Phase 2 route b(iOS / tvOS)流资格判定:仅放行含 HDR10 兼容基础层的
    /// P8.1(`compatId == 1`)与转换态 P7(`convertedP7CompatId == 1`)。
    /// P5 基础层为 IPT 非 PQ/BT.2020,保持软件 IPT 纠色路径。
    public static func isRouteBEligible(profile: UInt8, compatId: UInt8,
                                        convertedP7CompatId: UInt8? = nil) -> Bool {
        if profile == 7 {
            return convertedP7CompatId.map { eligibleP8CompatIds.contains($0) } ?? false
        }
        return profile == 8 && eligibleP8CompatIds.contains(compatId)
    }

    /// P7 转换态 open 后的逐帧 RPU 校验窗口:开头 N 帧全无有效 RPU → 判路由
    /// 失误,回 `degradedHDR10`(设计 §4.3)。单帧畸形只降级该帧,不 reopen。
    public static let rpuValidationFrames = 8

    public static func shouldFallbackAfterRpuValidation(validFrames: Int,
                                                        checkedFrames: Int) -> Bool {
        checkedFrames >= rpuValidationFrames && validFrames == 0
    }
}

/// Snapshot of whether the current platform + display can take the native DV
/// system path. Constructed by `NativeBackend` at open time (and refreshed on
/// display-configuration changes) and passed into `decideRendererStrategy`.
///
/// phase 3 (design §8, 2026-11-05 spike): iOS/tvOS join macOS — the probe now
/// follows the display EDR snapshot on all three platforms. The on-device
/// validation runs under the spike criteria in reflux `Docs/dolby-testing.md`
/// (§ spike, zinoio/zinora#390). Failure stays safe by construction: if the
/// iOS/tvOS system decoder refuses the `dvh1` declaration, the existing
/// first-frame timeout / `fallbackToSoftwareDV` returns to the software path
/// (once per session, position preserved). Non-EDR displays remain
/// conservative — unknown system behavior on SDR panels (design V2). Device
/// qualification beyond EDR (`AVPlayer.availableHDRModes` etc.) is planned as
/// a follow-up tightening once the spike lands (reflux PR #466, design §3b).
public struct SystemDVCapability: Sendable, Equatable {

    public var isAvailable: Bool

    /// Phase 2 route b(iOS / tvOS):VT 10-bit 硬解基础层 + 逐帧挂
    /// `DolbyVisionRPUData` / `DolbyCompatibilityID` 附件交由
    /// `AVSampleBufferDisplayLayer` 系统呈现。
    public var supportsRouteB: Bool

    public init(isAvailable: Bool, supportsRouteB: Bool = false) {
        self.isAvailable = isAvailable
        self.supportsRouteB = supportsRouteB
    }

    /// Sentinel for "system DV path not usable here" — also the default value
    /// of `decideRendererStrategy(systemDolbyVision:)`, keeping every existing
    /// call site on the software path.
    public static let unavailable = SystemDVCapability(isAvailable: false, supportsRouteB: false)

    /// Probe from a display capability snapshot.
    /// - macOS: EDR-capable displays use `isAvailable` (compressed passthrough).
    /// - iOS / tvOS: compressed passthrough is unavailable (7-round spike proved
    ///   black screen on iOS 26 full-screen), while `supportsRouteB` follows
    ///   `display.supportsEDR` (Phase 2 decoded-frame + RPU attachment path).
    public static func probe(display: DisplayCapability) -> SystemDVCapability {
#if os(macOS)
        return SystemDVCapability(isAvailable: display.supportsEDR, supportsRouteB: false)
#else
        return SystemDVCapability(isAvailable: false, supportsRouteB: display.supportsEDR)
#endif
    }
}
