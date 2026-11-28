import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

/// Builds one concat-demuxer script entry: a `file` line plus per-file `option`
/// directives that carry `headers` to that specific clip's http open.
private func concatFileEntry(url: URL, headers: [String: String]) -> String {
    var lines = ["file '\(concatEscape(url.absoluteString))'"]
    var rest: [String: String] = [:]
    for (key, value) in headers {
        switch key.lowercased() {
        case "user-agent": lines.append("option user_agent '\(concatEscape(value))'")
        case "referer":    lines.append("option referer '\(concatEscape(value))'")
        default:           rest[key] = value
        }
    }
    if let (key, value) = rest.first {
        lines.append("option headers '\(concatEscape("\(key): \(value)"))'")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func concatEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

// MARK: - Open & Play Entry Points

extension NativeBackend {

    public func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration? = nil) {
        let previousRate = state.rate
        stop()
        state = PlayerState()
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        logger.notice("play \(url.absoluteString.prefix(120))")

        playGeneration += 1
        let gen = playGeneration

        Task.detached(priority: .userInitiated) { [weak self, preferredMaxVideoWidth] in
            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = preferredMaxVideoWidth
            do {
                try demuxer.open(url: url, headers: headers,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.open FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: url, headers: headers,
                                 seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    public func play(reader: any MediaRandomAccessReader,
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        let previousRate = state.rate
        stop()
        state = PlayerState()
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        let t0 = Date()
        logger.notice("play (custom I/O reader)")

        playGeneration += 1
        let gen = playGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let t1 = Date()
            logger.info("GCD block started, delay=\(String(format: "%.0f", t1.timeIntervalSince(t0) * 1000))ms")

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.open(reader: reader,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.open (reader) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            let t2 = Date()
            logger.info("demuxer.open done in \(String(format: "%.0f", t2.timeIntervalSince(t1) * 1000))ms")

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: URL(string: "custom-io://reader")!,
                                 headers: [:], seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    public func play(concatURLs: [URL], headers: [String: String],
                     seekTo: Duration?, knownDuration: Duration? = nil) {
        let previousRate = state.rate
        stop()
        state = PlayerState()
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        guard !concatURLs.isEmpty else {
            state.error = "concat: no URLs"
            notifyStateChange()
            return
        }

        if concatURLs.count == 1 {
            play(url: concatURLs[0], headers: headers, seekTo: seekTo,
                 knownDuration: knownDuration)
            return
        }

        logger.notice("play concat \(concatURLs.count) urls")

        playGeneration += 1
        let gen = playGeneration

        let urls = concatURLs
        let hdrs = headers
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let listContent = urls.map { concatFileEntry(url: $0, headers: hdrs) }.joined()
            let tmpDir = FileManager.default.temporaryDirectory
            let listFile = tmpDir.appendingPathComponent("zyno-concat-\(UUID().uuidString).txt")
            do {
                try listContent.write(to: listFile, atomically: true, encoding: .utf8)
            } catch {
                let msg = "concat: failed to write list file: \(error.localizedDescription)"
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: listFile) }

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.openConcat(listFileURL: listFile, headers: hdrs,
                                       skipDurationProbe: knownDuration != nil,
                                       knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.openConcat FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "concat://list")!,
                                 headers: hdrs, seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    public func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        let previousRate = state.rate
        stop()
        state = PlayerState()
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        guard !clips.isEmpty else {
            state.error = "play(clips:): no clips"
            notifyStateChange()
            return
        }

        logger.notice("play \(clips.count) clips")

        playGeneration += 1
        let gen = playGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let demuxer = MultiClipDemuxer(clips: clips)
            guard let demuxer else {
                let msg = "play(clips:): MultiClipDemuxer init failed (empty clips or non-positive duration)"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            do {
                try demuxer.open()
            } catch {
                logger.error("demuxer.open (clips) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "clips://multi")!,
                                 headers: [:], seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    /// adopt 预热会话(zyno#108):跳过 new+open,直接 _finishOpen。
    public func play(prepared: PreparedMedia, seekTo: Duration? = nil,
                     knownDuration: Duration? = nil) throws {
        guard let demuxer = prepared.consume() else {
            throw PreparedMediaError.notConsumable
        }

        let previousRate = state.rate
        stop()
        state = PlayerState()
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        let url: URL
        let headers: [String: String]
        switch prepared.source {
        case .url(let u, let h):
            url = u
            headers = h
        case .reader:
            url = URL(string: "custom-io://reader")!
            headers = [:]
        }

        logger.notice("play (prepared, adopted demuxer)")
        playGeneration += 1

        _finishOpen(demuxer: demuxer, url: url, headers: headers,
                    seekTo: seekTo, knownDuration: knownDuration)
    }

    // MARK: - _finishOpen & Pipeline Setup

    func _finishOpen(demuxer: any PacketDemuxing, url: URL, headers: [String: String],
                     seekTo: Duration?, knownDuration: Duration?) {
        let t0 = Date()
        self.demuxer = demuxer

        let demuxDur: Double
        if let fd = demuxer as? FFmpegDemuxer {
            demuxDur = fd.duration
        } else if let mc = demuxer as? MultiClipDemuxer {
            demuxDur = mc.timeline.totalDurationSecs
        } else {
            demuxDur = 0
        }
        if let kd = knownDuration, kd > .zero {
            state.duration = kd
        } else if demuxDur > 0 {
            state.duration = Duration.seconds(demuxDur)
        }
        systemDVPipelineDurationSecs = Double(self.state.duration.components.seconds)
        systemDVHasAudio = demuxer.audioStreamIndex >= 0
        logger.info("duration: knownDuration=\(knownDuration.map{"\(Double($0.components.seconds))s"} ?? "nil") demuxer=\(String(format:"%.1f",demuxDur))s → using \(String(format:"%.1f",Double(self.state.duration.components.seconds)))s self=\(String(format:"%p", UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))")

        configureVideoColorAndStrategy(demuxer: demuxer)
        _renderer.displayCapability = displayCapability
        setupVideoDecoder(demuxer: demuxer)
        populateVideoInfo(demuxer: demuxer)
        populateAudioAndSubtitleTracks(demuxer: demuxer)
        setupAudioChain(demuxer: demuxer)

        _renderer.configure(
            codedSize: CGSize(width: codedVideoWidth, height: codedVideoHeight),
            sampleAspectRatio: demuxer.sampleAspectRatio)

        startOpenedPipelines(seekTo: seekTo)
        logger.info("_finishOpen done in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")
    }

    private func configureVideoColorAndStrategy(demuxer: any PacketDemuxing) {
        guard let vs = demuxer.videoStream else { return }
        let cp = vs.pointee.codecpar.pointee
        var cpParams = VideoColorParams()
        switch cp.color_trc {
        case AVCOL_TRC_SMPTE2084:    cpParams.transfer = .pq
        case AVCOL_TRC_ARIB_STD_B67: cpParams.transfer = .hlg
        default: break
        }
        switch cp.color_space {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: cpParams.matrix = .bt2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:     cpParams.matrix = .bt601
        default: break
        }
        cpParams.range = cp.color_range == AVCOL_RANGE_JPEG ? .full : .limited
        renderConfigLock.withLock {
            self.colorParams = cpParams
            if self.colorParams.transfer == .pq || self.colorParams.transfer == .hlg {
                logger.info("HDR: transfer=\(String(describing: self.colorParams.transfer)) matrix=\(String(describing: self.colorParams.matrix))")
            }
        }

        let attrs = demuxer.videoStreamAttributes()
            ?? VideoStreamAttributes(width: 0, height: 0, codecID: 0,
                                     colorMatrix: .bt709, transfer: .sdr, range: .limited)
        #if DEBUG
        let forceSystemDV = ProcessInfo.processInfo.environment["DV_SYSTEM_FORCE_EDR"] == "1"
            || UserDefaults.standard.bool(forKey: "dvSystemForceEDR")
        let effectiveDisplay: DisplayCapability = forceSystemDV
            ? DisplayCapability(supportsEDR: true,
                                targetPeakNits: max(displayCapability.targetPeakNits, 1000),
                                supports10Bit: displayCapability.supports10Bit,
                                supportsHLGOOTF: displayCapability.supportsHLGOOTF)
            : displayCapability
        #else
        let effectiveDisplay = displayCapability
        #endif
        var systemDV = SystemDVCapability.unavailable
        if dolbyVisionOutput == .system, !systemDVDisabledForSession,
           _renderer is ASBDLRenderer {
            systemDV = SystemDVCapability.probe(display: effectiveDisplay)
        }
        let strat = decideRendererStrategy(
            stream: attrs,
            prefersTenBit: _renderer.prefersTenBit,
            display: effectiveDisplay,
            doviEnabled: doviEnabled,
            systemDolbyVision: systemDV,
            dolbyVisionOutput: dolbyVisionOutput
        )
        let doviOpenPref = dolbyVisionOutput == .system ? "system" : "software"
        let doviOpenLine = "[dovi-open] pref=\(doviOpenPref) doviEnabled=\(doviEnabled) sysDV=\(systemDV.isAvailable) EDR=\(effectiveDisplay.supportsEDR) pro10bit=\(_renderer.prefersTenBit) disabled4Session=\(systemDVDisabledForSession) stream=P\(attrs.doviProfile)/c\(attrs.blSignalCompatibilityId) dv=\(attrs.isDolbyVision) -> \(String(describing: strat))"
        logger.notice("\(doviOpenLine, privacy: .public)")
        renderConfigLock.withLock { self.rendererStrategy = strat }

        if strat.videoPipeline == .decodedFrames,
           let provider = toneMapperProvider,
           let asbdl = _renderer as? ASBDLRenderer {
            asbdl.toneMapper = provider(strat, attrs)
        }
        let codecName = cp.codec_id != AV_CODEC_ID_NONE
            ? String(cString: avcodec_get_name(cp.codec_id)) : "?"
        logger.info("""
        strategy decision: codec=\(codecName, privacy: .public) \(cp.width, privacy: .public)x\(cp.height, privacy: .public) \
        bits_per_raw=\(cp.bits_per_raw_sample, privacy: .public) profile=\(cp.profile, privacy: .public) \
        trc=\(cp.color_trc.rawValue, privacy: .public) matrix=\(cp.color_space.rawValue, privacy: .public) range=\(cp.color_range.rawValue, privacy: .public) \
        → resolved(transfer=\(String(describing: cpParams.transfer), privacy: .public) matrix=\(String(describing: cpParams.matrix), privacy: .public) range=\(String(describing: cpParams.range), privacy: .public)) \
        isHEVC10Bit=\(attrs.isHEVC10Bit, privacy: .public) \
        isDoVi=\(demuxer.isDolbyVision, privacy: .public) profile=\(demuxer.doviProfile, privacy: .public) \
        hasHDR10Plus=\(demuxer.hasHDR10Plus, privacy: .public) \
        sideData=\(demuxer.sideDataTypesDescription, privacy: .public) \
        displayEDR=\(self.displayCapability.supportsEDR, privacy: .public) renderer10bit=\(self._renderer.prefersTenBit, privacy: .public) \
        → \(String(describing: strat), privacy: .public)
        """)
    }

    private func setupVideoDecoder(demuxer: any PacketDemuxing) {
        guard let vs = demuxer.videoStream else { return }
        let sar = demuxer.sampleAspectRatio
        let isDoVi = demuxer.isDolbyVision
        let convertedP7Compat = demuxer.videoStreamAttributes()?.doviConvertedCompatId

        if rendererStrategy?.videoPipeline == .compressedPassthrough {
            if let fd = demuxer as? FFmpegDemuxer,
               let dovi = fd.doviConfiguration {
                let isMpegTS = fd.isMpegTSContainer
                let p7Rewriter: DoviP7PacketRewriter? = convertedP7Compat != nil
                    ? DoviP7PacketRewriter(inputFormat: isMpegTS ? .annexB : .lengthPrefixed)
                    : nil
                let effectiveDovi = convertedP7Compat.map {
                    SystemDVFormatDescription.convertedP81Record(from: dovi, compatId: $0)
                } ?? dovi
                let hvcCOverride: [UInt8]? = (convertedP7Compat != nil && isMpegTS)
                    ? fd.synthesizedHvcC()
                    : nil
                if let builder = SystemDVSampleBuilder(
                       stream: vs, dovi: effectiveDovi,
                       hvcCOverride: hvcCOverride,
                       p7PacketRewriter: p7Rewriter.map { pw in { data in pw.rewrite(data) } }),
                   let asbdl = _renderer as? ASBDLRenderer {
                    systemDVP7Rewriter = p7Rewriter
                    let renderer = systemDVRendererFactory?(asbdl.displayLayer)
                        ?? SystemDVRenderer(displayLayer: asbdl.displayLayer)
                    renderer.onFailure = { [weak self] err in
                        self?.fallbackToSoftwareDV(
                            reason: "renderer failure: \(err.map { String(describing: $0) } ?? "layer failed")")
                    }
                    systemDVRenderer = renderer
                    systemDVBuilder = builder
                    systemDVActive = true
                    systemDVStarted = false
                    systemDVFirstSamplePts = .nan
                    systemDVStartWall = 0
                    activeVideoPipeline = .compressedPassthrough
                    let cpW = Int(vs.pointee.codecpar.pointee.width)
                    let cpH = Int(vs.pointee.codecpar.pointee.height)
                    codedVideoWidth = cpW; codedVideoHeight = cpH
                    videoWidth  = sar > 1.0 ? Int(Double(cpW) * sar) : cpW
                    videoHeight = sar < 1.0 ? Int(Double(cpH) / sar) : cpH
                    logger.info("[dovi-sys] system path active: profile=\(demuxer.doviProfile) convertedCompat=\(convertedP7Compat.map(String.init) ?? "none", privacy: .public) ts=\(isMpegTS) strategy=\(String(describing: self.rendererStrategy), privacy: .public)")
                } else {
                    fallbackStrategyToSoftware(demuxer: demuxer)
                }
            } else {
                fallbackStrategyToSoftware(demuxer: demuxer)
            }
        } else {
            systemDVActive = false
            systemDVRenderer = nil
            systemDVBuilder = nil
            systemDVP7Rewriter = nil
            activeVideoPipeline = .decodedFrames
        }

        guard !systemDVActive else { return }
        let preference = rendererStrategy?.decoderPreference ?? .vtHW
        let tVDec = Date()
        switch preference {
        case .ffmpegSW:
            if let dec = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                logger.info("video: FFmpeg SW \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) (strategy \(String(describing: self.rendererStrategy)))")
            } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                logger.info("video: FFmpeg SW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)\(isDoVi ? " (DoVi as HDR10)" : "")")
            }
        case .ffmpegHW:
            if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                logger.info("video: FFmpeg VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) hw=\(dec.isHardware)")
            } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                logger.info("video: FFmpeg HW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)")
            }
        case .vtHW:
            let isRouteB = rendererStrategy == .doviRouteB
            if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit,
                                        colorParams: colorParams,
                                        extractDoviRpu: isRouteB,
                                        isDoviProfile7: demuxer.doviProfile == 7) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                let dvTag = isRouteB ? " (DoVi route b)" : (isDoVi ? " (DoVi as HDR10)" : "")
                logger.info("video: VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) 10bit=\(dec.is10Bit)\(dvTag)")
            } else if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                videoDecoder = dec
                applyDecodedVideoDimensions(width: dec.width, height: dec.height, sar: sar)
                let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                logger.info("video: VT failed, FFmpeg fallback \(dec.width)x\(dec.height)\(sarStr) hw=\(dec.isHardware)")
            }
        }
        if let dec = videoDecoder {
            state.videoDecoderPath = Self.decoderPath(for: dec)
        }
        logger.info("video decoder init took \(String(format: "%.0f", Date().timeIntervalSince(tVDec) * 1000))ms")
    }

    private func fallbackStrategyToSoftware(demuxer: any PacketDemuxing) {
        logger.info("[dovi-sys] 样本构造器初始化失败,open 阶段即回软件路径")
        systemDVP7Rewriter = nil
        systemDVActive = false
        activeVideoPipeline = .decodedFrames
        let softAttrs = demuxer.videoStreamAttributes()
            ?? VideoStreamAttributes(width: 0, height: 0, codecID: 0,
                                     colorMatrix: .bt709, transfer: .sdr, range: .limited)
        let softwareStrat = decideRendererStrategy(
            stream: softAttrs,
            prefersTenBit: _renderer.prefersTenBit,
            display: displayCapability,
            doviEnabled: doviEnabled,
            systemDolbyVision: .unavailable,
            dolbyVisionOutput: dolbyVisionOutput
        )
        renderConfigLock.withLock { self.rendererStrategy = softwareStrat }
    }

    private func applyDecodedVideoDimensions(width: Int, height: Int, sar: Double) {
        codedVideoWidth = width
        codedVideoHeight = height
        videoWidth = sar > 1.0 ? Int(Double(width) * sar) : width
        videoHeight = sar < 1.0 ? Int(Double(height) / sar) : height
    }

    private func populateVideoInfo(demuxer: any PacketDemuxing) {
        guard let vs = demuxer.videoStream else { return }
        let cp = vs.pointee.codecpar.pointee
        let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
            ? String(cString: avcodec_get_name(cp.codec_id))
            : nil
        let isHDR = colorParams.transfer == .pq || colorParams.transfer == .hlg
        let fr = vs.pointee.avg_frame_rate
        let fps: Double? = (fr.num > 0 && fr.den > 0) ? Double(fr.num) / Double(fr.den) : nil
        let profile: String?
        if cp.profile > 0, let name = avcodec_profile_name(cp.codec_id, cp.profile) {
            profile = String(cString: name)
        } else {
            profile = nil
        }
        state.videoInfo = VideoInfo(
            width: videoWidth,
            height: videoHeight,
            codec: codecName,
            isHDR: isHDR,
            colorMatrix: isHDR ? "\(colorParams.matrix)" : nil,
            transfer: isHDR ? "\(colorParams.transfer)" : nil,
            isDolbyVision: demuxer.isDolbyVision,
            fps: fps,
            profile: profile,
            level: cp.level > 0 ? Int(cp.level) : nil,
            bitrate: cp.bit_rate > 0 ? cp.bit_rate : nil
        )
        state.videoBitrateIsEstimated = false
        if demuxer.isDolbyVision {
            logger.notice("[dovi-probe] DOVI_CONF present: profile=\(demuxer.doviProfile) blCompatId=\(demuxer.doviBLSignalCompatibilityId) isHDR=\(isHDR, privacy: .public)")
        } else {
            logger.notice("[dovi-probe] no DOVI_CONF from demuxer (side data: \(demuxer.sideDataTypesDescription, privacy: .public)) isHDR=\(isHDR, privacy: .public)")
        }
    }

    private func populateAudioAndSubtitleTracks(demuxer: any PacketDemuxing) {
        if let ctx = demuxer.formatContext {
            var tracks: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
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
                let isAtmos = (s.pointee.index == demuxer.audioStreamIndex)
                    ? demuxer.audioIsAtmos
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
            logger.info("audio tracks: \(tracks.count)")
        }

        if let ctx = demuxer.formatContext {
            var subs: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
                let cp = s.pointee.codecpar.pointee
                guard cp.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }

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
                subs.append(TrackInfo(
                    id: Int(s.pointee.index),
                    title: title,
                    lang: lang,
                    codec: codecName,
                    isDefault: isDefault
                ))
            }
            state.subtitleTracks = subs
            logger.info("subtitle tracks: \(subs.count)")

            chapters = FFmpegChapterParser.parse(ctx)
            if !chapters.isEmpty {
                logger.info("chapters: \(self.chapters.count)")
            }

            if demuxer.subtitleStreamIndex < 0, !subs.isEmpty {
                let chosen: TrackInfo?
                if let pref = preferredSubtitleLanguage, !pref.isEmpty {
                    if pref.lowercased() == "off" {
                        chosen = nil
                        logger.info("subtitles: language pref off — no embedded subtitle selected")
                    } else {
                        chosen = TrackLanguageMatcher.pickSubtitle(from: subs, preference: pref)
                        if let c = chosen {
                            logger.info("subtitles: language pref '\(pref)' → stream \(c.id) (\(c.lang ?? "?"))")
                        }
                    }
                } else {
                    chosen = subs.first(where: { $0.isDefault }) ?? subs.first
                }
                if let id = chosen?.id {
                    demuxer.selectSubtitleStream(by: id)
                    state.selectedSubtitleTrackId = id
                    logger.info("[sub] auto-selected stream \(id) (\(chosen?.lang ?? "?"))")
                }
            }
        }

        subtitleDecoder = nil
        assRenderer = nil
        if let defaultSubStream = demuxer.subtitleStream {
            let codecId = defaultSubStream.pointee.codecpar.pointee.codec_id
            let vSize = CGSize(width: codedVideoWidth, height: codedVideoHeight)
            if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                subtitleDecoder = FFmpegSubtitleDecoder(stream: defaultSubStream, videoSize: vSize)
            } else if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                let r = Self.makeASSRenderer(stream: defaultSubStream, videoSize: vSize,
                                             fontFamily: subtitleFontFamily)
                assRenderer = r
                logger.notice("[sub] ASS renderer \(r != nil ? "created" : "unavailable (no extradata)")")
            }
        }
    }

    private func setupAudioChain(demuxer: any PacketDemuxing) {
        if let pref = preferredAudioLanguage,
           let picked = TrackLanguageMatcher.pickAudio(from: state.audioTracks, preference: pref),
           picked.id != demuxer.audioStreamIndex,
           demuxer.selectAudioStream(by: picked.id) {
            logger.info("audio: language pref '\(pref)' → stream \(picked.id) (\(picked.lang ?? "?"))")
        }

        altAudioCache.removeAll()
        refreshAltAudioStreams(demuxer)

        if let as_ = demuxer.audioStream,
           let dec = FFmpegAudioDecoder(stream: as_, sampleRate: 44100, channels: 2,
                                         outputRateOverride: AudioDeviceSampleRate.preferred()) {
            audioDecoder = dec
            let out = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
            out.onDeviceDemoted = { [weak self] in self?.handleAudioDeviceDemoted() }
            out.onDeviceRecovered = { [weak self] in self?.handleAudioDeviceRecovered() }
            audioUnitOutput = out
            isPassthroughActive = false
            isInjectedPCMActive = false
            logger.info("audio: \(dec.outputSampleRate)Hz \(dec.outputChannels)ch")
            if demuxer.audioStreamIndex >= 0 {
                state.selectedAudioTrackId = Int(demuxer.audioStreamIndex)
            }
        }
    }

    private func startOpenedPipelines(seekTo: Duration?) {
        resetBufferingState()
        wireJitterBuffer()
        if let out = audioUnitOutput, let dec = audioDecoder {
            out.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            audioTempo.reset(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            out.setPlaybackRate(state.rate)
            out.pause()
        }

        discardLock.withLock { audioAnchoredAtTarget = false }
        if let seekTo { _seek(to: seekTo, synchronousDemuxerSeek: true) }

        startDemuxLoop()
        startDisplayLink()

        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
            audioDeviceDemoted = false
        }

        state.isPlaying = true
        notifyStateChange()
        if systemDVActive {
            audioUnitOutput?.resume()
            _injectedAudioOutput?.resume()
            state.isBuffering = false
        }
    }
}
