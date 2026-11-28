import AVFoundation
import Foundation
import QuartzCore
import PlayerKit
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

// MARK: - Native DV System Path & Master Audio Clock

extension NativeBackend {

    /// 测试专用:系统路径渲染器 timebase 当前时间(nil = 未启动/未激活)。
    nonisolated func systemDVRendererTimeForTesting() -> Double? {
        systemDVRenderer?.currentTime
    }

    /// 测试专用:系统路径下层 timebase 与音频主时钟的当前差(秒)。
    nonisolated func systemDVClockGapForTesting() -> Double {
        guard let renderer = systemDVRenderer, let t = renderer.currentTime else { return .nan }
        return t - currentMasterAudioTime()
    }

    /// 主时钟(音频)对外时间。
    nonisolated func currentMasterAudioTime() -> Double {
        if _injectedAudioOutput != nil, injectedClockActive,
           let pt = _injectedAudioOutput?.playbackTime, pt.isFinite, pt >= 0 {
            return pt + audioClock.fullDelay
        }
        if !systemDVActive, audioClock.hasConsumedOutput {
            let latency = audioUnitOutput?.hardwareOutputLatency ?? 0
            if latency > 0 {
                let rate = displayLoopLock.withLock { displayRate }
                return audioClock.audioTime - latency * rate
            }
            return audioClock.audioTime
        }
        if !systemDVActive, let device = audioUnitOutput?.devicePlaybackTime {
            return device + audioClock.fullDelay
        }
        return audioClock.audioTime
    }

    /// 系统路径的显示 tick。
    nonisolated func systemDVTick() {
        guard let renderer = systemDVRenderer else { return }
        let audioTime = currentMasterAudioTime()

        if !systemDVStarted, !self.systemDVFirstSamplePts.isNaN,
           renderer.pendingSampleCount > 0 || renderer.bufferedSeconds > 0 {
            systemDVStarted = true
            systemDVStartWall = CACurrentMediaTime()
            systemDVLastPresentOrStartWall = systemDVStartWall
            let rate = displayLoopLock.withLock { displayRate }
            renderer.start(at: self.systemDVFirstSamplePts, rate: Float(rate))
            logger.info("[dovi-sys] timebase start at \(String(format: "%.3f", self.systemDVFirstSamplePts), privacy: .public)s")
        }

        let (needsCal, forceCal) = displayLoopLock.withLock { (needsClockCalibration, forceClockCalibration) }
        if needsCal, systemDVStarted, let presented = renderer.currentTime {
            let audioAnchored = discardLock.withLock { audioAnchoredAtTarget }
            if ClockCalibrationPolicy.shouldCalibrate(firstFramePts: presented,
                                                      audioTime: audioTime,
                                                      force: forceCal,
                                                      audioAnchoredAtTarget: audioAnchored,
                                                      maxGap: maxCalibrationGap) {
                audioClock.calibrate(to: presented,
                                     sampleRate: audioDecoder?.outputSampleRate ?? 44100)
                logger.info("[dovi-sys] audio clock calibrated to \(String(format: "%.3f", presented), privacy: .public)s")
            }
            displayLoopLock.withLock {
                needsClockCalibration = false
                forceClockCalibration = false
            }
        }

        if systemDVStarted {
            renderer.calibrate(toAudioTime: audioTime)
        }

        let hasAudio = systemDVHasAudio
        let demuxEOF = jitterBuffer.atEOF
        let drained = renderer.pendingSampleCount == 0 && renderer.bufferedSeconds <= 0.001
        var pos = hasAudio ? max(0, audioTime) : max(0, renderer.currentTime ?? 0)
        if !hasAudio && demuxEOF && drained {
            pos = min(pos, systemDVPipelineDurationSecs)
        }
        let posDur = Duration.milliseconds(Int64(pos * 1000))
        let due = displayLoopLock.withLock { (posDur - lastNotifiedPos) >= .milliseconds(500) }
        if due {
            displayLoopLock.withLock { lastNotifiedPos = posDur }
            applyDisplayUpdate(DisplayUIUpdate(position: posDur,
                                               durationAtLeast: Duration.milliseconds(
                                                   Int64(systemDVPipelineDurationSecs * 1000)),
                                               generation: playGeneration, notify: true))
        }

        if systemDVStarted, CACurrentMediaTime() - self.systemDVLastProbeWall > 5.0 {
            self.systemDVLastProbeWall = CACurrentMediaTime()
            let snap = renderer.probeSnapshot()
            logger.notice("[dovi-sys] probe \(snap, privacy: .public)")
        }
        if systemDVStarted, renderer.hasPresentedFirstFrame,
           self.systemDVFirstPresentLoggedWall != self.systemDVStartWall {
            self.systemDVFirstPresentLoggedWall = self.systemDVStartWall
            logger.notice("[dovi-sys] first frame PRESENTED after \(String(format: "%.2f", CACurrentMediaTime() - self.systemDVStartWall), privacy: .public)s")
        }
        if systemDVStarted {
            let nowWall = CACurrentMediaTime()
            if renderer.hasPresentedFirstFrame {
                systemDVLastPresentOrStartWall = nowWall
            } else if nowWall - systemDVLastPresentOrStartWall > systemDVFirstFrameTimeout {
                logger.notice("[dovi-sys] first frame TIMEOUT after \(String(format: "%.1f", nowWall - self.systemDVLastPresentOrStartWall), privacy: .public)s without presentation — falling back")
                fallbackToSoftwareDV(reason: "first frame timeout")
            }
        }
    }

    /// 系统路径回退入口(design §6.2):只触发一次。
    nonisolated func fallbackToSoftwareDV(reason: String) {
        let didFall = systemDVFallbackLock.withLock { () -> Bool in
            guard !systemDVDisabledForSession, systemDVActive else { return false }
            systemDVDisabledForSession = true
            return true
        }
        guard didFall else { return }
        logger.error("[dovi-sys] fallback to software: \(reason, privacy: .public)")
        systemDVRenderer?.stop()
        systemDVRenderer = nil
        systemDVBuilder = nil
        systemDVP7Rewriter = nil
        systemDVActive = false
        systemDVStarted = false
        let pos = max(0, currentMasterAudioTime())
        activeVideoPipeline = .decodedFrames
        onSystemDVFallback?()
        Task { @MainActor [weak self] in
            self?.rebuildSoftwareDVChain(currentPosition: pos)
        }
    }

    private func rebuildSoftwareDVChain(currentPosition: Double) {
        guard let demuxer, systemDVDisabledForSession else { return }
        let attrs = demuxer.videoStreamAttributes()
            ?? VideoStreamAttributes(width: 0, height: 0, codecID: 0,
                                     colorMatrix: .bt709, transfer: .sdr, range: .limited)
        let strat = decideRendererStrategy(
            stream: attrs,
            prefersTenBit: _renderer.prefersTenBit,
            display: displayCapability,
            doviEnabled: doviEnabled,
            systemDolbyVision: .unavailable,
            dolbyVisionOutput: dolbyVisionOutput
        )
        renderConfigLock.withLock { self.rendererStrategy = strat }
        if let provider = toneMapperProvider, let asbdl = _renderer as? ASBDLRenderer {
            asbdl.toneMapper = provider(strat, attrs)
        }
        if let vs = demuxer.videoStream,
           let dec = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
            videoDecoder = dec
            state.videoDecoderPath = .ffmpegSoftware
            codedVideoWidth = dec.width; codedVideoHeight = dec.height
            let sar = demuxer.sampleAspectRatio
            videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
            videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
            logger.info("[dovi-sys] software chain rebuilt: \(dec.width)x\(dec.height) strategy=\(String(describing: strat), privacy: .public)")
        } else {
            logger.error("[dovi-sys] software decoder rebuild FAILED")
        }
        _seek(to: .seconds(max(0, currentPosition - 0.05)), synchronousDemuxerSeek: true)
    }
}
