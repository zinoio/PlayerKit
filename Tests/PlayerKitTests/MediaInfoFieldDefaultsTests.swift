import XCTest
@testable import PlayerKit

/// Task 4(zyno 播放器换壳 P1):TrackInfo/VideoInfo/PlayerState 扩展媒体信息
/// 字段。全部带默认值,旧调用方(MinimalPlayer/PlayerKitPro/三端 app)零改动。
final class MediaInfoFieldDefaultsTests: XCTestCase {
    func testTrackInfoNewFieldsDefaultNil() {
        let t = TrackInfo(id: 1)
        XCTAssertNil(t.channels)
        XCTAssertNil(t.sampleRate)
        XCTAssertNil(t.bitDepth)
        XCTAssertNil(t.bitrate)
    }

    func testVideoInfoNewFieldsDefaultNil() {
        let v = VideoInfo(width: 1920, height: 1080)
        XCTAssertNil(v.fps)
        XCTAssertNil(v.profile)
        XCTAssertNil(v.level)
        XCTAssertNil(v.bitrate)
    }

    func testPlayerStateDroppedFramesDefaultZero() {
        XCTAssertEqual(PlayerState().droppedVideoFrames, 0)
    }
}
