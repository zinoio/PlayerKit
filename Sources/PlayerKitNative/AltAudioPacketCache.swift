// Sources/PlayerKitNative/AltAudioPacketCache.swift

/// 备选音轨原始包的短期缓存(zyno#171):解复用循环把非当前音轨的包按时间窗
/// 缓存下来,切音轨时命中缓存就不必做物理 seek(网络源上一次 seek 实测 ~5.7s)。
/// 纯值类型、泛型 Payload(生产里是克隆的 AVPacket,测试里是 Int),不依赖 ffmpeg。
/// 线程安全由调用方保证(生产中只在 demuxLock 内访问)。
struct AltAudioPacketCache<Payload> {
    static var defaultWindowSeconds: Double { 20 }

    private struct Entry { let pts: Double; let payload: Payload; let bytes: Int }

    private let windowSeconds: Double
    private let maxBytes: Int
    private let bytesOf: (Payload) -> Int
    private let onEvict: (Payload) -> Void
    private var streams: [Int32: [Entry]] = [:]
    private(set) var totalBytes = 0

    init(windowSeconds: Double = Self.defaultWindowSeconds,
         maxBytes: Int = 48 * 1024 * 1024,
         bytesOf: @escaping (Payload) -> Int,
         onEvict: @escaping (Payload) -> Void = { _ in }) {
        self.windowSeconds = windowSeconds
        self.maxBytes = maxBytes
        self.bytesOf = bytesOf
        self.onEvict = onEvict
    }

    mutating func append(stream: Int32, pts: Double, payload: Payload) {
        let bytes = bytesOf(payload)
        streams[stream, default: []].append(Entry(pts: pts, payload: payload, bytes: bytes))
        totalBytes += bytes
        // 1. 时间窗:该流里比最新包早 windowSeconds 以上的淘汰。
        let cutoff = pts - windowSeconds
        while let first = streams[stream]?.first, first.pts < cutoff, streams[stream]!.count > 1 {
            evictFirst(of: stream)
        }
        // 2. 字节上限:全局从最旧的包起淘汰,但永不淘汰刚追加的这一个。
        while totalBytes > maxBytes {
            guard let victim = streams
                .filter({ $0.value.count > 1 || $0.key != stream })
                .compactMap({ key, list in list.first.map { (key, $0.pts) } })
                .min(by: { $0.1 < $1.1 })?.0 else { break }
            evictFirst(of: victim)
        }
    }

    func packets(stream: Int32, from: Double) -> [(pts: Double, payload: Payload)] {
        (streams[stream] ?? []).filter { $0.pts >= from }.map { ($0.pts, $0.payload) }
    }

    /// 缓存是否覆盖 `at`:该流最早缓存包 pts <= at+tolerance(没有缺口),
    /// 且最新包不早于 at(缓存还够新)。
    func covers(stream: Int32, at: Double, tolerance: Double) -> Bool {
        guard let list = streams[stream], let first = list.first, let last = list.last else { return false }
        return first.pts <= at + tolerance && at <= last.pts + 1.0
    }

    mutating func removeAll() {
        for list in streams.values { for e in list { onEvict(e.payload) } }
        streams.removeAll()
        totalBytes = 0
    }

    private mutating func evictFirst(of stream: Int32) {
        guard var list = streams[stream], !list.isEmpty else { return }
        let e = list.removeFirst()
        totalBytes -= e.bytes
        streams[stream] = list.isEmpty ? nil : list
        onEvict(e.payload)
    }
}

enum AltAudioCachePolicy {
    /// 音轨总数上限。蓝光原盘常有十几条音轨,让 libavformat 重组所有 PES 曾把解码拖到 0.2fps
    /// (见 FFmpegDemuxer.applyStreamDiscard),超过此数不启用缓存,切轨仍走 seek 路径。
    static let maxTracks = 4
    static func shouldEnable(audioTrackCount: Int) -> Bool {
        (2...maxTracks).contains(audioTrackCount)
    }
}
