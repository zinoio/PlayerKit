import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// zyno#142 fine-seek: byte-domain seeks (raw indexless MPEG-TS — BDMV clips)
/// must land AT or BEFORE the requested target and publish the landing PTS via
/// `lastSeekLandedPTS`, so NativeBackend can arm discard-until-target. The old
/// two-sided ±1.5 s tolerance let seeks land PAST the target (empirically 8.56s
/// for a 7.0s request on these very fixtures), which no discard stage can
/// recover — content behind the demux position is already gone.
final class SeekLandingTests: XCTestCase {
    private func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    private func makeDemuxer(_ name: String) throws -> FFmpegDemuxer {
        let demuxer = FFmpegDemuxer()
        // open(reader:) throws on failure (openFailed/noStreams/readFailed).
        try demuxer.open(reader: InMemoryReader(data: loadFixture(name)))
        return demuxer
    }

    /// Every byte-domain seek lands at/before its target and reports the
    /// landing. Targets span the 5s fixture; the low one (0.3s) exercises the
    /// clamp against seeking before byte 0.
    func testByteSeeksLandAtOrBeforeTargetAndPublishLanding() throws {
        let demuxer = try makeDemuxer("clip0_5s")
        for target in [0.3, 1.0, 2.5, 4.0, 4.8] {
            XCTAssertTrue(demuxer.seek(to: target), "seek to \(target)s must succeed")
            let landed = try XCTUnwrap(demuxer.lastSeekLandedPTS,
                "byte-domain seek must publish lastSeekLandedPTS (target \(target)s)")
            XCTAssertLessThanOrEqual(landed, target,
                "landing \(landed)s must not overshoot the target \(target)s")
        }
    }

    /// Consecutive seeks each refresh the landing — a stale landing from seek N
    /// must not survive into seek N+1 (the backend arms the discard from the
    /// CURRENT seek's landing).
    func testConsecutiveSeeksRefreshLandingPTS() throws {
        let demuxer = try makeDemuxer("clip0_5s")
        XCTAssertTrue(demuxer.seek(to: 4.5))
        let first = try XCTUnwrap(demuxer.lastSeekLandedPTS)
        XCTAssertLessThanOrEqual(first, 4.5)
        XCTAssertTrue(demuxer.seek(to: 1.0))
        let second = try XCTUnwrap(demuxer.lastSeekLandedPTS)
        XCTAssertLessThanOrEqual(second, 1.0)
    }

    /// The seek() entry clears the landing before dispatching, so a FAILED
    /// seek (or an index-guided seek that never probes) leaves nil behind and
    /// the backend stays on its historical land-on-GOP behavior. Simulated via
    /// a fresh demuxer that never seeked.
    func testLandingStartsNil() {
        let demuxer = try! makeDemuxer("clip0_5s")
        XCTAssertNil(demuxer.lastSeekLandedPTS,
            "no seek yet — landing must be nil so no discard can be armed")
    }

    /// Same one-sided contract on the multi-GOP fixture the FineSeek e2e
    /// tests drive through the whole backend — landings measured 4.28/5.32/
    /// 6.08/7.28 for targets 5.0/6.1/7.0/8.5 (the probe resyncs up to ~1.2s
    /// short on this VBR-ish layout, which is exactly the gap discard
    /// consumes).
    func testByteSeeksLandAtOrBeforeTargetOnMultiGOPFixture() throws {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: loadFixture("fineseek_gop1s_10s")))
        for target in [5.0, 6.1, 7.0, 8.5] {
            XCTAssertTrue(demuxer.seek(to: target), "seek to \(target)s must succeed")
            let landed = try XCTUnwrap(demuxer.lastSeekLandedPTS,
                "byte-domain seek must publish lastSeekLandedPTS (target \(target)s)")
            XCTAssertLessThanOrEqual(landed, target,
                "landing \(landed)s must not overshoot the target \(target)s")
        }
    }

    /// MultiClipDemuxer publishes the active clip's landing through the
    /// PacketDemuxing surface NativeBackend reads.
    func testMultiClipPublishesActiveClipLanding() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()
        XCTAssertNil(demuxer.lastSeekLandedPTS)
        XCTAssertTrue(demuxer.seek(to: 7.0))  // routes into clip1, local 2.0
        let landed = try XCTUnwrap(demuxer.lastSeekLandedPTS,
            "MultiClipDemuxer must forward the active clip's byte-seek landing")
        // The seek target in the ACTIVE clip's local time domain is 2.0s.
        XCTAssertLessThanOrEqual(landed, 2.0 + 0.001,
            "clip1-local landing \(landed)s must not overshoot the local target 2.0s")
    }
}
