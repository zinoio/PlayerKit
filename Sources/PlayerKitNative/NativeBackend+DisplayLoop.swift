import AVFoundation
import Foundation
import CoreGraphics
import QuartzCore
import PlayerKit
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

final class DisplayLinkProxy: NSObject {
    weak var backend: NativeBackend?
    init(backend: NativeBackend) { self.backend = backend }
    @objc func tick() {
        backend?.displayNextFrame()
    }
}

// MARK: - Display Loop, Presentation & UI Bridge

extension NativeBackend {

    struct DisplayUIUpdate {
        var position: Duration? = nil
        var durationAtLeast: Duration? = nil
        var subtitleText: String?? = nil
        var subtitleImage: CGImage?? = nil
        var subtitleImageRect: CGRect? = nil
        var doviFELActive: Bool? = nil
        var generation: Int
        var notify: Bool
    }

    nonisolated func displayNextFrame() {
        guard renderGate.try() else { return }
        defer { renderGate.unlock() }

        jitterBuffer.pollStarvation()

        let now = CACurrentMediaTime()
        let bufferPlaying = jitterBuffer.state == .playing

        displayLoopLock.lock()
        if let last = lastTickWallTime {
            let gap = now - last
            if gap > tickGapWarnThreshold && bufferPlaying {
                logger.warning("display tick gap \(Int(gap * 1000))ms (display thread stall?)")
            }
        } else if !firstTickLogged {
            if let linkStart = displayLinkStartWallTime {
                firstTickLogged = true
                displayLoopLock.unlock()
                logger.info("first display tick \(Int((now - linkStart) * 1000))ms after startDisplayLink()")
                displayLoopLock.lock()
            }
        }
        lastTickWallTime = now
        ticksSinceLastLog += 1
        displayLoopLock.unlock()

        if systemDVActive {
            systemDVTick()
            return
        }

        while true {
            let until = discardLock.withLock { discardVideoUntilPts }
            guard let until else { break }
            if let front = jitterBuffer.peek(at: 0), front.pts < until {
                jitterBuffer.pop()
                continue
            }
            if jitterBuffer.peek(at: 0) != nil {
                discardLock.withLock { discardVideoUntilPts = nil }
                logger.info("fine-seek: discard window drained, first frame at target")
            }
            break
        }
        if discardLock.withLock({ discardVideoUntilPts }) != nil { return }

        let (needsCalibration, forceCalibration) = displayLoopLock.withLock {
            (needsClockCalibration, forceClockCalibration)
        }
        if needsCalibration, let firstFrame = jitterBuffer.peek(at: 0) {
            let audioAnchored = discardLock.withLock { audioAnchoredAtTarget }
            if ClockCalibrationPolicy.shouldCalibrate(firstFramePts: firstFrame.pts,
                                                      audioTime: audioClock.audioTime,
                                                      force: forceCalibration,
                                                      audioAnchoredAtTarget: audioAnchored,
                                                      maxGap: maxCalibrationGap) {
                audioClock.calibrate(to: firstFrame.pts, sampleRate: audioDecoder?.outputSampleRate ?? 44100)
            }
            displayLoopLock.withLock {
                needsClockCalibration = false
                forceClockCalibration = false
            }
        }

        let audioTime = currentMasterAudioTime()
        let serial = seekLock.withLock { seekSerial }
        let playbackRate = displayLoopLock.withLock { displayRate }

        if !displayLoopLock.withLock({ audioDeviceDemoted }),
           let out = audioUnitOutput,
           out.noteDisplayTickForStall(now: now) {
            handleAudioDeviceDemoted()
        }

        let (stillNeedsCal, clockReady) = displayLoopLock.withLock {
            (needsClockCalibration, audioClockReady)
        }
        let audioEnded: Bool
        if injectedClockActive {
            audioEnded = jitterBuffer.atEOF && (_injectedAudioOutput?.bufferedDuration ?? 0) <= 0
        } else {
            audioEnded = jitterBuffer.atEOF
                && !(audioUnitOutput?.hasPendingOutput ?? false)
        }

        if runFreezeAheadAndSkipBehindGuard(
            stillNeedsCal: stillNeedsCal, clockReady: clockReady,
            audioEnded: audioEnded, audioTime: audioTime, playbackRate: playbackRate
        ) {
            return
        }

        if !clockReady, !displayLoopLock.withLock({ audioDeviceDemoted }),
           audioClock.hasConsumedOutput {
            displayLoopLock.withLock { audioClockReady = true }
        }
        if !clockReady, injectedClockActive, !isPassthroughActive,
           let pt = _injectedAudioOutput?.playbackTime, pt.isFinite, pt >= 0 {
            displayLoopLock.withLock { audioClockReady = true }
        }

        guard let frame = jitterBuffer.peek(at: 0) else {
            displayLoopLock.withLock { tickNoFrame += 1 }
            return
        }

        let followingPTS = jitterBuffer.peek(at: 1)?.pts
        let (shouldShow, delay): (Bool, Double)
        if clockReady {
            if audioEnded {
                let srcGap = followingPTS.map { max(0.01, min(0.5, $0 - frame.pts)) }
                    ?? (1.0 / 25.0)
                let due = displayLoopLock.withLock {
                    if now - lastBypassPopTime >= srcGap {
                        lastBypassPopTime = now
                        return true
                    }
                    return false
                }
                (shouldShow, delay) = (due, 0)
            } else {
                (shouldShow, delay) = syncController.check(
                    nextPTS: frame.pts,
                    followingPTS: followingPTS,
                    audioTime: audioTime,
                    now: now,
                    serial: serial,
                    rate: playbackRate
                )
            }
        } else {
            let srcGap = followingPTS.map { max(0.01, min(0.5, $0 - frame.pts)) }
                ?? (1.0 / 25.0)
            let due = displayLoopLock.withLock {
                if now - lastBypassPopTime >= srcGap {
                    lastBypassPopTime = now
                    return true
                }
                return false
            }
            (shouldShow, delay) = (due, 0)
        }

        guard shouldShow else {
            if clockReady { displayLoopLock.withLock { tickCheckDeny += 1 } }
            let pos = Duration.milliseconds(Int64(max(0, clockReady ? audioTime : frame.pts) * 1000))
            let due = displayLoopLock.withLock { (pos - lastNotifiedPos) >= .milliseconds(500) }
            if due {
                displayLoopLock.withLock { lastNotifiedPos = pos }
                applyDisplayUpdate(DisplayUIUpdate(position: pos, generation: playGeneration, notify: true))
            }
            return
        }

        guard let popped = jitterBuffer.pop() else { return }
        syncController.advance(delay: delay, pts: popped.pts,
                               followingPTS: followingPTS, audioTime: audioTime, now: now)
        let (cpBase, strategy) = renderConfigLock.withLock { (colorParams, rendererStrategy) }
        var cp = cpBase
        cp.dovi = popped.metadata.dovi
        _renderer.render(pixelBuffer: popped.pixelBuffer,
                         elPixelBuffer: popped.elPixelBuffer,
                         pts: popped.pts,
                         colorParams: cp,
                         metadata: popped.metadata,
                         strategy: strategy)
        let ptsCopy = popped.pts
        let pixelBuffer = popped.pixelBuffer
        let sinks = renderConfigLock.withLock { self._frameSinks.compactMap { $0.sink } }
        if !sinks.isEmpty {
            DispatchQueue.main.async {
                for sink in sinks {
                    sink.receive(pixelBuffer: pixelBuffer, pts: ptsCopy)
                }
            }
        }
        let firstFrameRendered: Bool = displayLoopLock.withLock {
            displayedVideoFrames += 1; framesSinceLastLog += 1
            avOffsetStats.record(popped.pts - audioTime)
            let shownGap = popped.pts - lastShownDiagPTS
            if shownGap.isFinite, shownGap > -1.0, shownGap < 1.0 {
                shownGapStats.record(shownGap)
            }
            lastShownDiagPTS = popped.pts
            if !seekLandLogged, let target = pendingSeekLandTarget {
                seekLandLogged = true
                logger.info("[diag] seek videoLand=\(String(format:"%+.3f", popped.pts - target), privacy: .public)s target=\(String(format:"%.3f", target), privacy: .public)s pts=\(String(format:"%.3f", popped.pts), privacy: .public)s")
            }
            return displayedVideoFrames == 1
        }

        let posDur = Duration.milliseconds(Int64(popped.pts * 1000))
        let gen = playGeneration
        let felActiveNow = popped.elPixelBuffer != nil
            && (popped.metadata.doviNlq.map { !$0.isMEL } ?? false)
            && !UserDefaults.standard.bool(forKey: "doviNlqOff")

        let (due, felChanged) = displayLoopLock.withLock { () -> (Bool, Bool) in
            let posDue = (posDur - lastNotifiedPos) >= .milliseconds(500)
            if posDue { lastNotifiedPos = posDur }
            let felDiff = felActiveNow != lastNotifiedFELActive
            if felDiff { lastNotifiedFELActive = felActiveNow }
            return (posDue, felDiff)
        }
        if firstFrameRendered || due || felChanged {
            applyDisplayUpdate(DisplayUIUpdate(
                position: posDur,
                durationAtLeast: posDur,
                doviFELActive: felChanged ? felActiveNow : nil,
                generation: gen,
                notify: true
            ))
        }

        updateActiveSubtitles(displayPts: popped.pts, posDur: posDur, generation: gen)
        logSync(now: now, pts: popped.pts, audioTime: audioTime)
    }

    private nonisolated func runFreezeAheadAndSkipBehindGuard(
        stillNeedsCal: Bool,
        clockReady: Bool,
        audioEnded: Bool,
        audioTime: Double,
        playbackRate: Double
    ) -> Bool {
        if syncController.hasDisplayedFrame, !stillNeedsCal, clockReady {
            let guardWindow = syncController.guardWindow(rate: playbackRate)
            while let lagging = jitterBuffer.peek(at: 0), lagging.pts < audioTime - guardWindow {
                jitterBuffer.pop()
                displayLoopLock.withLock {
                    tickDrainLag += 1
                    renderDropTotal += 1
                    drainDepthStats.record(audioTime - lagging.pts)
                }
            }
            if let ahead = jitterBuffer.peek(at: 0), ahead.pts > audioTime + guardWindow,
               !audioEnded {
                displayLoopLock.withLock {
                    tickStallAhead += 1
                    tickStallSample += 1
                    if tickStallSample >= 450 {
                        tickStallSample = 0
                        if Self.diagLoggingEnabled {
                            logger.warning("[diag] stall: front=\(String(format: "%.3f", ahead.pts), privacy: .public) audio=\(String(format: "%.3f", audioTime), privacy: .public) gap=\(String(format: "%.0f", (ahead.pts - audioTime) * 1000), privacy: .public)ms q=\(self.jitterBuffer.count, privacy: .public)")
                        }
                    }
                }
                let pos = Duration.milliseconds(Int64(max(0, audioTime) * 1000))
                let due = displayLoopLock.withLock { (pos - lastNotifiedPos) >= .milliseconds(500) }
                if due {
                    displayLoopLock.withLock { lastNotifiedPos = pos }
                    applyDisplayUpdate(DisplayUIUpdate(position: pos, generation: playGeneration, notify: true))
                }
                return true
            }
        } else {
            displayLoopLock.withLock {
                tickGuardSkip += 1
                tickGuardSkipSample += 1
                if tickGuardSkipSample >= 450 {
                    tickGuardSkipSample = 0
                    if Self.diagLoggingEnabled {
                        let front = jitterBuffer.peek(at: 0)
                        logger.warning("[diag] guardSkip: hasDisplayed=\(self.syncController.hasDisplayedFrame, privacy: .public) stillNeedsCal=\(stillNeedsCal, privacy: .public) clockReady=\(clockReady, privacy: .public) front=\(String(format: "%.3f", front?.pts ?? -1), privacy: .public) audio=\(String(format: "%.3f", audioTime), privacy: .public) q=\(self.jitterBuffer.count, privacy: .public)")
                    }
                }
            }
        }
        return false
    }

    private nonisolated func updateActiveSubtitles(displayPts: Double, posDur: Duration, generation: Int) {
        let subPts = SubtitleTiming.shifted(
            displayPts, delay: subtitleDelayLock.withLock { _subtitleDelay })
        let activeSub: String? = subtitleLock.withLock {
            subtitleCues.first { SubtitleTiming.contains(startPts: $0.startPts,
                                                         endPts: $0.endPts,
                                                         pts: subPts) }?.text
        }
        let assR = self.assRenderer
        let (newImage, newRect): (CGImage?, CGRect)
        if let assR {
            if let f = assR.renderFrame(ptsSecs: subPts) {
                newImage = f.image
                newRect = f.rect
            } else {
                newImage = nil
                newRect = .zero
            }
        } else {
            (newImage, newRect) = subtitleImageLock.withLock {
                if subtitleImageCues.count > 4 {
                    subtitleImageCues.removeAll { $0.endPts < displayPts - 1.0 }
                }
                if let c = subtitleImageCues.first(where: {
                    SubtitleTiming.contains(startPts: $0.startPts,
                                            endPts: $0.endPts, pts: subPts)
                }) {
                    return (c.image, c.rect)
                }
                return (nil, .zero)
            }
        }
        let (textChanged, imageChanged) = displayLoopLock.withLock { () -> (Bool, Bool) in
            let t = activeSub != lastSubtitleText
            let i = newImage !== lastSubtitleImage
            if t { lastSubtitleText = activeSub }
            if i { lastSubtitleImage = newImage }
            return (t, i)
        }
        if textChanged || imageChanged {
            var u = DisplayUIUpdate(position: posDur, durationAtLeast: posDur,
                                    generation: generation, notify: true)
            if textChanged { u.subtitleText = activeSub }
            if imageChanged {
                u.subtitleImage = newImage
                u.subtitleImageRect = newRect
            }
            applyDisplayUpdate(u)
        }
    }

    private nonisolated func logSync(now: Double, pts: Double, audioTime: Double) {
        let gen = playGeneration
        let (elapsed, fpsSamples, drops): (Double, Int, Int64) = displayLoopLock.withLock {
            let e = now - lastLogTime
            guard e > 5.0 else { return (0.0, 0, 0) }
            return (e, framesSinceLastLog, renderDropTotal)
        }
        guard elapsed > 5.0 else { return }
        let fps = Double(fpsSamples) / elapsed
        let diff = Int((pts - audioTime) * 1000)
        let subCueCount = subtitleLock.withLock { subtitleCues.count }
        let subImgCount = subtitleImageLock.withLock { subtitleImageCues.count }
        let av = displayLoopLock.withLock { () -> SyncDiagStats in
            let s = avOffsetStats
            avOffsetStats.reset()
            return s
        }
        let aq = audioClock.drainAdvanceDiag()
        let tick = drainTickDiag()
        let (shown, rewrites) = displayLoopLock.withLock { () -> (SyncDiagStats, Int) in
            let s = shownGapStats
            shownGapStats.reset()
            let r = diagPTSRewriteCount
            diagPTSRewriteCount = 0
            return (s, r)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playGeneration == gen else { return }
            let subStreamIdx = self.demuxer?.subtitleStreamIndex ?? -1
            let (tickCount, qCount): (Int, Int) = self.displayLoopLock.withLock { (self.ticksSinceLastLog, self.jitterBuffer.count) }
            let aBufMs = Int((self.audioUnitOutput?.bufferedDuration ?? 0) * 1000)
            let aUnd = self.audioUnitOutput?.drainUnderrunCount() ?? 0
            logger.info("q=\(qCount, privacy: .public) dur=\(Int(self.jitterBuffer.duration*1000), privacy: .public)ms fps=\(String(format:"%.1f",fps), privacy: .public) ticks=\(tickCount, privacy: .public) diff=\(diff, privacy: .public)ms a=\(String(format:"%.2f",audioTime), privacy: .public)s v=\(String(format:"%.2f",pts), privacy: .public)s aBuf=\(aBufMs, privacy: .public)ms aUnd=\(aUnd, privacy: .public) buf=\(self.state.isBuffering, privacy: .public) subStream=\(subStreamIdx, privacy: .public) subCues=\(subCueCount, privacy: .public) subImgCues=\(subImgCount, privacy: .public)")
            if Self.diagLoggingEnabled {
                let out = self.drainOutputQueueDiag()
                logger.info("[diag] out[cb=\(out.callbackCount, privacy: .public) cbSec=\(String(format: "%.2f", out.callbackSeconds), privacy: .public) wall=\(String(format: "%.2f", out.callbackWallSeconds), privacy: .public) qts=\(String(format: "%.2f", out.queueTimeSeconds), privacy: .public) enq=\(out.enqueues, privacy: .public) enqSec=\(String(format: "%.2f", out.enqueuedSeconds), privacy: .public) starts=\(out.starts, privacy: .public) pauses=\(out.pauses, privacy: .public) resumes=\(out.resumes, privacy: .public) paused=\(out.pausedNow, privacy: .public) bufSec=\(String(format: "%.2f", Double(out.bufferedSamplesNow) / Double(max(1, out.sampleRateNow))), privacy: .public) lead=\(String(format: "%.3f", out.leadSeconds), privacy: .public) rate=\(String(format: "%.2f", out.playRateNow), privacy: .public)]")
                logger.info("[diag] av[n=\(av.count, privacy: .public) mean=\(String(format:"%+.1f", av.mean*1000), privacy: .public)ms sd=\(String(format:"%.1f", av.stddev*1000), privacy: .public)ms min=\(String(format:"%+.1f", av.min*1000), privacy: .public)ms max=\(String(format:"%+.1f", av.max*1000), privacy: .public)ms jump=\(String(format:"%.1f", av.maxJump*1000), privacy: .public)ms flips=\(av.signFlips, privacy: .public)] aq[n=\(aq.count, privacy: .public) mean=\(String(format:"%.0f", aq.mean), privacy: .public) min=\(String(format:"%.0f", aq.min), privacy: .public) max=\(String(format:"%.0f", aq.max), privacy: .public) jump=\(String(format:"%.0f", aq.maxJump), privacy: .public)]")
                logger.info("[diag] tick[drain=\(tick.drainLag, privacy: .public) stall=\(tick.stallAhead, privacy: .public) deny=\(tick.checkDeny, privacy: .public) noFrame=\(tick.noFrame, privacy: .public) guardSkip=\(tick.guardSkip, privacy: .public) appends=\(tick.appends, privacy: .public) depth[n=\(tick.drainDepth.count, privacy: .public) mean=\(String(format:"%.0f", tick.drainDepth.mean*1000), privacy: .public)ms max=\(String(format:"%.0f", tick.drainDepth.max*1000), privacy: .public)ms]]")
                let th = self.drainThrottleDiag()
                let frontPts = self.jitterBuffer.peek(at: 0)?.pts ?? -1
                logger.info("[diag] throttle[pkt=\(th.packets, privacy: .public) slept=\(th.sleeps, privacy: .public) sleptMs=\(String(format: "%.0f", th.sleepMs), privacy: .public) audioSkip=\(th.audioStallSkips, privacy: .public) bp=\(th.backPressure, privacy: .public) lastPts=\(String(format: "%.3f", th.lastPts), privacy: .public) lastAudio=\(String(format: "%.3f", th.lastAudio), privacy: .public) ra=\(String(format: "%.2f", th.lastReadAhead), privacy: .public) gapMs=\(String(format: "%.0f", th.lastGapMs), privacy: .public) dropMs=\(String(format: "%.1f", th.maxDropMs), privacy: .public) pass=\(self.isPassthroughActive, privacy: .public) q=\(self.jitterBuffer.count, privacy: .public) dur=\(String(format: "%.2f", self.jitterBuffer.duration), privacy: .public) front=\(String(format: "%.3f", frontPts), privacy: .public) refused=\(self.jitterBuffer.droppedIncomingCount, privacy: .public)]")
                logger.info("[diag] show[n=\(shown.count, privacy: .public) mean=\(String(format:"%.1f", shown.mean*1000), privacy: .public)ms min=\(String(format:"%.1f", shown.min*1000), privacy: .public)ms max=\(String(format:"%.1f", shown.max*1000), privacy: .public)ms jump=\(String(format:"%.1f", shown.maxJump*1000), privacy: .public)ms] rewrites=\(rewrites, privacy: .public)")
            }

            let (bytesDelta, tpElapsed, hasBaseline): (Int64, Double, Bool) = self.throughputLock.withLock {
                (self.totalBytesRead - self.lastBytesLogged, now - self.lastThroughputTime, self.lastThroughputTime > 0)
            }
            if hasBaseline, tpElapsed > 1.0 {
                self.state.cacheSpeed = Int64(Double(bytesDelta) / tpElapsed)
                self.throughputLock.withLock {
                    self.lastBytesLogged = self.totalBytesRead
                    self.lastThroughputTime = now
                }
            } else if !hasBaseline {
                self.throughputLock.withLock {
                    self.lastBytesLogged = self.totalBytesRead
                    self.lastThroughputTime = now
                }
            }

            self.state.droppedVideoFrames = drops
            let recentDrops = max(0, drops - self.lastPublishedDropTotal)
            self.lastPublishedDropTotal = drops
            self.state.recentDroppedVideoFrames = recentDrops
            self.state.droppedVideoFramesPerSecond = elapsed > 0
                ? Double(recentDrops) / elapsed : 0
            let estBps = self.videoBitrateEstimator.bitsPerSecond
            if estBps > 0, let vi = self.state.videoInfo, (vi.bitrate ?? 0) <= 0 {
                self.state.videoInfo?.bitrate = estBps
                self.state.videoBitrateIsEstimated = true
            }

            self.displayLoopLock.withLock {
                self.lastLogTime = now
                self.framesSinceLastLog = 0
                self.ticksSinceLastLog = 0
            }
        }
    }

    // MARK: - Display → UI bridge

    nonisolated func applyDisplayUpdate(_ u: DisplayUIUpdate) {
        DispatchQueue.main.async { [weak self] in
            self?.applyDisplayUpdateOnMain(u)
        }
    }

    private func applyDisplayUpdateOnMain(_ u: DisplayUIUpdate) {
        guard u.generation == playGeneration else { return }

        if let pos = u.position { state.position = pos }
        if let d = u.durationAtLeast, d > state.duration { state.duration = d }

        let currentSecs = Double(state.position.components.seconds)
        let dlOffset = demuxer?.downloadedUpToOffset ?? -1
        let fileBytes = demuxer?.totalFileBytes ?? -1
        if dlOffset > 0, fileBytes > 0, state.duration > .zero {
            let dlFraction = min(1.0, Double(dlOffset) / Double(fileBytes))
            let dlSecs = dlFraction * Double(state.duration.components.seconds)
            state.bufferedDuration = .milliseconds(Int64(max(0, dlSecs - currentSecs) * 1000))
        } else {
            let downloaded = maxDownloadedPts
            state.bufferedDuration = downloaded > currentSecs
                ? .milliseconds(Int64((downloaded - currentSecs) * 1000))
                : .zero
        }

        if let t = u.subtitleText { state.currentSubtitleText = t }
        if let img = u.subtitleImage {
            state.currentSubtitleImage = img
            state.currentSubtitleImageRect = u.subtitleImageRect ?? .zero
        }
        if let fel = u.doviFELActive { state.doviFELActive = fel }
        state.audioOutputDegraded = displayLoopLock.withLock { audioDeviceDemoted }

        if u.notify { notifyStateChange() }
    }

    // MARK: - Display Link

    nonisolated func noteContentFrameRate(_ fps: Double) {
        let previous = contentFps
        contentFps = fps
        guard previous == 0 || abs(fps - previous) >= 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyFrameRateRange()
        }
    }

    func applyFrameRateRange() {
        #if os(iOS) || os(tvOS)
        guard let link = displayLink else { return }
        guard #available(iOS 15.0, tvOS 15.0, *) else { return }
        let range = FrameRateMatcher.displayRange(contentFps: contentFps, matchingEnabled: frameRateMatchingEnabled)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(range.minimum), maximum: Float(range.maximum), preferred: Float(range.preferred))
        #endif
    }

    func startDisplayLink() {
        displayLinkStartWallTime = CACurrentMediaTime()
        displayLoopLock.withLock { firstTickLogged = false; displayLoopStopped = false }
        #if os(iOS) || os(tvOS)
        let proxy = DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        displayLink?.invalidate()
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        displayLink = link
        applyFrameRateRange()
        let thread = Thread { [weak self] in
            let rl = RunLoop.current
            link.add(to: rl, forMode: .common)
            while !(self?.displayLoopStopped ?? true) {
                rl.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
            }
        }
        thread.name = "io.zyno.PlayerKit.displayLink"
        thread.qualityOfService = QualityOfService.userInteractive
        displayLinkThread = thread
        thread.start()
        #elseif os(macOS)
        if cvDisplayLink == nil {
            var link: CVDisplayLink?
            let createRC = CVDisplayLinkCreateWithActiveCGDisplays(&link)
            if let link {
                cvDisplayLink = link
            } else {
                logger.error("CVDisplayLinkCreateWithActiveCGDisplays FAILED rc=\(createRC) — using fallback timer only")
            }
        }
        if let cv = cvDisplayLink {
            let proxy = displayLinkProxy ?? DisplayLinkProxy(backend: self)
            displayLinkProxy = proxy
            let proxyPtr = Unmanaged.passUnretained(proxy).toOpaque()
            CVDisplayLinkSetOutputCallback(cv, { _, _, _, _, _, ctx in
                guard let ctx else { return kCVReturnSuccess }
                let p = Unmanaged<DisplayLinkProxy>.fromOpaque(ctx).takeUnretainedValue()
                p.tick()
                return kCVReturnSuccess
            }, proxyPtr)
            if !CVDisplayLinkIsRunning(cv) {
                CVDisplayLinkStart(cv)
            }
        }
        fallbackRenderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: displayFallbackQueue)
        let fallbackInterval: DispatchTimeInterval = cvDisplayLink == nil
            ? .milliseconds(8) : .milliseconds(33)
        timer.schedule(deadline: .now() + 0.05, repeating: fallbackInterval)
        timer.setEventHandler { [weak self] in
            self?.displayNextFrame()
        }
        timer.resume()
        fallbackRenderTimer = timer
        #endif
    }
}
