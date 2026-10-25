import XCTest
import PlayerKit
@testable import PlayerKitNative

final class AltAudioPacketCacheTests: XCTestCase {
    private final class Evicted { var items: [Int] = [] }

    private func make(window: Double = 10, maxBytes: Int = 1000) -> (AltAudioPacketCache<Int>, Evicted) {
        let ev = Evicted()
        let c = AltAudioPacketCache<Int>(windowSeconds: window, maxBytes: maxBytes,
                                         bytesOf: { $0 }, onEvict: { ev.items.append($0) })
        return (c, ev)
    }

    func testPacketsReturnedFromPositionInOrder() {
        var (c, _) = make()
        for i in 0..<5 { c.append(stream: 2, pts: Double(i), payload: 10) }
        XCTAssertEqual(c.packets(stream: 2, from: 2).map(\.pts), [2, 3, 4])
    }

    func testWindowEvictsOldPackets() {
        var (c, ev) = make(window: 3)
        for i in 0..<10 { c.append(stream: 2, pts: Double(i), payload: i) }
        XCTAssertEqual(c.packets(stream: 2, from: 0).first?.pts, 6)   // 9 - 3
        XCTAssertEqual(ev.items.sorted(), [0, 1, 2, 3, 4, 5])
    }

    func testByteCapEvictsOldestAndKeepsNewest() {
        var (c, ev) = make(window: 100, maxBytes: 100)
        for i in 0..<5 { c.append(stream: 2, pts: Double(i), payload: 30) }
        XCTAssertLessThanOrEqual(c.totalBytes, 100)
        XCTAssertFalse(ev.items.isEmpty)
        XCTAssertEqual(c.packets(stream: 2, from: 0).last?.pts, 4, "最新包必须保留")
    }

    func testByteCapEvictsOldestAcrossStreams() {
        var (c, _) = make(window: 100, maxBytes: 100)
        c.append(stream: 2, pts: 0, payload: 40)
        c.append(stream: 3, pts: 1, payload: 40)
        c.append(stream: 3, pts: 2, payload: 40)       // 超限:最旧的是 stream 2 的 pts 0
        XCTAssertTrue(c.packets(stream: 2, from: 0).isEmpty)
        XCTAssertEqual(c.packets(stream: 3, from: 0).count, 2)
    }

    func testCoversWhenEarliestPacketAtOrBeforePosition() {
        var (c, _) = make()
        for i in 5..<10 { c.append(stream: 2, pts: Double(i), payload: 1) }
        XCTAssertTrue(c.covers(stream: 2, at: 6, tolerance: 0.1))
        XCTAssertTrue(c.covers(stream: 2, at: 5.05, tolerance: 0.1))
        XCTAssertFalse(c.covers(stream: 2, at: 4, tolerance: 0.1), "位置早于最早缓存包 → 有缺口")
        XCTAssertFalse(c.covers(stream: 3, at: 6, tolerance: 0.1), "没缓存的流")
    }

    func testNotCoveredWhenPositionBeyondNewest() {
        var (c, _) = make()
        for i in 0..<5 { c.append(stream: 2, pts: Double(i), payload: 1) }
        XCTAssertFalse(c.covers(stream: 2, at: 100, tolerance: 0.1))
    }

    func testRemoveAllEvictsEverything() {
        var (c, ev) = make()
        for i in 0..<3 { c.append(stream: 2, pts: Double(i), payload: i + 1) }
        c.removeAll()
        XCTAssertEqual(c.totalBytes, 0)
        XCTAssertEqual(ev.items.sorted(), [1, 2, 3])
        XCTAssertTrue(c.packets(stream: 2, from: 0).isEmpty)
    }

    func testTakeReturnsPacketsFromPositionAndEmptiesStream() {
        var (c, ev) = make()
        for i in 0..<6 { c.append(stream: 2, pts: Double(i), payload: i + 1) }
        c.append(stream: 3, pts: 0, payload: 100)
        let taken = c.take(stream: 2, from: 3)
        XCTAssertEqual(taken.map(\.pts), [3, 4, 5])
        XCTAssertEqual(taken.map(\.payload), [4, 5, 6], "归调用方所有,不触发 onEvict")
        XCTAssertEqual(ev.items.sorted(), [1, 2, 3], "from 之前的包被淘汰释放")
        XCTAssertTrue(c.packets(stream: 2, from: 0).isEmpty)
        XCTAssertEqual(c.packets(stream: 3, from: 0).count, 1, "别的流不受影响")
        XCTAssertEqual(c.totalBytes, 100)
    }

    // MARK: - selectCandidates(zyno#359:多轨盘只缓存少数候选)

    private func track(_ id: Int, lang: String? = nil, def: Bool = false) -> TrackInfo {
        TrackInfo(id: id, lang: lang, isDefault: def)
    }

    func testSelectAllWhenFewAlternates() {
        let tracks = (1...4).map { track($0) }
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                          preferredLanguage: nil, lastSwitchedFrom: nil)
        XCTAssertEqual(Set(result), Set([Int32(2), 3, 4]), "备选总数 ≤ N 时全选(≤4 轨现状回归)")
    }

    func testSelectEmptyForSingleOrNoTrack() {
        XCTAssertEqual(AltAudioCachePolicy.selectCandidates(tracks: [], current: 1,
                                                            preferredLanguage: nil, lastSwitchedFrom: nil), [])
        XCTAssertEqual(AltAudioCachePolicy.selectCandidates(tracks: [track(1)], current: 1,
                                                            preferredLanguage: nil, lastSwitchedFrom: nil), [])
    }

    func testLastSwitchedFromRanksFirst() {
        // 计划原文只给 id 5="chi" 一条偏好命中,候选最多 2 条凑不满 limit 3;
        // 再给 id 7="zho"(同样命中 "zh")使 count==3 断言成立,顺带验证
        // lastSwitchedFrom 之后偏好组继续填充。
        var tracks = (1...14).map { track($0) }
        tracks[4] = track(5, lang: "chi")
        tracks[6] = track(7, lang: "zho")
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                          preferredLanguage: "zh", lastSwitchedFrom: 9)
        XCTAssertEqual(result.first, 9, "lastSwitchedFrom 必须排第一(#196 切回命中依赖)")
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.contains(5))
    }

    func testPreferredLanguageMatchesVariants() {
        var tracks = (1...14).map { track($0) }
        tracks[2] = track(3, lang: "chi")
        tracks[3] = track(4, lang: "zho-TW")
        tracks[4] = track(5, lang: "eng")
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                          preferredLanguage: "zh", lastSwitchedFrom: nil,
                                                          limit: 2)
        XCTAssertEqual(Set(result), Set([Int32(3), 4]), "偏好 zh 应匹配 chi/zho-TW 变体,不匹配 eng")
    }

    func testPreferredDefaultFirstThenContainerOrder() {
        var tracks = (1...14).map { track($0) }
        tracks[6] = track(7, lang: "eng")
        tracks[7] = track(8, lang: "eng", def: true)
        tracks[8] = track(9, lang: "eng")
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                          preferredLanguage: "en", lastSwitchedFrom: nil,
                                                          limit: 2)
        XCTAssertEqual(result, [8, 7], "isDefault 优先,其次容器顺序")
    }

    func testSameLanguageAsCurrentFallback() {
        var tracks = (1...14).map { track($0) }
        tracks[1] = track(2, lang: "eng")
        tracks[5] = track(6, lang: "eng")
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 2,
                                                          preferredLanguage: nil, lastSwitchedFrom: nil)
        XCTAssertEqual(result, [6, 1, 3], "同语言先入选,余下名额按容器顺序兜底补满(当前轨 2 不在内)")
    }

    /// 目标盘(00046.m2ts,14 轨)音轨无语言元数据(zyno#339):无任何信号时也必须补满,
    /// 否则起播候选为空、快路径不启用。
    func testNoSignalFillsByDefaultThenContainerOrder() {
        var tracks = (1...14).map { track($0) }
        XCTAssertEqual(AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                            preferredLanguage: nil, lastSwitchedFrom: nil),
                       [2, 3, 4], "无信号无默认轨:按容器顺序补满")
        tracks[4] = track(5, def: true)
        XCTAssertEqual(AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                            preferredLanguage: nil, lastSwitchedFrom: nil),
                       [5, 2, 3], "isDefault 优先,其次容器顺序")
    }

    func testFillOnlyUsesRemainingSlots() {
        var tracks = (1...14).map { track($0) }
        tracks[4] = track(5, lang: "chi")
        let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                          preferredLanguage: "zh", lastSwitchedFrom: 9)
        XCTAssertEqual(result, [9, 5, 2], "信号命中的轨先入选,兜底只补最后一个名额")
    }

    func testIgnoresLastSwitchedFromWhenCurrentOrUnknown() {
        var tracks = (1...14).map { track($0) }
        tracks[4] = track(5, lang: "chi")
        func select(last: Int?) -> [Int32] {
            AltAudioCachePolicy.selectCandidates(tracks: tracks, current: 1,
                                                 preferredLanguage: "zh", lastSwitchedFrom: last)
        }
        XCTAssertEqual(select(last: 1), [5, 2, 3], "lastSwitchedFrom==current 被忽略(偏好命中 5,余下兜底补 2、3)")
        XCTAssertEqual(select(last: 99), [5, 2, 3], "lastSwitchedFrom 不在轨道列表被忽略")
    }

    func testNeverContainsCurrentAndNoDuplicates() {
        var tracks = (1...14).map { track($0) }
        tracks[1] = track(2, lang: "eng")
        tracks[4] = track(5, lang: "chi")
        tracks[5] = track(6, lang: "zho-TW", def: true)
        tracks[8] = track(9, lang: "eng")
        let scenarios: [(current: Int, pref: String?, last: Int?)] = [
            (1, "zh", 9), (1, nil, nil), (2, "en", 2), (5, "zh", 5), (1, "zh", 99), (1, "ko", nil),
        ]
        for s in scenarios {
            let result = AltAudioCachePolicy.selectCandidates(tracks: tracks, current: s.current,
                                                              preferredLanguage: s.pref, lastSwitchedFrom: s.last)
            XCTAssertEqual(Set(result).count, result.count, "scenario \(s): 无重复")
            XCTAssertFalse(result.contains(Int32(s.current)), "scenario \(s): 不含当前轨")
            XCTAssertLessThanOrEqual(result.count, 3, "scenario \(s): 不超 limit")
        }
    }

    // MARK: - retain(streams:)(zyno#359:候选集收缩时清掉被移出流的包)

    func testRetainDropsOtherStreamsAndReleases() {
        var (c, ev) = make()
        for s in [2, 3, 4] as [Int32] {
            for i in 0..<3 { c.append(stream: s, pts: Double(i), payload: Int(s) * 10 + i) }
        }
        c.retain(streams: [2])
        XCTAssertTrue(c.packets(stream: 3, from: 0).isEmpty)
        XCTAssertTrue(c.packets(stream: 4, from: 0).isEmpty)
        XCTAssertEqual(ev.items.sorted(), [30, 31, 32, 40, 41, 42], "被移出流的包经 onEvict 释放")
        XCTAssertEqual(c.totalBytes, 20 + 21 + 22, "totalBytes 只剩保留流(20/21/22)的字节")
        XCTAssertEqual(c.packets(stream: 2, from: 0).count, 3, "保留流不受影响")
    }

    func testRetainKeepsAllWhenSupersetAndEmptySetClears() {
        var (c, ev) = make()
        c.append(stream: 2, pts: 0, payload: 20)
        c.append(stream: 3, pts: 1, payload: 30)
        c.retain(streams: [2, 3, 5])
        XCTAssertTrue(ev.items.isEmpty, "超集不动任何流")
        XCTAssertEqual(c.totalBytes, 50)
        c.retain(streams: [])
        XCTAssertEqual(ev.items.sorted(), [20, 30], "空集合等价 removeAll")
        XCTAssertEqual(c.totalBytes, 0)
        XCTAssertTrue(c.packets(stream: 2, from: 0).isEmpty)
    }

    func testRetainThenReappendLeavesNoGap() {
        var (c, _) = make()
        for i in 0..<5 { c.append(stream: 3, pts: Double(i), payload: i) }
        c.retain(streams: [2])
        c.append(stream: 3, pts: 10, payload: 99)
        // 旧包已清:首包 pts=10 > 2+0.3,covers 必须为 false(强制慢路径重新积累),
        // 否则「旧包+空洞+新包」会被 covers 的首尾 pts 判断误命中。
        XCTAssertFalse(c.covers(stream: 3, at: 2, tolerance: 0.3))
        XCTAssertEqual(c.packets(stream: 3, from: 0).map(\.pts), [10])
    }
}
