import Foundation
import CoreVideo
import PlayerKit

final class VideoJitterBuffer: @unchecked Sendable {

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let elPixelBuffer: CVPixelBuffer?
        let pts: Double
        let metadata: FrameMetadata

        init(pixelBuffer: CVPixelBuffer,
             elPixelBuffer: CVPixelBuffer? = nil,
             pts: Double,
             metadata: FrameMetadata) {
            self.pixelBuffer = pixelBuffer
            self.elPixelBuffer = elPixelBuffer
            self.pts = pts
            self.metadata = metadata
        }

        /// Bytes this frame holds. A frame is a decoded picture, so this is what
        /// actually costs memory (a 4K 10-bit HDR frame is ~18.5 MB).
        var byteSize: Int {
            CVPixelBufferGetDataSize(pixelBuffer)
                + (elPixelBuffer.map { CVPixelBufferGetDataSize($0) } ?? 0)
        }
    }

    enum State: Equatable { case playing, buffering }

    /// Ceiling for the decoded frames held here.
    ///
    /// The frame cap used to be fps x maxDuration (240 frames at 120 fps) with no
    /// regard for frame size. For 4K 10-bit HDR that is ~4.4 GB: on iPhone the app
    /// got a memory warning ~1 s after the first frame (q=113, ~2.1 GB) and was
    /// SIGKILLed (2026-09-30). Frames are IOSurface-backed, so this never shows in
    /// RSS on the Mac and cannot be caught there by looking at process memory.
    let memoryBudgetBytes: Int

    /// iOS extensions/apps are killed at a few GB; a Mac has room to spare.
    static var defaultMemoryBudgetBytes: Int {
        #if os(iOS)
        return 512 << 20
        #else
        return 2 << 30
        #endif
    }

    /// Frames the byte budget always leaves room for, so a very large frame can
    /// never make the buffer unusable (it must still be able to start playing).
    private static let minBudgetFrames = 6
    /// Frames that may already be in flight in the decoder (VT reorders and
    /// returns asynchronously) when `isFull` starts holding the demux loop back.
    private static let inFlightSlackFrames = 8

    init(memoryBudgetBytes: Int = VideoJitterBuffer.defaultMemoryBudgetBytes,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.memoryBudgetBytes = memoryBudgetBytes
        self.now = now
        self.bufferingStart = now()
    }

    private var bufferedBytesLocked = 0
    /// Largest frame seen. Frame size is a property of the stream, so this settles
    /// after the first frame; until then the budget cannot be converted to frames.
    private var frameBytesHint = 0

    /// Bytes of decoded frames currently held.
    var bufferedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bufferedBytesLocked
    }

    /// True when the byte budget is used up: the demux loop should stop feeding the
    /// decoder for a moment. Only ever true for byte pressure, so normal content
    /// (small frames) is unaffected. Independent of the audio clock on purpose: at
    /// start the audio clock has not advanced, the time-based throttle is inactive
    /// and decoding ran at full speed.
    var isFull: Bool {
        lock.lock(); defer { lock.unlock() }
        return frames.count >= budgetFramesLocked
    }

    /// How far (seconds of content) the demux loop may read ahead of the audio clock.
    ///
    /// The time throttle used a flat `maxDuration` (2 s). With 4K 10-bit HDR the byte
    /// budget holds only ~20 frames (~0.8 s at 24 fps), so 2 s of read-ahead is ~48
    /// frames into a buffer that takes 28: `append` refuses the overflow for good and
    /// the display loop shows every ~1.6th frame (device 2026-10-23: 14.7 fps against
    /// 23.976, show gaps up to 208 ms, av offset swinging +-100 ms). Keeping the
    /// read-ahead inside what the budget holds means nothing is ever refused.
    ///
    /// Never below what the buffer needs to reach the playing threshold, or playback
    /// would never start.
    var readAheadSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        let frameDur = 1.0 / max(framesPerSecondHint, 1)
        let floor = resumeDurationLocked + 2.0 * frameDur
        // demux 预读是「读到哪解码到哪」,不是压缩包缓存:深度绝不能超过
        // jitter 容量,否则超出的部分被 append 拒收 → PTS 空洞 → 跳帧。
        let capacitySecs = capacitySecondsLocked
        guard frameBytesHint > 0 else { return min(maxDuration, capacitySecs) }
        let byBudget = Double(budgetFramesLocked) / framesPerSecondHint * Self.readAheadBudgetFill
        return min(min(maxDuration, capacitySecs), max(byBudget, floor))
    }

    /// Share of the byte-budget frames the read-ahead may fill; the rest absorbs the
    /// B-frame reordering the decoder still returns after the throttle trips.
    private static let readAheadBudgetFill = 0.9

    /// How many frames the byte budget allows (Int.max until a frame size is known).
    private var budgetFramesLocked: Int {
        guard frameBytesHint > 0 else { return Int.max }
        return max(Self.minBudgetFrames, memoryBudgetBytes / frameBytesHint)
    }

    /// Soft capacity in frames: what the buffer is meant to hold.
    private var capacityFramesLocked: Int {
        min(max(60, Int((framesPerSecondHint * maxDuration).rounded(.up))), budgetFramesLocked)
    }

    /// 解码帧容量(秒):帧数硬上限扣掉在途余量。预读深度与水位阈值都必须
    /// 落在其内——超出容量的预读会被 append 拒收并打出 PTS 空洞(显示跳帧),
    /// 超出容量的水位则永远攒不满(只能靠 slowDecoderGrace 强开)。
    /// 2026-11-19 真机(已撤销的自适应预读 4~11s / 容量 60 帧):拒收 50~200
    /// 帧/5s,显示间隔均值 41.7→191ms、fps 21.6→3.7(声音正常、渲染层健康)。
    private var capacitySecondsLocked: Double {
        Double(max(0, maxFrameCountLocked - Self.inFlightSlackFrames))
            / max(framesPerSecondHint, 1)
    }

    /// The resume threshold is a duration sized for ~2 s of buffer. When
    /// the byte budget shrinks the buffer below that, scale it — otherwise
    /// the buffer can never reach `resumeDuration` and playback falls into the old
    /// "start, show one frame, freeze for 4 s" loop (see the 120 fps note below).
    private var thresholdScaleLocked: Double {
        min(1.0, (Double(capacityFramesLocked) / framesPerSecondHint) / maxDuration)
    }
    /// 高水位还受「容量 − 2 帧」约束:demux 只预读到 readAheadSeconds,而
    /// readAhead 的下限 = 本值 + 2 帧,两者互相锁定才能保证容量内既攒得到
    /// 水位、又不会溢出。
    private var resumeDurationLocked: Double {
        min(resumeDuration * thresholdScaleLocked,
            max(0, capacitySecondsLocked - 2.0 / max(framesPerSecondHint, 1)))
    }

    /// Called synchronously when state transitions between .playing and
    /// .buffering. Fires on the demux thread (append) or main thread (pop),
    /// so the handler must be thread-safe. This is intentional: audio
    /// pause/resume must happen synchronously to avoid races where the
    /// AudioQueue keeps consuming buffers between the state flip and an
    /// async dispatch.
    var onStateChange: ((State) -> Void)?

    // 水位是 `let`:不要在播放期间按下载速度之类的信号运行时调整。2026-11-18 的
    // 缓冲策略自适应(097d2e1)这样做过——信号测的是 demux 消费速度而非网速,稳态
    // 被判成慢网/中档(慢网档 min 2.0s),而 60 帧容量下稳态水位约 (60−8)/fps 秒,
    // 与之只差 0–3 帧:24fps 刚好多 2 帧,≥25fps 即 playing↔buffering 抖动
    // (fps 掉 27–34%),2026-11-20 撤销。方案 B 后低水位不再是状态迁移信号。
    // 放行水位 1.5s(2026-11-21 探针轮 F/G 定案):4K VBR 高码率场景(~8Mbps 段)
    // 遇通道到达率缺口(实测 ~6Mbps ≈ 0.8×)时,0.86s 的开放水位每 ~4.5s 必然
    // 触底断粮;容量(iOS 512MB 预算 ≈ 41 帧 ≈ 1.64s @25fps)允许更深的吸收。
    // 水位加深到 1.5s:补缓冲攒满一次能吃掉 ~1.5s 供给缺口,CDN 突发(实测
    // 13.8Mbps)多数时候填得回来,断粮周期拉长一倍且大多不再触底。G 轮对照:
    // 同设备同网络,通道跟上时 45s+ 零断粮、25fps 间隔均匀——管线无回归,差距
    // 全在缓冲深度对缺口的吸收能力。
    // 2026-09-02 曾试降到 0.6s 换更快首帧,但 115 CDN 单次请求耗时观测到
    // 5~9.5s 的抖动(Cloud115StreamReader.swift 头部注释详述),0.6s 的缓冲
    // margin 扛不住,反而更频繁触发二次卡顿——已撤销回 1.0,今日再加深到 1.5。
    // 代价:起播首开慢 ~0.6s(slowDecoderGrace 4s 兜底供给极慢的场景)。
    let resumeDuration: Double = 1.5  // 达到此值 → playing
    let maxDuration: Double = 2.0     // demux 背压阈值（不丢帧，只是限速）
    /// 帧数硬上限，本是"限制内存占用的最后防线"——正常应由上面 maxDuration 的时长背压
    /// 先生效，这个上限极少真正绑定。但它是按固定帧数写的，原为 60（注释"≈2.5s at 24fps"）:
    /// 对 24fps 内容对应 2.5s，远高于 maxDuration/resumeDuration，安全；但对 120fps 内容
    /// 60 帧只等于 0.5s，反而先于 maxDuration 绑定，且同时低于 resumeDuration(1.0s)和
    /// minDuration(0.5s)——缓冲区永远攒不到开播门槛，只能靠 4s 慢速兜底硬开，开播后弹一帧
    /// 剩余时长又跌破 minDuration 立刻打回缓冲，形成"开播→弹一帧→冻结 4 秒"的循环，肉眼看
    /// 就是卡死（2026-09-22 用户反馈"流浪地球直接卡住不动"，4K HDR 120fps HEVC 实测复现：
    /// 60 秒内状态推进仅一次）。
    ///
    /// 修复：上限按源帧率换算 maxDuration 秒的帧数，60 帧只作为下限（保持 ≤60fps 内容的
    /// 既有行为和内存占用不变）。`configureFrameRate` 在拿到帧率之前不调用,此时用 60
    /// (对未知/低帧率场景安全;高帧率场景在拿到 demuxer 的帧率信息后会被立即纠正)。
    private var framesPerSecondHint: Double = 24.0
    /// 加锁版,给临界区外的调用方。已持 `lock` 的代码必须改用
    /// `maxFrameCountLocked`——NSLock 不可重入,持锁时再进这里的
    /// lock.lock() 是同线程二次加锁,必然死锁。
    var maxFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return maxFrameCountLocked
    }

    /// 不加锁版,仅在已持有 `lock` 的临界区内使用。
    private var maxFrameCountLocked: Int {
        let byTime = max(60, Int((framesPerSecondHint * maxDuration).rounded(.up)))
        let budget = budgetFramesLocked
        return budget == Int.max ? byTime : min(byTime, budget + Self.inFlightSlackFrames)
    }

    /// 告知视频源的实际帧率，让 `maxFrameCount` 按真实帧率换算，而不是隐含假设
    /// ~24fps。应在拿到 demuxer 的帧率信息后、开始给这个视频 append 帧之前调用一次
    /// (每次打开新视频/新会话都要重新调用——帧率是流属性，不跨视频保留)。
    /// 非法值(≤0、NaN、无穷)忽略，保留当前值。
    func configureFrameRate(_ fps: Double) {
        guard fps.isFinite, fps > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        framesPerSecondHint = fps
    }

    private var frames: [Frame] = []
    /// Frames refused by the hard cap in append() since the last flush(). A
    /// rising value means the demux loop is feeding faster than the display loop
    /// drains (see the back-pressure there) — the counter makes that visible
    /// instead of letting the buffer silently reshape under pressure.
    private var droppedIncomingFrames = 0
    /// 缓冲宽限(恒定):真断粮回缓冲后,水位攒不到也至少等满该时长再靠
    /// 已到帧放行——给网络/解码真正的攒缓冲窗口。2026-11-21 真机裁定撤销
    /// 「强开后降级 0.5s」闩:供给不足时 0.5s 只攒出 1-2 帧,开门即空、
    /// 0.5-1.5s 微循环;老「播 0.5s 卡 4s」的病根是水位抖动回缓冲(方案 B
    /// 已删),不是 4s 本身。
    private let slowDecoderGrace: TimeInterval = 4.0
    /// 实际断粮防抖(方案 B):播放中队列为空的连续时长达到 starvationDebounce
    /// 才真正回缓冲。低水位(minDuration)只是预警,不再触发状态迁移——2026-11-21
    /// 真机实锤:低水位驱动的 catchUp 每分钟 pause/resume 音频 94 次。
    private var starvingSince: TimeInterval?
    private let starvationDebounce: TimeInterval = 0.12
    /// 清除 starvingSince 所需的恢复深度(帧)。涓流供给(一次一帧)不得重置
    /// 防抖——2026-11-21 真机:每帧清一次导致防抖永远凑不满,音频超前画面
    /// 1.2s、画面冻住且无缓冲卡。3 帧 ≈ 0.12s@25fps 的恢复脉冲。
    private let starvationRecoveryFrames = 3
    private let lock = NSLock()
    private var _state: State = .buffering
    /// 视频流已读到 EOF(demux 线程 markEOF 置位)。此后不再要求攒满
    /// resumeDuration 才开播 —— seek 到接近文件末尾时剩余内容可能不足 1s,
    /// 永远攒不满 → displayNextFrame 永远停在 buffering 门 → 零帧黑屏。
    /// EOF 后 pop 也不再因剩余不足回 .buffering,把末尾帧放完。
    private var eofReached = false
    /// 进入 .buffering 的时刻(systemUptime)。解码/读取极慢(如 4K SW 软解
    /// 仅 1-5fps,或 115 网络慢)时 1.0s 缓冲要等几十秒,期间纯黑屏;超过
    /// slowDecoderGrace 后只要有帧就开播 —— 慢但可见,用户不会误以为卡死。
    /// 计时源经 init 的 `now` 注入(生产 = systemUptime,测试可注假墙钟)。
    private var bufferingStart: TimeInterval
    /// 与 bufferingStart 同源的墙钟(见 init `now`)。
    private let now: () -> TimeInterval

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    /// Frames refused at the frame cap since the last flush (see append).
    var droppedIncomingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedIncomingFrames
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        guard frames.count >= 2 else { return 0 }
        return frames.last!.pts - frames.first!.pts
    }

    // MARK: - Write (demux thread)

    func append(_ frame: Frame) {
        var newState: State?
        lock.lock()

        // Hard cap: refuse the incoming frame while the buffer is full; the demux
        // loop backs off on the same condition (count >= maxFrameCount) so this is
        // rare, and the refusal is counted instead of silent.
        //
        // It must NOT be resolved by dropping the oldest frame (the previous
        // policy): frames[0] is the display loop's next frame, so evicting it made
        // every overflow advance the buffer front further ahead of the audio clock.
        // The front then had to be pulled back by the freeze-ahead guard while
        // audio caught up — the 晃动/卡顿 regression (2026-10-12, real device:
        // 18-24fps against 23.976fps content). Duration-based dropping is also
        // intentionally removed for VOD — the demux loop's throttle (pts >
        // audioPos + 2.0 → sleep) is the pacing mechanism.
        guard frames.count < maxFrameCountLocked else {
            droppedIncomingFrames += 1
            lock.unlock()
            return
        }

        let wallNow = now()
        // 防抖窗口内帧重新到达:只有恢复到足够深度才清除真空计时——涓流
        // 单帧不清(pops 又会立刻打空,防抖被无限重置);已在 .buffering 时
        // starvingSince 本为 nil,此分支不生效。
        if _state == .playing, frames.count >= starvationRecoveryFrames {
            starvingSince = nil
        }

        // Insert in PTS-sorted order so pop() always returns the next display frame.
        // VTVideoDecoder returns B-frames in decode order (not display order); without
        // sorting, jitterBuffer PTS values are scrambled, causing backwards progress
        // and wrong nominalDelay in SyncController.
        let insertIdx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
        let size = frame.byteSize
        bufferedBytesLocked += size
        if size > frameBytesHint { frameBytesHint = size }

        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        if _state == .buffering, !frames.isEmpty {
            let stalled = wallNow - bufferingStart > slowDecoderGrace
            if dur >= resumeDurationLocked || eofReached || stalled {
                _state = .playing
                newState = .playing
            }
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
    }

    // MARK: - Read (main thread)

    func peek(at index: Int = 0) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        return index < frames.count ? frames[index] : nil
    }

    @discardableResult
    func pop() -> Frame? {
        var popped: Frame?
        var newState: State?
        lock.lock()
        guard !frames.isEmpty else { lock.unlock(); return nil }
        popped = frames.removeFirst()
        bufferedBytesLocked -= popped?.byteSize ?? 0
        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        // 方案 B:低水位(minDuration)只是预警,不再在这里回缓冲——真正无帧
        // 可显示经 pollStarvation 防抖后才是 buffering(2026-11-21 真机:低水位
        // 驱动的音频 pause/resume 每分钟 94 次)。EOF 后排空同样保持 playing,
        // 末尾帧放完是正常结束。防抖计时从队列变空的时刻起算(spec §4.2),
        // 而不是第一次 poll 的时刻。
        if _state == .playing, !eofReached, frames.isEmpty, starvingSince == nil {
            // 只在「非空 → 空」的起点锚定一次;涓流下后续 pop 打空不得重启
            // 计时(否则防抖永远凑不满),只有恢复深度 append 才清除。
            starvingSince = now()
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
        return popped
    }

    /// 实际断粮检查(方案 B):每个显示 tick 调用。播放中队列为空且非 EOF
    /// 连续达到防抖时长才真正回缓冲;防抖窗口内帧重新到达则静默清除,不产生
    /// 任何音频/UI 副作用。转缓冲时重置 bufferingStart(#75 语义,原 pop 低水位
    /// 路径迁来的迟滞起点)。
    func pollStarvation() {
        var newState: State?
        lock.lock()
        if _state == .playing, !eofReached {
            if frames.count >= starvationRecoveryFrames {
                // 深度恢复:防抖计时作废,继续正常播放。
                starvingSince = nil
            } else if let since = starvingSince, now() - since >= starvationDebounce {
                // 防抖到期:真断粮。转移条件不再要求「队列此刻为空」——
                // 涓流下队列常驻 1 帧,空判据会让真断粮永远漏判。
                starvingSince = nil
                _state = .buffering
                bufferingStart = now()
                newState = .buffering
            }
        } else {
            starvingSince = nil
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
    }

    /// 视频流是否已读到 EOF(demux 线程 markEOF 置位,flush 复位)。
    /// 显示循环用它判断"音频已结束且排空"的末尾 free-run(zyno#104)。
    var atEOF: Bool {
        lock.withLock { eofReached }
    }

    /// 视频流已读取到 EOF。若此刻仍在 .buffering 且已有帧(剩余内容不足
    /// resumeDuration,正常门槛永远无法满足),立即转 .playing 开始渲染,
    /// 避免 seek 到接近末尾时零帧黑屏。
    func markEOF() {
        var newState: State?
        lock.lock()
        eofReached = true
        starvingSince = nil
        if _state == .buffering, !frames.isEmpty {
            _state = .playing
            newState = .playing
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        bufferedBytesLocked = 0
        droppedIncomingFrames = 0
        _state = .buffering
        eofReached = false
        bufferingStart = now()
        starvingSince = nil
    }
}
