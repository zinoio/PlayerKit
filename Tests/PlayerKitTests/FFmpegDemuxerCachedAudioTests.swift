import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// zyno#171:备选音轨缓存要求解复用层保留(不丢弃)这些流。
/// 断言 AVStream.discard 本身——这是我们控制的单元;各容器是否据此跳过包
/// 因格式而异(Matroska 不看 discard,MPEG-TS/蓝光会跳过 PES 重组)。
final class FFmpegDemuxerCachedAudioTests: XCTestCase {
    private func openTwoAudio() throws -> FFmpegDemuxer {
        let url = Bundle.module.url(forResource: "two_audio_6s", withExtension: "mkv", subdirectory: "Fixtures")!
        let d = FFmpegDemuxer()
        try d.open(reader: InMemoryReader(data: try Data(contentsOf: url)))
        return d
    }

    private func discard(_ d: FFmpegDemuxer, _ index: Int32) -> AVDiscard {
        d.formatContext!.pointee.streams[Int(index)]!.pointee.discard
    }

    private func otherAudio(_ d: FFmpegDemuxer) throws -> Int32 {
        try XCTUnwrap(d.audioStreamIndices.first { $0 != d.audioStreamIndex })
    }

    func testFixtureHasTwoAudioStreams() throws {
        XCTAssertEqual(try openTwoAudio().audioStreamIndices.count, 2)
    }

    func testUnselectedAudioStreamIsDiscardedByDefault() throws {
        let d = try openTwoAudio()
        XCTAssertEqual(discard(d, try otherAudio(d)), AVDISCARD_ALL)
    }

    func testCachedAudioStreamIsKept() throws {
        let d = try openTwoAudio()
        let other = try otherAudio(d)
        d.setCachedAudioStreams([other])
        XCTAssertEqual(discard(d, other), AVDISCARD_DEFAULT)
        XCTAssertEqual(discard(d, d.audioStreamIndex), AVDISCARD_DEFAULT)
        XCTAssertEqual(discard(d, d.videoStreamIndex), AVDISCARD_DEFAULT)
    }

    func testClearingCachedStreamsDiscardsAgain() throws {
        let d = try openTwoAudio()
        let other = try otherAudio(d)
        d.setCachedAudioStreams([other])
        d.setCachedAudioStreams([])
        XCTAssertEqual(discard(d, other), AVDISCARD_ALL)
    }

    func testCachedStreamSurvivesSelectingAnotherTrack() throws {
        let d = try openTwoAudio()
        let other = try otherAudio(d)
        let first = d.audioStreamIndex
        d.setCachedAudioStreams([other])
        XCTAssertTrue(d.selectAudioStream(by: Int(other)))
        d.setCachedAudioStreams([first])           // 旧轨变成备选
        XCTAssertEqual(discard(d, first), AVDISCARD_DEFAULT)
        XCTAssertEqual(discard(d, d.audioStreamIndex), AVDISCARD_DEFAULT)
    }
}
