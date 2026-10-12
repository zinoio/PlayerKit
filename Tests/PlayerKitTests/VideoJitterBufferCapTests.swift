import XCTest
import CoreVideo
import PlayerKit
@testable import PlayerKitNative

/// Overflow policy of the decoded-frame buffer (zymo P1 晃动 fix, 2026-10-12).
///
/// The old policy kept the frame cap by discarding the OLDEST frame on every
/// append past it. That frame is exactly the display loop's next frame, so a
/// full buffer — the normal state while the demux loop free-runs at decode
/// speed before the audio clock starts — advanced the buffer front ahead of
/// the audio clock continuously. The display loop's freeze-ahead guard then
/// held the picture until audio caught up, which is what the user saw as
/// 晃动 / 过几秒卡一次 (device: 18-24fps against 23.976fps content).
///
/// The buffer must instead refuse the incoming frame (the demux loop backs
/// off on `count >= maxFrameCount`), so the front stays put — and the refusal
/// must be counted, not silent.
final class VideoJitterBufferCapTests: XCTestCase {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        XCTAssertEqual(status, kCVReturnSuccess)
        return pb!
    }

    private func frame(pts: Double) -> VideoJitterBuffer.Frame {
        .init(pixelBuffer: makePixelBuffer(), pts: pts, metadata: FrameMetadata())
    }

    /// 16x16 BGRA frames are 1 KB each: the byte budget never binds here, so
    /// the frame cap (60 at the default 24fps hint) is what does.
    private func makeBuffer() -> VideoJitterBuffer {
        VideoJitterBuffer(memoryBudgetBytes: 1 << 30)
    }

    func testAppendAtCapDropsIncomingAndKeepsOldest() {
        let buf = makeBuffer()
        let cap = buf.maxFrameCount
        XCTAssertEqual(cap, 60, "precondition: 24fps hint, 2s maxDuration → 60-frame floor")

        for i in 0..<(cap + 5) {
            buf.append(frame(pts: Double(i) * 0.04))
        }

        XCTAssertEqual(buf.count, cap, "count must never exceed the cap")
        XCTAssertEqual(buf.droppedIncomingCount, 5,
                       "overflow must be counted — the old silent drop hid ~190 frames/10s")
        XCTAssertEqual(buf.peek(at: 0)?.pts ?? -1, 0, accuracy: 1e-9,
                       "oldest frame must survive: it is the next frame to display")
        XCTAssertEqual(buf.peek(at: cap - 1)?.pts ?? -1, Double(cap - 1) * 0.04, accuracy: 1e-9,
                       "the last frame that fit must be the newest one held")
    }

    /// A pop makes room again: the next append is accepted, not dropped.
    func testAppendAcceptedAfterPopFreesRoom() {
        let buf = makeBuffer()
        let cap = buf.maxFrameCount
        for i in 0..<cap {
            buf.append(frame(pts: Double(i) * 0.04))
        }
        XCTAssertEqual(buf.droppedIncomingCount, 0)

        XCTAssertEqual(buf.pop()?.pts ?? -1, 0, accuracy: 1e-9)
        buf.append(frame(pts: 100.0))

        XCTAssertEqual(buf.droppedIncomingCount, 0, "room was freed — nothing to drop")
        XCTAssertEqual(buf.count, cap)
        XCTAssertEqual(buf.peek(at: cap - 1)?.pts ?? -1, 100.0, accuracy: 1e-9)
    }

    /// flush() clears content and the drop counter — a new session starts clean.
    func testFlushResetsDropCounter() {
        let buf = makeBuffer()
        let cap = buf.maxFrameCount
        for i in 0..<(cap + 3) {
            buf.append(frame(pts: Double(i) * 0.04))
        }
        XCTAssertEqual(buf.droppedIncomingCount, 3)

        buf.flush()

        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(buf.droppedIncomingCount, 0)
    }
}
