import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "dovi.system.renderer")

/// Native DV system path, part 3: drive the shared `AVSampleBufferDisplayLayer`
/// from `ASBDLRenderer` with compressed samples (design §5.3).
///
/// Audio remains the master clock: this renderer owns a `CMTimebase` (host
/// time clock source) attached to the layer's sample buffer renderer, set to
/// the first frame's pts at `start`, re-rated for pause/speed, and periodically
/// re-anchored to `AudioClock` via `calibrate` — **without** any output-latency
/// adjustments of its own (#357: read exactly what AudioClock reports so both
/// pipelines share one convention).
///
/// Session release discipline (design §6.5, spike conclusion 4): a system
/// decode session that isn't fully released makes the next session fail with
/// -12910. `stop()` therefore does the full synchronous teardown —
/// stopRequestingMediaData + flush(removingDisplayedImage) + detach the
/// controlTimebase + drop the request flag — and every teardown path
/// (stop / seek rebuild / preference switch / fallback) must go through it
/// before a new session is created.
class SystemDVRenderer {

    private let displayLayer: AVSampleBufferDisplayLayer
    private var sampleRenderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }
    /// Serial queue: all layer/renderer state transitions happen here.
    private let queue = DispatchQueue(label: "io.zyno.PlayerKit.dovi.system.renderer")

    private var pendingSamples: [CMSampleBuffer] = []
    private var pendingDuration: Double = 0
    private var timebase: CMTimebase?
    private var lastEnqueuedPts: Double?
    private var requestActive = false
    private var stopped = true
    private var failureReported = false

    /// Layer status == .failed or renderer reported an error → invoked **once**.
    /// NativeBackend tears down the system path and rebuilds the software path.
    var onFailure: ((Error?) -> Void)?

    /// Look-ahead cap in seconds of compressed content held ahead of the
    /// presentation point (demux-side throttle reads `bufferedSeconds`).
    var maxLookaheadSeconds: Double = 1.5
    /// Re-anchor the timebase only when the drift vs AudioClock exceeds this;
    /// smaller drifts are left alone to avoid visible jerk.
    var driftThresholdSeconds: Double = 0.08

    /// Test/diagnostic visibility: samples not yet handed to the layer.
    var pendingSampleCount: Int {
        queue.sync { pendingSamples.count }
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    // MARK: - Lifecycle

    /// New timebase anchored at `pts` (host clock source), then start pulling.
    func start(at pts: Double, rate: Float) {
        queue.sync {
            stopped = false
            failureReported = false
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: nil,
                                            sourceClock: CMClockGetHostTimeClock(),
                                            timebaseOut: &tb)
            guard let tb else {
                logger.error("CMTimebaseCreateWithSourceClock failed")
                return
            }
            CMTimebaseSetTime(tb, time: CMTime(seconds: pts, preferredTimescale: 90_000))
            CMTimebaseSetRate(tb, rate: Double(rate))
            displayLayer.controlTimebase = tb
            self.timebase = tb
            beginRequestIfNeededLocked()
        }
    }

    /// Thread-safe enqueue; handing to the layer happens on the serial queue
    /// via `requestMediaDataWhenReady`.
    func enqueue(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let duration = CMTimeGetSeconds(
                CMSampleBufferGetDuration(sample))
            self.pendingSamples.append(sample)
            if duration.isFinite, duration > 0 { self.pendingDuration += duration }
            self.beginRequestIfNeededLocked()
        }
    }

    /// Pause = 0, playback = 1, speed = rate.
    func setRate(_ rate: Float) {
        queue.async { [weak self] in
            guard let self, let tb = self.timebase else { return }
            CMTimebaseSetRate(tb, rate: Double(rate))
        }
    }

    /// Re-anchor the timebase to AudioClock's external time **when the drift
    /// exceeds `driftThresholdSeconds`**. `t` is taken as-is — no output
    /// latency additions/subtractions here (#357 stays single-convention).
    func calibrate(toAudioTime t: Double) {
        queue.async { [weak self] in
            guard let self, let tb = self.timebase else { return }
            let now = CMTimeGetSeconds(CMTimebaseGetTime(tb))
            guard now.isFinite, abs(now - t) > self.driftThresholdSeconds else { return }
            logger.info("calibrate: drift \(now - t, format: .fixed(precision: 3))s → re-anchor")
            CMTimebaseSetTime(tb, time: CMTime(seconds: t, preferredTimescale: 90_000))
        }
    }

    /// Seek: drop everything (incl. the displayed image) and re-anchor time.
    func flush(at pts: Double) {
        queue.sync {
            pendingSamples.removeAll()
            pendingDuration = 0
            lastEnqueuedPts = nil
            sampleRenderer.flush(removingDisplayedImage: true)
            if let tb = timebase {
                CMTimebaseSetTime(tb, time: CMTime(seconds: pts, preferredTimescale: 90_000))
            }
        }
    }

    /// Full synchronous teardown. **Every** path that ends or rebuilds a system
    /// session must call this before creating the next one (-12910, design §6.5).
    ///
    /// 2026-10-28 实证(SystemDVRendererTests.testCreateStopCreateLoopDoesNotFail,
    /// 同 layer 复用 10 轮 + 每 2 轮换 layer):以下四步合起来足以释放系统解码
    /// 会话,复用 layer 的下一轮不再报 -12910 / 不触发 onFailure——
    ///   1. stopRequestingMediaData(停掉 requestMediaDataWhenReady 的拉取循环)
    ///   2. flush(removingDisplayedImage: true)(丢层内队列 + 当前显示帧)
    ///   3. 摘掉 controlTimebase(结束 timebase 驱动的呈现节奏)
    ///   4. 丢弃 builder/renderer 对样本的全部引用
    /// 单独做其中一步(只 flush / 只停拉取)不构成完整释放契约,不做实验性
    /// 裁剪;若未来在真机/外接屏上仍出现 -12910,升级方案是整层换新(layer
    /// 重建),NativeBackend 侧已按"换 layer 也允许"设计。
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            sampleRenderer.stopRequestingMediaData()
            sampleRenderer.flush(removingDisplayedImage: true)
            displayLayer.controlTimebase = nil
            timebase = nil
            pendingSamples.removeAll()
            pendingDuration = 0
            lastEnqueuedPts = nil
            requestActive = false
        }
    }

    // MARK: - State for NativeBackend tick / demux throttle

    /// Seconds of compressed content queued ahead of the presentation point
    /// (pending + in-layer span). Demux throttle compares against
    /// `maxLookaheadSeconds`.
    var bufferedSeconds: Double {
        queue.sync {
            var buffered = pendingDuration
            if let last = lastEnqueuedPts, let now = currentTimeLocked(),
               last > now {
                buffered += last - now
            }
            return buffered
        }
    }

    /// First frame ready for display (native first-frame reveal signal).
    /// macOS/iOS/tvOS 14.0-17.3(各平台对应版本)上无 isReadyForDisplay,
    /// 退化为 status 代理(enqueue 后进入 .rendering),首帧超时回退的语义
    /// 在这些版本上是放宽的。
    var hasPresentedFirstFrame: Bool {
        #if os(macOS)
        if #available(macOS 14.4, *) { return displayLayer.isReadyForDisplay }
        #elseif os(tvOS)
        if #available(tvOS 17.4, *) { return displayLayer.isReadyForDisplay }
        #else
        if #available(iOS 17.4, *) { return displayLayer.isReadyForDisplay }
        #endif
        return displayLayer.status != .unknown
    }

    /// Timebase time in pts-domain seconds (nil before start / after stop).
    /// Reading this is safe from any thread.
    var currentTime: Double? {
        queue.sync { currentTimeLocked() }
    }

    // MARK: - Internals (queue-confined)

    private func currentTimeLocked() -> Double? {
        guard let tb = timebase else { return nil }
        let t = CMTimeGetSeconds(CMTimebaseGetTime(tb))
        return t.isFinite ? t : nil
    }

    private func beginRequestIfNeededLocked() {
        guard !requestActive, !stopped else { return }
        requestActive = true
        sampleRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.supplyMediaData()
        }
    }

    /// Called by the layer whenever it can accept more data.
    private func supplyMediaData() {
        // queue-confined
        guard !stopped else { return }
        while sampleRenderer.isReadyForMoreMediaData, !pendingSamples.isEmpty {
            // Backpressure: keep `maxLookaheadSeconds` ahead of the timebase.
            if let now = currentTimeLocked(), let last = lastEnqueuedPts,
               last - now > maxLookaheadSeconds {
                break
            }
            let sample = pendingSamples.removeFirst()
            let d = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            if d.isFinite, d > 0 {
                pendingDuration -= d
                if pendingDuration < 0 { pendingDuration = 0 }
            }
            sampleRenderer.enqueue(sample)
            lastEnqueuedPts = CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sample))
        }
        if pendingSamples.isEmpty, !sampleRenderer.isReadyForMoreMediaData {
            // Layer saturated; requestMediaDataWhenReady will call again.
        }
        checkFailureLocked()
    }

    private func checkFailureLocked() {
        guard !failureReported else { return }
        let layerError = displayLayer.error
        let rendererError = sampleRenderer.error
        if displayLayer.status == .failed || layerError != nil || rendererError != nil {
            reportFailureLocked(rendererError ?? layerError)
        }
    }

    /// 失败上报。回调**必须跳离渲染器队列**:消费方(NativeBackend 回退)
    /// 会 queue.sync 进 stop(),同队列重入直接死锁(dispatch target queue
    /// 自检 SIGTRAP)。
    private func reportFailureLocked(_ err: Error?) {
        guard !failureReported else { return }
        failureReported = true
        logger.error("system DV layer failed: \(String(describing: err))")
        DispatchQueue.global().async { [weak self] in
            self?.onFailure?(err)
        }
    }

    /// 测试专用:直接走真实失败上报路径(只触发一次的语义与生产一致)。
    func reportFailureForTesting(_ err: Error?) {
        queue.sync { reportFailureLocked(err) }
    }
}
