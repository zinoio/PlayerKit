import AVFoundation
import Foundation

/// Main playback control protocol. All UI-facing playback goes through this.
@MainActor
public protocol Playable: AnyObject {
    /// Current playback state. UI binds to this.
    var state: PlayerState { get }

    /// Called when state changes. UI subscribes here instead of polling.
    var onStateChange: ((PlayerState) -> Void)? { get set }

    /// Start or restart playback at the given URL.
    /// - Parameters:
    ///   - url: Media URL (local file, HTTP, or custom scheme).
    ///   - headers: HTTP headers sent with the request.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration?)

    /// Start playback using a custom I/O reader instead of a URL.
    /// The reader feeds bytes to ffmpeg via avio_alloc_context,
    /// bypassing ffmpeg's built-in HTTP protocol layer.
    /// - Parameters:
    ///   - reader: Random-access byte stream reader.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    func play(reader: any MediaRandomAccessReader,
              seekTo: Duration?,
              knownDuration: Duration?)

    /// Start playback by concatenating multiple URLs into a single stream.
    /// Uses ffmpeg's concat demuxer to virtually stitch clips together,
    /// enabling precise seek across clip boundaries (BDMV disc playback).
    /// - Parameters:
    ///   - urls: Ordered list of media URLs (clip files).
    ///   - headers: HTTP headers sent with each request.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    func play(concatURLs: [URL], headers: [String: String],
              seekTo: Duration?, knownDuration: Duration?)

    /// Start playback of an ordered sequence of custom-I/O clip readers as
    /// one continuous presentation timeline (BDMV disc playback). Unlike
    /// `play(concatURLs:)` (ffmpeg concat demuxer, URL-openable inputs),
    /// each clip's bytes come from a `MediaRandomAccessReader` that ffmpeg
    /// cannot open by protocol — the backend demuxes each clip separately
    /// and rebases PTS onto a continuous timeline.
    /// - Parameters:
    ///   - clips: Ordered clips; each carries the clip's reader and its own
    ///     real duration (caller-supplied, e.g. from BD playlist metadata).
    ///     Must be non-empty with all durations > 0.
    ///   - seekTo: Optional start position (global timeline).
    ///   - knownDuration: Pre-known total duration, skips probe if non-nil.
    func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
              seekTo: Duration?,
              knownDuration: Duration?)

    /// Pause playback. Call `resume()` to continue.
    func pause()

    /// Resume from paused state.
    func resume()

    /// Seek to a specific position.
    func seek(to: Duration)

    /// Stop playback and release resources.
    func stop()

    /// Set volume (0.0 = silent, 1.0 = unity).
    func setVolume(_ volume: Double)

    /// Set playback rate (1.0 = normal, 2.0 = double speed).
    func setRate(_ rate: Double)

    /// Select an audio track by its identifier.
    func selectAudioTrack(id: String)

    /// Select a subtitle track, or pass nil to disable subtitles.
    func selectSubtitle(id: String?)

    /// 被动解码音频旁路:每解码一段音频回调一次(交错 float32,后台解码队列
    /// 上同步调用,不得阻塞)。默认实现为 no-op;支持的后端(NativeBackend)
    /// 覆盖。见扩展里的完整回调约定。
    var onDecodedAudio: ((_ pcm: Data, _ channels: Int, _ sampleRate: Double, _ pts: Double) -> Void)? { get set }
}

extension Playable {
    /// Manually trigger an onStateChange notification with the current state.
    public func notifyStateChange() {
        onStateChange?(state)
    }

    /// 被动解码音频旁路(通用能力):每解码一段音频就回调一次,供上层做音频
    /// 分析(如片头片尾特征采集)而无需额外下载/解码。默认 nil = 后端不支持
    /// 或未订阅,零开销。NativeBackend 覆盖此实现;回调约定:
    ///  - `pcm` 为交错 float32(声道数/采样率随参数给出,解码器输出格式);
    ///  - 在音频解码队列(后台)上同步调用,不得阻塞;需要留存请拷贝;
    ///  - `pts` 是该段在内容时间轴上的秒,无法确定时为 NaN(消费方按 PTS 分窗);
    ///  - 暂停/seek 后不保证连续。
    public var onDecodedAudio: ((_ pcm: Data, _ channels: Int, _ sampleRate: Double, _ pts: Double) -> Void)? {
        get { nil }
        set {}
    }
}
