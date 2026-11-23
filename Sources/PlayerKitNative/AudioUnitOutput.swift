import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os
import PlayerKit

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "audio.output")

public final class AudioUnitOutput: AudioOutputBackend {
    /// Guards `audioQueue`, `running`, `paused`, `bufferedFrameCount`, `enqueuedFrames`.
    /// The AudioQueue callback runs on an internal AudioToolbox thread and calls
    /// back into `_callbackConsumed`; dispose is synchronous (inSync=true), so
    /// we must NOT hold the lock during AudioQueueDispose or we'd deadlock when
    /// the callback tries to acquire it.  See stop() for the swap-then-dispose
    /// pattern.
    private let lock = NSLock()

    private var audioQueue: AudioQueueRef?
    private let clock: AudioClock
    private var _channels: Int32 = 2
    private var enqueuedFrames = 0
    var bufferedFrameCount = 0
    private var running = false
    private var paused = false
    /// How many primer-buffer callbacks have not yet fired. Guarded by lock.
    /// Decremented in _callbackConsumed; used to route primer callbacks to
    /// clock.advancePrimer() so _primerPendingSamples stays accurate.
    private var pendingPrimerCallbacks: Int = 0

    // MARK: Audio delay (zyno#104)

    /// Physical hold for d>0: frames park here before the real queue. See
    /// AudioDelayLine. Guarded by its own lock; ordering output lock → line
    /// lock only (the line never calls back in).
    private let delayLine = AudioDelayLine()
    /// User audio delay in CONTENT seconds (≥ 0 here — the negative half is a
    /// pure clock offset owned by AudioClock). Guarded by lock.
    private var _delayTargetContent: Double = 0

    // Test seams (off by default; production never sets them). With
    // `tracksPlayedContent` on, the source-content PTS of every enqueued buffer is
    // queued (buffers complete in order) and, as buffers finish playing, the content
    // position the device has actually played is recorded — so tests can compare what
    // is HEARD with what is SHOWN. `mutedForTesting` sets the queue volume to 0 so
    // tests can play real content silently. Guarded by lock.
    nonisolated(unsafe) static var tracksPlayedContent = false
    nonisolated(unsafe) static var mutedForTesting = false

    /// Test seams for the AudioQueue control entry points. Production uses the
    /// real functions; tests substitute slow/stuck implementations to prove the
    /// control calls never block their caller (see the non-blocking contract
    /// tests). Reset in test tearDown.
    nonisolated(unsafe) static var pauseImpl: (AudioQueueRef) -> OSStatus = { AudioQueuePause($0) }
    nonisolated(unsafe) static var startImpl: (AudioQueueRef) -> OSStatus = { AudioQueueStart($0, nil) }
    /// 音量参数 seam(2026-11-09 macOS 播放器音量 UI 前置):生产用真实现,
    /// 测试替换以断言"clamped 值被应用到活队列/建队时补挂",不依赖真实设备。
    nonisolated(unsafe) static var setVolumeParamImpl: (AudioQueueRef, Float) -> OSStatus = {
        AudioQueueSetParameter($0, kAudioQueueParam_Volume, $1)
    }
    /// GetCurrentTime seam(#72 主时钟插值缓存):生产用真实现,测试包装计数,
    /// 断言 freshWindow 内的重复读取不重复进设备查询。Reset in test tearDown.
    nonisolated(unsafe) static var getCurrentTimeImpl: (AudioQueueRef) -> (sampleTime: Double, valid: Bool) = { queue in
        var ts = AudioTimeStamp()
        let rc = AudioQueueGetCurrentTime(queue, nil, &ts, nil)
        return (ts.mSampleTime, rc == noErr && ts.mFlags.contains(.sampleTimeValid))
    }
    /// #72 测试 seam:freshWindow 覆盖(默认 0.1s)。生产永不安值;测试放大/
    /// 缩小窗口以确定性地断言「窗内零查询 / 超窗一次查询」。Reset in tearDown.
    nonisolated(unsafe) static var clockFreshWindowForTesting: TimeInterval?

    // MARK: - #608 音频设备死亡降级

    /// 设备健康(降级/探测节流/恢复边沿,纯逻辑见 AudioDeviceHealth)。
    let deviceHealth = AudioDeviceHealth()
    var deviceHealthForTesting: AudioDeviceHealth { deviceHealth }
    /// 降级边沿(连续 Start 失败越过阈值):backend 安装,切视频时钟续播。
    /// 在 controlQueue / 调用线程上触发,实现方自行切线程。
    nonisolated(unsafe) var onDeviceDemoted: (() -> Void)?
    /// 恢复边沿(降级期真实回调到达 = 设备 IO 复活):backend 重校准时钟。
    nonisolated(unsafe) var onDeviceRecovered: (() -> Void)?

    /// 记一次 Start 失败并在越过阈值时报降级边沿。
    private func recordStartFailure() {
        if deviceHealth.recordStartFailure(now: ProcessInfo.processInfo.systemUptime) {
            logger.error("[#608] 音频输出设备连续 Start 失败 → 降级:画面按源帧率续播,音频静音,定时探测恢复")
            onDeviceDemoted?()
        }
    }

    /// Serial queue that owns every AudioQueue control call (Pause/Start).
    ///
    /// These calls dispatch_sync into AudioToolbox's internal server context —
    /// the same serial context the macOS CVDisplayLink tick runs on. The
    /// 2026-10-10 seek freeze: the display tick (jitter pop → underrun) called
    /// pause() and its AudioQueuePause got stuck in BeginPause's IO-cycle wait
    /// on that context, while the demux thread (jitter append → refill resume)
    /// dispatch_sync'd AudioQueueStart behind it — pipeline-wide deadlock, no
    /// supply, silent logs, ~50% CPU. Hot paths (jitter append/pop callbacks,
    /// seek path) must therefore never block on a control call: the flag flips
    /// synchronously (enqueue cap / clock semantics unchanged) and only the
    /// AudioQueue call is dispatched here. Serial ⇒ pause→resume order is
    /// preserved; the queue ref is re-read under the lock inside the block so
    /// a stop()/flush() that ran first is skipped.
    private let controlQueue = DispatchQueue(label: "io.zyno.PlayerKit.audio.control")

    private func currentQueueLocked() -> AudioQueueRef? {
        lock.lock(); defer { lock.unlock() }
        return audioQueue
    }
    private var contentFifo: [(pts: Double, dur: Double)] = []
    private var playedContentEndPTS: Double = .nan

    /// Test seam: source-content PTS (seconds) up to which audio has been fully
    /// played by the device; NaN until a buffer with a known PTS completed.
    func playedContentEnd() -> Double {
        lock.lock(); defer { lock.unlock() }
        return playedContentEndPTS
    }

    /// Test seam: whether a live AudioQueue exists (start() succeeded). Tests
    /// skip the control-call contracts when the environment has no device.
    var hasQueueForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return audioQueue != nil
    }

    /// Upper bound (seconds of audio) the queue may hold while it is paused.
    var maxPausedBufferSeconds: Double = 5.0

    /// Samples (per channel) currently queued and not yet played, excluding the
    /// silent primer buffers. Guarded by lock. Lets the paused cap be expressed
    /// in seconds instead of in buffers — a buffer is 512 samples (10.7 ms) for
    /// DTS but 1024 (21 ms) for AAC, so a buffer-count cap meant wildly
    /// different amounts of audio per codec.
    private var bufferedSamples = 0

    /// Upper bound (seconds) on audio the AudioQueue has TAKEN from us (its
    /// buffer callback fired) but not yet PLAYED. This is a different quantity
    /// from both `bufferedSamples` and `maxPausedBufferSeconds`:
    ///  - `bufferedSamples` is enqueued-but-not-taken — the normal demux
    ///    read-ahead (~1.2 s) — and must stay free to grow;
    ///  - TAKEN-but-unplayed is ~0 in steady playback (callbacks fire at the
    ///    play rate) and is what must stay small.
    /// zyno#361: after a reader stall the demux refills at many × real time and
    /// the queue takes that recovery burst immediately (the callback means
    /// "finished taking data from a buffer"), so the callback-driven AudioClock
    /// advanced 2–3× while the device kept playing at 1× — clock and picture
    /// jumped ~7 s ahead of the sound.
    ///
    /// The primary fix for that state is rebuildQueueIfStarved(): the queue is
    /// replaced before the recovery burst is fed, so a healthy queue never
    /// over-takes (pre-stall it takes exactly at the play rate, lead ≈ 0).
    /// This cap is the safety net for a queue that over-takes WITHOUT a long
    /// callback gap. It must stay well above the demux's normal read-ahead
    /// (~1.2 s in `bufferedSamples`): a tight cap blocks the enqueue, collapses
    /// that read-ahead, and turns playback into a just-in-time feed whose
    /// callback bursts make the clock (and the picture) stutter — measured
    /// with a 0.1 s cap after a freeze: bufSec stayed 0.00, the lead crept to
    /// 0.37 s and the display dropped to 3–5 fps.
    var maxPlayingLeadSeconds: Double = 2.0

    /// Seconds without an AudioQueue callback (while playing, not paused) after
    /// which the queue counts as starved and rebuildQueueIfStarved() replaces
    /// it. Production 2 s; tests raise it when they exercise other behaviour on
    /// slow CI runners (a stalled virtual audio device plus a slow test process
    /// can stretch a "normal" feed past the threshold).
    var starvationRebuildSeconds: Double = 2.0

    /// Wall time of the last AudioQueue callback. Guarded by lock. A gap of
    /// seconds means the queue starved; see rebuildQueueIfStarved().
    private var lastCallbackWall: TimeInterval = 0
    /// Starvation-triggered queue rebuilds since start (test/diag seam).
    private var queueRebuilds = 0

    // True-progress accounting for maxPlayingLeadSeconds. Guarded by lock.
    /// Cumulative output samples handed back by AudioQueue callbacks — exactly
    /// what AudioClock.advance() is fed. Includes the silent primers.
    private var takenOutputSamples: Int64 = 0
    /// Wall-anchored take-rate baseline: (wall, taken) at the last moment the
    /// queue had NOT taken more than the device could have played. The excess
    /// `taken − anchorTaken − elapsed × sampleRate` is the audio the queue has
    /// taken but cannot have played yet — the lead that maxPlayingLeadSeconds
    /// bounds. AudioQueueGetCurrentTime is NOT usable for this: it is the
    /// device timeline and keeps advancing through an underrun, which would
    /// hide exactly the post-stall burst this cap exists for (measured: qts
    /// advanced 1× while callbacks took 2.8×).
    private var leadAnchorWall: TimeInterval = 0
    private var leadAnchorTaken: Int64 = 0

    // [diag] cumulative queue-health counters (晃动 localization 2026-10-12):
    // enqueues/starts/pauses/resumes since last drain — distinguishes "queue
    // never fed" (enqueues≈callbacks, both tiny) from "queue repeatedly
    // paused/started" (starts≫callbacks) as the reason the audio clock crawls.
    private var diagEnqueues = 0
    private var diagStarts = 0
    private var diagPauses = 0
    private var diagResumes = 0
    // [diag] callback-side accumulators, guarded by lock.
    private var diagCallbackCount = 0
    private var diagCallbackSamples: Int64 = 0
    private var diagCallbackWall: TimeInterval = 0
    private var diagLastCallbackWall: TimeInterval = 0
    private var diagQueueTimeLast: Double?
    private var diagQueueTimeDelta: Double = 0
    private var diagEnqueuedSamples: Int64 = 0

    public let supportsPassthrough: Bool = false

    /// [diag] Queue health since last drain: control-call counts + the
    /// instantaneous paused/buffered state.
    struct QueueDiag {
        var enqueues = 0
        var starts = 0
        var pauses = 0
        var resumes = 0
        var pausedNow = false
        var bufferedSamplesNow = 0
        var bufferedFramesNow = 0
        // [diag] zyno#361 callback-side observability. A sample-count clock can
        // only advance when the AudioQueue reports consumed buffers; if the
        // callback sum outruns wall time, either the device really consumed
        // faster (a device-clock anomaly) or buffers completed without being
        // played (a drain). `queueTimeSeconds` is AudioQueue's own played-
        // sample timebase — it separates the two.
        var callbackCount = 0
        var callbackSeconds = 0.0
        var callbackWallSeconds = 0.0
        var queueTimeSeconds = 0.0
        var enqueuedSeconds = 0.0
        var sampleRateNow: Int32 = 48000
        var playRateNow: Double = 1.0
        /// Instantaneous TAKEN-but-unplayed lead (see maxPlayingLeadSeconds).
        /// Stays ~0 in healthy playback; grows to seconds when the queue takes
        /// a recovery burst it cannot play in step (zyno#361).
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
        // Approximate: assume 1024 samples per frame at the output sample rate.
        Double(bufferedFrameCount) * 1024.0 / Double(clock.sampleRate)
    }

    init(clock: AudioClock, delaySecs: Double = 0) {
        self.clock = clock
        _delayTargetContent = max(0, delaySecs.isFinite ? delaySecs : 0)
        // Wall target is (re)derived from the rate in setPlaybackRate/start();
        // the output starts at rate 1.0 so content == wall here.
        delayLine.setTarget(_delayTargetContent)
    }

    deinit { stop() }

    /// Configure the output for a given stream. AudioQueue is already configured
    /// in start(), so this is a no-op for AudioUnitOutput.
    public func configure(streamInfo: AudioStreamInfo) async throws {
        // no-op
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
        // no-op: AudioUnitOutput does not support passthrough
    }

    func start(sampleRate: Int32, channels: Int32) {
        // Dispose any pre-existing queue first (swap-then-dispose to avoid
        // holding the lock during the synchronous AudioQueueDispose).
        let (oldQueue, _) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
        }

        let sr = sampleRate > 0 ? sampleRate : 44100
        let ch = channels > 0 ? channels : 2
        _channels = ch
        delayLine.configure(sampleRate: sr)

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

        var newQueue: AudioQueueRef?
        let rc = AudioQueueNewOutput(&format, audioQueueCallback,
                                     Unmanaged.passUnretained(self).toOpaque(),
                                     nil, nil, 0, &newQueue)
        guard rc == noErr, let queue = newQueue else {
            logger.error("AudioQueueNewOutput FAILED: \(rc)")
            return
        }

        if Self.mutedForTesting { AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0) }
        // 用户音量(0~1)在(重)建队时补挂:换轨/starve 重建会换新 queue ref,
        // 不补的话每次重建音量都跳回 1.0。mutedForTesting 已置 0 时跳过,
        // 保住测试静音语义。
        let savedVolume = currentVolume()
        if !Self.mutedForTesting, savedVolume != 1.0 {
            Self.setVolumeParamImpl(queue, savedVolume)
        }

        // Primer: 3 silence buffers to prevent initial underrun.
        // startPrimer() creates a negative debt and records the pending count so
        // AudioClock.calibrate() can re-apply the exact remaining debt after a
        // position reset without losing the primer cancellation.
        let primerCount = 3
        let primerBytes = 4096
        clock.startPrimer(bufferCount: primerCount, bytesPerBuffer: primerBytes, channels: ch)
        for _ in 0..<primerCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, UInt32(primerBytes), &buffer)
            if let buf = buffer {
                memset(buf.pointee.mAudioData, 0, primerBytes)
                buf.pointee.mAudioDataByteSize = UInt32(primerBytes)
                AudioQueueEnqueueBuffer(queue, buf, 0, nil)
            }
        }

        // #608:Start 失败不再静默——连续失败越过阈值触发降级(设备死亡
        // 时每次重建都是一次 HAL 喂锤,必须在源头记账)。
        let startRC = Self.startImpl(queue)
        if startRC != noErr {
            logger.error("AudioQueueStart(start) FAILED: \(startRC)")
            recordStartFailure()
        } else {
            deviceHealth.recordStartSuccess()
        }

        // Swap in the new queue atomically.  Any in-flight enqueue() that was
        // waiting on the lock will see the new queue, not the disposed one.
        lock.lock()
        audioQueue = queue
        running = true
        paused = false
        // 新队列的 sampleTime 从 0 起算,内容基准取当前时钟位置(seek 时
        // 调用方已先 audioClock.reset(to: target),这里正好对上)。
        _deviceBaseContent = clock.audioTime
        _deviceBaseSample = 0
        enqueuedFrames = 0
        bufferedFrameCount = 0
        pendingPrimerCallbacks = primerCount
        bufferedSamples = 0
        takenOutputSamples = 0
        leadAnchorWall = 0
        leadAnchorTaken = 0
        lastCallbackWall = 0
        contentFifo.removeAll(); playedContentEndPTS = .nan
        lock.unlock()

        logger.info("started: \(sr)Hz \(ch)ch")
    }

    /// Atomically null out `audioQueue` and return the previous value (plus the
    /// final enqueued-frame count for logging) so the queue can be disposed
    /// outside the lock.  After this returns, no enqueue() can observe the old
    /// queue pointer, so disposing it is safe from the producer side; and
    /// because enqueue() holds the lock across its AudioQueue calls, dispose
    /// won't start until any in-flight enqueue() finishes.
    private func disposeUnderLock() -> (AudioQueueRef?, Int) {
        lock.lock()
        let old = audioQueue
        let finalEnqueued = enqueuedFrames
        audioQueue = nil
        running = false
        paused = false
        bufferedFrameCount = 0
        enqueuedFrames = 0
        pendingPrimerCallbacks = 0
        bufferedSamples = 0
        takenOutputSamples = 0
        leadAnchorWall = 0
        leadAnchorTaken = 0
        lastCallbackWall = 0
        contentFifo.removeAll(); playedContentEndPTS = .nan
        // #72:队列引用已作废(新队列是新时间轴),锚点必须失效
        clockCache.invalidate()
        lock.unlock()
        // Seek/stop/track-switch all land here: drop the held-back frames so
        // stale pre-seek audio can't play from the new position, and zero the
        // clock's hold with it. (stop()/flush()/start() all route through.)
        delayLine.flush()
        clock.setExternalHold(0)
        return (old, finalEnqueued)
    }

    func stop() {
        let (oldQueue, finalEnqueued) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
            if finalEnqueued > 0 {
                logger.info("stopped, enqueued \(finalEnqueued) frames total")
            }
        }
    }

    /// Flush pending audio buffers. Resets state without disposing the queue.
    public func flush() {
        // Same swap-then-dispose as stop(): null the queue reference under the
        // lock, then dispose outside the lock so the AudioQueue callback can't
        // deadlock against us.  A fresh queue will be created by start().
        let (oldQueue, _) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
        }
    }

    /// Pause without destroying the queue or resetting the clock. Non-blocking:
    /// the AudioQueuePause is dispatched onto `controlQueue` (see its doc).
    public func pause() {
        lock.lock()
        let queue = audioQueue
        if !paused { paused = true }
        diagPauses += 1
        lock.unlock()
        guard queue != nil else { return }
        controlQueue.async { [weak self] in
            guard let self, let q = self.currentQueueLocked() else { return }
            _ = Self.pauseImpl(q)
            // #72:暂停落地后把锚点钉到真实冻结点——否则暂停显示位置冻结在
            // flag 翻转前的锚点,最多滞后一个 freshWindow。control 路径一次
            // 查询,不进热路径。
            let r = Self.getCurrentTimeImpl(q)
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
        let queue = audioQueue
        if paused { paused = false }
        diagResumes += 1
        // A deliberate pause is not a starvation: re-anchor the callback clock
        // so the first enqueue after a resume cannot trigger a rebuild.
        if lastCallbackWall > 0 { lastCallbackWall = ProcessInfo.processInfo.systemUptime }
        // #72:resume 后锚点失效——AudioQueueStart 是异步下发的,落地前真实
        // 查询返回的仍是暂停冻结值(与旧语义一致),落地后自然前进。
        clockCache.invalidate()
        lock.unlock()
        guard queue != nil else {
            // 音频队列尚不存在时被要求恢复:start() 未跑或队列已 dispose。
            // 若此后不再有 .playing 翻转,音频会永久暂停 → audioClock 卡 0
            // → 同步旁路加速/卡死。这是 _finishOpen 竞态的直接症状。
            logger.warning("resume() called but audioQueue is nil")
            return
        }
        controlQueue.async { [weak self] in
            guard let self, let q = self.currentQueueLocked() else { return }
            // #608:降级期零打扰——设备已死,再 Start 只是给 HAL 喂锤
            // (每次重建失败还会拉长 soft-blacklist 式停机)。
            guard !self.deviceHealth.isDemoted else { return }
            let rc = Self.startImpl(q)
            if rc != noErr {
                logger.error("AudioQueueStart(resume) FAILED: \(rc)")
                self.recordStartFailure()
            } else {
                self.deviceHealth.recordStartSuccess()
            }
        }
    }

    /// Rebuild the AudioQueue if it has been starved for seconds.
    ///
    /// zyno#361 follow-up: a playback AudioQueue that underruns for a long time
    /// does not necessarily recover when data returns. Measured after a 25 s
    /// reader stall: callbacks resumed at ~1× (so the sample clock looked
    /// healthy and the picture no longer fast-forwarded), but the device output
    /// stayed at digital silence (-120 dB) for minutes while the app-side buffer
    /// never refilled — the queue consumed buffers without playing them.
    /// Rebuilding it (the same stop()/start() path a seek takes) restores sound.
    ///
    /// Runs on the decode path before the first post-stall enqueue, so a broken
    /// queue is never fed. resume() re-anchors the callback clock: a deliberate
    /// pause is not a starvation. Threshold 2 s: normal hiccups are far shorter,
    /// and the reader's own stall handling can keep a 4K stream starved for
    /// several seconds.
    private func rebuildQueueIfStarved() {
        let now = ProcessInfo.processInfo.systemUptime
        // #608:降级期把「重建」退化为按 probeInterval 节流的探测。探测走
        // 与 starve 重建相同的 start() 路径:新队列天然冲刷陈旧缓冲,
        // Start 成功且真实回调到达即由回调路径标记恢复(见 _callbackConsumed)。
        if deviceHealth.isDemoted {
            guard deviceHealth.shouldProbe(now: now) else { return }
            deviceHealth.recordProbedAt(now: now)
            logger.info("[#608] 降级探测:重建音频队列试探设备恢复")
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
        logger.warning("AudioQueue starved \(String(format: "%.1f", gap), privacy: .public)s — rebuilding")
        start(sampleRate: sr, channels: ch)
    }

    /// Number of starvation-triggered AudioQueue rebuilds (test seam).
    func queueRebuildCountForTesting() -> Int {
        lock.lock(); defer { lock.unlock() }
        return queueRebuilds
    }

    /// Block until the AudioQueue's TAKEN-but-unplayed lead is within
    /// `maxPlayingLeadSeconds` (zyno#361). Only the decode path calls this —
    /// control paths (setDelayTarget/setPlaybackRate) release delay-line frames
    /// through enqueueDirect directly and must never block their caller.
    ///
    /// The wait runs on the audio decode queue, which is exactly where
    /// back-pressure belongs: the demux keeps reading video/subtitle packets,
    /// only decoded audio waits. Playback consumes output samples at the
    /// output sample rate regardless of the tempo rate, so the device can have
    /// played at most `elapsed × sampleRate` since the anchor — anything taken
    /// beyond that (plus the cap) is a take burst the device cannot have
    /// played, and it is what made the callback clock jump (zyno#361).
    /// A 2 s deadline keeps a device-side stall from wedging the decode queue
    /// forever; past it we enqueue anyway (dropping audio would be worse).
    private func waitForPlaybackLead() {
        let cap = maxPlayingLeadSeconds
        guard cap > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let sr = Double(max(1, clock.sampleRate))
            // Pacing only makes sense while the queue is actually playing: a
            // paused queue is bounded by maxPausedBufferSeconds instead, and
            // before the first callback there is no anchor to measure from.
            let canPace = running && !paused && leadAnchorWall > 0
            let excess = Double(takenOutputSamples - leadAnchorTaken)
                - max(0, now - leadAnchorWall) * sr
            let shouldWait = canPace && excess > cap * sr
            lock.unlock()
            guard shouldWait, now < deadline else { return }
            // 5 ms: a few 40-sample TrueHD buffers (0.83 ms each) per step —
            // fine-grained enough not to overshoot the lead cap meaningfully.
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Test seam: pretend the last AudioQueue callback was `seconds` ago, so
    /// rebuildQueueIfStarved() can be exercised without a real audio-thread
    /// stall (CI's virtual device does not reliably deliver callbacks).
    func simulateStarvationForTesting(seconds: Double) {
        lock.lock()
        if running {
            lastCallbackWall = ProcessInfo.processInfo.systemUptime - max(0, seconds)
        }
        lock.unlock()
    }

    /// Test seam: inject a TAKEN-but-unplayed lead so waitForPlaybackLead() can
    /// be exercised deterministically — the real queue's post-starvation take
    /// burst depends on audio-thread timing and is not reproducible in CI.
    func injectPlaybackLeadForTesting(takenSeconds: Double) {
        lock.lock()
        let sr = Double(max(1, clock.sampleRate))
        takenOutputSamples = Int64(max(0, takenSeconds) * sr)
        leadAnchorTaken = 0
        leadAnchorWall = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// Test seam: the current TAKEN-but-unplayed lead in seconds, i.e. how
    /// much audio the queue has taken beyond what the device could have played.
    func playbackLeadSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        let sr = Double(max(1, clock.sampleRate))
        let excess = Double(takenOutputSamples - leadAnchorTaken)
            - max(0, ProcessInfo.processInfo.systemUptime - leadAnchorWall) * sr
        return max(0, excess / sr)
    }

    /// Line-aware entry (zyno#104). With no delay target (the default) this is
    /// a direct pass-through — zero behavior change. With d>0 the frame parks
    /// in AudioDelayLine and only frames the pump releases reach the queue.
    /// The line runs OUTSIDE the output lock (it never calls back in; see its
    /// doc) — releasing it into enqueueDirect per frame re-takes the lock.
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
        // Frames arriving here are rate-scaled (wall) audio — the tempo
        // processor runs upstream — so the content target ÷ rate gives the
        // wall hold. The clock reads the hold back in CONTENT seconds
        // (wall × rate), keeping the picture on the feed timeline while the
        // sound lags it.
        let due = delayLine.push(frame, contentPts: contentPts)
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    /// Apply the user audio delay (CONTENT seconds, ≥ 0 meaningful here — the
    /// negative half is a pure clock offset owned by AudioClock). Called by
    /// NativeBackend.setAudioDelay and after rebuilding the output (track
    /// switch / reopen carry the delay across, like setPlaybackRate).
    func setDelayTarget(contentSecs: Double) {
        lock.lock()
        _delayTargetContent = max(0, contentSecs.isFinite ? contentSecs : 0)
        let rate = _playbackRate
        lock.unlock()
        let due = delayLine.setTarget(_delayTargetContent / max(0.25, rate))
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    /// Seconds of audio still pending somewhere in this output (queue + delay
    /// line + unpaid primers). The display loop's end-of-stream free-run uses
    /// this to tell "audio ended" from "audio still draining".
    var hasPendingOutput: Bool {
        lock.lock()
        let queuePending = bufferedSamples > 0 || pendingPrimerCallbacks > 0
        lock.unlock()
        return queuePending || delayLine.heldSeconds > 0.001
    }

    /// Push the line's current hold to the clock in CONTENT seconds.
    private func _syncHoldToClock() {
        lock.lock(); let rate = _playbackRate; lock.unlock()
        clock.setExternalHold(delayLine.heldSeconds * rate)
    }

    private func enqueueDirect(_ frame: PCMFrame, contentPts: Double) {
        // #608:降级期丢弃入队——设备不会播放它们;入队只会触发必然失败的
        // Start(喂锤)并让时钟/缓冲记账撒谎(hasPendingOutput 永真会挡死
        // EOF 自由跑)。探测重建由 rebuildQueueIfStarved 节流负责。
        guard !deviceHealth.isDemoted else { return }
        // Hold the lock across allocate+copy+enqueue so the dispose path can't
        // tear down the queue between the guard and the AudioQueue calls.
        // disposeUnderLock() also takes this lock, so it waits for any in-flight
        // enqueue() to finish before nulling the queue and disposing it.
        lock.lock()
        guard let queue = audioQueue else {
            lock.unlock()
            return
        }
        // Drop frames when the queue is paused and has accumulated too much audio.
        // The demux has no audio throttle and reads from cache at many ×real-time,
        // so without this cap the AudioQueue accumulates minutes of audio while
        // buffering. When resume() is called, all frames drain at real-time,
        // advancing the audio clock far ahead of video — the skip-behind guard
        // then dumps all video frames from the jitter buffer → stuck.
        //
        // The cap is in SECONDS of audio. It used to be "60 buffers", which was
        // meant as ≈2 s but is only 0.64 s for 512-sample DTS frames — shorter
        // than the ~1.2–1.4 s the video jitter buffer needs to fill after every
        // start/resume. Every frame beyond it was silently discarded, so the
        // audible content jumped ahead of the picture by the dropped span
        // (measured: 0.555 s at each start, 0.57–0.74 s more after each resume).
        // The default (5 s) is well above any normal buffering window and keeps
        // the accumulation bounded.
        // The cap is in SECONDS of audio. It used to be "60 buffers", which was
        // meant as ≈2 s but is only 0.64 s for 512-sample DTS frames — shorter
        // than the ~1.2–1.4 s the video jitter buffer needs to fill after every
        // start/resume. Every frame beyond it was silently discarded, so the
        // audible content jumped ahead of the picture by the dropped span
        // (measured: 0.555 s at each start, 0.57–0.74 s more after each resume).
        // The default (5 s) is well above any normal buffering window and keeps
        // the accumulation bounded. The delay line's hold counts toward the
        // budget too (zyno#104): at d=+5 the pipeline legitimately parks 5 s in
        // the line, and the cap must not treat the queue alone as the whole
        // budget or it would strangle the refill after resume.
        // (Already under the output lock here; the line lock nests after it.)
        let lineHold = _delayTargetContent > 0.0005 ? delayLine.heldSeconds : 0
        if paused,
           Double(bufferedSamples) / Double(max(1, clock.sampleRate)) + lineHold
              >= maxPausedBufferSeconds {
            lock.unlock()
            return
        }
        var buffer: AudioQueueBufferRef?
        let rc = AudioQueueAllocateBuffer(queue, UInt32(frame.data.count), &buffer)
        guard rc == noErr, let buf = buffer else {
            lock.unlock()
            logger.error("AudioQueueAllocateBuffer FAILED: \(rc)")
            return
        }
        frame.data.copyBytes(to: buf.pointee.mAudioData.assumingMemoryBound(to: UInt8.self),
                             count: frame.data.count)
        buf.pointee.mAudioDataByteSize = UInt32(frame.data.count)
        AudioQueueEnqueueBuffer(queue, buf, 0, nil)
        if Self.tracksPlayedContent { contentFifo.append((contentPts, Double(frame.sampleCount) / Double(max(1, clock.sampleRate)))) }
        enqueuedFrames += 1
        diagEnqueues += 1
        bufferedFrameCount += 1
        bufferedSamples += frame.sampleCount
        diagEnqueuedSamples += Int64(frame.sampleCount)
        let shouldRestart = !paused
        if shouldRestart { diagStarts += 1 }
        lock.unlock()

        // Only (re)start if not deliberately paused by the buffering state machine.
        // Dispatched like pause()/resume(): this runs on the demux thread, the
        // same hot path the 2026-10-10 deadlock froze — a Start issued here just
        // before .buffering flips the flag would otherwise dispatch_sync into
        // the AudioToolbox server context behind a stuck BeginPause.
        if shouldRestart {
            controlQueue.async { [weak self] in
                guard let self, let q = self.currentQueueLocked() else { return }
                let rc = Self.startImpl(q)
                if rc != noErr {
                    logger.error("AudioQueueStart(enqueue) FAILED: \(rc)")
                    self.recordStartFailure()
                } else {
                    self.deviceHealth.recordStartSuccess()
                }
            }
        }
    }

    /// Called from the AudioQueue callback — do not call directly.
    func _callbackConsumed(byteCount: Int, queue: AudioQueueRef?) {
        // #608:任何真实回调都证明设备 IO 活着——这是半死态(Start 成功但
        // 不出声)下唯一可信的存活信号。降级期到达即报恢复边沿,backend
        // 据此把主时钟回切音频主导。
        if deviceHealth.recordDeviceAlive(now: ProcessInfo.processInfo.systemUptime) {
            logger.warning("[#608] 音频输出设备恢复(真实回调到达)→ 回切音频主导时钟")
            onDeviceRecovered?()
        }
        // [diag] The queue's own sample timebase, read OUTSIDE our lock: holding
        // the lock across an AudioQueue call can deadlock against the enqueue
        // path (which holds the lock across AudioQueueEnqueueBuffer). Note it
        // advances through underruns, so it is diagnostics only — the playing
        // back-pressure measures against wall time instead (see leadAnchorWall).
        var queueSampleTime: Double?
        if NativeBackend.diagLoggingEnabled, let queue {
            var ts = AudioTimeStamp()
            if AudioQueueGetCurrentTime(queue, nil, &ts, nil) == noErr,
               ts.mFlags.contains(.sampleTimeValid) {
                queueSampleTime = ts.mSampleTime
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // 用户暂停兜底:pause() 同步置 paused,但真正的 AudioQueuePause 是
        // controlQueue.async 下发的,AudioToolbox 内部 IO-cycle 等待可能让它
        // 晚到;此间回调若继续消耗缓冲,会把音频时钟推过暂停位置(2026-11-15
        // 真机:恢复后位置 = 暂停位置 + 暂停时长,画面跳过整个暂停段)。
        if paused {
            lock.unlock()
            return
        }
        if bufferedFrameCount > 0 { bufferedFrameCount &-= 1 }
        let ch = _channels
        let rate = _playbackRate
        let isPrimer = pendingPrimerCallbacks > 0
        if isPrimer { pendingPrimerCallbacks -= 1 }
        else {
            bufferedSamples = max(0, bufferedSamples - byteCount / (max(1, Int(ch)) * 4))
            if Self.tracksPlayedContent, !contentFifo.isEmpty {
                let done = contentFifo.removeFirst()
                if done.pts.isFinite { playedContentEndPTS = done.pts + done.dur }
            }
        }
        if diagLastCallbackWall > 0 { diagCallbackWall += now - diagLastCallbackWall }
        diagLastCallbackWall = now
        diagCallbackCount += 1
        diagCallbackSamples += Int64(byteCount / (max(1, Int(ch)) * 4))
        if let qts = queueSampleTime {
            if let last = diagQueueTimeLast {
                let d = qts - last
                if d >= 0, d < Double(clock.sampleRate) * 10 { diagQueueTimeDelta += d }
            }
            diagQueueTimeLast = qts
        }
        // True-progress accounting for the playing back-pressure (zyno#361).
        takenOutputSamples += Int64(byteCount / (max(1, Int(ch)) * 4))
        let sr = Double(max(1, clock.sampleRate))
        let excess = Double(takenOutputSamples - leadAnchorTaken)
            - (now - leadAnchorWall) * sr
        if leadAnchorWall == 0 || excess < -0.05 * sr {
            // The queue took less than the device could have played since the
            // anchor (startup, underrun, or a reader stall). Re-anchor rather
            // than bank that deficit as credit the next burst could spend — a
            // stall must never license a fast-forward.
            leadAnchorWall = now
            leadAnchorTaken = takenOutputSamples
        }
        lastCallbackWall = now
        lock.unlock()
        // Route primer callbacks to advancePrimer() so _primerPendingSamples in
        // AudioClock stays accurate for calibrate() after a position reset.
        // Primer buffers are silent and carry no content time, so they are NOT
        // rate-scaled — the primer debt in startPrimer() is recorded in output
        // samples and must cancel exactly.
        if isPrimer {
            clock.advancePrimer(byteCount: byteCount, channels: ch)
        } else {
            // Tempo path: the queue holds rate-scaled PCM, so convert consumed
            // OUTPUT samples back to CONTENT samples for the clock (zyno#99).
            clock.advance(byteCount: byteCount, channels: ch, rate: rate)
        }
    }

    /// Playback rate for content-time accounting (see _callbackConsumed).
    /// Guarded by `lock`.
    private var _playbackRate: Double = 1.0

    public func setPlaybackRate(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate.isFinite ? rate : 1.0))
        // 倍速变更:设备时钟按"输出样本 × rate"换算内容秒,先把基准重锚到
        // 当前内容位置与当前 sampleTime,避免整段历史按新 rate 重算导致跳变。
        var sampleTime: Double?
        lock.lock()
        let queue = audioQueue
        lock.unlock()
        if let queue {
            var ts = AudioTimeStamp()
            if AudioQueueGetCurrentTime(queue, nil, &ts, nil) == noErr,
               ts.mFlags.contains(.sampleTimeValid) {
                sampleTime = ts.mSampleTime
            }
        }
        lock.lock()
        if let st = sampleTime {
            _deviceBaseContent = clock.audioTime
            _deviceBaseSample = st
        }
        _playbackRate = clamped
        // #72:基准刚按真实 sampleTime 重锚,锚点同步失效,下一读回真值,
        // 保证 base 与缓存锚点取自同一次时间轴状态。
        clockCache.invalidate()
        let targetContent = _delayTargetContent
        let effective = _playbackRate
        lock.unlock()
        guard targetContent > 0.0005 else { return }
        // Re-derive the wall hold for the new rate and release whatever became
        // due (the line's frames are wall audio of the OLD rate; re-deriving
        // with the new rate keeps the CONTENT delay the user asked for).
        let due = delayLine.setTarget(targetContent / max(0.25, effective))
        _syncHoldToClock()
        for f in due { enqueueDirect(f.frame, contentPts: f.contentPts) }
    }

    // MARK: - 用户音量(2026-11-09,macOS 播放器音量 UI 前置)

    /// 用户音量 0~1(1 = 原始增益)。Guarded by lock。此前 `Playable.setVolume`
    /// 只写 `state.volume`、没有任何消费者(UI 是空转的);这里经
    /// `kAudioQueueParam_Volume` 真正衰减 AudioQueue 输出,建队/重建时补挂。
    private var _volume: Float = 1.0

    /// 设备时钟的内容基准:队列创建时对应的内容秒。设备播放位置 =
    /// base + AudioQueueGetCurrentTime 的 sampleTime / sampleRate。
    ///
    /// AudioQueue 的 sampleTime 在 Pause 期间不变、Start 后继续,所以暂停/
    /// 恢复天然连续,恢复时队列里积压的 PCM 也不会把时钟推过暂停点 ——
    /// 这正是业内做法(时钟取设备位置,而不是累计消费样本)。Guarded by lock。
    private var _deviceBaseContent: Double = 0
    /// 基准时刻的设备 sampleTime(队列时间轴)。倍速切换时与 _deviceBaseContent
    /// 一起重锚,保证内容时间 = base + (sample - baseSample)/sr × rate。
    private var _deviceBaseSample: Double = 0
    /// #72 主时钟插值缓存:sampleTime 锚点 + 单调墙钟外推,热路径零 XPC。
    /// 锚点在 disposeUnderLock/resume/setPlaybackRate 失效。Guarded by lock。
    private var clockCache = InterpolatedDeviceClock(
        freshWindow: AudioUnitOutput.clockFreshWindowForTesting ?? 0.10)

    /// 设备播放位置(内容秒)。nil = 队列不可用/取不到有效采样时间。
    /// #72:freshWindow(0.1s ⇒ ≥10Hz 真查询)内走锚点外推,热路径零 XPC/
    /// 锁等待;暂停期锚点冻结;查询失败在 grace 内兜底外推。AudioQueue API
    /// 在锁外调用(与 enqueue 路径的锁纪律一致)。
    var devicePlaybackTime: Double? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let queue = audioQueue
        let base = _deviceBaseContent
        let baseSample = _deviceBaseSample
        let sr = clock.sampleRate
        let rate = _playbackRate
        let pausedNow = paused
        let action = clockCache.plan(paused: pausedNow, now: now, sampleRate: Double(max(1, sr)))
        lock.unlock()
        guard let queue, sr > 0 else { return nil }
        let sample: Double?
        switch action {
        case .extrapolate(let s), .frozen(let s):
            sample = s
        case .query:
            let result = Self.getCurrentTimeImpl(queue)
            lock.lock()
            if result.valid {
                clockCache.commit(sample: result.sampleTime, now: now)
                sample = result.sampleTime
            } else {
                // 瞬时 XPC 抖动:grace 内按锚点外推,不把失败注入视频时钟
                sample = clockCache.fallbackAfterFailedQuery(now: now, sampleRate: Double(max(1, sr)))
            }
            lock.unlock()
        }
        guard let s = sample else { return nil }
        // sampleTime 是输出(墙钟)样本;内容时间与 AudioClock.advance 同口径,
        // 需要乘播放倍速(2x 时 1 秒输出 = 2 秒内容),否则倍速播放位置只走 1x。
        return base + max(0, s - baseSample) / Double(sr) * Double(rate)
    }

    /// 短临界区读当前音量(start() 不持锁运行,不能裸读)。
    private func currentVolume() -> Float {
        lock.lock(); defer { lock.unlock() }
        return _volume
    }

    public func setVolume(_ volume: Double) {
        // 与 setPlaybackRate 同款收口:非有限值回 1.0,越界夹取。
        let clamped = Float(max(0.0, min(1.0, volume.isFinite ? volume : 1.0)))
        lock.lock()
        _volume = clamped
        let queue = audioQueue
        lock.unlock()
        // AudioQueueSetParameter 是轻量参数调用(非 Pause/Start 那类要进
        // AudioToolbox 串行 server 上下文的控制调用),不必 dispatch 到
        // controlQueue;无活队列(未起播/已停)时只存值,建队时补挂。
        guard let queue else { return }
        Self.setVolumeParamImpl(queue, clamped)
    }

    /// Proxy for clock.audioTime.
    var audioTime: Double {
        clock.audioTime
    }

    /// Proxy for clock.reset(to:sampleRate:).
    func resetClock(to time: Double, sampleRate: Int32 = 44100) {
        clock.reset(to: time, sampleRate: sampleRate)
    }
}

private func audioQueueCallback(_ userData: UnsafeMutableRawPointer?,
                                 _ queue: AudioQueueRef,
                                 _ buffer: AudioQueueBufferRef) {
    guard let p = userData else { AudioQueueFreeBuffer(queue, buffer); return }
    let output = Unmanaged<AudioUnitOutput>.fromOpaque(p).takeUnretainedValue()
    output._callbackConsumed(byteCount: Int(buffer.pointee.mAudioDataByteSize), queue: queue)
    AudioQueueFreeBuffer(queue, buffer)
}
