import XCTest
import CoreGraphics
@testable import PlayerKitNative

/// Unit tests for the libass typeset renderer (zyno#158): header parsing,
/// event ingestion in Matroska packet format, composite bitmap output,
/// change detection, and seek flush.  The end-to-end case plays a real
/// MKV+ASS fixture through NativeBackend and asserts the bitmap pipeline
/// (state.currentSubtitleImage) surfaces a frame.
final class ASSRendererTests: XCTestCase {

    /// Same header block the fixture MKV carries (PlayRes 320x240, one style).
    private static let extradata = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 240
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    private let videoSize = CGSize(width: 320, height: 240)

    private func makeRenderer() -> ASSRenderer? {
        ASSRenderer(extradata: Data(Self.extradata.utf8),
                    videoSize: videoSize,
                    startOffsetSecs: 0)
    }

    /// One Matroska-format ASS event line: ReadOrder,Layer,Style,Name,
    /// MarginL,MarginR,MarginV,Effect,Text.  Timing is carried by
    /// processPacket's timecode/duration, not the text.
    private func event(_ readOrder: Int, _ text: String) -> Data {
        Data("\(readOrder),0,Default,,0,0,0,,\(text)".utf8)
    }

    private func feed(_ r: ASSRenderer, _ readOrder: Int, _ text: String,
                      start: Double, duration: Double) {
        r.processPacket(event(readOrder, text), ptsSecs: start, durationSecs: duration)
    }

    // MARK: - Unit: renderer lifecycle

    func testNilWithoutExtradata() {
        XCTAssertNil(ASSRenderer(extradata: Data(), videoSize: videoSize, startOffsetSecs: 0))
        XCTAssertNil(ASSRenderer(extradata: Data(Self.extradata.utf8),
                                 videoSize: .zero, startOffsetSecs: 0))
    }

    // MARK: - Unit: typeset rendering

    private func feedRedDialogue(_ r: ASSRenderer) {
        // Red (ASS &H0000FF& = BB GG RR → R=255) large text centered via \pos.
        feed(r, 0, "{\\pos(160,120)\\1c&H0000FF&\\fs36}HELLO ASS",
             start: 1.0, duration: 3.0)
    }

    func testDialogueRendersCompositeBitmap() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feedRedDialogue(r)

        guard let f = r.renderFrame(ptsSecs: 2.0) else {
            return XCTFail("active dialogue must produce a frame")
        }
        XCTAssertGreaterThan(f.image.width, 0)
        XCTAssertGreaterThan(f.image.height, 0)
        // Normalized rect must sit inside the video frame.
        XCTAssertTrue(f.rect.minX >= 0 && f.rect.minY >= 0)
        XCTAssertTrue(f.rect.maxX <= 1.001 && f.rect.maxY <= 1.001)
        // \pos(160,120) centers the block; the union should straddle mid-frame.
        XCTAssertTrue(abs(f.rect.midX - 0.5) < 0.35, "rect \(f.rect)")
    }

    func testNothingRendersOutsideEventWindow() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feedRedDialogue(r)
        XCTAssertNil(r.renderFrame(ptsSecs: 0.5), "before the event")
        XCTAssertNil(r.renderFrame(ptsSecs: 4.5), "after the event")
    }

    func testRedDialogueYieldsRedPixels() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feedRedDialogue(r)
        guard let f = r.renderFrame(ptsSecs: 2.0) else { return XCTFail("no frame") }

        let w = f.image.width, h = f.image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(f.image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var redish = 0
        var opaque = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i + 3] > 200 { opaque += 1 }
            if pixels[i + 3] > 200 && pixels[i] > 180 && pixels[i + 1] < 90 && pixels[i + 2] < 90 {
                redish += 1
            }
        }
        XCTAssertGreaterThan(opaque, 100, "text must have opaque pixels")
        XCTAssertGreaterThan(Double(redish) / Double(opaque), 0.3,
                             "\\1c&H0000FF& must render as red, not white/default")
    }

    func testChangeDetectionReturnsSameInstance() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feedRedDialogue(r)
        let a = r.renderFrame(ptsSecs: 2.0)
        let b = r.renderFrame(ptsSecs: 2.2)
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.image === b?.image,
                      "static dialogue must reuse the cached composite")
    }

    func testMoveAnimationProducesDistinctFrames() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feed(r, 1, "{\\move(40,120,280,120,0,3000)}MOVING", start: 1.0, duration: 3.0)
        let early = r.renderFrame(ptsSecs: 1.2)
        let late = r.renderFrame(ptsSecs: 3.6)
        XCTAssertNotNil(early)
        XCTAssertNotNil(late)
        XCTAssertFalse(early?.image === late?.image,
                       "\\move must produce a changed composite")
        XCTAssertNotEqual(early?.rect, late?.rect)
    }

    func testFlushDropsQueuedEvents() {
        guard let r = makeRenderer() else { return XCTFail("renderer init failed") }
        feedRedDialogue(r)
        XCTAssertNotNil(r.renderFrame(ptsSecs: 2.0))
        r.flushEvents()
        XCTAssertNil(r.renderFrame(ptsSecs: 2.0), "flush must drop active events")
    }

    // MARK: - End-to-end: MKV+ASS stream through the real backend pipeline

    /// Plays the fixture and polls state — the dialogue is on screen 1-4s, so
    /// currentSubtitleImage must surface within a few seconds of playback and
    /// carry a sane normalized rect.  This guards the demux → processPacket →
    /// renderFrame → DisplayUIUpdate wiring, which the unit tests above skip.
    func testMKVASSStreamSurfacesBitmapThroughBackend() async throws {
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        let url = Bundle.module.url(forResource: "ass_typeset_10s", withExtension: "mkv",
                                    subdirectory: "Fixtures")!
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        // Poll up to 8s of wall clock for a subtitle image to appear (decode
        // startup + 1s lead-in of the first dialogue).  Liveness only — no
        // throughput assertion (see PlaybackSpeedMeasurementTests for why).
        var seen: (CGRect, Int, Int)?
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let snap: (CGImage, CGRect)? = await MainActor.run {
                guard let img = backend.state.currentSubtitleImage else { return nil }
                return (img, backend.state.currentSubtitleImageRect)
            }
            if let (img, rect) = snap {
                seen = (rect, img.width, img.height)
                break
            }
        }
        let (rect, w, h) = try XCTUnwrap(seen, "ASS dialogue never surfaced as a bitmap subtitle")
        XCTAssertGreaterThan(w, 0)
        XCTAssertGreaterThan(h, 0)
        XCTAssertTrue(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1.001 && rect.maxY <= 1.001,
                      "rect \(rect) must be normalized inside the frame")
    }
}
