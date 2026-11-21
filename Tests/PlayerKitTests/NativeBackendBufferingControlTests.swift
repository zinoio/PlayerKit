import AVFoundation
import XCTest
import PlayerKit
@testable import PlayerKitNative

/// 方案 B:音频停走的统一仲裁。
/// - 非用户暂停时,jitter 放行(.playing)可以恢复音频;
/// - 用户主动暂停期间,任何缓冲状态变化都不得把音频顶起来;
/// - stop 重置用户暂停标记后恢复能力回归。
private final class RecordingAudioOutput: AudioOutputBackend {
    let supportsPassthrough = false
    let acceptsPCM = true
    var bufferedDuration: Double { 0 }
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func configure(streamInfo: AudioStreamInfo) async throws {}
    func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double) {}
    func outputCompressed(_ packet: Data, pts: Double, codec: String) {}
    var playbackTime: Double? { nil }
    func flush() {}
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
}

@MainActor
final class NativeBackendBufferingControlTests: XCTestCase {

    func testAudioResumesWhenNotUserPaused() throws {
        let fake = RecordingAudioOutput()
        let backend = try NativeBackend(audioOutput: fake)
        backend.setAudioPaused(true)
        XCTAssertEqual(fake.pauseCount, 1)
        backend.setAudioPaused(false)
        XCTAssertEqual(fake.resumeCount, 1)
        backend.stop()
    }

    func testAudioResumeIsRejectedWhileUserPaused() throws {
        let fake = RecordingAudioOutput()
        let backend = try NativeBackend(audioOutput: fake)
        backend.pause()
        let resumesAfterUserPause = fake.resumeCount
        backend.setAudioPaused(false)
        XCTAssertEqual(fake.resumeCount, resumesAfterUserPause,
            "用户暂停期间,缓冲状态变化不得恢复音频")
        backend.stop()
    }

    func testStopClearsUserPauseGate() throws {
        let fake = RecordingAudioOutput()
        let backend = try NativeBackend(audioOutput: fake)
        backend.pause()
        backend.stop()
        backend.setAudioPaused(false)
        XCTAssertGreaterThanOrEqual(fake.resumeCount, 1,
            "stop 重置用户暂停标记后,音频恢复能力应回归")
    }
}
