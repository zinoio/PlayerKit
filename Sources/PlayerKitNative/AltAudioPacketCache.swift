// Sources/PlayerKitNative/AltAudioPacketCache.swift

import PlayerKit

/// 备选音轨原始包的短期缓存(zyno#171):解复用循环把非当前音轨的包按时间窗
/// 缓存下来,切音轨时命中缓存就不必做物理 seek(网络源上一次 seek 实测 ~5.7s)。
/// 纯值类型、泛型 Payload(生产里是克隆的 AVPacket,测试里是 Int),不依赖 ffmpeg。
/// 线程安全由调用方保证(生产中只在 demuxLock 内访问)。
struct AltAudioPacketCache<Payload> {
    /// 实测网络源读超前深度 ≤2.4s(2026-10-16,zyno#171),10s 约 4 倍余量。
    static var defaultWindowSeconds: Double { 10 }

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

    /// 取走该流 pts >= from 的包(所有权交给调用方,不触发 onEvict);
    /// 更早的包淘汰释放。调用后该流缓存为空。
    mutating func take(stream: Int32, from: Double) -> [(pts: Double, payload: Payload)] {
        guard let list = streams.removeValue(forKey: stream) else { return [] }
        var kept: [(pts: Double, payload: Payload)] = []
        for e in list {
            totalBytes -= e.bytes
            if e.pts >= from { kept.append((e.pts, e.payload)) } else { onEvict(e.payload) }
        }
        return kept
    }

    mutating func removeAll() {
        for list in streams.values { for e in list { onEvict(e.payload) } }
        streams.removeAll()
        totalBytes = 0
    }

    /// 只保留 `streams` 集合内的流:其余流的包逐个经 `onEvict` 释放并同步扣减
    /// `totalBytes`。候选集收缩时调用(zyno#359)——被移出的流会立即 discard、缓存
    /// 停止更新,若不清掉旧包,之后又被选回时会因「旧包+空洞+新包」被 covers 的
    /// 首尾 pts 判断误命中。集合内的流(含当前轨克隆)一律不动。
    mutating func retain(streams: Set<Int32>) {
        for key in self.streams.keys where !streams.contains(key) {
            guard let list = self.streams.removeValue(forKey: key) else { continue }
            for e in list {
                totalBytes -= e.bytes
                onEvict(e.payload)
            }
        }
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
    /// 多轨盘保留的备选音轨候选上限(zyno#359)。初值 3 —— 3 备选 + 当前轨克隆正是
    /// ≤4 轨文件的既有包络;实测定值后可能下调为 2。
    static let maxAlternates = 3

    /// 从 `tracks` 里挑出值得缓存的备选音轨(不含当前轨),按优先级填满 `limit` 为止:
    /// 0. 备选总数 ≤ limit:全部入选(≤4 轨文件行为与旧的「全量缓存」一致);
    /// 1. `lastSwitchedFrom`(用户刚离开的轨;#196 的「切走后立刻切回」命中依赖它被保留);
    /// 2. 匹配 `preferredLanguage` 的轨(isDefault 优先,其次容器顺序);
    /// 3. 与当前轨同语言的其他轨(BD 常见 TrueHD 主轨 + AC3 兼容轨)。
    /// 4. 兜底补满:前三项不足 `limit` 时,剩余备选按 isDefault 优先、其次容器顺序补满。
    ///    BD M2TS 的音轨常无语言元数据(zyno#339),前三项依赖语言/切轨历史,首次起播会全空,
    ///    快路径就一直用不上;补满后候选数仍 ≤ limit,猜错的代价只是走慢路径。
    /// 多轨盘只缓存至多 `limit` 条候选,避免 libavformat 为全部 PID 重组 PES 拖垮解码。
    /// 纯函数,不依赖 ffmpeg。
    static func selectCandidates(tracks: [TrackInfo], current: Int,
                                 preferredLanguage: String?, lastSwitchedFrom: Int?,
                                 limit: Int = maxAlternates) -> [Int32] {
        guard limit > 0 else { return [] }
        let others = tracks.filter { $0.id != current }
        guard others.count > limit else { return others.map { Int32($0.id) } }
        var chosen: [Int32] = []
        func add(_ id: Int?) {
            guard let id, id != current, tracks.contains(where: { $0.id == id }),
                  !chosen.contains(Int32(id)), chosen.count < limit else { return }
            chosen.append(Int32(id))
        }
        add(lastSwitchedFrom)
        if let pref = preferredLanguage, !pref.isEmpty {
            let matched = others
                .filter { TrackLanguageMatcher.matches(preference: pref, trackLang: $0.lang) }
                .sorted { ($0.isDefault ? 0 : 1, $0.id) < ($1.isDefault ? 0 : 1, $1.id) }
            for t in matched where chosen.count < limit { add(t.id) }
        }
        if let curLang = tracks.first(where: { $0.id == current })?.lang,
           !TrackLanguageMatcher.normalized(curLang).isEmpty {
            let cur = TrackLanguageMatcher.normalized(curLang)
            for t in others where chosen.count < limit {
                if TrackLanguageMatcher.normalized(t.lang ?? "") == cur { add(t.id) }
            }
        }
        // 两段拼接而非 sorted(by:):后者不承诺稳定,这里要保持容器顺序。
        for t in others.filter(\.isDefault) + others.filter({ !$0.isDefault }) where chosen.count < limit {
            add(t.id)
        }
        return chosen
    }
}
