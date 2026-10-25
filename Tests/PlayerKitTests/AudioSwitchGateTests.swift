import XCTest
@testable import PlayerKitNative

/// zyno#360: the gate lets an audio-track switch take `demuxLock` without
/// waiting out the demux loop's in-flight network read.
final class AudioSwitchGateTests: XCTestCase {

    func testPendingGateMakesTheLoopWait() {
        let gate = AudioSwitchGate()
        gate.begin()
        XCTAssertTrue(gate.isPending)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.end() }
        let started = Date()
        gate.waitUntilSwitchFinishes(cancelled: { false })
        let waited = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(waited, 0.05, "the gate must block while a switch is pending")
        XCTAssertLessThan(waited, 2.0, "end() must wake the loop promptly")
        XCTAssertFalse(gate.isPending)
    }

    func testWaitReturnsImmediatelyWhenNoSwitchIsPending() {
        let gate = AudioSwitchGate()
        let started = Date()
        gate.waitUntilSwitchFinishes(cancelled: { false })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }

    func testWaitExitsWhenDemuxIsCancelled() {
        let gate = AudioSwitchGate()
        gate.begin()
        let started = Date()
        gate.waitUntilSwitchFinishes(cancelled: { true })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "stop() must be able to retire the loop while a switch is pending")
    }

    func testBeginEndAreIdempotent() {
        let gate = AudioSwitchGate()
        gate.begin()
        gate.begin()
        gate.end()
        XCTAssertFalse(gate.isPending)
        gate.end()
        XCTAssertFalse(gate.isPending)
    }
}
