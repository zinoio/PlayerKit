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
    public static func isEligible(profile: UInt8, compatId: UInt8) -> Bool {
        switch profile {
        case 5:  return true
        case 8:  return eligibleP8CompatIds.contains(compatId)
        default: return false
        }
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

    public init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    /// Sentinel for "system DV path not usable here" — also the default value
    /// of `decideRendererStrategy(systemDolbyVision:)`, keeping every existing
    /// call site on the software path.
    public static let unavailable = SystemDVCapability(isAvailable: false)

    /// Probe from a display capability snapshot. macOS: EDR-capable displays
    /// qualify. **iOS/tvOS: `.unavailable`(2026-11-06 spike 定案)**——七轮真机
    /// 证实 iOS 全屏 in-app 对压缩 DV 直通(dvh1)合成黑帧(与 DV 声明无关,
    /// PiP 可用),管线其余部分全绿;压缩直通路线定案不可行,iPhone 真 DV
    /// 唯一路线 = route b(解码帧+RPU 附件),届时按其结论重开本探针。
    /// 详见 reflux PR #466/#472 设计稿 §7(七轮判读)。
    /// Note (design §5.4): the result must be re-derived when the display
    /// configuration changes — the display-change notification flow (macOS)
    /// handles that, no extra observer here.
    public static func probe(display: DisplayCapability) -> SystemDVCapability {
#if os(macOS)
        return SystemDVCapability(isAvailable: display.supportsEDR)
#else
        return .unavailable
#endif
    }
}
