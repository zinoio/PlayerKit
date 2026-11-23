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
/// - **失败计数按滑动窗口**:`failureWindow`(120s)内的 Start 失败累计
///   ≥ `demoteThreshold`(4)→ 降级。真机第二轮:半死设备会偶发回一个
///   孤立回调再彻底停转,严格「连续」计数被孤立回调清零,10s 间隔的失败
///   永远凑不满(实测 5 次失败无一次降级)——窗口计数对孤立回跳免疫。
/// - **Start 成功不证明设备活着**(半死态:队列能 start 但 HAL 不出声,
///   实测 `afplay` 退出码 0 而无声),故 Start 成功不计入。
/// - **真实 AudioQueue 回调 = 设备 IO 活着的唯一铁证**:降级中来回调构成
///   一次性**恢复边沿**,并清空失败窗口;未降级时回调不清零(见上)。
/// - 降级期的时钟停转判据由 AudioStallWatchdog(独立)承担。
///
/// 线程安全:内部锁;调用方传 `now`(systemUptime)便于确定性测试。
final class AudioDeviceHealth: @unchecked Sendable {
    private let lock = NSLock()

    /// 窗口内多少条 Start 失败判定设备死亡。
    var demoteThreshold = 4

    /// 失败计数滑动窗口(秒)。真机失败间隔约 10s(解码/保活路径各一路),
    /// 120s 容纳十余次仍不误伤一次瞬态失败。
    var failureWindow: TimeInterval = 120

    /// 降级期探测节流(秒):到点才允许一次 start 重建探测。
    /// 5 分钟——风控/HAL 都不该被更密的探测打扰;demand 保底供数期间
    /// 视频按源帧率照常播。
    var probeInterval: TimeInterval = 300

    private var failureTimes: [TimeInterval] = []
    private var lastProbeAt = Date.distantPast.timeIntervalSinceReferenceDate
    private(set) var isDemoted = false
    private(set) var demotionCount = 0

    /// 记一次 Start 失败。返回 true = 本次失败触发降级边沿(仅一次)。
    @discardableResult
    func recordStartFailure(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isDemoted else { return false }
        failureTimes.append(now)
        failureTimes.removeAll { now - $0 > failureWindow }
        guard failureTimes.count >= demoteThreshold else { return false }
        isDemoted = true
        demotionCount += 1
        failureTimes.removeAll()
        lastProbeAt = Date.distantPast.timeIntervalSinceReferenceDate   // 首探立即放行
        return true
    }

    /// Start 返回 noErr 时调用:**不**清零失败窗口(半死态 Start 也能
    /// 成功,见文件头)。
    func recordStartSuccess() {}

    /// 真实回调到达:设备 IO 活着。返回 true = 恢复边沿(降级→正常)。
    /// 未降级时不清零失败窗口(孤立回跳不得延迟降级判定)。
    @discardableResult
    func recordDeviceAlive(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isDemoted else { return false }
        isDemoted = false
        failureTimes.removeAll()
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
