import XCTest
import CoreAudio
import AudioToolbox
@testable import PlayerKitNative

/// 用户音量链路(2026-11-09,macOS 播放器音量 UI 前置):
/// 此前 `Playable.setVolume` 只写 `state.volume`、没有任何消费者(UI 是
/// 空转的)。现在 AudioUnitOutput 经 `kAudioQueueParam_Volume` 真正衰减:
///  - 越界/非有限值收口(0~1,NaN 回 1.0);
///  - 活队列立即应用;
///  - 未起播时只存值,start() 建队时补挂——换轨/starve 重建队列后音量
///    不回跳 1.0。
/// 应用值经 `setVolumeParamImpl` seam 捕获断言,不依赖真实衰减听感。
final class AudioUnitOutputVolumeTests: XCTestCase {

    private let sampleRate: Int32 = 48000

    private var captured: [Float] = []
    private var savedImpl: ((AudioQueueRef, Float) -> OSStatus)!

    override func setUp() {
        super.setUp()
        captured = []
        savedImpl = AudioUnitOutput.setVolumeParamImpl
        AudioUnitOutput.setVolumeParamImpl = { [weak self] queue, volume in
            self?.captured.append(volume)
            return AudioQueueSetParameter(queue, kAudioQueueParam_Volume, volume)
        }
    }

    override func tearDown() {
        AudioUnitOutput.setVolumeParamImpl = savedImpl
        super.tearDown()
    }

    func testClampsAndAppliesToLiveQueue() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.setVolume(1.4)   // 越界上界 → 1.0
        output.setVolume(0.25)
        output.setVolume(-3)    // 越界下界 → 0.0
        output.setVolume(.nan)  // 非有限 → 1.0

        XCTAssertEqual(captured, [1.0, 0.25, 0.0, 1.0])
    }

    func testVolumeSurvivesQueueRebuild() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)

        // 未起播:只存值,seam 不触发
        output.setVolume(0.4)
        XCTAssertTrue(captured.isEmpty, "无活队列时不应应用音量参数")

        // 建队:补挂保存的音量(0.4)
        output.start(sampleRate: sampleRate, channels: 2)
        XCTAssertEqual(captured, [0.4])

        // 重建(换轨/starve 路径):新 queue 再补挂一次,音量不回 1.0
        output.start(sampleRate: sampleRate, channels: 2)
        XCTAssertEqual(captured, [0.4, 0.4])

        output.stop()
    }

    func testDefaultVolumeDoesNotTouchQueueAtCreation() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)

        // 用户从未调过音量(=1.0):建队不发起多余参数调用
        output.start(sampleRate: sampleRate, channels: 2)
        XCTAssertTrue(captured.isEmpty, "默认音量 1.0 时建队不应应用参数")

        output.stop()
    }
}
