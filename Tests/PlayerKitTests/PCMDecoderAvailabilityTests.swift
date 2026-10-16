import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// zyno#176:蓝光/DVD 的 LPCM 音轨需要对应的 PCM 解码器,否则选轨无声(此前还会冻死影片)。
final class PCMDecoderAvailabilityTests: XCTestCase {
    func testBluRayAndDVDPCMDecodersAreCompiledIn() {
        XCTAssertNotNil(avcodec_find_decoder(AV_CODEC_ID_PCM_BLURAY), "pcm_bluray")
        XCTAssertNotNil(avcodec_find_decoder(AV_CODEC_ID_PCM_DVD), "pcm_dvd")
        XCTAssertNotNil(avcodec_find_decoder(AV_CODEC_ID_PCM_S16BE), "pcm_s16be")
        XCTAssertNotNil(avcodec_find_decoder(AV_CODEC_ID_PCM_S24BE), "pcm_s24be")
    }

    func testPCMBluRayStreamDecodesToAudio() throws {
        let url = Bundle.module.url(forResource: "pcm_bluray_2s", withExtension: "ts", subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: try Data(contentsOf: url)))
        let stream = try XCTUnwrap(demuxer.audioStream)
        XCTAssertEqual(stream.pointee.codecpar.pointee.codec_id, AV_CODEC_ID_PCM_BLURAY)
        let decoder = try XCTUnwrap(FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2),
                                    "解码器应能建起来(此前 codec not found)")

        var samples = 0
        while let r = demuxer.readPacket() {
            if r.streamIndex == demuxer.audioStreamIndex, let pcm = decoder.decode(packet: r.packet) {
                samples += pcm.sampleCount
            }
            var p: UnsafeMutablePointer<AVPacket>? = r.packet
            av_packet_free(&p)
        }
        XCTAssertGreaterThan(samples, 48000, "2 秒音频至少应解出 1 秒以上的样本,实际 \(samples)")
    }
}
