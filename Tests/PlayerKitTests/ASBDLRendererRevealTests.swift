import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit

/// zyno#337: ASBDLRenderer.render() runs on the display thread. It used to wrap
/// `isHidden = false` in an explicit CATransaction and commit it on every frame;
/// an outermost commit off-main also lays out every pending UIView, which hits the
/// Auto Layout engine off-main and aborts. The reveal must happen once, after
/// `clear()`, on the main thread.
final class ASBDLRendererRevealTests: XCTestCase {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let r = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        XCTAssertEqual(r, kCVReturnSuccess)
        return pb!
    }

    /// Calls render() the way NativeBackend does: from a non-main thread.
    private func renderOffMain(_ renderer: ASBDLRenderer, count: Int = 1) {
        let pb = makePixelBuffer()
        let done = expectation(description: "rendered off-main")
        DispatchQueue.global(qos: .userInteractive).async {
            for i in 0..<count {
                renderer.render(pixelBuffer: pb, pts: Double(i) / 24,
                                colorParams: VideoColorParams(),
                                metadata: FrameMetadata(), strategy: nil)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// Lets blocks already queued on the main queue run.
    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testFirstFrameAfterClearRevealsLayerOnMain() {
        let renderer = ASBDLRenderer()
        renderer.clear()
        XCTAssertTrue(renderer.displayLayer.isHidden)

        renderOffMain(renderer)
        drainMain()

        XCTAssertFalse(renderer.displayLayer.isHidden)
    }

    func testRenderDoesNotWriteIsHiddenOnEveryFrame() {
        let renderer = ASBDLRenderer()
        // Layer was never cleared, so no reveal is owed. If render() still wrote
        // isHidden each frame (the pre-#337 behaviour) this would flip back.
        renderer.displayLayer.isHidden = true

        renderOffMain(renderer, count: 5)
        drainMain()

        XCTAssertTrue(renderer.displayLayer.isHidden)
    }

    func testRevealIsSkippedWhenClearedAgainBeforeMainBlockRuns() {
        let renderer = ASBDLRenderer()
        renderer.clear()

        // This test body runs on the main thread, and `sync` does not spin the
        // main run loop, so the reveal render() queues stays pending until
        // drainMain().
        let pb = makePixelBuffer()
        DispatchQueue.global(qos: .userInteractive).sync {
            renderer.render(pixelBuffer: pb, pts: 0, colorParams: VideoColorParams(),
                            metadata: FrameMetadata(), strategy: nil)
        }
        renderer.clear()          // the player is cleared again before it runs
        drainMain()

        XCTAssertTrue(renderer.displayLayer.isHidden,
                      "a stale reveal must not undo a later clear()")
    }

    func testClearedAgainThenNextFrameRevealsAgain() {
        let renderer = ASBDLRenderer()
        renderer.clear()
        renderOffMain(renderer)
        drainMain()
        XCTAssertFalse(renderer.displayLayer.isHidden)

        renderer.clear()
        XCTAssertTrue(renderer.displayLayer.isHidden)
        renderOffMain(renderer)
        drainMain()
        XCTAssertFalse(renderer.displayLayer.isHidden)
    }
}
