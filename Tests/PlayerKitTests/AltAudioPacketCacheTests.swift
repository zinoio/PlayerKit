import XCTest
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

    func testPolicyGate() {
        XCTAssertFalse(AltAudioCachePolicy.shouldEnable(audioTrackCount: 0))
        XCTAssertFalse(AltAudioCachePolicy.shouldEnable(audioTrackCount: 1), "单音轨没有备选")
        XCTAssertTrue(AltAudioCachePolicy.shouldEnable(audioTrackCount: 2))
        XCTAssertTrue(AltAudioCachePolicy.shouldEnable(audioTrackCount: 4))
        XCTAssertFalse(AltAudioCachePolicy.shouldEnable(audioTrackCount: 5), "蓝光多音轨走 seek 路径")
    }
}
