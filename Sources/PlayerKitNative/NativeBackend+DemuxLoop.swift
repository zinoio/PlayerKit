import AVFoundation
import Foundation
import CoreGraphics
import QuartzCore
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

// MARK: - Demux Loop & Packet Routing

extension NativeBackend {

    func startDemuxLoop() {
        demuxStateLock.lock()
        if demuxLoopRunning {
            if let current = demuxer, current as AnyObject === demuxLoopDemuxer as AnyObject {
                demuxCancelled = false
                demuxStateLock.unlock()
                logger.info("startDemuxLoop: loop already running (same demuxer), reviving it")
                return
            }
            var waitedTicks = 0
            while demuxLoopRunning && waitedTicks < 200 {
                demuxStateLock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
                demuxStateLock.lock()
                waitedTicks += 1
            }
            if demuxLoopRunning {
                logger.warning("startDemuxLoop: old loop did not exit in 1s, forcing")
                demuxLoopRunning = false
                demuxLoopDemuxer = nil
            }
        }
        demuxLoopRunning = true
        demuxLoopDemuxer = demuxer
        demuxCancelled = false
        demuxStateLock.unlock()

        guard let demuxer = self.demuxer else {
            logger.error("startDemuxLoop: demuxer is nil (stop was called?)")
            demuxStateLock.lock()
            demuxLoopRunning = false
            demuxLoopDemuxer = nil
            demuxStateLock.unlock()
            return
        }
        let audioDec = audioDecoder
        let audioOut = audioUnitOutput
        let clock = audioClock
        let jitter = jitterBuffer
        let dLock = demuxLock
        let sLock = seekLock

        DispatchQueue.global().async { [weak self, colorParams] in
            defer {
                if let self = self {
                    self.demuxStateLock.lock()
                    if let current = self.demuxLoopDemuxer, current as AnyObject === demuxer as AnyObject {
                        self.demuxLoopRunning = false
                        self.demuxLoopDemuxer = nil
                    }
                    self.demuxStateLock.unlock()
                }
            }
            var ptsValidator = PTSValidator()
            var packetCount: Int32 = 0
            var eofRecoveryDone = false
            var lastSeenPhysicalGen: Int64 = -1
            var diagAppendCount = 0
            var diagLastAppendedPts = -Double.infinity
            var lastThrottleAudioPos: Double = 0
            var lastAudioAdvanceWall = CACurrentMediaTime()

            let frameDuration: Double
            var contentFPS: Double = 0
            if let vs = demuxer.videoStream {
                let fr = vs.pointee.avg_frame_rate
                frameDuration = fr.num > 0 ? Double(fr.den) / Double(fr.num) : 1.0 / 25.0
                if fr.num > 0 && fr.den > 0 {
                    let fps = Double(fr.num) / Double(fr.den)
                    contentFPS = fps
                    jitter.configureFrameRate(fps)
                    self?.noteContentFrameRate(fps)
                }
            } else {
                frameDuration = 1.0 / 25.0
            }
            ptsValidator.frameDuration = frameDuration

            while true {
                guard let self, !self.demuxCancelled else { break }

                dLock.lock()
                if self.demuxCancelled { dLock.unlock(); break }
                if demuxer as AnyObject !== self.demuxer as AnyObject {
                    dLock.unlock()
                    logger.info("demux loop: demuxer replaced, exiting")
                    break
                }

                let currentSerial = sLock.withLock { self.seekSerial }
                let landedAtStart = SeekFrameGate.landedAtIterationStart(
                    landedSerial: self.seekLandedSerial, iterationSerial: currentSerial)

                let currentPhysicalGen = self.physicalSeekGeneration
                if currentPhysicalGen != lastSeenPhysicalGen {
                    logger.info("ptsValidator.reset() for physicalSeekGeneration=\(currentPhysicalGen) (was \(lastSeenPhysicalGen))")
                    ptsValidator.reset()
                    lastSeenPhysicalGen = currentPhysicalGen
                }

                if self.audioSwitchGate.isPending {
                    dLock.unlock()
                    self.audioSwitchGate.waitUntilSwitchFinishes(cancelled: { self.demuxCancelled })
                    continue
                }

                guard let result = demuxer.readPacket() else {
                    dLock.unlock()
                    let action = self.handleDemuxReadEOFOrError(
                        demuxer: demuxer, packetCount: packetCount,
                        eofRecoveryDone: &eofRecoveryDone,
                        dLock: dLock, audioDec: audioDec, audioOut: audioOut,
                        clock: clock, jitter: jitter)
                    switch action {
                    case .retry: continue
                    case .stop:  break
                    }
                    break
                }

                packetCount += 1
                let pktSize = Int(result.packet.pointee.size)
                if pktSize > 0 { self.throughputLock.withLock { self.totalBytesRead += Int64(pktSize) } }
                let streamIndex = result.streamIndex
                let packet = result.packet
                var handedOffPacket = false

                if streamIndex == demuxer.videoStreamIndex {
                    self.processVideoPacket(
                        packet: packet, pktSize: pktSize, didSwitchClip: result.didSwitchClip,
                        demuxer: demuxer, dLock: dLock, sLock: sLock,
                        ptsValidator: &ptsValidator, colorParams: colorParams,
                        contentFPS: contentFPS, packetCount: packetCount,
                        landedAtStart: landedAtStart, currentSerial: currentSerial,
                        clock: clock, jitter: jitter,
                        diagAppendCount: &diagAppendCount,
                        diagLastAppendedPts: &diagLastAppendedPts,
                        lastThrottleAudioPos: &lastThrottleAudioPos,
                        lastAudioAdvanceWall: &lastAudioAdvanceWall)
                } else if streamIndex == demuxer.elVideoStreamIndex, demuxer.elVideoStreamIndex >= 0 {
                    self.videoDecoder?.feedExternalElPacket(packet)
                    dLock.unlock()
                } else if streamIndex == demuxer.audioStreamIndex {
                    handedOffPacket = self.processAudioPacket(
                        packet: packet, streamIndex: streamIndex,
                        demuxer: demuxer, dLock: dLock)
                } else if streamIndex == demuxer.subtitleStreamIndex,
                          demuxer.subtitleStreamIndex >= 0 {
                    self.processSubtitlePacket(
                        packet: packet, streamIndex: streamIndex,
                        demuxer: demuxer, dLock: dLock, clock: clock)
                } else if self.altAudioStreams.contains(streamIndex) {
                    let pts = Self.ptsFromPacket(packet, demuxer: demuxer)
                    if pts.isFinite, let clone = av_packet_clone(packet) {
                        self.altAudioCache.append(stream: streamIndex, pts: pts, payload: clone)
                    }
                    dLock.unlock()
                } else {
                    dLock.unlock()
                }

                if !handedOffPacket {
                    var p: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&p)
                }
            }
        }
    }

    private enum DemuxReadEndAction {
        case retry
        case stop
    }

    private nonisolated func handleDemuxReadEOFOrError(
        demuxer: any PacketDemuxing,
        packetCount: Int32,
        eofRecoveryDone: inout Bool,
        dLock: NSLock,
        audioDec: FFmpegAudioDecoder?,
        audioOut: AudioUnitOutput?,
        clock: AudioClock,
        jitter: VideoJitterBuffer
    ) -> DemuxReadEndAction {
        if demuxer.lastDemuxInterrupted || audioSwitchGate.isPending {
            if Self.diagLoggingEnabled {
                logger.info("[diag] demux read interrupted for audio switch — waiting")
            }
            audioSwitchGate.waitUntilSwitchFinishes(cancelled: { self.demuxCancelled })
            return .retry
        }
        if let demuxError = demuxer.lastDemuxError {
            let msg = "demux I/O error: "
                + ((demuxError as? CustomStringConvertible)?.description
                   ?? String(describing: demuxError))
            logger.error("\(msg, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.demuxCancelled else { return }
                self.state.error = msg
                self.notifyStateChange()
            }
            return .stop
        }
        if packetCount == 0, !eofRecoveryDone {
            eofRecoveryDone = true
            logger.error("immediate EOF, recovering to 0")
            dLock.lock()
            _ = demuxer.seek(to: 0)
            discardAudioUntilPts = nil
            discardLock.withLock { self.discardVideoUntilPts = nil; self.audioAnchoredAtTarget = false }
            videoDecoder?.flush()
            audioDecodeQueue.sync { audioDec?.flush() }
            dLock.unlock()
            jitter.flush()
            clock.reset(to: 0, sampleRate: audioDec?.outputSampleRate ?? 44100)
            audioOut?.stop()
            if let dec = audioDec {
                audioOut?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            }
            return .retry
        }
        logger.info("demux EOF after \(packetCount) packets")
        jitter.markEOF()
        return .stop
    }

    private nonisolated func processVideoPacket(
        packet: UnsafeMutablePointer<AVPacket>,
        pktSize: Int,
        didSwitchClip: Bool,
        demuxer: any PacketDemuxing,
        dLock: NSLock,
        sLock: NSLock,
        ptsValidator: inout PTSValidator,
        colorParams: VideoColorParams,
        contentFPS: Double,
        packetCount: Int32,
        landedAtStart: Bool,
        currentSerial: Int64,
        clock: AudioClock,
        jitter: VideoJitterBuffer,
        diagAppendCount: inout Int,
        diagLastAppendedPts: inout Double,
        lastThrottleAudioPos: inout Double,
        lastAudioAdvanceWall: inout Double
    ) {
        videoBitrateEstimator.record(packetBytes: pktSize, frameRate: contentFPS)
        let rawPTS = Self.ptsFromPacket(packet, demuxer: demuxer)
        let pts: Double
        if didSwitchClip, rawPTS.isFinite {
            ptsValidator.forceRebase(to: rawPTS)
            pts = rawPTS
            let subIdx = demuxer.subtitleStreamIndex
            if subIdx >= 0 {
                recreateSubtitleRenderers(demuxer: demuxer, trackId: Int(subIdx))
            }
        } else {
            pts = ptsValidator.validate(rawPTS)
            if rawPTS.isFinite, abs(pts - rawPTS) > 0.0005 {
                displayLoopLock.withLock { self.diagPTSRewriteCount += 1 }
            }
        }
        if rawPTS.isFinite && rawPTS > maxDownloadedPts { maxDownloadedPts = rawPTS }
        if packetCount < 5 || (packetCount % 500 == 0) {
            logger.debug("pkt#\(packetCount) rawPTS=\(String(format:"%.3f",rawPTS)) pts=\(String(format:"%.3f",pts)) audio=\(String(format:"%.3f",clock.audioTime))")
        }

        if let vt = self.videoDecoder as? VTVideoDecoder, vt.needsSoftwareFallback,
           let vs = demuxer.videoStream,
           let sw = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
            logger.notice("VT→SW fallback: \(sw.width)x\(sw.height) — HW decoder failed, using FFmpeg SW")
            let vtCodecID = vs.pointee.codecpar.pointee.codec_id
            logger.notice("[vt-probe] codec=\(vtCodecID == AV_CODEC_ID_H264 ? "h264" : (vtCodecID == AV_CODEC_ID_HEVC ? "hevc" : "other"), privacy: .public) is10Bit=\(vt.is10Bit, privacy: .public) sideData=\(demuxer.sideDataTypesDescription, privacy: .public)")
            self.videoDecoder = sw
            DispatchQueue.main.async { [weak self] in
                self?.state.videoDecoderPath = .ffmpegSoftware
            }
        }

        if systemDVActive, let builder = systemDVBuilder, let renderer = systemDVRenderer {
            let doNotDisplay = discardLock.withLock { self.discardVideoUntilPts }
                .map { pts < $0 } ?? false
            if let sb = builder.makeSample(packet: packet, pts: pts, doNotDisplay: doNotDisplay) {
                if systemDVFirstSamplePts.isNaN {
                    systemDVFirstSamplePts = pts
                    systemDVStarted = true
                    systemDVStartWall = CACurrentMediaTime()
                    systemDVLastPresentOrStartWall = systemDVStartWall
                    let r = displayLoopLock.withLock { self.displayRate }
                    renderer.start(at: pts, rate: Float(r))
                    logger.info("[dovi-sys] timebase start at \(String(format: "%.3f", pts), privacy: .public)s")
                }
                renderer.enqueue(sb)
            }
            dLock.unlock()
            if let pw = systemDVP7Rewriter, pw.shouldFallbackToSoftware() {
                let snap = pw.validationSnapshot()
                fallbackToSoftwareDV(reason: "P7 RPU validation: \(snap.checked) 帧全无有效 RPU")
            }
            if renderer.bufferedSeconds >= renderer.maxLookaheadSeconds {
                Thread.sleep(forTimeInterval: 0.020)
            }
        } else {
            let decoded = self.videoDecoder?.decode(packet: packet)
            dLock.unlock()

            if let frame = decoded,
               SeekFrameGate.accepts(landedAtIterationStart: landedAtStart,
                                     iterationSerial: currentSerial,
                                     latestSerial: sLock.withLock({ self.seekSerial })) {
                let framePts: Double
                let diagBounded: Bool
                if let decoderPts = frame.pts, decoderPts.isFinite,
                   decoderPts <= rawPTS, rawPTS - decoderPts < 1.0 {
                    framePts = pts - (rawPTS - decoderPts)
                    diagBounded = true
                } else {
                    framePts = pts
                    diagBounded = false
                }
                diagAppendCount += 1
                if diagAppendCount <= 200, Self.diagLoggingEnabled {
                    let appendIdx = diagAppendCount
                    let regressed = framePts < diagLastAppendedPts
                    logger.info("[diag] append#\(appendIdx, privacy: .public) framePts=\(String(format:"%.3f",framePts), privacy: .public) decoderPts=\(frame.pts.map { String(format:"%.3f",$0) } ?? "nil", privacy: .public) bounded=\(diagBounded, privacy: .public) rawPTS=\(String(format:"%.3f",rawPTS), privacy: .public) REGRESSED=\(regressed, privacy: .public)")
                }
                diagLastAppendedPts = framePts
                jitter.append(.init(pixelBuffer: frame.pixelBuffer, elPixelBuffer: frame.elPixelBuffer, pts: framePts, metadata: frame.metadata))
                displayLoopLock.withLock { self.diagAppendsSinceLog += 1 }
                let ptsCopy = framePts
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let d = Duration.milliseconds(Int64(ptsCopy * 1000))
                    if d > self.state.duration { self.state.duration = d }
                }
            }
        }

        applyDemuxReadAheadThrottle(
            pts: pts, clock: clock, jitter: jitter,
            lastThrottleAudioPos: &lastThrottleAudioPos,
            lastAudioAdvanceWall: &lastAudioAdvanceWall)
    }

    private nonisolated func applyDemuxReadAheadThrottle(
        pts: Double,
        clock: AudioClock,
        jitter: VideoJitterBuffer,
        lastThrottleAudioPos: inout Double,
        lastAudioAdvanceWall: inout Double
    ) {
        let audioPos: Double
        if _injectedAudioOutput != nil && injectedClockActive,
           let pt = _injectedAudioOutput?.playbackTime {
            audioPos = pt + audioClock.fullDelay
            passthroughWallClockAnchor = nil
        } else if _injectedAudioOutput != nil && injectedClockActive {
            if let anchor = passthroughWallClockAnchor {
                audioPos = anchor.pts + CACurrentMediaTime() - anchor.wall
                    + audioClock.fullDelay
            } else if pts.isFinite {
                passthroughWallClockAnchor = (CACurrentMediaTime(), pts)
                audioPos = pts
            } else {
                audioPos = 0
            }
        } else {
            audioPos = clock.audioTime
        }

        let readAhead = jitter.readAheadSeconds
        let throttleGap = pts - audioPos - readAhead
        let wantsThrottle = pts.isFinite && throttleGap > 0
        let nowWall = CACurrentMediaTime()
        let audioDelta = audioPos - lastThrottleAudioPos
        if audioDelta > 0 { lastAudioAdvanceWall = nowWall }
        let audioStalled = nowWall - lastAudioAdvanceWall > 0.5
        var throttledSleep = 0.0
        if wantsThrottle, !audioStalled {
            throttledSleep = min(throttleGap, 0.050)
            Thread.sleep(forTimeInterval: throttledSleep)
        }
        if Self.diagLoggingEnabled {
            displayLoopLock.withLock {
                self.diagThrottlePackets += 1
                self.diagThrottleLastPts = pts
                self.diagThrottleLastAudio = audioPos
                self.diagThrottleLastReadAhead = readAhead
                self.diagThrottleLastGapMs = wantsThrottle ? throttleGap * 1000 : 0
                if audioDelta < 0, -audioDelta < 5.0,
                   -audioDelta * 1000 > self.diagThrottleMaxDropMs {
                    self.diagThrottleMaxDropMs = -audioDelta * 1000
                }
                if wantsThrottle {
                    if audioStalled {
                        self.diagThrottleAudioStallSkips += 1
                    } else {
                        self.diagThrottleSleeps += 1
                        self.diagThrottleSleepMs += throttledSleep * 1000
                    }
                }
            }
        }
        lastThrottleAudioPos = audioPos

        if jitter.isFull {
            Thread.sleep(forTimeInterval: 0.010)
            if Self.diagLoggingEnabled {
                displayLoopLock.withLock { self.diagBackPressureSleeps += 1 }
            }
        }
        if jitter.count >= jitter.maxFrameCount {
            Thread.sleep(forTimeInterval: 0.010)
            if Self.diagLoggingEnabled {
                displayLoopLock.withLock { self.diagBackPressureSleeps += 1 }
            }
        }
    }

    private nonisolated func processAudioPacket(
        packet: UnsafeMutablePointer<AVPacket>,
        streamIndex: Int32,
        demuxer: any PacketDemuxing,
        dLock: NSLock
    ) -> Bool {
        let codecName = String(cString: avcodec_get_name(
            demuxer.audioStream!.pointee.codecpar.pointee.codec_id))
        let currentRate = displayLoopLock.withLock { displayRate }
        let usePassthrough: Bool
        if let injected = _injectedAudioOutput,
           injected.supportsPassthrough,
           demuxer.isPassthroughCodec,
           abs(currentRate - 1.0) < 0.001 {
            usePassthrough = true
        } else {
            usePassthrough = false
        }

        if let until = discardAudioUntilPts,
           NativeBackend.ptsFromPacket(packet, demuxer: demuxer) < until {
            dLock.unlock()
            return false
        }
        if usePassthrough {
            isPassthroughActive = true
            let pkt = packet.pointee
            let size = Int(pkt.size)
            let pts = NativeBackend.ptsFromPacket(packet, demuxer: demuxer)
            var data = Data(count: size)
            if size > 0, let buf = pkt.data {
                data.withUnsafeMutableBytes { raw in
                    raw.baseAddress!.copyMemory(from: buf, byteCount: size)
                }
            }
            dLock.unlock()
            _injectedAudioOutput?.outputCompressed(data, pts: pts, codec: codecName)
            return false
        }

        if isPassthroughActive { isPassthroughActive = false }
        let pcmToInjected = self._injectedAudioOutput?.acceptsPCM == true
        if pcmToInjected != isInjectedPCMActive {
            isInjectedPCMActive = pcmToInjected
        }
        let currentDec = self.audioDecoder
        let currentOut = self.audioUnitOutput
        let currentSink = pcmToInjected ? self._injectedAudioOutput : nil
        let cachePts = Self.ptsFromPacket(packet, demuxer: demuxer)
        if altCacheEnabled, cachePts.isFinite, let clone = av_packet_clone(packet) {
            altAudioCache.append(stream: streamIndex, pts: cachePts, payload: clone)
        }
        let tapPts = Self.audioPacketPts(packet, demuxer: demuxer)
        dLock.unlock()
        let trackContent = AudioUnitOutput.tracksPlayedContent
        let packetPts = trackContent ? Self.ptsFromPacket(packet, demuxer: demuxer) : .nan
        let outputRate = Double(currentDec?.outputSampleRate ?? 48000)
        audioDecodeQueue.async {
            self.decodeAndEnqueueAudio(packet: packet, decoder: currentDec, output: currentOut,
                                       pcmSink: currentSink,
                                       trackContent: trackContent, packetPts: packetPts,
                                       outputRate: outputRate, tapPts: tapPts)
        }
        return true
    }

    private nonisolated func processSubtitlePacket(
        packet: UnsafeMutablePointer<AVPacket>,
        streamIndex: Int32,
        demuxer: any PacketDemuxing,
        dLock: NSLock,
        clock: AudioClock
    ) {
        let stream = demuxer.subtitleStream
        let codecId = stream?.pointee.codecpar.pointee.codec_id
        let codecName = codecId.map { String(cString: avcodec_get_name($0)) } ?? "nil"
        if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
            let r = self.assRenderer
            let tb = stream?.pointee.time_base ?? AVRational(num: 0, den: 0)
            let tbSecs = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
            let nopts = Int64(bitPattern: 0x8000000000000000)
            let ptsValid = r != nil && tbSecs > 0
                && packet.pointee.pts != nopts
                && packet.pointee.size > 0
                && packet.pointee.data != nil
            let pts = Double(packet.pointee.pts) * tbSecs
            let dur = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * tbSecs : 5.0
            dLock.unlock()
            if ptsValid {
                let data = Data(bytes: packet.pointee.data!, count: Int(packet.pointee.size))
                r?.processPacket(data, ptsSecs: pts, durationSecs: dur)
                logger.debug("[sub] ASS packet → libass: pts=\(String(format:"%.2f",pts)) dur=\(String(format:"%.2f",dur))")
            } else if let cue = Self.parseASSCue(packet: packet, stream: stream) {
                self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                logger.debug("[sub] ASS cue appended (text fallback): pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts)) text=\(cue.text.prefix(30))")
            }
        } else if codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT {
            let cue = Self.parseSRTCue(packet: packet, stream: stream)
            dLock.unlock()
            if let cue {
                self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                logger.debug("[sub] SRT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
            } else {
                logger.warning("[sub] SRT parseSRTCue returned nil")
            }
        } else if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
            let dec = self.subtitleDecoder
            let audioPos = clock.audioTime
            dLock.unlock()
            if let cue = dec?.decode(packet: packet) {
                let adjustedStart = cue.startPts < audioPos ? audioPos : cue.startPts
                self.subtitleImageLock.withLock {
                    let cutoff = adjustedStart
                    for i in self.subtitleImageCues.indices {
                        if self.subtitleImageCues[i].endPts > cutoff {
                            self.subtitleImageCues[i] = SubtitleImageCue(
                                startPts: self.subtitleImageCues[i].startPts,
                                endPts: cutoff,
                                image: self.subtitleImageCues[i].image,
                                rect: self.subtitleImageCues[i].rect)
                        }
                    }
                    self.subtitleImageCues.append(
                        SubtitleImageCue(startPts: adjustedStart, endPts: cue.endPts,
                                         image: cue.image, rect: cue.rect)
                    )
                }
                logger.debug("[sub] PGS cue appended: pts=\(String(format:"%.2f",adjustedStart))-\(String(format:"%.2f",cue.endPts))")
            } else if dec == nil {
                logger.warning("[sub] PGS packet received but subtitleDecoder is nil")
            }
        } else if codecId == AV_CODEC_ID_WEBVTT {
            let cue = Self.parseWebVTTCue(packet: packet, stream: stream)
            dLock.unlock()
            if let cue {
                self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                logger.debug("[sub] WebVTT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
            } else {
                logger.warning("[sub] WebVTT parseWebVTTCue returned nil")
            }
        } else if codecId == AV_CODEC_ID_MOV_TEXT {
            let cue = Self.parseMOVTextCue(packet: packet, stream: stream)
            dLock.unlock()
            if let cue {
                self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                logger.debug("[sub] MOVText cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
            } else {
                logger.warning("[sub] MOVText parseMOVTextCue returned nil")
            }
        } else {
            logger.warning("[sub] unsupported subtitle codec=\(codecName) streamIdx=\(streamIndex)")
            dLock.unlock()
        }
    }

    // MARK: - PTS & Subtitle Packet Helpers

    private nonisolated static func audioPacketPts(_ packet: UnsafeMutablePointer<AVPacket>,
                                                   demuxer: any PacketDemuxing) -> Double {
        guard let aStream = demuxer.audioStream else { return .nan }
        let tb = aStream.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard tb.den > 0, packet.pointee.pts != nopts else { return .nan }
        let pts = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
        if aStream.pointee.start_time != nopts {
            let startOffset = Double(aStream.pointee.start_time) * Double(tb.num) / Double(tb.den)
            return pts - startOffset
        }
        return pts
    }

    nonisolated static func ptsFromPacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                          demuxer: any PacketDemuxing) -> Double {
        guard let vs = demuxer.videoStream else { return .nan }
        let tb = vs.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard tb.den > 0, packet.pointee.pts != nopts else { return .nan }
        let pts = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
        if vs.pointee.start_time != nopts {
            let startOffset = Double(vs.pointee.start_time) * Double(tb.num) / Double(tb.den)
            return pts - startOffset
        }
        return pts
    }

    static func decoderPath(for decoder: any VideoDecoding) -> VideoDecoderPath {
        if decoder is VTVideoDecoder { return .videoToolbox }
        if let ff = decoder as? FFmpegVideoDecoder {
            return ff.isHardware ? .videoToolbox : .ffmpegSoftware
        }
        return .ffmpegSoftware
    }

    nonisolated static func makeASSRenderer(
        stream: UnsafeMutablePointer<AVStream>, videoSize: CGSize,
        fontFamily: String?) -> ASSRenderer? {
        guard let par = stream.pointee.codecpar else { return nil }
        guard let ex = par.pointee.extradata, par.pointee.extradata_size > 0 else { return nil }
        let exData = Data(bytes: ex, count: Int(par.pointee.extradata_size))
        let tb = stream.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        let offset: Double
        if stream.pointee.start_time != nopts, tb.den > 0 {
            offset = Double(stream.pointee.start_time) * Double(tb.num) / Double(tb.den)
        } else {
            offset = 0
        }
        return ASSRenderer(extradata: exData, videoSize: videoSize,
                           startOffsetSecs: offset, preferredFontFamily: fontFamily)
    }

    private nonisolated static func parseASSCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA else { return nil }

        guard let raw = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                           count: Int(packet.pointee.size)),
                               encoding: .utf8) else { return nil }

        let parts = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count >= 9 else { return nil }

        var text = String(parts[8]).trimmingCharacters(in: .newlines)
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    private nonisolated static func parseSRTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    private nonisolated static func parseWebVTTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    private nonisolated static func parseMOVTextCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 2,
              let rawPtr = packet.pointee.data else { return nil }

        let textLen = Int(rawPtr[0]) << 8 | Int(rawPtr[1])
        guard textLen > 0, textLen <= packet.pointee.size - 2 else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr + 2,
                                                            count: textLen),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }
}
