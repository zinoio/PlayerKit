import XCTest
import AVFoundation
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

/// zyno#224 / #223:输出路径(透传开关、输出设备)播放中变化时的状态机复位与设备透传。
private final class NullRenderer: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams,
                metadata: FrameMetadata, strategy: RendererStrategy?) {}
    func flush() {}
    func clear() {}
}

/// 记录调用的输出后端替身(模拟 PRO PassthroughOutput)。
private final class MockPassthroughOutput: AudioOutputBackend {
    var supportsPassthrough = true
    var bufferedDuration: Double { 0 }
    private(set) var flushCount = 0
    private(set) var deviceUIDs: [String?] = []
    func configure(streamInfo: AudioStreamInfo) async throws {}
    func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double) {}
    func outputCompressed(_ packet: Data, pts: Double, codec: String) {}
    func flush() { flushCount += 1 }
    func pause() {}
    func resume() {}
    func setOutputDevice(uid: String?) { deviceUIDs.append(uid) }
}

final class AudioOutputRouteChangeTests: XCTestCase {

    private func makeBackend(output: MockPassthroughOutput) async throws -> NativeBackend {
        try await MainActor.run { try NativeBackend(renderer: NullRenderer(), audioOutput: output) }
    }

    /// #224 根因:isPassthroughActive 只在 open 复位,播放中关透传后主时钟仍绑在透传渲染器上。
    func testRouteChangeResetsPassthroughActiveFlag() async throws {
        let out = MockPassthroughOutput()
        let backend = try await makeBackend(output: out)
        await MainActor.run {
            backend.isPassthroughActive = true
            backend.audioOutputRouteDidChange()
        }
        XCTAssertFalse(backend.isPassthroughActive,
                       "路径变化后必须复位,否则主时钟仍读已不再收包的透传渲染器")
    }

    /// 切路径要冲掉透传渲染器里已排队的压缩包,否则旧位流还会播几秒。
    func testRouteChangeFlushesInjectedOutput() async throws {
        let out = MockPassthroughOutput()
        let backend = try await makeBackend(output: out)
        await MainActor.run { backend.audioOutputRouteDidChange() }
        XCTAssertGreaterThanOrEqual(out.flushCount, 1)
    }

    func testSetAudioOutputDeviceForwardsToInjectedOutputAndStoresUID() async throws {
        let out = MockPassthroughOutput()
        let backend = try await makeBackend(output: out)
        await MainActor.run { backend.setAudioOutputDevice(uid: "BuiltInSpeakerDevice") }
        XCTAssertEqual(out.deviceUIDs, ["BuiltInSpeakerDevice"])
        let uid = await MainActor.run { backend.audioOutputDeviceUID }
        XCTAssertEqual(uid, "BuiltInSpeakerDevice")
    }

    func testSettingSameDeviceAgainIsNoOp() async throws {
        let out = MockPassthroughOutput()
        let backend = try await makeBackend(output: out)
        await MainActor.run {
            backend.setAudioOutputDevice(uid: "X")
            backend.setAudioOutputDevice(uid: "X")
        }
        XCTAssertEqual(out.deviceUIDs, ["X"], "同一设备重复设置不应重复重建")
    }

    func testClearingDeviceFollowsSystem() async throws {
        let out = MockPassthroughOutput()
        let backend = try await makeBackend(output: out)
        await MainActor.run {
            backend.setAudioOutputDevice(uid: "X")
            backend.setAudioOutputDevice(uid: nil)
        }
        let uid = await MainActor.run { backend.audioOutputDeviceUID }
        XCTAssertNil(uid)
        XCTAssertEqual(out.deviceUIDs, ["X", nil])
    }

    // MARK: 播放中变化不应打断播放(端到端,真实 FFmpeg 管线)

    private static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func fixture(_ name: String, _ ext: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!)
    }

    private func position(_ b: NativeBackend) async -> Double {
        await MainActor.run { Self.secs(b.state.position) }
    }

    /// 轮询到位置超过 `above`(秒)或超时。
    private func waitForPosition(_ b: NativeBackend, above: Double, timeout: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await position(b) > above { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testRouteChangeDuringPlaybackKeepsPlayingFromSamePosition() async throws {
        let out = MockPassthroughOutput()
        out.supportsPassthrough = false
        let backend = try await makeBackend(output: out)
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run {
            backend.play(reader: InMemoryReader(data: fixture("two_audio_60s", "mkv")),
                         seekTo: nil, knownDuration: .seconds(60))
        }
        let started = await waitForPosition(backend, above: 1.0)
        XCTAssertTrue(started, "应先正常播放")
        let before = await position(backend)

        await MainActor.run { backend.audioOutputRouteDidChange() }

        let resumed = await waitForPosition(backend, above: before + 1.0)
        XCTAssertTrue(resumed, "路径重建后应从原位置继续前进,不应卡住或回到开头")
        let after = await position(backend)
        XCTAssertGreaterThan(after, before, "不应回退到开头")
        XCTAssertGreaterThanOrEqual(out.flushCount, 1)
    }

    #if os(macOS)
    // MARK: 设备模型(纯映射,不依赖真实硬件)

    func testTransportTypeMapping() {
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeHDMI), .hdmi)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeDisplayPort), .displayPort)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeAirPlay), .airPlay)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeVirtual), .virtual)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: kAudioDeviceTransportTypeAggregate), .aggregate)
        XCTAssertEqual(AudioOutputDevice.transport(fromRaw: 0xDEADBEEF), .other)
    }

    func testVirtualAndAggregateAreNotPhysical() {
        func dev(_ t: AudioOutputDevice.Transport) -> AudioOutputDevice {
            AudioOutputDevice(id: 1, uid: "u", name: "n", transport: t)
        }
        XCTAssertTrue(dev(.builtIn).isPhysical)
        XCTAssertTrue(dev(.hdmi).isPhysical)
        XCTAssertTrue(dev(.bluetooth).isPhysical)
        XCTAssertFalse(dev(.virtual).isPhysical)
        XCTAssertFalse(dev(.aggregate).isPhysical)
    }
    #endif
}
