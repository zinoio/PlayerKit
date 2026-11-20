import Foundation

/// #72 主时钟插值缓存:把「每帧一次 AudioQueueGetCurrentTime 同步 XPC 往返」
/// 降为 ≥10Hz(freshWindow=0.1s),热路径用单调墙钟外推 sampleTime。
///
/// 修的是 2026-11-20 实机定位的病灶(issue #72,sample 栈实锤):XPC 延迟
/// 抖动直接注入视频时钟 → A/V diff 追猎式摆动(±60~70ms,口型可感)+
/// display tick gap(渲染空档),每帧 XPC+锁开销同时拖低显示帧率上限。
///
/// 语义与裸查询一致:AudioQueue sampleTime 在 Pause 期间不变(冻结)、
/// Start 后继续;锚点在队列销毁/resume/倍速切换时失效,失效后首读回真值。
/// 决策(plan)与查询分离:查询必须在 AudioUnitOutput 的锁外执行(与
/// enqueue 路径锁纪律一致),决策在锁内完成。
struct InterpolatedDeviceClock {
    enum Action: Equatable {
        /// 热路径:从锚点外推,零设备查询
        case extrapolate(Double)
        /// 暂停期:锚点冻结值(sampleTime 暂停时不前进)
        case frozen(Double)
        /// 需要真实设备查询(锚点失效或过期)
        case query
    }

    /// 真查询频率下限的倒数:0.1s ⇒ ≥10Hz 重锚,墙钟与设备钟的 ppm 级漂移
    /// 每窗归零,误差上界 = drift × 0.1s(亚微秒级)。
    private let freshWindow: TimeInterval
    /// 查询失败时的兜底外推时限:超过则返回 nil,上层回退 audioClock,
    /// guardWindow 语义接管。
    private let staleGrace: TimeInterval

    /// 最近一次真实查询的设备 sampleTime(队列时间轴)。nil = 未锚定。
    private var anchorSample: Double?
    /// 锚定时刻(单调 uptime,与 lastCallbackWall 同钟)。
    private var anchorWall: TimeInterval = 0

    init(freshWindow: TimeInterval = 0.10, staleGrace: TimeInterval = 0.50) {
        self.freshWindow = freshWindow
        self.staleGrace = staleGrace
    }

    /// 纯决策:按暂停态/锚点新鲜度决定「外推/冻结/查询」。不查询、不改状态。
    /// sampleRate = 输出采样率(sampleTime 是墙钟样本轴)。
    func plan(paused: Bool, now: TimeInterval, sampleRate: Double) -> Action {
        guard let sample = anchorSample else { return .query }
        if paused { return .frozen(sample) }
        let elapsed = now - anchorWall
        if elapsed < freshWindow {
            return .extrapolate(sample + max(0, elapsed) * sampleRate)
        }
        return .query
    }

    /// 真实查询成功后重锚。
    mutating func commit(sample: Double, now: TimeInterval) {
        anchorSample = sample
        anchorWall = now
    }

    /// 真实查询失败时的兜底:锚点仍在 grace 内 → 外推(吸收瞬时 XPC 抖动,
    /// 消除 -70ms 那类瞬间回跳),超过 grace → nil。
    func fallbackAfterFailedQuery(now: TimeInterval, sampleRate: Double) -> Double? {
        guard let sample = anchorSample else { return nil }
        let elapsed = now - anchorWall
        guard elapsed >= 0, elapsed < staleGrace else { return nil }
        return sample + elapsed * sampleRate
    }

    /// 队列时间轴失效(建队/销毁/resume/倍速切换):下一读回真值。
    mutating func invalidate() {
        anchorSample = nil
    }
}
