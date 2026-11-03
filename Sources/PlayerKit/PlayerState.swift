import Foundation
import CoreGraphics

/// Snapshot of current player state. Emitted on every change via onStateChange.
// @unchecked Sendable: currentSubtitleImage (CGImage) is only written on the main actor
// via NativeBackend.displayNextFrame / selectSubtitle, and read from SwiftUI body evaluation.
public struct PlayerState: @unchecked Sendable {
    /// Whether media is actively playing (not paused).
    public var isPlaying:   Bool     = false
    /// Whether the player is currently buffering.
    public var isBuffering: Bool     = false
    /// zyno#360: an audio-track switch is in progress (the backend is
    /// reconfiguring decoders/output; the picture may be stalled). Drives the
    /// player's "switching audio track" loading overlay.
    public var isSwitchingAudioTrack: Bool = false
    /// Total duration buffered and available for playback.
    public var bufferedDuration: Duration = .zero
    /// Current playback position.
    public var position:    Duration = .zero
    /// Total media duration, zero until known.
    public var duration:    Duration = .zero
    /// Current volume (0.0-1.0).
    public var volume:      Double   = 1.0
    /// Current playback rate.
    public var rate:        Double   = 1.0
    /// Non-nil when an error has occurred.
    public var error:       String?  = nil

    /// Available audio tracks.
    public var audioTracks:    [TrackInfo] = []
    /// Available subtitle tracks.
    public var subtitleTracks: [TrackInfo] = []
    /// Currently selected audio track ID, nil if default/auto.
    public var selectedAudioTrackId: Int? = nil
    /// Currently selected subtitle track ID, nil if none.
    public var selectedSubtitleTrackId: Int? = nil
    /// Text of the currently active subtitle cue, nil when no subtitle is showing.
    public var currentSubtitleText: String? = nil
    /// CGImage of the currently active bitmap subtitle cue (PGS/VOBSUB). Nil when no graphic subtitle is showing.
    public var currentSubtitleImage: CGImage? = nil
    /// Normalized position of currentSubtitleImage within the video frame (0...1 per axis, origin top-left).
    public var currentSubtitleImageRect: CGRect = .zero
    /// Current video stream info, nil until loaded.
    public var videoInfo:      VideoInfo?  = nil
    /// Cache download speed in bytes/second.
    public var cacheSpeed:     Int64       = 0
    /// Cumulative count of decoded video frames dropped before render
    /// (frames that fell behind audio and were drained), refreshed periodically
    /// by the backend. "Not due yet" sync denials are retries, not drops.
    public var droppedVideoFrames: Int64 = 0
    /// Frames dropped since the last diagnostics publish (~5s window).
    public var recentDroppedVideoFrames: Int64 = 0
    /// Drop rate over that publish window, in frames/second.
    public var droppedVideoFramesPerSecond: Double = 0
    /// Active video decode path, nil until a decoder is created or when the
    /// native Dolby Vision system path bypasses the decoder (P1 diagnostics).
    public var videoDecoderPath: VideoDecoderPath? = nil
    /// True when `videoInfo.bitrate` was filled by the demux EMA because the
    /// container did not declare a stream bitrate (P1 diagnostics).
    public var videoBitrateIsEstimated: Bool = false

    public init() {}
}

/// How video frames are currently being decoded (P1 diagnostics).
public enum VideoDecoderPath: String, Sendable {
    /// VideoToolbox hardware decoding (VTVideoDecoder or FFmpeg's VT path).
    case videoToolbox
    /// FFmpeg software decoding (including the VT→SW fallback).
    case ffmpegSoftware
}

/// Metadata for a single audio or subtitle track.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// Track index in the container.
    public let id: Int
    /// Human-readable track title.
    public let title: String?
    /// Language code (BCP 47 or ISO 639).
    public let lang: String?
    /// Codec name.
    public let codec: String?
    /// Whether this track is the default selection.
    public let isDefault: Bool
    /// Whether this audio track carries Dolby Atmos object metadata.
    public let isAtmos: Bool
    /// Audio channel count (e.g. 6 ≈ 5.1), nil when unknown.
    public var channels: Int?
    /// Audio sample rate in Hz, nil when unknown.
    public var sampleRate: Int?
    /// Bits per sample, nil when unknown.
    public var bitDepth: Int?
    /// Track bitrate in bits/second, nil when unknown.
    public var bitrate: Int64?

    public init(id: Int, title: String? = nil, lang: String? = nil,
                codec: String? = nil, isDefault: Bool = false, isAtmos: Bool = false,
                channels: Int? = nil, sampleRate: Int? = nil,
                bitDepth: Int? = nil, bitrate: Int64? = nil) {
        self.id = id
        self.title = title
        self.lang = lang
        self.codec = codec
        self.isDefault = isDefault
        self.isAtmos = isAtmos
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
    }
}

/// Info about the currently playing video stream.
public struct VideoInfo: Sendable, Equatable {
    /// Display width in pixels.
    public let width: Int
    /// Display height in pixels.
    public let height: Int
    /// Video codec name.
    public let codec: String?
    /// Whether the stream uses HDR.
    public let isHDR: Bool
    /// Color matrix (e.g. "bt.2020-ncl").
    public let colorMatrix: String?
    /// Transfer characteristic (e.g. "smpte2084").
    public let transfer: String?
    /// Whether the stream is Dolby Vision (profile 5/8/9 detected via DOVI_CONF side data).
    public let isDolbyVision: Bool
    /// Frame rate in fps (from avg_frame_rate), nil when unknown.
    public var fps: Double?
    /// Codec profile name (e.g. "Main 10"), nil when unknown.
    public var profile: String?
    /// Codec level as declared in the container, nil when unknown.
    public var level: Int?
    /// Stream bitrate in bits/second (container-declared, else rolling estimate), nil when unknown.
    public var bitrate: Int64?

    public init(width: Int, height: Int, codec: String? = nil,
                isHDR: Bool = false, colorMatrix: String? = nil,
                transfer: String? = nil, isDolbyVision: Bool = false,
                fps: Double? = nil, profile: String? = nil,
                level: Int? = nil, bitrate: Int64? = nil) {
        self.width = width
        self.height = height
        self.codec = codec
        self.isHDR = isHDR
        self.colorMatrix = colorMatrix
        self.transfer = transfer
        self.isDolbyVision = isDolbyVision
        self.fps = fps
        self.profile = profile
        self.level = level
        self.bitrate = bitrate
    }
}

/// Errors that can occur during player lifecycle.
public enum PlayerError: Error, Sendable {
    /// Initialization failed with a reason message.
    case initFailed(String)
    /// Render context creation failed.
    case renderContextFailed
    /// Media loading failed with a reason message.
    case loadFailed(String)
    /// Metal is not available on this device.
    case metalUnavailable
    /// Decoding failed for the given stream index.
    case decodeFailed(Int)
}
