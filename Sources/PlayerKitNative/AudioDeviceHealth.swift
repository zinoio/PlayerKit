import Foundation

/// #608:音频输出设备健康跟踪(纯逻辑,不碰 CoreAudio,CI 无设备可测)。
///
/// 2026-11-23 真机:LG UltraFine DisplayPort 音频起播 10s 后
/// `kAudioDevicePropertyIOStoppedAbnormally` 停机,此后 `AudioQueueStart`
/// 恒被 HAL 拒绝('stop',1937010544),starved-rebuild 每 10s 重建同样
/// 失败——每次重建都是一次喂锤;音频主导的主时钟冻结,画面 0~0.7fps,
/// UI 永远「正在缓冲」,而 demux/网络数据面完全健康,用户无从归因。
///
/// 判定语义:
/// - **连续 Start 失败 ≥ demoteThreshold → 降级**:降级期 enqueue 丢帧、
///   resume 不再 Start(零打扰);starvation-rebuild 退化为按
///   `probeInterval` 节流的探测(start 重建队列,天然冲刷陈旧缓冲)。
/// - **Start 成功不证明设备活着**(半死态:队列能 start 但 HAL 不出声,
///   实测 `afplay` 退出码 0 而无声),故 Start 成功**不复位**计数。
/// - **真实 AudioQueue 回调 = 设备 IO 活着的唯一铁证**:复位计数;
///   若此前已降级,则构成一次性**恢复边沿**(调用方据此重校准时钟回切)。
///
/// 线程安全:内部锁;调用方传 `now`(systemUptime)便于确定性测试。
final class AudioDeviceHealth: @unchecked Sendable {
    private let lock = NSLock()

    /// 连续多少条 Start 失败判定设备死亡。真机形态是每 10s 一条失败
    /// (enqueue/resume 各一路),4 条约 40s 内收敛,不至于把一次瞬态
    /// 失败误判成死亡。
    var demoteThreshold = 4

    /// 降级期探测节流(秒):到点才允许一次 start 重建探测。
    /// 5 分钟——风控/HAL 都不该被更密的探测打扰;demand 保底供数期间
    /// 视频按源帧率照常播。
    var probeInterval: TimeInterval = 300

    private var consecutiveFailures = 0
    private var lastProbeAt = Date.distantPast.timeIntervalSinceReferenceDate
    private(set) var isDemoted = false
    private(set) var demotionCount = 0

    /// 记一次 Start 失败。返回 true = 本次失败触发降级边沿(仅一次)。
    @discardableResult
    func recordStartFailure(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isDemoted else { return false }
        consecutiveFailures += 1
        guard consecutiveFailures >= demoteThreshold else { return false }
        isDemoted = true
        demotionCount += 1
        lastProbeAt = Date.distantPast.timeIntervalSinceReferenceDate   // 首探立即放行
        return true
    }

    /// Start 返回 noErr 时调用:**不复位**失败计数(半死态 Start 也能
    /// 成功,见文件头)。
    func recordStartSuccess() {}

    /// 真实回调到达:设备 IO 活着。返回 true = 恢复边沿(降级→正常)。
    @discardableResult
    func recordDeviceAlive(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        guard isDemoted else { return false }
        isDemoted = false
        return true
    }

    /// 现在是否允许探测。未降级恒 true(保持原 starvation-rebuild 语义)。
    func shouldProbe(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isDemoted else { return true }
        return now - lastProbeAt >= probeInterval
    }

    /// 记录一次探测已发起(下次探测节流起点)。
    func recordProbedAt(now: TimeInterval) {
        lock.lock(); lastProbeAt = now; lock.unlock()
    }
}
