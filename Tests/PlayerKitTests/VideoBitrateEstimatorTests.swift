import XCTest
@testable import PlayerKitNative

/// Task 5(播放器换壳 P1):视频码率 EMA 估算器——按包大小×帧率指数滑动平均,
/// 供 HUD 在容器未声明码率时兜底展示。
final class VideoBitrateEstimatorTests: XCTestCase {
    func testFirstSampleSeedsEMA() {
        var e = VideoBitrateEstimator()
        e.record(packetBytes: 125_000, frameRate: 24)
        XCTAssertEqual(e.bitsPerSecond, 24_000_000)  // 125000 * 8 * 24
    }

    func testEMAPullsTowardNewSamples() {
        var e = VideoBitrateEstimator()
        e.record(packetBytes: 125_000, frameRate: 24)                      // 24 Mbps
        for _ in 0..<40 { e.record(packetBytes: 250_000, frameRate: 24) }  // 48 Mbps
        XCTAssertGreaterThan(e.bitsPerSecond, 40_000_000)
        XCTAssertLessThan(e.bitsPerSecond, 48_000_000)
    }

    func testInvalidInputIgnored() {
        var e = VideoBitrateEstimator()
        e.record(packetBytes: 125_000, frameRate: 0)
        e.record(packetBytes: 0, frameRate: 24)
        XCTAssertEqual(e.bitsPerSecond, 0)
    }
}
