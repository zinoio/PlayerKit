import Foundation
import PlayerKit

/// adopt 已预热会话失败(prepared 已被消费或已 abandon)。
public enum PreparedMediaError: Error, LocalizedError {
    case notConsumable

    public var errorDescription: String? {
        switch self {
        case .notConsumable:
            return "PreparedMedia is no longer consumable (already adopted or closed)"
        }
    }
}

/// 预热的媒体会话(zyno#108 下一集预加载):已完成 open(avformat_open_input
/// + find_stream_info)的 FFmpegDemuxer,等待被 `NativeBackend.play(prepared:)`
/// adopt。预热对象不持有解码器/音频输出/显示链接,内存 sub-MB(demuxer 上下文
/// + AVIOBridge 32KB buffer + probesize ≤256KB + app 层 reader 自身缓存)。
///
/// 生命周期:`NativeBackend.prepareMedia` 创建 → 调用方持有,择机 `close()`
/// (abandon,幂等)或交给 `play(prepared:)`(consume,所有权移交 backend;
/// 此后 close() 是 no-op —— demuxer 归 backend 的 stop() 管,二次 close 会撞
/// 上 backend 的会话)。
///
/// 模式先例:MultiClipDemuxer 在当前 clip 剩余 ≤3s 时后台 pre-open 下一个
/// clip 的 demuxer,seam 处直接复用——本类型把同一思路泛化到单文件切换。
public final class PreparedMedia: @unchecked Sendable {
    public enum Source {
        case url(URL, headers: [String: String])
        case reader(any MediaRandomAccessReader)
    }

    public let source: Source
    let demuxer: FFmpegDemuxer

    private let stateLock = NSLock()
    private var consumed = false
    private var closed = false

    init(demuxer: FFmpegDemuxer, source: Source) {
        self.demuxer = demuxer
        self.source = source
    }

    /// 是否仍可被 `play(prepared:)` adopt。
    public var isConsumable: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !consumed && !closed
    }

    /// abandon 预热:close demuxer。幂等;consume 之后调用是 no-op。
    public func close() {
        stateLock.lock()
        if consumed || closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        demuxer.close()
    }

    /// consume(仅 PlayerKitNative 可触):置位并交出 demuxer;不可消费返回 nil。
    func consume() -> FFmpegDemuxer? {
        stateLock.lock()
        if consumed || closed {
            stateLock.unlock()
            return nil
        }
        consumed = true
        stateLock.unlock()
        return demuxer
    }
}

extension NativeBackend {
    /// 提前打开媒体(zyno#108):付清网络首包 + find_stream_info 两笔冷起播
    /// 大头,返回可交接的会话。不触碰音频会话/显示链接/渲染器,可与正在
    /// 播放的会话并存;失败 throw,调用方静默回退普通 play() 路径。
    ///
    /// `preferredMaxVideoWidth` 需与随后 adopt 它的 backend 一致(影响流
    /// 选择),调用方从 `backend.preferredMaxVideoWidth` 读入。
    /// 时长探测在预热期全量执行(skipDurationProbe=false)——这正是要
    /// 预付的成本之一;adopt 时传入的 knownDuration 仍按 _finishOpen 优先级生效。
    public static func prepareMedia(url: URL, headers: [String: String],
                                    preferredMaxVideoWidth: Int = 0) async throws -> PreparedMedia {
        let demuxer = FFmpegDemuxer()
        demuxer.preferredMaxVideoWidth = preferredMaxVideoWidth
        // avformat_open_input + find_stream_info block on network I/O —
        // same constraint as play(url:): must leave the main actor.
        try await Task.detached(priority: .userInitiated) {
            try demuxer.open(url: url, headers: headers)
        }.value
        return PreparedMedia(demuxer: demuxer, source: .url(url, headers: headers))
    }

    /// reader 变体:预热走 app 层自定义 I/O(115 等 RandomAccess driver)。
    /// open 用 GCD 而非 Task.detached —— Swift 协作线程池可能被其他 async
    /// 工作饿死导致 open 延迟 10-15s(见 play(reader:) 同款注释)。
    public static func prepareMedia(reader: any MediaRandomAccessReader,
                                    preferredMaxVideoWidth: Int = 0) async throws -> PreparedMedia {
        let demuxer = FFmpegDemuxer()
        demuxer.preferredMaxVideoWidth = preferredMaxVideoWidth
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try demuxer.open(reader: reader)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return PreparedMedia(demuxer: demuxer, source: .reader(reader))
    }
}
