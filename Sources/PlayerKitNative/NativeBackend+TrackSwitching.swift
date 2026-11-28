import AVFoundation
import Foundation
import CoreGraphics
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

// MARK: - Audio & Subtitle Track Switching

extension NativeBackend {

    nonisolated static func audioTrackIsSwitchable(codecID: AVCodecID, passthroughAvailable: Bool) -> Bool {
        passthroughAvailable || avcodec_find_decoder(codecID) != nil
    }

    public func selectAudioTrack(id: String) {
        guard let demuxer else { return }
        guard let trackId = Int(id) else { return }
        guard trackId != demuxer.audioStreamIndex else { return }
        if let ctx = demuxer.formatContext {
            for i in 0..<Int(ctx.pointee.nb_streams) {
                guard let st = ctx.pointee.streams[i], Int(st.pointee.index) == trackId else { continue }
                let cid = st.pointee.codecpar.pointee.codec_id
                if !Self.audioTrackIsSwitchable(codecID: cid,
                                                passthroughAvailable: _injectedAudioOutput?.supportsPassthrough == true) {
                    logger.warning("selectAudioTrack id=\(trackId) refused: no decoder for codec \(String(cString: avcodec_get_name(cid)), privacy: .public) — keeping current track")
                    return
                }
                break
            }
        }
        logger.info("selectAudioTrack id=\(trackId) — dispatching to background (zyno#171)")

        let demuxerRef = demuxer
        Self.audioSwitchQueue.async { [weak self] in
            guard let self else { return }
            self.audioSwitchGate.begin()
            Task { @MainActor [weak self] in
                self?.state.isSwitchingAudioTrack = true
                self?.notifyStateChange()
            }
            defer {
                self.audioSwitchGate.end()
                Task { @MainActor [weak self] in
                    self?.state.isSwitchingAudioTrack = false
                    self?.notifyStateChange()
                }
            }
            self.lastSwitchedFromAudioTrack = Int(demuxerRef.audioStreamIndex)
            if self.performAudioTrackSwitchFast(trackId: trackId, demuxer: demuxerRef) { return }
            self.performAudioTrackSwitch(id: id, trackId: trackId, demuxer: demuxerRef)
        }
    }

    nonisolated func decodeAndEnqueueAudio(packet: UnsafeMutablePointer<AVPacket>,
                                          decoder: FFmpegAudioDecoder?,
                                          output: AudioUnitOutput?,
                                          pcmSink: (any AudioOutputBackend)? = nil,
                                          trackContent: Bool, packetPts: Double,
                                          outputRate: Double, tapPts: Double) {
        let pcm = decoder?.decode(packet: packet)
        if let pcm {
            if let cb = onDecodedAudio {
                cb(pcm.data, Int(decoder?.outputChannels ?? 2), outputRate, tapPts)
            }
            let stretched = audioTempo.process(pcm)
            if let sink = pcmSink {
                let sinkPts = tapPts.isFinite ? tapPts : .nan
                let sinkChannels = Int32(decoder?.outputChannels ?? 2)
                for out in stretched {
                    if let buf = Self.makeInjectedPCMBuffer(
                        frame: out, sampleRate: outputRate, channels: sinkChannels) {
                        sink.outputPCM(buf, pts: sinkPts)
                    }
                }
            } else {
                var contentPts = Double.nan
                if trackContent {
                    contentPts = packetPts.isFinite ? packetPts : playedContentTrackerEnd
                    playedContentTrackerEnd = contentPts + Double(pcm.sampleCount) / outputRate
                }
                for out in stretched {
                    output?.enqueue(out, contentPts: contentPts)
                }
            }
        }
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
    }

    private nonisolated static func makeInjectedPCMBuffer(frame: PCMFrame,
                                                          sampleRate: Double,
                                                          channels: Int32) -> AVAudioPCMBuffer? {
        let ch = Int(channels)
        guard ch > 0, sampleRate > 0, frame.sampleCount > 0 else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else { return nil }
        let frames = frame.sampleCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        let expected = frames * ch
        guard frame.data.count >= expected * MemoryLayout<Float>.size else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        frame.data.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { return }
            let src = srcBase.assumingMemoryBound(to: Float.self)
            guard let dst = buffer.floatChannelData else { return }
            for c in 0..<ch {
                let channel = dst[c]
                for i in 0..<frames {
                    channel[i] = src[i * ch + c]
                }
            }
        }
        return buffer
    }

    private func performAudioTrackSwitchFast(trackId: Int, demuxer: any PacketDemuxing) -> Bool {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let newStream = Int32(trackId)
        guard altAudioStreams.contains(newStream), state.isPlaying else { return false }
        demuxLock.lock()
        guard altAudioStreams.contains(newStream), state.isPlaying,
              !isPassthroughActive, _injectedAudioOutput?.acceptsPCM != true else {
            demuxLock.unlock(); return false
        }
        let posSecs = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18
        guard altAudioCache.covers(stream: newStream, at: posSecs, tolerance: 0.3) else {
            demuxLock.unlock(); return false
        }
        let oldStream = Int(demuxer.audioStreamIndex)
        guard demuxer.selectAudioStream(by: trackId), let stream = demuxer.audioStream else {
            demuxLock.unlock(); return false
        }
        if _injectedAudioOutput?.supportsPassthrough == true, demuxer.isPassthroughCodec,
           abs(state.rate - 1.0) < 0.001 {
            _ = demuxer.selectAudioStream(by: oldStream)
            demuxLock.unlock(); return false
        }
        logger.info("selectAudioTrack id=\(trackId) — fast path (cache hit, no seek)")

        audioUnitOutput?.stop()
        audioDecodeQueue.sync { audioDecoder?.flush() }
        let newDecoder = FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2,
                                            outputRateOverride: AudioDeviceSampleRate.preferred())
        audioDecoder = newDecoder
        discardAudioUntilPts = nil
        let cached = altAudioCache.take(stream: newStream, from: posSecs)
        refreshAltAudioStreams(demuxer)

        let sr = newDecoder?.outputSampleRate ?? 44100
        let ch = newDecoder?.outputChannels ?? 2
        audioTempo.reset(sampleRate: sr, channels: ch)
        audioClock.reset(to: posSecs, sampleRate: sr)
        let newOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        audioUnitOutput = newOutput
        newOutput.start(sampleRate: sr, channels: ch)
        newOutput.setPlaybackRate(state.rate)
        newOutput.pause()
        let trackContent = AudioUnitOutput.tracksPlayedContent
        let outputRate = Double(sr)
        for (pts, packet) in cached {
            audioDecodeQueue.async {
                self.decodeAndEnqueueAudio(packet: packet, decoder: newDecoder, output: newOutput,
                                           trackContent: trackContent, packetPts: trackContent ? pts : .nan,
                                           outputRate: outputRate, tapPts: pts)
            }
        }
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
            discardLock.withLock { audioAnchoredAtTarget = false }
        }
        let canResume = jitterBuffer.state == .playing
        demuxLock.unlock()

        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        if canResume { newOutput.resume() }

        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        lastAudioSwitchPath = "fast"
        logger.notice("[diag] audioswitch path=fast total=\(String(format: "%.1f", ms), privacy: .public)ms cachedPackets=\(cached.count, privacy: .public)")
        return true
    }

    private func performAudioTrackSwitch(id: String, trackId: Int, demuxer: any PacketDemuxing) {
        logger.info("selectAudioTrack id=\(trackId)")
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms(_ since: UInt64) -> String {
            String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6)
        }

        let readHead = maxDownloadedPts
        let playhead = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18
        logger.notice("[diag] audioswitch readahead=\(String(format: "%.1f", readHead - playhead), privacy: .public)s readHead=\(String(format: "%.1f", readHead), privacy: .public) playhead=\(String(format: "%.1f", playhead), privacy: .public)")

        audioUnitOutput?.stop()
        let tStop = ms(t0)

        let posSecs = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18

        let interruptToken = demuxer.interruptPendingReads()
        demuxLock.lock()
        let tLock = ms(t0)
        demuxer.resumeReads(after: interruptToken)
        audioDecodeQueue.sync { audioDecoder?.flush() }
        audioDecoder = nil
        let tQueue = ms(t0)
        guard demuxer.selectAudioStream(by: trackId) else {
            _ = demuxer.seek(to: posSecs)
            physicalSeekGeneration += 1
            seekLock.withLock { seekSerial += 1; seekLandedSerial = seekSerial }
            demuxLock.unlock()
            logger.warning("selectAudioTrack: stream \(trackId) not found, recreating original output")
            recreateAudioOutput()
            return
        }
        let tSeek0 = DispatchTime.now().uptimeNanoseconds
        _ = demuxer.seek(to: posSecs)
        let tSeek = ms(tSeek0)
        altAudioCache.removeAll()
        refreshAltAudioStreams(demuxer)
        if let landed = demuxer.lastSeekLandedPTS,
           FineSeekPolicy.shouldArm(landed: landed, target: posSecs) {
            discardLock.withLock { discardVideoUntilPts = posSecs; audioAnchoredAtTarget = true }
            discardAudioUntilPts = posSecs
            logger.info("fine-seek (track switch): discard \(String(format: "%.2f", posSecs - landed), privacy: .public)s (landed=\(String(format: "%.2f", landed), privacy: .public))")
        } else {
            discardLock.withLock { discardVideoUntilPts = nil; audioAnchoredAtTarget = false }
            discardAudioUntilPts = nil
        }
        if let stream = demuxer.audioStream {
            audioDecoder = FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2,
                                              outputRateOverride: AudioDeviceSampleRate.preferred())
        }
        videoDecoder?.flush()
        jitterBuffer.flush()
        physicalSeekGeneration += 1
        seekLock.withLock { seekSerial += 1; seekLandedSerial = seekSerial }
        demuxLock.unlock()
        let tUnlock = ms(t0)

        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        _renderer.flush()

        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        audioTempo.reset(sampleRate: sr, channels: ch)
        audioClock.reset(to: posSecs, sampleRate: sr)
        audioUnitOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        audioUnitOutput?.setPlaybackRate(state.rate)
        audioUnitOutput?.pause()
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }
        maxDownloadedPts = posSecs

        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()

        logger.info("selectAudioTrack done, new decoder sampleRate=\(self.audioDecoder?.outputSampleRate ?? 0)")
        lastAudioSwitchPath = "slow"
        logger.notice("[diag] audioswitch path=slow main=\(Thread.isMainThread, privacy: .public) stop=\(tStop, privacy: .public)ms lock=\(tLock, privacy: .public)ms audioQueue=\(tQueue, privacy: .public)ms seek=\(tSeek, privacy: .public)ms heldLock=\(tUnlock, privacy: .public)ms interrupted=\(interruptToken != 0, privacy: .public) total=\(ms(t0), privacy: .public)ms")
    }

    public func selectSubtitle(id: String?) {
        guard let demuxer else { return }
        let trackId = id.flatMap(Int.init)

        if let resolvedId = trackId, let fmtCtx = demuxer.formatContext {
            let nb = Int(fmtCtx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = fmtCtx.pointee.streams[i],
                      Int(s.pointee.index) == resolvedId else { continue }
                let cp = s.pointee.codecpar.pointee
                let codecName = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id)) : "none"
                logger.notice("[sub] selectSubtitle trackId=\(resolvedId) codec=\(codecName) tb=\(s.pointee.time_base.num)/\(s.pointee.time_base.den)")
                break
            }
        } else {
            logger.notice("[sub] selectSubtitle → disabled")
        }

        demuxLock.lock()
        demuxer.selectSubtitleStream(by: trackId)
        let resolvedIdx = demuxer.subtitleStreamIndex
        demuxLock.unlock()
        logger.notice("[sub] subtitleStreamIndex after select=\(resolvedIdx)")

        let hadText = state.currentSubtitleText != nil
        let hadImage = state.currentSubtitleImage != nil
        subtitleLock.withLock { subtitleCues.removeAll() }
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        displayLoopLock.withLock { lastSubtitleImage = nil }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        displayLoopLock.withLock { lastSubtitleText = nil }
        state.currentSubtitleText = nil
        state.selectedSubtitleTrackId = trackId
        if hadText || hadImage {
            notifyStateChange()
        }

        recreateSubtitleRenderers(demuxer: demuxer, trackId: trackId)
    }

    nonisolated func recreateSubtitleRenderers(demuxer: any PacketDemuxing, trackId: Int?) {
        subtitleDecoder = nil
        assRenderer = nil
        guard let resolvedTrackId = trackId else { return }
        let nb = Int(demuxer.formatContext?.pointee.nb_streams ?? 0)
        for i in 0..<nb {
            guard let s = demuxer.formatContext?.pointee.streams[i],
                  Int(s.pointee.index) == resolvedTrackId else { continue }
            let codecId = s.pointee.codecpar.pointee.codec_id
            if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                subtitleDecoder = FFmpegSubtitleDecoder(
                    stream: s,
                    videoSize: CGSize(width: codedVideoWidth, height: codedVideoHeight)
                )
                logger.notice("[sub] PGS/DVD decoder recreated: \(self.subtitleDecoder != nil ? "OK" : "FAILED")")
            } else if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                let r = Self.makeASSRenderer(
                    stream: s,
                    videoSize: CGSize(width: codedVideoWidth, height: codedVideoHeight),
                    fontFamily: subtitleFontFamily
                )
                assRenderer = r
                logger.notice("[sub] ASS renderer \(r != nil ? "created" : "unavailable (no extradata)")")
            }
            break
        }
    }

    private func recreateAudioOutput() {
        audioUnitOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        if let dec = audioDecoder {
            audioUnitOutput?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            audioUnitOutput?.pause()
            audioUnitOutput?.setPlaybackRate(state.rate)
        }
    }

    static func audioBitDepth(_ cp: AVCodecParameters) -> Int? {
        if cp.bits_per_raw_sample > 0 { return Int(cp.bits_per_raw_sample) }
        let bits = Int(av_get_bytes_per_sample(AVSampleFormat(rawValue: cp.format))) * 8
        return bits > 0 ? bits : nil
    }

    private func refreshAudioTracks() {
        guard let fmtCtx = demuxer?.formatContext else { return }
        var tracks: [TrackInfo] = []
        let nb = Int(fmtCtx.pointee.nb_streams)
        for i in 0..<nb {
            guard let s = fmtCtx.pointee.streams[i] else { continue }
            let cp = s.pointee.codecpar.pointee
            guard cp.codec_type == AVMEDIA_TYPE_AUDIO else { continue }

            let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id))
                : nil

            var title: String?
            var lang: String?
            if let meta = s.pointee.metadata {
                if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                    title = String(cString: v)
                }
                if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                    lang = String(cString: v)
                }
            }

            let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
            let isAtmos = (s.pointee.index == demuxer?.audioStreamIndex)
                ? (demuxer?.audioIsAtmos ?? false)
                : false

            tracks.append(TrackInfo(
                id: Int(s.pointee.index),
                title: title,
                lang: lang,
                codec: codecName,
                isDefault: isDefault,
                isAtmos: isAtmos,
                channels: cp.ch_layout.nb_channels > 0 ? Int(cp.ch_layout.nb_channels) : nil,
                sampleRate: cp.sample_rate > 0 ? Int(cp.sample_rate) : nil,
                bitDepth: Self.audioBitDepth(cp),
                bitrate: cp.bit_rate > 0 ? cp.bit_rate : nil
            ))
        }
        state.audioTracks = tracks
    }
}
