import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os
import PlayerKit

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "audio.output")

/// Pull-mode CoreAudio `AudioUnit` output (`kAudioUnitSubType_RemoteIO` on iOS/tvOS,
/// `kAudioUnitSubType_DefaultOutput` on macOS) backed by an in-memory `PCMRingBuffer`.
///
/// Why Pull-mode `AudioUnit` instead of `AudioQueue`:
/// 1. iOS `AudioQueue` (`audiomxd`) defaults to a 72,000-frame (1.5s) internal decode
///    ring buffer, firing buffer callbacks ~1.3–1.5s BEFORE audio reaches the speaker.
///    Pull-mode `AudioUnit` pulls ~5–10ms IO slices directly on hardware cadence, so
///    consumed samples track real speaker output closely, and exact hardware/Bluetooth
///    output latency is queried via `AVAudioSession.outputLatency` / `kAudioUnitProperty_Latency`.
/// 2. High packet-rate streams (TrueHD: 1,200 frames/s @ 40 samples; Blu-ray LPCM:
///    200 frames/s @ 240 samples) previously triggered 200–1,200 XPC calls/s
///    (`AudioQueueAllocateBuffer` + `EnqueueBuffer` + `Start` + `FreeBuffer`), choking
///    `audiomxd` and stalling playback. With `PCMRingBuffer`, `enqueue()` is a single
///    in-memory `memcpy` with zero XPC calls.
public final class AudioUnitOutput: AudioOutputBackend {
    /// Guards `audioUnit`, `running`, `paused`, `ringBuffer`, `bufferedSamples`,
    /// `enqueuedFrames`, `playedOutputSamples`, and diagnostic counters.
    ///
    /// Both `enqueueDirect` and `audioUnitRenderCallback` hold `lock` ONLY for an
    /// in-memory `memcpy` (~1 µs) — never across AudioToolbox/CoreAudio API calls.
    /// `stop()`/`flush()` swap `audioUnit` to `nil` under the lock and dispose
    /// outside the lock so `AudioOutputUnitStop` cannot deadlock with a render callback.
    private let lock = NSLock()

    private var audioUnit: AudioComponentInstance?
    private let clock: AudioClock
    private var _channels: Int32 = 2
    private var enqueuedFrames = 0
    var bufferedFrameCount = 0
    private var running = false
    private var paused = false

    /// In-memory circular buffer bridging `enqueueDirect` (decode thread) and
    /// `audioUnitRenderCallback` (CoreAudio RT IO thread). Guarded by `lock`.
    private let ringBuffer = PCMRingBuffer(capacity: 2 * 1024 * 1024, maxCapacity: 16 * 1024 * 1024)

    /// Total real (non-silence) output samples pulled by the AudioUnit render
    /// callback since the current unit was created. Guarded by `lock`.
    private var playedOutputSamples: Int64 = 0

    // MARK: Audio delay (zyno#104)

    /// Physical hold for d>0: frames park here before the ring buffer. See
    /// AudioDelayLine. Guarded by its own lock; ordering output lock → line
    /// lock only (the line never calls back in).
    private let delayLine = AudioDelayLine()
    /// User audio delay in CONTENT seconds (≥ 0 here — the negative half is a
    /// pure clock offset owned by AudioClock). Guarded by lock.
    private var _delayTargetContent: Double = 0

    // Test seams (off by default; production never sets them). With
    // `tracksPlayedContent` on, the source-content PTS of every enqueued frame is
    // tracked in sample units so tests can compare what is HEARD with what is SHOWN.
    // `mutedForTesting` zeroes output in the render callback so tests run silently.
    nonisolated(unsafe) static var tracksPlayedContent = false
    nonisolated(unsafe) static var mutedForTesting = false

    /// Test seams for AudioUnit control entry points. Production uses the real
    /// CoreAudio functions; tests substitute slow/failing implementations.
    nonisolated(unsafe) static var pauseImpl: (AudioComponentInstance) -> OSStatus = {
        AudioOutputUnitStop($0)
    }
    nonisolated(unsafe) static var startImpl: (AudioComponentInstance) -> OSStatus = {
        AudioOutputUnitStart($0)
    }
    /// Volume parameter seam (2026-11-09). Production applies software gain in
    /// the render callback (works identically on iOS RemoteIO / tvOS / macOS);
    /// tests hook this seam to assert clamped values applied to live/rebuilt units.
    nonisolated(unsafe) static var setVolumeParamImpl: (AudioComponentInstance, Float) -> OSStatus = { _, _ in
        noErr
    }
    /// Device-time query seam (#72). Production reads `playedOutputSamples` directly
    /// (zero XPC); tests hook this seam to count device queries across `freshWindow`.
    nonisolated(unsafe) static var getCurrentTimeImpl: ((AudioComponentInstance) -> (sampleTime: Double, valid: Bool))?
    /// #72 test seam: freshWindow override (default 0.1s).
    nonisolated(unsafe) static var clockFreshWindowForTesting: TimeInterval?
    /// Test seam: override reported hardware output latency (seconds). Nil in production.
    nonisolated(unsafe) static var outputLatencyOverrideForTesting: Double?

    // MARK: - #608 音频设备死亡降级

    /// 设备健康(降级/探测节流/恢复边沿,纯逻辑见 AudioDeviceHealth)。
    let deviceHealth = AudioDeviceHealth()
    var deviceHealthForTesting: AudioDeviceHealth { deviceHealth }
    /// 降级边沿(连续 Start 失败越过阈值):backend 安装,切视频时钟续播。
    nonisolated(unsafe) var onDeviceDemoted: (() -> Void)?
    /// 恢复边沿(降级期真实回调到达 = 设备 IO 复活):backend 重校准时钟。
    nonisolated(unsafe) var onDeviceRecovered: (() -> Void)?

    private func recordStartFailure() {
        if deviceHealth.recordStartFailure(now: ProcessInfo.processInfo.systemUptime) {
            logger.error("[#608] 音频输出设备连续 Start 失败 → 降级:画面按源帧率续播,音频静音,定时探测恢复")
            onDeviceDemoted?()
        }
    }

    /// #608:音频时钟停转看门狗(见 AudioStallWatchdog)。由显示循环每 tick
    /// 调用;true = 判定设备停转,调用方执行降级。
    func noteDisplayTickForStall(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running, !paused, clock.hasConsumedOutput else {
            stallWatchdog.reset()
            return false
        }
        return stallWatchdog.note(now: now, audioTime: clock.audioTime)
    }

    private var stallWatchdog = AudioStallWatchdog()

    /// Serial queue that owns every AudioUnit control call (Stop/Start) so hot
    /// paths (jitter callbacks, seek, pause/resume) never block on HAL/IO-cycle waits.
    private let controlQueue = DispatchQueue(label: "io.zyno.PlayerKit.audio.control")

    private func currentUnitLocked() -> AudioComponentInstance? {
        lock.lock(); defer { lock.unlock() }
        return audioUnit
    }

    private struct ContentSpan {
        var startPts: Double
        var totalSamples: Int
        var remainingSamples: Int
        var sampleDuration: Double
    }
    private var contentFifo: [ContentSpan] = []
    private var playedContentEndPTS: Double = .nan

    /// Test seam: source-content PTS (seconds) up to which audio has been pulled
    /// by the AudioUnit; NaN until a frame with a known PTS has been consumed.
    func playedContentEnd() -> Double {
        lock.lock(); defer { lock.unlock() }
        return playedContentEndPTS
    }

    /// Test seam: whether a live AudioUnit exists (`start()` succeeded).
    var hasQueueForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return audioUnit != nil
    }

    /// Upper bound (seconds of audio) the ring buffer may hold while paused.
    var maxPausedBufferSeconds: Double = 5.0

    /// Samples (per channel) currently buffered in the ring buffer and not yet pulled.
    /// Guarded by `lock`.
    private var bufferedSamples = 0

    /// Upper bound (seconds) on audio taken beyond wall-clock playback rate (zyno#361).
    /// With Pull-mode AudioUnit, hardware pulls at 1× naturally, so lead stays ~0;
    /// kept as a safety net and to preserve the existing pacing contract/tests.
    var maxPlayingLeadSeconds: Double = 2.0

    /// Seconds without a render callback (while playing, not paused) after which
    /// `rebuildQueueIfStarved()` rebuilds the AudioUnit.
    var starvationRebuildSeconds: Double = 2.0

    /// Wall time of the last AudioUnit render callback. Guarded by `lock`.
    private var lastCallbackWall: TimeInterval = 0
    /// Starvation-triggered rebuilds since start (test/diag seam).
    private var queueRebuilds = 0

    // True-progress accounting for maxPlayingLeadSeconds. Guarded by lock.
    private var takenOutputSamples: Int64 = 0
    private var leadAnchorWall: TimeInterval = 0
    private var leadAnchorTaken: Int64 = 0

    // Cached hardware output latency (seconds). Refreshed off the RT thread.
    private var _cachedOutputLatency: Double = 0
    private var _lastLatencyRefreshWall: TimeInterval = 0

    // [diag] cumulative queue-health counters, guarded by lock.
    private var diagEnqueues = 0
    private var diagStarts = 0
    private var diagPauses = 0
    private var diagResumes = 0
    private var diagCallbackCount = 0
    private var diagCallbackSamples: Int64 = 0
    private var diagCallbackWall: TimeInterval = 0
    private var diagLastCallbackWall: TimeInterval = 0
    private var diagQueueTimeLast: Double?
    private var diagQueueTimeDelta: Double = 0
    private var diagEnqueuedSamples: Int64 = 0
    private var diagUnderrunCount = 0

    func drainUnderrunCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = diagUnderrunCount
        diagUnderrunCount = 0
        return n
    }

    public let supportsPassthrough: Bool = false

    struct QueueDiag {
        var enqueues = 0
        var starts = 0
        var pauses = 0
        var resumes = 0
        var pausedNow = false
        var bufferedSamplesNow = 0
        var bufferedFramesNow = 0
        var callbackCount = 0
        var callbackSeconds = 0.0
        var callbackWallSeconds = 0.0
        var queueTimeSeconds = 0.0
        var enqueuedSeconds = 0.0
        var sampleRateNow: Int32 = 48000
        var playRateNow: Double = 1.0
        var leadSeconds = 0.0
    }

    func drainQueueDiag() -> QueueDiag {
        lock.lock(); defer { lock.unlock() }
        let sr = max(1, clock.sampleRate)
        let d = QueueDiag(enqueues: diagEnqueues, starts: diagStarts, pauses: diagPauses,
                          resumes: diagResumes, pausedNow: paused,
                          bufferedSamplesNow: bufferedSamples,
                          bufferedFramesNow: bufferedFrameCount,
                          callbackCount: diagCallbackCount,
                          callbackSeconds: Double(diagCallbackSamples) / Double(sr),
                          callbackWallSeconds: diagCallbackWall,
                          queueTimeSeconds: diagQueueTimeDelta / Double(sr),
                          enqueuedSeconds: Double(diagEnqueuedSamples) / Double(sr),
                          sampleRateNow: sr,
                          playRateNow: _playbackRate,
                          leadSeconds: max(0, Double(takenOutputSamples - leadAnchorTaken) / Double(sr)
                              - (ProcessInfo.processInfo.systemUptime - leadAnchorWall)))
        diagEnqueues = 0; diagStarts = 0; diagPauses = 0; diagResumes = 0
        diagCallbackCount = 0; diagCallbackSamples = 0; diagCallbackWall = 0
        diagQueueTimeDelta = 0; diagQueueTimeLast = nil; diagEnqueuedSamples = 0
        diagLastCallbackWall = 0
        return d
    }

    public var bufferedDuration: Double {
        lock.lock(); defer { lock.unlock() }
        let sr = Double(max(1, clock.sampleRate))
        return Double(bufferedSamples) / sr
    }

    /// Live hardware output latency in seconds (speaker / AirPods / Bluetooth A2DP).
    ///
    /// When the render callback hands samples at content time `T` to CoreAudio,
    /// those samples reach the user's ears at `now + hardwareOutputLatency`.
    /// Subtracting `hardwareOutputLatency * playbackRate` from the consumed clock
    /// aligns rendered video frames with what is actually audible right now.
    var hardwareOutputLatency: Double {
        if let override = Self.outputLatencyOverrideForTesting {
            return max(0, override)
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let stale = now - _lastLatencyRefreshWall > 0.5
        let cached = _cachedOutputLatency
        let unit = audioUnit
        lock.unlock()
        guard stale else { return cached }
        let measured = Self.measureHardwareOutputLatency(unit: unit)
        lock.lock()
        _cachedOutputLatency = measured
        _lastLatencyRefreshWall = now
        lock.unlock()
        return measured
    }

    private static func measureHardwareOutputLatency(unit: AudioComponentInstance?) -> Double {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let outLat = session.outputLatency
        let ioDur = session.ioBufferDuration
        let total = (outLat.isFinite ? max(0, outLat) : 0) + (ioDur.isFinite ? max(0, ioDur) : 0)
        // Sanity-clamp: Bluetooth A2DP is typically 0.15–0.30s; cap at 1.0s against bogus values.
        return min(1.0, total)
        #else
        var latency: Float64 = 0
        if let unit {
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                                    kAudioUnitScope_Global, 0, &latency, &size) != noErr {
                latency = 0
            }
        }
        return latency.isFinite ? max(0, min(1.0, latency)) : 0
        #endif
    }

    init(clock: AudioClock, delaySecs: Double = 0) {
        self.clock = clock
        _delayTargetContent = max(0, delaySecs.isFinite ? delaySecs : 0)
        _ = delayLine.setTarget(_delayTargetContent)
    }

    deinit { stop() }

    public func configure(streamInfo: AudioStreamInfo) async throws {
        // no-op: configured in start(sampleRate:channels:)
    }

    /// Convert an AVAudioPCMBuffer to a PCMFrame and enqueue it.
    public func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let totalSamples = frameCount * channelCount
        var data = Data(count: totalSamples * 4)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.assumingMemoryBound(to: Float.self)
            for ch in 0..<channelCount {
                let src = floatData[ch]
                for i in 0..<frameCount {
                    dst[i * channelCount + ch] = src[i]
                }
            }
        }
        let frame = PCMFrame(data: data, pts: pts, sampleCount: frameCount)
        enqueue(frame)
    }

    /// Compressed passthrough is not supported. No-op.
    public func outputCompressed(_ packet: Data, pts: Double, codec: String) {
        // no-op
    }

    func start(sampleRate: Int32, channels: Int32) {
        let (oldUnit, _) = disposeUnderLock()
        if let old = oldUnit {
            Self.teardownUnit(old)
        }

        let sr = sampleRate > 0 ? sampleRate : 44100
        let ch = channels > 0 ? channels : 2
        _channels = ch
        delayLine.configure(sampleRate: sr)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: {
                #if os(iOS) || os(tvOS)
                return kAudioUnitSubType_RemoteIO
                #else
                return kAudioUnitSubType_DefaultOutput
                #endif
            }(),
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioComponentFindNext FAILED")
            return
        }

        var newUnit: AudioComponentInstance?
        var rc = AudioComponentInstanceNew(component, &newUnit)
        guard rc == noErr, let unit = newUnit else {
            logger.error("AudioComponentInstanceNew FAILED: \(rc)")
            return
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(sr),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(ch) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(ch) * 4,
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        rc = AudioUnitSetProperty(unit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &format,
                                  UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard rc == noErr else {
            logger.error("AudioUnitSetProperty(StreamFormat) FAILED: \(rc)")
            AudioComponentInstanceDispose(unit)
            return
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: audioUnitRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        rc = AudioUnitSetProperty(unit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &callbackStruct,
                                  UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard rc == noErr else {
            logger.error("AudioUnitSetProperty(SetRenderCallback) FAILED: \(rc)")
            AudioComponentInstanceDispose(unit)
            return
        }

        rc = AudioUnitInitialize(unit)
        guard rc == noErr else {
            logger.error("AudioUnitInitialize FAILED: \(rc)")
            AudioComponentInstanceDispose(unit)
            return
        }

        let savedVolume = currentVolume()
        if !Self.mutedForTesting, savedVolume != 1.0 {
            _ = Self.setVolumeParamImpl(unit, savedVolume)
        }

        let bytesPerSec = Int(sr) * Int(ch) * 4
        let desiredCap = Int(ceil(max(maxPausedBufferSeconds + 1.0, 6.0))) * bytesPerSec
        let measuredLatency = Self.measureHardwareOutputLatency(unit: unit)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        ringBuffer.ensureCapacity(desiredCap)
        ringBuffer.reset()
        _deviceBaseContent = clock.audioTime
        _deviceBaseSample = 0
        playedOutputSamples = 0
        enqueuedFrames = 0
        bufferedFrameCount = 0
        bufferedSamples = 0
        takenOutputSamples = 0
        leadAnchorWall = 0
        leadAnchorTaken = 0
        lastCallbackWall = 0
        _cachedOutputLatency = measuredLatency
        _lastLatencyRefreshWall = now
        contentFifo.removeAll(); playedContentEndPTS = .nan
        lock.unlock()

        let startRC = Self.startImpl(unit)
        if startRC != noErr {
            logger.error("AudioOutputUnitStart(start) FAILED: \(startRC)")
            recordStartFailure()
        } else {
            deviceHealth.recordStartSuccess()
        }

        lock.lock()
        audioUnit = unit
        running = true
        paused = false
        lock.unlock()

        logger.info("started (Pull AudioUnit): \(sr)Hz \(ch)ch latency=\(Int(measuredLatency * 1000))ms")
    }

    private static func teardownUnit(_ unit: AudioComponentInstance) {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func disposeUnderLock() -> (AudioComponentInstance?, Int) {
        lock.lock()
        let old = audioUnit
        let finalEnqueued = enqueuedFrames
        audioUnit = nil
        running = false
        paused = false
        bufferedFrameCount = 0
        enqueuedFrames = 0
        bufferedSamples = 0
        playedOutputSamples = 0
        takenOutputSamples = 0
        leadAnchorWall = 0
        leadAnchorTaken = 0
        lastCallbackWall = 0
        ringBuffer.reset()
        contentFifo.removeAll(); playedContentEndPTS = .nan
        clockCache.invalidate()
        lock.unlock()
        delayLine.flush()
        clock.setExternalHold(0)
        return (old, finalEnqueued)
    }

    func stop() {
        let (oldUnit, finalEnqueued) = disposeUnderLock()
        if let old = oldUnit {
            Self.teardownUnit(old)
            if finalEnqueued > 0 {
                logger.info("stopped, enqueued \(finalEnqueued) frames total")
            }
        }
    }

    public func flush() {
        let (oldUnit, _) = disposeUnderLock()
        if let old = oldUnit {
            Self.teardownUnit(old)
        }
    }

    /// Pause without destroying the unit or resetting the clock. Non-blocking:
    /// `paused` flips synchronously (render callback immediately outputs silence
    /// and stops advancing the clock), and `AudioOutputUnitStop` runs on `controlQueue`.
    public func pause() {
        lock.lock()
        let unit = audioUnit
        if !paused { paused = true }
        diagPauses += 1
        lock.unlock()
        guard unit != nil else { return }
        controlQueue.async { [weak self] in
            guard let self, let u = self.currentUnitLocked() else { return }
            _ = Self.pauseImpl(u)
            let r = self.queryDeviceSampleTime(unit: u)
            self.lock.lock()
            if r.valid {
                self.clockCache.commit(sample: r.sampleTime,
                                       now: ProcessInfo.processInfo.systemUptime)
            }
            self.lock.unlock()
        }
    }

    /// Resume after pause(). Non-blocking, same dispatch as pause().
    public func resume() {
        lock.lock()
        let unit = audioUnit
        if paused { paused = false }
        diagResumes += 1
        if lastCallbackWall > 0 { lastCallbackWall = ProcessInfo.processInfo.systemUptime }
        clockCache.invalidate()
        _lastLatencyRefreshWall = 0  // refresh outputLatency on route/resume
        lock.unlock()
        guard unit != nil else {
            logger.warning("resume() called but audioUnit is nil")
            return
        }
        controlQueue.async { [weak self] in
            guard let self, let u = self.currentUnitLocked() else { return }
            guard !self.deviceHealth.isDemoted else { return }
            let rc = Self.startImpl(u)
            if rc != noErr {
                logger.error("AudioOutputUnitStart(resume) FAILED: \(rc)")
                self.recordStartFailure()
            } else {
                self.deviceHealth.recordStartSuccess()
            }
        }
    }

    /// Rebuild the AudioUnit if it has stopped firing render callbacks for seconds
    /// while playing (or probe recovery when demoted under #608).
    private func rebuildQueueIfStarved() {
        let now = ProcessInfo.processInfo.systemUptime
        if deviceHealth.isDemoted {
            guard deviceHealth.shouldProbe(now: now) else { return }
            deviceHealth.recordProbedAt(now: now)
            logger.info("[#608] 降级探测:重建音频单元试探设备恢复")
            start(sampleRate: clock.sampleRate, channels: _channels)
            return
        }
        lock.lock()
        let gap = lastCallbackWall > 0 ? now - lastCallbackWall : 0
        let starved = running && !paused && lastCallbackWall > 0
            && gap > starvationRebuildSeconds
        let sr = clock.sampleRate
        let ch = _channels
        if starved {
            queueRebuilds += 1
            lastCallbackWall = now
        }
        lock.unlock()
        guard starved else { return }
        logger.warning("AudioUnit starved \(String(format: "%.1f", gap), privacy: .public)s — rebuilding")
        start(sampleRate: sr, channels: ch)
    }

    func queueRebuildCountForTesting() -> Int {
        lock.lock(); defer { lock.unlock() }
        return queueRebuilds
    }

    private func waitForPlaybackLead() {
        let cap = maxPlayingLeadSeconds
        guard cap > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let sr = Double(max(1, clock.sampleRate))
            let canPace = running && !paused && leadAnchorWall > 0
            let excess = Double(takenOutputSamples - leadAnchorTaken)
                - max(0, now - leadAnchorWall) * sr
            let shouldWait = canPace && excess > cap * sr
            lock.unlock()
            guard shouldWait, now < deadline else { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func simulateStarvationForTesting(seconds: Double) {
        lock.lock()
        if running {
            lastCallbackWall = ProcessInfo.processInfo.systemUptime - max(0, seconds)
        }
        lock.unlock()
    }

    func injectPlaybackLeadForTesting(takenSeconds: Double) {
        lock.lock()
        let sr = Double(max(1, clock.sampleRate))
        takenOutputSamples = Int64(max(0, takenSeconds) * sr)
        leadAnchorTaken = 0
        leadAnchorWall = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func playbackLeadSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        let sr = Double(max(1, clock.sampleRate))
        let excess = Double(takenOutputSamples - leadAnchorTaken)
            - max(0, ProcessInfo.processInfo.systemUptime - leadAnchorWall) * sr
        return max(0, excess / sr)
    }

    /// Line-aware entry (zyno#104). With d=0 this writes straight into the ring
    /// buffer with zero XPC / AudioToolbox calls.
    func enqueue(_ frame: PCMFrame, contentPts: Double = .nan) {
        rebuildQueueIfStarved()
        waitForPlaybackLead()
        lock.lock()
        let targetContent = _delayTargetContent
        let rate = _playbackRate
        lock.unlock()
        guard targetContent > 0.0005, rate > 0 else {
            enqueueDirect(frame, contentPts: contentPts)
            return
        }
        let due = delayLine.push(frame, contentPts: contentPts)
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    func setDelayTarget(contentSecs: Double) {
        lock.lock()
        _delayTargetContent = max(0, contentSecs.isFinite ? contentSecs : 0)
        let rate = _playbackRate
        lock.unlock()
        let due = delayLine.setTarget(_delayTargetContent / max(0.25, rate))
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    var hasPendingOutput: Bool {
        lock.lock()
        let queuePending = bufferedSamples > 0
        lock.unlock()
        return queuePending || delayLine.heldSeconds > 0.001
    }

    private func _syncHoldToClock() {
        lock.lock(); let rate = _playbackRate; lock.unlock()
        clock.setExternalHold(delayLine.heldSeconds * rate)
    }

    private func enqueueDirect(_ frame: PCMFrame, contentPts: Double) {
        guard !deviceHealth.isDemoted else { return }
        guard !frame.data.isEmpty, frame.sampleCount > 0 else { return }
        lock.lock()
        guard audioUnit != nil else {
            lock.unlock()
            return
        }
        let lineHold = _delayTargetContent > 0.0005 ? delayLine.heldSeconds : 0
        let sr = Double(max(1, clock.sampleRate))
        if paused, Double(bufferedSamples) / sr + lineHold >= maxPausedBufferSeconds {
            lock.unlock()
            return
        }
        let writtenBytes = ringBuffer.write(frame.data)
        let bytesPerFrame = max(1, Int(_channels)) * 4
        let writtenSamples = writtenBytes / bytesPerFrame
        if writtenSamples > 0 {
            if Self.tracksPlayedContent {
                contentFifo.append(ContentSpan(
                    startPts: contentPts,
                    totalSamples: writtenSamples,
                    remainingSamples: writtenSamples,
                    sampleDuration: 1.0 / sr
                ))
            }
            enqueuedFrames += 1
            diagEnqueues += 1
            bufferedFrameCount += 1
            bufferedSamples += writtenSamples
            diagEnqueuedSamples += Int64(writtenSamples)
        }
        lock.unlock()
    }

    /// CoreAudio real-time render callback — pulls PCM from `ringBuffer`.
    fileprivate func render(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            inNumberFrames: UInt32,
                            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, ioData.pointee.mNumberBuffers > 0 else { return noErr }
        let buf = ioData.pointee.mBuffers
        guard let dst = buf.mData, buf.mDataByteSize > 0 else { return noErr }

        let requestedBytes = Int(buf.mDataByteSize)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let ch = _channels
        let bytesPerFrame = max(1, Int(ch)) * 4
        let rate = _playbackRate
        let pausedNow = paused
        let vol: Float = Self.mutedForTesting ? 0.0 : _volume

        if pausedNow {
            lock.unlock()
            memset(dst, 0, requestedBytes)
            ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }

        // Align read to whole frames so channels never desync across callbacks.
        let alignedRequest = (requestedBytes / bytesPerFrame) * bytesPerFrame
        let copiedBytes = ringBuffer.read(into: dst, count: alignedRequest)
        let copiedSamples = copiedBytes / bytesPerFrame
        if copiedBytes < alignedRequest {
            diagUnderrunCount += 1
        }

        diagCallbackCount += 1
        if copiedSamples > 0 {
            bufferedSamples = max(0, bufferedSamples - copiedSamples)
            if bufferedSamples == 0 { bufferedFrameCount = 0 }
            playedOutputSamples += Int64(copiedSamples)

            if Self.tracksPlayedContent {
                var rem = copiedSamples
                while rem > 0, !contentFifo.isEmpty {
                    if contentFifo[0].remainingSamples <= rem {
                        let done = contentFifo.removeFirst()
                        rem -= done.remainingSamples
                        if done.startPts.isFinite {
                            playedContentEndPTS = done.startPts + Double(done.totalSamples) * done.sampleDuration
                        }
                    } else {
                        contentFifo[0].remainingSamples -= rem
                        let consumedInSpan = contentFifo[0].totalSamples - contentFifo[0].remainingSamples
                        if contentFifo[0].startPts.isFinite {
                            playedContentEndPTS = contentFifo[0].startPts + Double(consumedInSpan) * contentFifo[0].sampleDuration
                        }
                        rem = 0
                    }
                }
            }

            if diagLastCallbackWall > 0 { diagCallbackWall += now - diagLastCallbackWall }
            diagLastCallbackWall = now
            diagCallbackSamples += Int64(copiedSamples)
            let qts = Double(playedOutputSamples)
            if let last = diagQueueTimeLast {
                let d = qts - last
                if d >= 0, d < Double(clock.sampleRate) * 10 { diagQueueTimeDelta += d }
            }
            diagQueueTimeLast = qts

            takenOutputSamples += Int64(copiedSamples)
            let sr = Double(max(1, clock.sampleRate))
            let excess = Double(takenOutputSamples - leadAnchorTaken)
                - (now - leadAnchorWall) * sr
            if leadAnchorWall == 0 || excess < -0.05 * sr {
                leadAnchorWall = now
                leadAnchorTaken = takenOutputSamples
            }
        }
        lastCallbackWall = now
        lock.unlock()

        // #608: real render callback proves hardware IO is alive.
        if deviceHealth.recordDeviceAlive(now: now) {
            logger.warning("[#608] 音频输出设备恢复(真实回调到达)→ 回切音频主导时钟")
            onDeviceRecovered?()
        }

        if copiedBytes == 0 {
            memset(dst, 0, requestedBytes)
            ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }

        if copiedBytes < requestedBytes {
            memset(dst.advanced(by: copiedBytes), 0, requestedBytes - copiedBytes)
        }

        // Software gain (outside lock, on thread-local render buffer).
        if vol <= 0.0001 {
            memset(dst, 0, copiedBytes)
            ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        } else if vol < 0.9999 {
            let floatPtr = dst.assumingMemoryBound(to: Float.self)
            let floatCount = copiedBytes / MemoryLayout<Float>.size
            for i in 0..<floatCount {
                floatPtr[i] *= vol
            }
        }

        clock.advance(byteCount: copiedBytes, channels: ch, rate: rate)
        return noErr
    }

    /// Playback rate for content-time accounting. Guarded by `lock`.
    private var _playbackRate: Double = 1.0

    public func setPlaybackRate(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate.isFinite ? rate : 1.0))
        lock.lock()
        let hasUnit = audioUnit != nil
        if hasUnit {
            _deviceBaseContent = clock.audioTime
            _deviceBaseSample = Double(playedOutputSamples)
        }
        _playbackRate = clamped
        clockCache.invalidate()
        let targetContent = _delayTargetContent
        let effective = _playbackRate
        lock.unlock()
        guard targetContent > 0.0005 else { return }
        let due = delayLine.setTarget(targetContent / max(0.25, effective))
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    // MARK: - 用户音量(2026-11-09)

    private var _volume: Float = 1.0

    private var _deviceBaseContent: Double = 0
    private var _deviceBaseSample: Double = 0
    private var clockCache = InterpolatedDeviceClock(
        freshWindow: AudioUnitOutput.clockFreshWindowForTesting ?? 0.10)

    private func queryDeviceSampleTime(unit: AudioComponentInstance) -> (sampleTime: Double, valid: Bool) {
        if let impl = Self.getCurrentTimeImpl {
            return impl(unit)
        }
        lock.lock()
        let s = Double(playedOutputSamples)
        let ok = running
        lock.unlock()
        return (s, ok)
    }

    /// 设备播放位置(内容秒)。nil = 单元不可用/取不到有效采样时间。
    var devicePlaybackTime: Double? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let unit = audioUnit
        let base = _deviceBaseContent
        let baseSample = _deviceBaseSample
        let sr = clock.sampleRate
        let rate = _playbackRate
        let pausedNow = paused
        let action = clockCache.plan(paused: pausedNow, now: now, sampleRate: Double(max(1, sr)))
        lock.unlock()
        guard let unit, sr > 0 else { return nil }
        let sample: Double?
        switch action {
        case .extrapolate(let s), .frozen(let s):
            sample = s
        case .query:
            let result = queryDeviceSampleTime(unit: unit)
            lock.lock()
            if result.valid {
                clockCache.commit(sample: result.sampleTime, now: now)
                sample = result.sampleTime
            } else {
                sample = clockCache.fallbackAfterFailedQuery(now: now, sampleRate: Double(max(1, sr)))
            }
            lock.unlock()
        }
        guard let s = sample else { return nil }
        return base + max(0, s - baseSample) / Double(sr) * Double(rate)
    }

    private func currentVolume() -> Float {
        lock.lock(); defer { lock.unlock() }
        return _volume
    }

    public func setVolume(_ volume: Double) {
        let clamped = Float(max(0.0, min(1.0, volume.isFinite ? volume : 1.0)))
        lock.lock()
        _volume = clamped
        let unit = audioUnit
        lock.unlock()
        guard let unit else { return }
        _ = Self.setVolumeParamImpl(unit, clamped)
    }

    var audioTime: Double {
        clock.audioTime
    }

    func resetClock(to time: Double, sampleRate: Int32 = 44100) {
        clock.reset(to: time, sampleRate: sampleRate)
    }
}

private func audioUnitRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let output = Unmanaged<AudioUnitOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    return output.render(ioActionFlags: ioActionFlags,
                         inNumberFrames: inNumberFrames,
                         ioData: ioData)
}
