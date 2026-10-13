import XCTest
import PlayerKit
@testable import PlayerKitNative

/// PreparedMedia warm-up + adopt end-to-end (zyno#108): prepareMedia must
/// produce a fully-open session without touching the live backend, and
/// play(prepared:) must reach playback identical to a cold play(url:).
/// Fixture: chapters_mk_30s.mkv (30s MKV, codecpar-carried params).
final class PreparedMediaTests: XCTestCase {

    private let fixture = Bundle.module.url(forResource: "chapters_mk_30s", withExtension: "mkv",
                                            subdirectory: "Fixtures")!

    /// prepareMedia opens fully (duration visible) and stays consumable.
    func testPrepareMediaOpensSession() async throws {
        let prepared = try await NativeBackend.prepareMedia(url: fixture, headers: [:])
        XCTAssertTrue(prepared.isConsumable)
        prepared.close()
    }

    /// play(prepared:) reaches real playback — position advances past 0.5s,
    /// same bar as the cold-open end-to-end tests.
    func testAdoptReachesPlayback() async throws {
        let prepared = try await NativeBackend.prepareMedia(url: fixture, headers: [:])
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }

        try await MainActor.run { try backend.play(prepared: prepared) }

        var position = Duration.zero
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            position = await MainActor.run { backend.state.position }
            if position > .seconds(0.5) { break }
        }
        XCTAssertGreaterThan(position, .seconds(0.5),
                             "adopted session must reach actual playback")
    }

    /// A consumed prepared media is rejected — and the rejection leaves the
    /// current session untouched (state not clobbered by the failed adopt).
    func testDoubleAdoptThrows() async throws {
        let prepared = try await NativeBackend.prepareMedia(url: fixture, headers: [:])
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }

        try await MainActor.run { try backend.play(prepared: prepared) }
        // Wait until the session is actually playing before re-adopting.
        var started = false
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            started = await MainActor.run { backend.state.position > .seconds(0.1) }
            if started { break }
        }

        // MainActor do/catch — play(prepared:) is @MainActor and
        // XCTAssertThrowsError's closure is synchronous nonisolated.
        let adoptError: Error? = await MainActor.run {
            do { try backend.play(prepared: prepared); return nil }
            catch { return error }
        }
        XCTAssertTrue(adoptError is PreparedMediaError, "expected notConsumable, got \(String(describing: adoptError))")
        let stillPlaying = await MainActor.run { backend.state.isPlaying || backend.state.position > .zero }
        XCTAssertTrue(stillPlaying, "failed adopt must not stop the current session")
    }

    /// abandon before adopt: close() is idempotent and the prepared media
    /// stops being consumable.
    func testCloseBeforeAdopt() async throws {
        let prepared = try await NativeBackend.prepareMedia(url: fixture, headers: [:])
        XCTAssertTrue(prepared.isConsumable)
        prepared.close()
        prepared.close() // idempotent
        XCTAssertFalse(prepared.isConsumable)

        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        let adoptError: Error? = await MainActor.run {
            do { try backend.play(prepared: prepared); return nil }
            catch { return error }
        }
        XCTAssertTrue(adoptError is PreparedMediaError,
                      "expected notConsumable, got \(String(describing: adoptError))")
    }
}
