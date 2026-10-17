import AVFoundation
import Foundation

/// Audio output backend. Implementations handle PCM rendering or compressed passthrough.
public protocol AudioOutputBackend: AnyObject {
    /// Whether this backend supports compressed audio passthrough (AC3/DTS/Atmos).
    var supportsPassthrough: Bool { get }
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

    /// 指定输出设备(macOS;CoreAudio 设备 UID),nil = 跟随系统默认输出。
    /// 后端应在**下一次**开始输出时生效(调用方随后会重建音频路径)。
    /// 默认空实现:iOS/tvOS 的输出路由由系统管理,不适用。
    func setOutputDevice(uid: String?)
}

public extension AudioOutputBackend {
    /// Default: output routing is system-managed (iOS/tvOS) or unsupported.
    func setOutputDevice(uid: String?) {}
    /// Default: no playback clock — NativeBackend falls back to its AudioClock.
    var playbackTime: Double? { nil }
    /// Default: rate is ignored (no real clock or no tempo support). Backends
    /// that consume PCM at a device-fixed rate implement this so their
    /// content-time accounting converts consumed OUTPUT samples back to
    /// CONTENT samples (playback rate ≠ output sample rate).
    func setPlaybackRate(_ rate: Double) {}
}
