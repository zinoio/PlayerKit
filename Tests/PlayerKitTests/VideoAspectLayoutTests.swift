import XCTest
import QuartzCore
import AVFoundation
import PlayerKit

/// VideoAspectMode layout semantics (feat/player-reskin, reflux issue #444 P1):
/// three display modes over the shared `videoLayerFrame` computation used by
/// both PlayerNativeViewMac and PlayerNativeViewiOS.
final class VideoAspectLayoutTests: XCTestCase {

    let wide16x9Bounds = CGRect(x: 0, y: 0, width: 200, height: 100) // 2:1 bounds
    let hd = VideoInfo(width: 1920, height: 1080, codec: nil) // 16:9 source

    func testSourceModeLetterboxesLikeLegacyFit() {
        // 16:9 video in 2:1 bounds → pillarbox (side bars): height-bound width.
        let f = VideoAspectLayout.frame(in: wide16x9Bounds, videoInfo: hd, mode: .source)
        XCTAssertEqual(f.width, 100.0 * (16.0 / 9.0), accuracy: 0.01)
        XCTAssertEqual(f.height, 100, accuracy: 0.01)
        XCTAssertEqual(f.midX, 100, accuracy: 0.01)
        XCTAssertEqual(f.midY, 50, accuracy: 0.01)
    }

    func testRatio169ForcesWindowRegardlessOfSourceAspect() {
        // A 4:3 source forced into a 16:9 window in the same bounds: the
        // window geometry equals the 16:9 pillarboxed rect, NOT the 4:3 rect.
        let sd = VideoInfo(width: 1440, height: 1080, codec: nil) // 4:3
        let f = VideoAspectLayout.frame(in: wide16x9Bounds, videoInfo: sd, mode: .ratio169)
        XCTAssertEqual(f.width, 100.0 * (16.0 / 9.0), accuracy: 0.01)
        XCTAssertEqual(f.height, 100, accuracy: 0.01)
    }

    func testFillSpansWholeBounds() {
        let f = VideoAspectLayout.frame(in: wide16x9Bounds, videoInfo: hd, mode: .fill)
        XCTAssertEqual(f, wide16x9Bounds)
    }

    func testUnknownVideoFallsBackToBounds() {
        let f = VideoAspectLayout.frame(in: wide16x9Bounds, videoInfo: nil, mode: .source)
        XCTAssertEqual(f, wide16x9Bounds)
    }

    func testGravitySelection() {
        // fill → resizeAspectFill even though frame == bounds.
        XCTAssertEqual(VideoAspectLayout.gravity(frame: wide16x9Bounds,
                                                 bounds: wide16x9Bounds,
                                                 mode: .fill),
                       AVLayerVideoGravity.resizeAspectFill)
        // source with exact bounds (unknown video fallback) → resizeAspect.
        XCTAssertEqual(VideoAspectLayout.gravity(frame: wide16x9Bounds,
                                                 bounds: wide16x9Bounds,
                                                 mode: .source),
                       AVLayerVideoGravity.resizeAspect)
        // source with a fitted video rect → resize (layer exactly the video).
        let fitted = CGRect(x: 11.11, y: 0, width: 177.78, height: 100)
        XCTAssertEqual(VideoAspectLayout.gravity(frame: fitted,
                                                 bounds: wide16x9Bounds,
                                                 mode: .source),
                       AVLayerVideoGravity.resize)
        // ratio169 → resizeAspect: a non-16:9 source (e.g. 4:3) must fit
        // INSIDE the 16:9 window with bars, never stretch to fill it.
        XCTAssertEqual(VideoAspectLayout.gravity(frame: fitted,
                                                 bounds: wide16x9Bounds,
                                                 mode: .ratio169),
                       AVLayerVideoGravity.resizeAspect)
    }
}
