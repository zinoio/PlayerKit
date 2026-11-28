import AVFoundation
import Foundation
import QuartzCore
import PlayerKit
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

// MARK: - Buffering, Device Health, Lifecycle & Seek

extension NativeBackend {

    func wireJitterBuffer() {
        jitterBuffer.onStateChange = { [weak self] newState in
            guard let self = self, !self.systemDVActive else { return }
            switch newState {
            case .buffering:
                self.setAudioPaused(true)
                self.requestUIBuffering(true)
            case .playing:
                self.setAudioPaused(false)
                self.requestUIBuffering(false)
            }
        }
    }

    // MARK: - 缓冲状态副作用(方案 B:单一拥有者)

    nonisolated func resetBufferingState() {
        bufferingStateLock.withLock {
            reportedUIBuffering = nil
        }
        userPausedForPolicy = false
    }

    nonisolated func setAudioPaused(_ paused: Bool) {
        if paused {
            audioUnitOutput?.pause()
            _injectedAudioOutput?.pause()
        } else {
            guard !userPausedForPolicy else { return }
            audioUnitOutput?.resume()
            _injectedAudioOutput?.resume()
        }
    }

    private nonisolated func requestUIBuffering(_ buffering: Bool) {
        let changed = bufferingStateLock.withLock { () -> Bool in
            guard reportedUIBuffering != buffering else { return false }
            reportedUIBuffering = buffering
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.isBuffering = buffering
            if buffering { self.lastTickWallTime = nil }
            self.notifyStateChange()
        }
    }

    // MARK: - #608 音频设备降级 / 恢复

    nonisolated func handleAudioDeviceDemoted() {
        let changed = displayLoopLock.withLock { () -> Bool in
            guard !audioDeviceDemoted else { return false }
            audioDeviceDemoted = true
            audioClockReady = false
            needsClockCalibration = false
            forceClockCalibration = false
            return true
        }
        if changed {
            logger.error("[#608] 音频输出设备不可用 → 降级续播:画面按源帧率推进,音频静音,定时探测设备恢复")
        }
    }

    nonisolated func handleAudioDeviceRecovered() {
        let changed = displayLoopLock.withLock { () -> Bool in
            guard audioDeviceDemoted else { return false }
            audioDeviceDemoted = false
            audioClockReady = false
            needsClockCalibration = true
            forceClockCalibration = true
            return true
        }
        if changed {
            logger.warning("[#608] 音频输出设备恢复 → 回切音频主导时钟(强制重校准)")
        }
    }

    // MARK: - Controls

    public func pause() {
        userPausedForPolicy = true
        logger.info("pause")
        displayLink?.invalidate(); displayLink = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(macOS)
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #else
        displayLinkProxy = nil
        #endif
        audioUnitOutput?.pause()
        _injectedAudioOutput?.pause()
        systemDVRenderer?.setRate(0)
        demuxStateLock.lock()
        demuxCancelled = true
        demuxStateLock.unlock()
        state.isPlaying = false; notifyStateChange()
    }

    public func resume() {
        guard demuxer != nil else {
            logger.warning("resume: demuxer is nil, player was stopped — ignoring")
            demuxStateLock.lock()
            demuxCancelled = false
            demuxStateLock.unlock()
            return
        }
        logger.info("resume")
        userPausedForPolicy = false
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let resumingContinuous = demuxStateLock.withLock { demuxLoopRunning && !demuxCancelled }
        audioUnitOutput?.resume()
        _injectedAudioOutput?.resume()
        displayLink?.invalidate()
        displayLink = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(iOS)
        displayLinkProxy = nil
        #endif
        if !resumingContinuous {
            syncController.reset()
            displayLoopLock.withLock { lastBypassPopTime = 0 }
            if let vt = videoDecoder as? VTVideoDecoder {
                vt.flush()
            }
        }
        startDemuxLoop()
        startDisplayLink()
        if systemDVActive {
            systemDVRenderer?.setRate(Float(state.rate))
            audioUnitOutput?.resume()
            _injectedAudioOutput?.resume()
            state.isBuffering = false
        }
        state.isPlaying = true; notifyStateChange()
    }

    public func seek(to: Duration) {
        _seek(to: to, synchronousDemuxerSeek: false)
    }

    func _seek(to: Duration, synchronousDemuxerSeek: Bool,
               keepDisplayedFrame: Bool = false) {
        let secs = to.secondsDouble
        logger.info("seek to \(String(format:"%.1f",secs))s")
        displayLoopLock.withLock {
            pendingSeekLandTarget = secs
            seekLandLogged = false
        }
        let mySerial: Int64 = seekLock.withLock { seekSerial += 1; return seekSerial }

        subtitleLock.withLock { subtitleCues.removeAll() }
        displayLoopLock.withLock { lastSubtitleText = nil }
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        assRenderer?.flushEvents()
        displayLoopLock.withLock { lastSubtitleImage = nil }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        jitterBuffer.flush()
        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        passthroughWallClockAnchor = nil
        if !keepDisplayedFrame {
            _renderer.flush()
        }
        if systemDVActive {
            systemDVRenderer?.flush(at: secs)
        }

        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        audioUnitOutput?.stop()
        _injectedAudioOutput?.flush()
        audioClock.reset(to: secs, sampleRate: sr)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        audioUnitOutput?.pause()
        if systemDVActive {
            audioUnitOutput?.resume()
            _injectedAudioOutput?.resume()
        }
        maxDownloadedPts = secs
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
            discardLock.withLock { audioAnchoredAtTarget = false }
        }
        state.position = .seconds(secs)
        notifyStateChange()

        let demuxerRef = demuxer
        let videoDec = videoDecoder
        let audioDec = audioDecoder
        let dLock = demuxLock
        let aQueue = audioDecodeQueue
        let sLock = seekLock
        let audioOut = audioUnitOutput
        let clockRef = audioClock
        let jitterRef = jitterBuffer
        let onLanded: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.displayLoopLock.withLock {
                    self.needsClockCalibration = true
                    self.audioClockReady = false
                    self.lastBypassPopTime = 0
                }
                self.syncController.reset()
            }
        }
        if synchronousDemuxerSeek {
            NativeBackend.performDemuxerSeek(to: secs, expectedSerial: mySerial, seekLock: sLock, backend: self,
                                              demuxer: demuxerRef, videoDecoder: videoDec,
                                              audioDecoder: audioDec, lock: dLock, audioQueue: aQueue,
                                              audioOutput: audioOut, audioClock: clockRef,
                                              audioSampleRate: sr, audioChannels: ch,
                                              jitterBuffer: jitterRef, onLanded: onLanded)
        } else {
            DispatchQueue.global().async { [weak self] in
                NativeBackend.performDemuxerSeek(to: secs, expectedSerial: mySerial, seekLock: sLock, backend: self,
                                                  demuxer: demuxerRef, videoDecoder: videoDec,
                                                  audioDecoder: audioDec, lock: dLock, audioQueue: aQueue,
                                                  audioOutput: audioOut, audioClock: clockRef,
                                                  audioSampleRate: sr, audioChannels: ch,
                                                  jitterBuffer: jitterRef, onLanded: onLanded)
            }
        }
    }

    private static func performDemuxerSeek(to secs: Double, expectedSerial: Int64, seekLock: NSLock,
                                            backend: NativeBackend?, demuxer: (any PacketDemuxing)?,
                                            videoDecoder: (any VideoDecoding)?, audioDecoder: FFmpegAudioDecoder?,
                                            lock: NSLock, audioQueue: DispatchQueue,
                                            audioOutput: AudioUnitOutput? = nil, audioClock: AudioClock? = nil,
                                            audioSampleRate: Int32 = 44100, audioChannels: Int32 = 2,
                                            jitterBuffer: VideoJitterBuffer? = nil,
                                            onLanded: (@Sendable () -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard seekLock.withLock({ backend?.seekSerial }) == expectedSerial else {
            logger.info("seek to \(String(format:"%.1f",secs))s skipped — superseded by a newer seek before it reached demuxLock")
            return
        }
        _ = demuxer?.seek(to: secs)
        backend?.altAudioCache.removeAll()
        if let landed = demuxer?.lastSeekLandedPTS, FineSeekPolicy.shouldArm(landed: landed, target: secs) {
            backend?.discardLock.withLock { backend?.discardVideoUntilPts = secs; backend?.audioAnchoredAtTarget = true }
            backend?.discardAudioUntilPts = secs
            logger.info("fine-seek: discard \(String(format: "%.2f", secs - landed), privacy: .public)s (landed=\(String(format: "%.2f", landed), privacy: .public) target=\(String(format: "%.2f", secs), privacy: .public))")
        } else {
            backend?.discardLock.withLock { backend?.discardVideoUntilPts = nil; backend?.audioAnchoredAtTarget = false }
            backend?.discardAudioUntilPts = nil
        }
        videoDecoder?.flush()
        audioQueue.sync {
            audioDecoder?.flush()
            backend?.audioTempo.reset()
        }
        if let out = audioOutput, let clock = audioClock {
            out.stop()
            clock.reset(to: secs, sampleRate: audioSampleRate)
            out.start(sampleRate: audioSampleRate, channels: audioChannels)
            out.pause()
        }
        jitterBuffer?.flush()
        onLanded?()
        let gen = (backend?.physicalSeekGeneration ?? 0) + 1
        backend?.physicalSeekGeneration = gen
        backend?.seekLandedSerial = expectedSerial
        if backend?.systemDVActive == true {
            backend?.audioUnitOutput?.resume()
            backend?._injectedAudioOutput?.resume()
        }
        logger.info("seek to \(String(format:"%.1f",secs))s landed physically, physicalSeekGeneration=\(gen)")
    }

    public func stop() {
        playGeneration += 1
        logger.info("stop (displayed \(self.displayLoopLock.withLock { self.displayedVideoFrames }) frames)")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(macOS)
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        cvDisplayLink = nil
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #endif
        demuxCancelled = true
        systemDVRenderer?.stop()
        systemDVRenderer = nil
        systemDVBuilder = nil
        systemDVP7Rewriter = nil
        systemDVActive = false
        systemDVStarted = false
        systemDVDisabledForSession = false
        activeVideoPipeline = .decodedFrames
        audioUnitOutput?.stop()
        _injectedAudioOutput?.flush()
        demuxLock.lock()
        altAudioCache.removeAll(); altAudioStreams = []; altCacheEnabled = false
        lastSwitchedFromAudioTrack = nil
        demuxer?.close(); demuxer = nil
        videoDecoder = nil; audioDecoder = nil
        state.videoDecoderPath = nil
        state.videoBitrateIsEstimated = false
        seekLock.withLock { seekLandedSerial = seekSerial }
        discardAudioUntilPts = nil
        demuxLock.unlock()
        jitterBuffer.flush()
        syncController.reset()
        resetBufferingState()
        displayLoopLock.withLock {
            lastBypassPopTime = 0
            forceClockCalibration = false
            discardLock.withLock { discardVideoUntilPts = nil; audioAnchoredAtTarget = false }
            lastNotifiedPos = .zero
            displayedVideoFrames = 0
            renderDropTotal = 0
            lastPublishedDropTotal = 0
            videoBitrateEstimator = VideoBitrateEstimator()
            throughputLock.withLock {
                lastBytesLogged = 0
                lastThroughputTime = 0
            }
            lastSubtitleText = nil
            lastSubtitleImage = nil
        }
        passthroughWallClockAnchor = nil
        audioClock.reset(to: 0, sampleRate: 44100)
        _renderer.flush()
        _renderer.clear()
        totalBytesRead = 0
        maxDownloadedPts = 0
        subtitleLock.withLock { subtitleCues.removeAll() }
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero
        subtitleDecoder = nil
        assRenderer = nil
        chapters = []
        state = PlayerState()
        notifyStateChange()
    }
}
