import AVFoundation
import Foundation

/// Audio output backend. Implementations handle PCM rendering or compressed passthrough.
public protocol AudioOutputBackend: AnyObject {
    /// Whether this backend supports compressed audio passthrough (AC3/DTS/Atmos).
    var supportsPassthrough: Bool { get }
    /// Whether this backend consumes decoded PCM buffers via `outputPCM`.
    /// True for the open-source AudioUnitOutput and PRO DSPOutput; false for
    /// PassthroughOutput (compressed bitstream only). NativeBackend routes
    /// decoded PCM to the injected backend only when this is true — otherwise
    /// the packets fall through to the built-in AudioUnitOutput path, which
    /// also keeps the zyno#105 passthrough runtime fallback (bitstream route
    /// fails → PCM decode) audible instead of silently dropped.
    var acceptsPCM: Bool { get }
    /// Buffered audio duration in seconds.
    var bufferedDuration: Double { get }

    /// Configure the output for a given stream.
    func configure(streamInfo: AudioStreamInfo) async throws

    /// Output a decoded PCM buffer. Implemented by the open-source AudioUnitOutput.
    func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double)

    /// Output a compressed audio packet. PRO PassthroughOutput implements this.
    /// The open-source AudioUnitOutput treats this as a no-op.
    func outputCompressed(_ packet: Data, pts: Double, codec: String)

    /// Current media playback position in seconds, if this backend maintains a
    /// real playback clock (e.g. an AVSampleBufferRenderSynchronizer timebase).
    ///
    /// Non-nil providers become the master A/V sync clock in NativeBackend's
    /// display loop. This matters for passthrough mode: there the PCM
    /// AudioClock never runs (audio is not decoded), and without a real
    /// reference the display loop free-wheels at decode speed — MKV/DTS
    /// sources played at ~2-3x. Nil (the default) leaves pacing on AudioClock.
    var playbackTime: Double? { get }

    func flush()
    func pause()
    func resume()
}

public extension AudioOutputBackend {
    /// Default: consumes PCM (AudioUnitOutput, DSPOutput). PassthroughOutput
    /// overrides to false.
    var acceptsPCM: Bool { true }
    /// Default: no playback clock — NativeBackend falls back to its AudioClock.
    var playbackTime: Double? { nil }
    /// Default: rate is ignored (no real clock or no tempo support). Backends
    /// that consume PCM at a device-fixed rate implement this so their
    /// content-time accounting converts consumed OUTPUT samples back to
    /// CONTENT samples (playback rate ≠ output sample rate).
    func setPlaybackRate(_ rate: Double) {}
    /// Default: volume is state-only (NativeBackend records it in
    /// `state.volume`). PCM 后端(AudioUnitOutput)覆盖以真正衰减输出增益;
    /// 码流直通(PassthroughOutput)物理上无法对已编码码流做音量,维持
    /// no-op——state 仍记录、UI 可显示,听感不变(透传时音量交由功放)。
    /// 0.0 = 静音,1.0 = 原始增益。
    func setVolume(_ volume: Double) {}
}
