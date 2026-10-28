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
    case system
    case software
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
/// v1 is macOS-only (design §8 phase 3): iOS/tvOS return `.unavailable` until
/// each platform passes its own on-device spike. Non-EDR displays are
/// conservative — unknown system behavior on SDR panels, so the software path
/// keeps handling DV there (design V2).
public struct SystemDVCapability: Sendable, Equatable {

    public var isAvailable: Bool

    public init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    /// Sentinel for "system DV path not usable here" — also the default value
    /// of `decideRendererStrategy(systemDolbyVision:)`, keeping every existing
    /// call site on the software path.
    public static let unavailable = SystemDVCapability(isAvailable: false)

    /// Probe from a display capability snapshot. macOS only; EDR-capable
    /// displays qualify. Note (design §5.4): the result must be re-derived when
    /// the display configuration changes — the existing display-change
    /// notification flow handles that, no extra observer here.
    public static func probe(display: DisplayCapability) -> SystemDVCapability {
#if os(macOS)
        return SystemDVCapability(isAvailable: display.supportsEDR)
#else
        return .unavailable
#endif
    }
}
