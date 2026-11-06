import AVFoundation
import Foundation
import QuartzCore
#if canImport(AVKit)
import AVKit
#endif

/// High-level player facade. Wraps a backend and exposes its state via @Observable.
@Observable
@MainActor
public final class Player {

    /// Current playback state. UI binds to this observable property.
    public var state = PlayerState()

    private let backend: any Playable

    /// Create a player with the given backend.
    /// - Parameter backend: A Playable-compliant backend (NativeBackend or MPVBackend).
    public init(backend: any Playable) {
        self.backend = backend
        backend.onStateChange = { [weak self] s in
            self?.state = s
            #if !os(tvOS)
            if #available(iOS 15.0, macOS 12.0, *) {
                if let info = s.videoInfo, info.width > 0, info.height > 0 {
                    self?.pipController?.videoSize = CGSize(width: Double(info.width),
                                                           height: Double(info.height))
                }
            }
            #endif
        }
        #if !os(tvOS)
        setUpPiPController()
        #endif
    }

    // MARK: - Playable forwarding

    /// 被动解码音频旁路(Playable.onDecodedAudio 转发):每解码一段音频回调
    /// 一次,交错 float32 PCM;回调在后台解码队列上,不得阻塞,需要留存请
    /// 拷贝。PTS 无法确定时为 NaN。不支持的后端(MPV)为 no-op。
    public var onDecodedAudio: ((_ pcm: Data, _ channels: Int, _ sampleRate: Double, _ pts: Double) -> Void)? {
        get { backend.onDecodedAudio }
        set { backend.onDecodedAudio = newValue }
    }

    /// Start or restart playback at the given URL.
    /// - Parameters:
    ///   - url: Media URL (local file, HTTP, or custom scheme).
    ///   - headers: HTTP headers sent with the request.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    public func play(url: URL, headers: [String: String] = [:],
                     seekTo: Duration? = nil, knownDuration: Duration? = nil) {
        backend.play(url: url, headers: headers, seekTo: seekTo, knownDuration: knownDuration)
    }

    /// Start playback using a custom I/O reader.
    public func play(reader: any MediaRandomAccessReader,
                     seekTo: Duration? = nil,
                     knownDuration: Duration? = nil) {
        backend.play(reader: reader, seekTo: seekTo, knownDuration: knownDuration)
    }

    /// Start playback by concatenating multiple URLs (BDMV disc clips).
    public func play(concatURLs: [URL], headers: [String: String] = [:],
                     seekTo: Duration? = nil, knownDuration: Duration? = nil) {
        backend.play(concatURLs: concatURLs, headers: headers,
                     seekTo: seekTo, knownDuration: knownDuration)
    }

    /// Start playback of an ordered sequence of custom-I/O clip readers as
    /// one continuous presentation timeline (BDMV disc playback). Each clip's
    /// bytes come from a `MediaRandomAccessReader`; the backend demuxes each
    /// clip separately and rebases PTS onto the continuous timeline.
    public func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
                     seekTo: Duration? = nil,
                     knownDuration: Duration? = nil) {
        backend.play(clips: clips, seekTo: seekTo, knownDuration: knownDuration)
    }

    /// Pause playback. Call `resume()` to continue.
    public func pause()                        { backend.pause() }

    /// Resume from paused state.
    public func resume()                       { backend.resume() }

    /// Seek to a specific position.
    public func seek(to: Duration)             { backend.seek(to: to) }

    /// Stop playback and release resources.
    public func stop()                         { backend.stop() }

    /// Set volume (0.0 = silent, 1.0 = unity).
    public func setVolume(_ v: Double)         { backend.setVolume(v) }

    /// Set playback rate (1.0 = normal, 2.0 = double speed).
    public func setRate(_ r: Double)           { backend.setRate(r) }

    /// Clear the current error status. UI calls this when the user dismisses
    /// the error overlay.
    public func clearError() {
        guard state.error != nil else { return }
        state.error = nil
    }

    /// Select an audio track by its identifier.
    public func selectAudioTrack(id: String)   { backend.selectAudioTrack(id: id) }

    /// Select a subtitle track, or pass nil to disable subtitles.
    public func selectSubtitle(id: String?)    { backend.selectSubtitle(id: id) }

    /// User-selectable video display geometry (feat/player-reskin, reflux
    /// #444 P1 — the tuning panel's aspect-ratio presets). Session-level UI
    /// preference owned by the app; changing it posts
    /// `.playerKitVideoAspectDidChange` and the mounted PlayerNativeView
    /// re-layouts on the next pass (instant mid-play, no pipeline rebuild).
    /// Applies to AVSampleBufferDisplayLayer renderers; Metal renderers
    /// manage their own content rect.
    public var videoAspectMode: VideoAspectMode = .source {
        didSet {
            guard oldValue != videoAspectMode else { return }
            NotificationCenter.default.post(name: .playerKitVideoAspectDidChange,
                                            object: nil)
        }
    }

    /// Preferred subtitle font family (nil = system/libass default). Forwarded
    /// to backends that render ASS/SSA through libass; takes effect when the
    /// next ASS renderer is created (track switch / next episode — libass
    /// requires font lookup to be set before use). Text subtitles rendered by
    /// `SubtitleOverlayView` use its own `fontFamily` parameter and switch
    /// immediately.
    public var subtitleFontFamily: String? {
        didSet {
            guard oldValue != subtitleFontFamily else { return }
            (backend as? any SubtitleFontConfigurable)?
                .setSubtitleFontFamily(subtitleFontFamily)
        }
    }

    // MARK: - Renderer (requires PlayerBackend)

    /// The renderer's Core Animation layer for embedding in a view hierarchy.
    /// Requires a PlayerBackend-compliant backend; nil otherwise.
    public var renderLayer: CALayer? {
        (backend as? any PlayerBackend)?.renderer.layer
    }

    // MARK: - PiP (requires ASBDLRenderer)

    /// A controller for Picture in Picture playback.
    /// Requires an ASBDLRenderer-based backend; nil otherwise.
    /// Created once and cached for the player's lifetime.
    #if !os(tvOS)
    @available(iOS 15.0, macOS 12.0, *)
    public private(set) var pipController: PiPController?

    private func setUpPiPController() {
        guard #available(iOS 15.0, macOS 12.0, *),
              let asbdlRenderer = (backend as? any PlayerBackend)?.renderer as? ASBDLRenderer
        else { return }
        pipController = PiPController(displayLayer: asbdlRenderer.displayLayer)
    }
    #endif

    // MARK: - Frame sinks (requires PlayerBackend)

    /// Register a frame sink to receive decoded video frames.
    public func addFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.addFrameSink(sink)
    }

    /// Remove a previously registered frame sink.
    public func removeFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.removeFrameSink(sink)
    }

    // MARK: - Lifecycle

    /// Reset the player for reuse with new media.
    public func prepareForReuse() {
        (backend as? any PlayerBackend)?.prepareForReuse()
    }
}
