import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// PlayerKit#76:44.1kHz AAC 内容在 48kHz 设备上曾出现音频时钟域错位——
/// 输出率取内容率(44100)而设备消费 48k,时钟慢 10% → 视频 paced 出
/// 匀速拖帧(fps 25→22.5)。修复:decoder 接受 outputRateOverride(设备
/// 原生率,AudioDeviceSampleRate.preferred() 探测),swr 在解码器内完成
/// 内容率→设备率的重采样。
///
/// 回归判定:2 秒 44.1kHz AAC fixture
///   - 无 override:输出样本数 ≈ 44100 × 2s
///   - override 48000:输出样本数 ≈ 48000 × 2s(AAC 编码器 priming/尾帧
///     带来 ±5% 容差;比率 48000/44100 = 1.088 必须体现)
final class AudioDeviceDomainTests: XCTestCase {
    private func decodeAll(outputRateOverride: Int32?) throws -> Int {
        let url = Bundle.module.url(forResource: "aac44100_2s", withExtension: "aac", subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: try Data(contentsOf: url)))
        let stream = try XCTUnwrap(demuxer.audioStream)
        let decoder = try XCTUnwrap(
            FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2,
                               outputRateOverride: outputRateOverride))

        var samples = 0
        while let r = demuxer.readPacket() {
            if r.streamIndex == demuxer.audioStreamIndex, let pcm = decoder.decode(packet: r.packet) {
                samples += pcm.sampleCount
            }
            var p: UnsafeMutablePointer<AVPacket>? = r.packet
            av_packet_free(&p)
        }
        return samples
    }

    func testContentRateOutputWhenNoOverride() throws {
        let samples = try decodeAll(outputRateOverride: nil)
        XCTAssertEqual(Double(samples), 44100.0 * 2.0, accuracy: 44100.0 * 2.0 * 0.15,
                       "无 override 时输出应为内容域 44100Hz 样本,实际 \(samples)")
    }

    func testDeviceRateOutputWithOverride() throws {
        let samples = try decodeAll(outputRateOverride: 48000)
        XCTAssertEqual(Double(samples), 48000.0 * 2.0, accuracy: 48000.0 * 2.0 * 0.15,
                       "override 48000 时输出应为设备域 48kHz 样本,实际 \(samples)")
    }

    func testOverrideRaisesOutputSampleRateProperty() throws {
        let url = Bundle.module.url(forResource: "aac44100_2s", withExtension: "aac", subdirectory: "Fixtures")!
        let demuxer = FFmpegDemuxer()
        try demuxer.open(reader: InMemoryReader(data: try Data(contentsOf: url)))
        let stream = try XCTUnwrap(demuxer.audioStream)
        let decoder = try XCTUnwrap(
            FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2,
                               outputRateOverride: 48000))
        XCTAssertEqual(decoder.outputSampleRate, 48000, "outputSampleRate 应取设备域覆写值")
    }
}
