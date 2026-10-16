import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// zyno#171 附带发现:切到没有解码器的音轨("codec not found")会让音频时钟永不前进,
/// 视频被冻结等待音频 → 整个影片卡死。无解码器且无法透传的轨道必须拒绝切换。
final class AudioTrackSwitchableTests: XCTestCase {
    func testDecodableCodecIsSwitchable() {
        XCTAssertTrue(NativeBackend.audioTrackIsSwitchable(codecID: AV_CODEC_ID_AAC, passthroughAvailable: false))
        XCTAssertTrue(NativeBackend.audioTrackIsSwitchable(codecID: AV_CODEC_ID_AC3, passthroughAvailable: false))
    }

    func testCodecWithoutDecoderIsRefusedUnlessPassthrough() {
        XCTAssertFalse(NativeBackend.audioTrackIsSwitchable(codecID: AV_CODEC_ID_NONE, passthroughAvailable: false))
        XCTAssertTrue(NativeBackend.audioTrackIsSwitchable(codecID: AV_CODEC_ID_NONE, passthroughAvailable: true),
                      "能透传的输出不需要本地解码器")
    }
}
