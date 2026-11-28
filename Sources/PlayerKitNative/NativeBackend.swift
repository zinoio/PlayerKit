import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import PlayerKit
@_exported import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

extension Duration {
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Decides whether a frame decoded by the demux loop may enter the jitter buffer after
/// a seek.
enum SeekFrameGate {
    static func landedAtIterationStart(landedSerial: Int64, iterationSerial: Int64) -> Bool {
        landedSerial == iterationSerial
    }

    static func accepts(landedAtIterationStart: Bool, iterationSerial: Int64, latestSerial: Int64) -> Bool {
        landedAtIterationStart && iterationSerial == latestSerial
    }
}

@MainActor
public final class NativeBackend: PlayerBackend, SubtitleFontConfigurable {
    public internal(set) var state = PlayerState()
    public internal(set) var videoWidth: Int = 0
    public internal(set) var videoHeight: Int = 0
    nonisolated(unsafe) var codedVideoWidth: Int = 0
    nonisolated(unsafe) var codedVideoHeight: Int = 0
    /// P2: snapshotted by the display thread under renderConfigLock; written on
    /// the main actor at stream open.
    public nonisolated(unsafe) internal(set) var colorParams = VideoColorParams()
    public var displayCapability: DisplayCapability = .appleMobile {
        didSet {
            _renderer.displayCapability = displayCapability
        }
    }
    public var doviEnabled: Bool = true

    // MARK: Native DV system path(design §5/§6)

    public var dolbyVisionOutput: DolbyVisionOutputPreference = .system
    public nonisolated(unsafe) internal(set) var activeVideoPipeline: VideoPipeline = .decodedFrames
    public nonisolated(unsafe) var onSystemDVFallback: (() -> Void)?

    nonisolated(unsafe) var systemDVActive = false
    nonisolated(unsafe) var systemDVDisabledForSession = false
    nonisolated(unsafe) var systemDVRenderer: SystemDVRenderer?
    nonisolated(unsafe) var systemDVBuilder: SystemDVSampleBuilder?
    nonisolated(unsafe) var systemDVP7Rewriter: DoviP7PacketRewriter?
    nonisolated(unsafe) var systemDVFirstSamplePts: Double = .nan
    nonisolated(unsafe) var systemDVStarted = false
    nonisolated(unsafe) var systemDVStartWall: Double = 0
    nonisolated(unsafe) var systemDVFirstPresentLoggedWall: Double = .nan
    nonisolated(unsafe) var systemDVLastPresentOrStartWall: Double = 0
    nonisolated(unsafe) var systemDVLastProbeWall: Double = 0
    nonisolated(unsafe) var systemDVFirstFrameTimeout: Double = {
#if os(iOS) || os(tvOS)
        return 10.0
#else
        return 3.0
#endif
    }()
    nonisolated(unsafe) var systemDVRendererFactory: ((AVSampleBufferDisplayLayer) -> SystemDVRenderer?)?
    let systemDVFallbackLock = NSLock()
    nonisolated(unsafe) var systemDVPipelineDurationSecs: Double = 0
    nonisolated(unsafe) var systemDVHasAudio = false

    public nonisolated(unsafe) var preferredMaxVideoWidth: Int = 0
    public var frameRateMatchingEnabled: Bool = true {
        didSet { applyFrameRateRange() }
    }
    public var preferredSubtitleLanguage: String?
    public var preferredAudioLanguage: String?
    public internal(set) var chapters: [ChapterInfo] = []

    public nonisolated(unsafe) internal(set) var rendererStrategy: RendererStrategy?
    public var onStateChange: ((PlayerState) -> Void)?
    public var toneMapperProvider: ((RendererStrategy, VideoStreamAttributes) -> (any ToneMapping)?)?

    let _renderer: any VideoRenderer
    public var renderer: any VideoRenderer { _renderer }

    nonisolated(unsafe) var _injectedAudioOutput: (any AudioOutputBackend)?
    public nonisolated(unsafe) var onDecodedAudio: ((_ pcm: Data, _ channels: Int, _ sampleRate: Double, _ pts: Double) -> Void)?

    public private(set) var audioDelay: Double = 0

    public func setAudioDelay(_ secs: Double) {
        let clamped = min(5.0, max(-5.0, secs.isFinite ? secs : 0))
        audioDelay = clamped
        audioClock.setDelay(clamped)
        audioUnitOutput?.setDelayTarget(contentSecs: max(0, clamped))
    }

    public private(set) var subtitleDelay: Double = 0
    let subtitleDelayLock = NSLock()
    nonisolated(unsafe) var _subtitleDelay: Double = 0

    public func setSubtitleDelay(_ secs: Double) {
        let clamped = min(30.0, max(-30.0, secs.isFinite ? secs : 0))
        subtitleDelay = clamped
        subtitleDelayLock.withLock { _subtitleDelay = clamped }
    }

    public nonisolated(unsafe) private(set) var subtitleFontFamily: String?

    public func setSubtitleFontFamily(_ family: String?) {
        let normalized = (family?.isEmpty ?? true) ? nil : family
        subtitleFontFamily = normalized
    }

    var demuxer: (any PacketDemuxing)?
    nonisolated(unsafe) var videoDecoder: (any VideoDecoding)?
    nonisolated(unsafe) var audioDecoder: FFmpegAudioDecoder?
    let audioDecodeQueue = DispatchQueue(label: "io.zyno.PlayerKit.audioDecode")

    let audioClock = AudioClock()
    nonisolated(unsafe) var audioUnitOutput: AudioUnitOutput?
    let audioTempo = PlaybackTempoProcessor()
    nonisolated(unsafe) var isPassthroughActive = false
    nonisolated(unsafe) var isInjectedPCMActive = false
    nonisolated var injectedClockActive: Bool {
        isPassthroughActive || isInjectedPCMActive
    }
    let jitterBuffer = VideoJitterBuffer()

    nonisolated(unsafe) var reportedUIBuffering: Bool?
    nonisolated(unsafe) var userPausedForPolicy = false
    let bufferingStateLock = NSLock()
    nonisolated(unsafe) let syncController = SyncController()
    nonisolated(unsafe) var needsClockCalibration: Bool = false
    let maxCalibrationGap: Double = 15.0

    let discardLock = NSLock()
    nonisolated(unsafe) var discardVideoUntilPts: Double?
    nonisolated(unsafe) var audioAnchoredAtTarget = false
    nonisolated(unsafe) var discardAudioUntilPts: Double?

    struct SubtitleCue {
        let startPts: Double
        let endPts: Double
        let text: String
    }
    let subtitleLock = NSLock()
    nonisolated(unsafe) var subtitleCues: [SubtitleCue] = []
    nonisolated(unsafe) var lastSubtitleText: String? = nil

    struct SubtitleImageCue {
        let startPts: Double
        let endPts: Double
        let image: CGImage
        let rect: CGRect
    }
    let subtitleImageLock = NSLock()
    nonisolated(unsafe) var subtitleImageCues: [SubtitleImageCue] = []
    nonisolated(unsafe) var lastSubtitleImage: CGImage? = nil

    nonisolated(unsafe) var subtitleDecoder: FFmpegSubtitleDecoder?
    nonisolated(unsafe) var assRenderer: ASSRenderer?

    let demuxLock = NSLock()
    let audioSwitchGate = AudioSwitchGate()
    let demuxStateLock = NSLock()
    let seekLock = NSLock()
    nonisolated(unsafe) var seekSerial: Int64 = 0
    nonisolated(unsafe) var seekLandedSerial: Int64 = 0
    nonisolated(unsafe) var physicalSeekGeneration: Int64 = 0
    nonisolated(unsafe) var lastAudioSwitchPath: String?
    nonisolated(unsafe) var audioClockReady: Bool = false
    nonisolated(unsafe) var demuxCancelled = false
    nonisolated(unsafe) var demuxLoopRunning = false
    nonisolated(unsafe) var demuxLoopDemuxer: (any PacketDemuxing)?
    var displayLink: CADisplayLink?
    var displayLinkProxy: DisplayLinkProxy?
    nonisolated(unsafe) var contentFps: Double = 0
    var displayLinkThread: Thread?
    nonisolated(unsafe) var displayLoopStopped = true
    let displayFallbackQueue = DispatchQueue(label: "io.zyno.PlayerKit.displayFallback", qos: .userInteractive)
    #if os(macOS)
    var cvDisplayLink: CVDisplayLink?
    var fallbackRenderTimer: DispatchSourceTimer?
    #endif

    nonisolated(unsafe) var playGeneration: Int = 0

    // MARK: Display-loop shared state (P2)

    let renderGate = NSLock()
    let displayLoopLock = NSLock()

    nonisolated(unsafe) var displayedVideoFrames = 0
    nonisolated(unsafe) var framesSinceLastLog = 0
    nonisolated(unsafe) var ticksSinceLastLog = 0
    nonisolated(unsafe) var lastLogTime: Double = 0
    nonisolated(unsafe) var tickDrainLag = 0
    nonisolated(unsafe) var tickStallAhead = 0
    nonisolated(unsafe) var tickCheckDeny = 0
    nonisolated(unsafe) var tickNoFrame = 0
    nonisolated(unsafe) var tickGuardSkip = 0
    nonisolated(unsafe) var tickGuardSkipSample = 0
    nonisolated(unsafe) var tickStallSample = 0
    nonisolated(unsafe) var drainDepthStats = SyncDiagStats()
    nonisolated(unsafe) var diagAppendsSinceLog = 0
    nonisolated(unsafe) var videoBitrateEstimator = VideoBitrateEstimator()
    nonisolated(unsafe) var renderDropTotal: Int64 = 0
    nonisolated(unsafe) var lastPublishedDropTotal: Int64 = 0
    nonisolated(unsafe) var diagThrottlePackets = 0
    nonisolated(unsafe) var diagThrottleSleeps = 0
    nonisolated(unsafe) var diagThrottleSleepMs: Double = 0
    nonisolated(unsafe) var diagThrottleAudioStallSkips = 0
    nonisolated(unsafe) var diagThrottleLastPts: Double = 0
    nonisolated(unsafe) var diagThrottleLastAudio: Double = 0
    nonisolated(unsafe) var diagThrottleLastReadAhead: Double = 0
    nonisolated(unsafe) var diagThrottleLastGapMs: Double = 0
    nonisolated(unsafe) var diagThrottleMaxDropMs: Double = 0
    nonisolated(unsafe) var diagBackPressureSleeps = 0
    nonisolated(unsafe) var lastTickWallTime: Double?
    let tickGapWarnThreshold: Double = 0.05
    nonisolated(unsafe) var displayLinkStartWallTime: Double?
    nonisolated(unsafe) var firstTickLogged = false
    nonisolated(unsafe) var lastBypassPopTime: Double = 0
    nonisolated(unsafe) var lastNotifiedPos: Duration = .zero
    nonisolated(unsafe) var passthroughWallClockAnchor: (wall: Double, pts: Double)?
    nonisolated(unsafe) var forceClockCalibration = false
    nonisolated(unsafe) var audioDeviceDemoted = false
    nonisolated(unsafe) var displayRate: Double = 1.0

    public nonisolated(unsafe) static var diagLoggingEnabled =
        ProcessInfo.processInfo.environment["PLAYERKIT_DIAG"] == "1"

    nonisolated(unsafe) var avOffsetStats = SyncDiagStats()
    nonisolated(unsafe) var shownGapStats = SyncDiagStats()
    nonisolated(unsafe) var lastShownDiagPTS: Double = -.infinity
    nonisolated(unsafe) var diagPTSRewriteCount = 0
    nonisolated(unsafe) var pendingSeekLandTarget: Double?
    nonisolated(unsafe) var seekLandLogged = true

    func drainDiagAvOffset() -> SyncDiagStats {
        displayLoopLock.withLock { () -> SyncDiagStats in
            let s = avOffsetStats
            avOffsetStats.reset()
            return s
        }
    }

    func drainAudioQueueDiag() -> SyncDiagStats {
        audioClock.drainAdvanceDiag()
    }

    func drainOutputQueueDiag() -> AudioUnitOutput.QueueDiag {
        if let out = audioUnitOutput { return out.drainQueueDiag() }
        return AudioUnitOutput.QueueDiag()
    }

    struct TickDiag {
        var drainLag = 0
        var stallAhead = 0
        var checkDeny = 0
        var noFrame = 0
        var guardSkip = 0
        var drainDepth = SyncDiagStats()
        var appends = 0
    }

    nonisolated func drainTickDiag() -> TickDiag {
        displayLoopLock.withLock { () -> TickDiag in
            let t = TickDiag(drainLag: tickDrainLag, stallAhead: tickStallAhead,
                             checkDeny: tickCheckDeny, noFrame: tickNoFrame,
                             guardSkip: tickGuardSkip, drainDepth: drainDepthStats,
                             appends: diagAppendsSinceLog)
            tickDrainLag = 0
            tickStallAhead = 0
            tickCheckDeny = 0
            tickNoFrame = 0
            tickGuardSkip = 0
            drainDepthStats.reset()
            diagAppendsSinceLog = 0
            return t
        }
    }

    struct ThrottleDiag {
        var packets = 0
        var sleeps = 0
        var sleepMs: Double = 0
        var audioStallSkips = 0
        var backPressure = 0
        var lastPts: Double = 0
        var lastAudio: Double = 0
        var lastReadAhead: Double = 0
        var lastGapMs: Double = 0
        var maxDropMs: Double = 0
    }

    nonisolated func drainThrottleDiag() -> ThrottleDiag {
        displayLoopLock.withLock { () -> ThrottleDiag in
            let t = ThrottleDiag(packets: diagThrottlePackets,
                                 sleeps: diagThrottleSleeps,
                                 sleepMs: diagThrottleSleepMs,
                                 audioStallSkips: diagThrottleAudioStallSkips,
                                 backPressure: diagBackPressureSleeps,
                                 lastPts: diagThrottleLastPts,
                                 lastAudio: diagThrottleLastAudio,
                                 lastReadAhead: diagThrottleLastReadAhead,
                                 lastGapMs: diagThrottleLastGapMs,
                                 maxDropMs: diagThrottleMaxDropMs)
            diagThrottlePackets = 0
            diagThrottleSleeps = 0
            diagThrottleSleepMs = 0
            diagThrottleAudioStallSkips = 0
            diagThrottleMaxDropMs = 0
            diagBackPressureSleeps = 0
            return t
        }
    }

    let renderConfigLock = NSLock()
    nonisolated(unsafe) var _frameSinks: [WeakFrameSink] = []
    struct WeakFrameSink {
        weak var sink: (any FrameSink)?
    }

    nonisolated(unsafe) var totalBytesRead: Int64 = 0
    nonisolated(unsafe) var lastBytesLogged: Int64 = 0
    nonisolated(unsafe) var lastThroughputTime: Double = 0
    let throughputLock = NSLock()
    nonisolated(unsafe) var maxDownloadedPts: Double = 0

    nonisolated(unsafe) var altAudioCache = AltAudioPacketCache<UnsafeMutablePointer<AVPacket>>(
        bytesOf: { Int($0.pointee.size) },
        onEvict: { var p: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&p) })
    nonisolated(unsafe) var altAudioStreams: Set<Int32> = []
    nonisolated(unsafe) var altCacheEnabled = false
    nonisolated(unsafe) var lastSwitchedFromAudioTrack: Int? = nil

    static let audioSwitchQueue = DispatchQueue(
        label: "com.zyno.playerkit.audio-switch", qos: .userInitiated)

    func refreshAltAudioStreams(_ demuxer: any PacketDemuxing) {
        let all = demuxer.audioStreamIndices
        let enabled = all.count >= 2
        if enabled {
            let tracks = state.audioTracks.filter { all.contains(Int32($0.id)) }
            altAudioStreams = Set(AltAudioCachePolicy.selectCandidates(
                tracks: tracks,
                current: Int(demuxer.audioStreamIndex),
                preferredLanguage: preferredAudioLanguage,
                lastSwitchedFrom: lastSwitchedFromAudioTrack))
            altAudioCache.retain(streams: altAudioStreams.union([demuxer.audioStreamIndex]))
        } else {
            altAudioStreams = []
            altAudioCache.removeAll()
        }
        altCacheEnabled = enabled
        demuxer.setCachedAudioStreams(altAudioStreams)
        logger.notice("[diag] altaudio audioTracks=\(all.count, privacy: .public) enabled=\(!self.altAudioStreams.isEmpty, privacy: .public) cached=\(self.altAudioStreams.sorted(), privacy: .public)")
    }

    // MARK: - Init

    public convenience init() throws {
        try self.init(renderer: nil, audioOutput: nil)
    }

    public convenience init(audioOutput: (any AudioOutputBackend)?) throws {
        try self.init(renderer: nil, audioOutput: audioOutput)
    }

    public init(renderer: (any VideoRenderer)?, audioOutput: (any AudioOutputBackend)?) throws {
        self._renderer = try renderer ?? ASBDLRenderer()
        self._injectedAudioOutput = audioOutput
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        logger.info("init OK")
    }

    // MARK: - Public Audio/Output/Sink Controls

    nonisolated(unsafe) var playedContentTrackerEnd: Double = .nan

    func audioContentGapForTesting() -> Double {
        (audioUnitOutput?.playedContentEnd() ?? .nan) - audioClock.audioTime
    }

    public func setVolume(_ volume: Double) {
        let clamped = max(0.0, min(1.0, volume.isFinite ? volume : 1.0))
        state.volume = clamped
        audioUnitOutput?.setVolume(clamped)
        if _injectedAudioOutput?.acceptsPCM == true {
            _injectedAudioOutput?.setVolume(clamped)
        }
        notifyStateChange()
    }

    public func setRate(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate.isFinite ? rate : 1.0))
        state.rate = clamped
        displayLoopLock.withLock { displayRate = clamped }
        audioTempo.setRate(clamped)
        audioUnitOutput?.setPlaybackRate(clamped)
        if _injectedAudioOutput?.acceptsPCM == true {
            _injectedAudioOutput?.setPlaybackRate(clamped)
        }
        systemDVRenderer?.setRate(Float(clamped))
        notifyStateChange()
    }

    public func replaceInjectedAudioOutput(_ output: (any AudioOutputBackend)?) {
        demuxLock.lock()
        let old = _injectedAudioOutput
        _injectedAudioOutput = output
        isPassthroughActive = false
        isInjectedPCMActive = false
        demuxLock.unlock()
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }
        passthroughWallClockAnchor = nil
        old?.flush()
        notifyStateChange()
    }

    public func prepareForReuse() { stop() }

    public func addFrameSink(_ sink: any FrameSink) {
        renderConfigLock.withLock {
            _frameSinks.removeAll { $0.sink == nil }
            _frameSinks.append(WeakFrameSink(sink: sink))
        }
    }

    public func removeFrameSink(_ sink: any FrameSink) {
        renderConfigLock.withLock {
            _frameSinks.removeAll { $0.sink == nil || $0.sink === sink }
        }
    }

    func notifyStateChange() {
        onStateChange?(state)
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
