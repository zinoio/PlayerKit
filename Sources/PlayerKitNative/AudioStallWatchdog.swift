import Foundation

/// #608:音频时钟停转看门狗(纯逻辑,CI 可测)。
///
/// 真机第二轮(2026-11-23):半死设备(LG DP 音频 IO 停机)会偶发回一个
/// 孤立回调再彻底停转——`AudioQueueStart` 失败计数凑不满、被孤立回跳
/// 干扰;但音频主导的时钟一旦冻结,freeze-ahead 守卫就把超前帧无限冻结
/// (fps 0.7、UI 永远「正在缓冲」)。严格失败计数不可靠,真正要编码的
/// 判据是:**播放中音频时钟是否在真实推进**。
///
/// 语义:相邻判定间隔 ≥ `stallThreshold`(3s)时,若该窗口内 `audioTime`
/// 推进 < `minAdvanceSeconds`(0.1s)⇒ 判定停转(一次性返回 true,窗口
/// 随即重置——持续停转会再判,调用方按降级状态去重)。正常 1x 播放每窗口
/// 推进数秒,偶发 23ms 孤立回跳远达不到 0.1s,均不误报。
struct AudioStallWatchdog {
    /// 判定窗口(秒)。
    var stallThreshold: TimeInterval = 3.0
    /// 窗口内视为「仍在推进」的最小音频时钟增量(秒)。
    var minAdvanceSeconds: Double = 0.1

    /// nil = 尚未建立基线(首 tick / reset 后)。
    private var lastWall: TimeInterval?
    private var lastAudio: Double = 0

    /// 清空基线(暂停/降级/重建时调用,避免把合法的静止判成停转)。
    mutating func reset() {
        lastWall = nil
    }

    /// 喂一个采样;返回 true = 本窗口判定停转。
    mutating func note(now: TimeInterval, audioTime: Double) -> Bool {
        guard let wall = lastWall else {
            lastWall = now
            lastAudio = audioTime
            return false
        }
        let elapsed = now - wall
        guard elapsed >= stallThreshold else { return false }
        let advanced = audioTime - lastAudio
        lastWall = now
        lastAudio = audioTime
        return advanced < minAdvanceSeconds
    }
}
