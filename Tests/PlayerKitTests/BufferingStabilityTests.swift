import XCTest
import PlayerKit
@testable import PlayerKitNative

/// 稳态播放不得有 playing↔buffering 抖动(2026-11-20 回归)。
///
/// 097d2e1(#69)让 NativeBackend 每 5s 按「cacheSpeed/码率」比值运行时重调 jitter 水位。
/// 但 cacheSpeed 是 demux 的消费速度——预读节流把它压到约等于播放码率——不是网速,
/// 所以稳态下被判成「慢网档」(min 2.0s / resume 4.0s)。60 帧解码帧容量下稳态水位
/// 约 (60−8)/fps 秒,与该档的 min 只差 0–3 帧:24fps 刚好多 2 帧,≥25fps 时 pop()
/// 几乎每帧都进缓冲,下一帧 append 又退出,以 ~10–13Hz 抖动并反复暂停/恢复音频。
///
/// 受控 A/B(本地 320×240 样本、硬解、进程 CPU 7%,各 30 s,仅切换该策略):
/// 25fps 开 = 18.29 fps、22 s 内 229 次进缓冲,关 = 25.00 fps、0 次;
/// 30/50/60fps 开 = 20.7/33.8/39.7 fps,关 = 满帧;23.976/24fps 开关无差别。
/// 本测试用 25fps 样本——正好落在抖动一侧。
///
/// 本测试播放真实样本,越过会触发水位重调的 5 s 诊断窗口后观测 8 s,数 isBuffering 的
/// 上升沿。健康为 0;门槛放宽到 5 以容忍 CI 调度抖动,而退化时是几十到几百次。
/// 要重新引入运行时水位调整,必须先让本测试(及真机稳态实测)通过。
final class BufferingStabilityTests: XCTestCase {

    @MainActor
    func testSteadyPlaybackDoesNotFlapBuffering() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "speed_aac44_stereo_60s",
                                                  withExtension: "mp4", subdirectory: "Fixtures"))
        let backend = try NativeBackend()
        backend.setVolume(0)
        backend.play(url: url, headers: [:], seekTo: nil)
        defer { backend.stop() }

        // 预热 11 s:越过起播缓冲,并让 5 s 诊断窗口走完 ≥2 轮(首轮只记吞吐基线)。
        try await Task.sleep(nanoseconds: 11_000_000_000)

        var entries = 0
        var wasBuffering = backend.state.isBuffering
        let start = Date()
        while Date().timeIntervalSince(start) < 8.0 {
            let isBuffering = backend.state.isBuffering
            if isBuffering && !wasBuffering { entries += 1 }
            wasBuffering = isBuffering
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertLessThanOrEqual(entries, 5,
            "steady playback of a local fixture entered .buffering \(entries) times in 8 s — the jitter buffer is flapping between playing and buffering (healthy: 0)")
    }
}
