import XCTest
@testable import PlayerKit

final class DoviElExtractorTests: XCTestCase {

    private func lengthPrefixed(_ nal: [UInt8]) -> [UInt8] {
        let n = nal.count
        return [
            UInt8((n >> 24) & 0xFF),
            UInt8((n >> 16) & 0xFF),
            UInt8((n >> 8) & 0xFF),
            UInt8(n & 0xFF),
        ] + nal
    }

    func testLengthPrefixedExtractsUnspec63AndSkipsBLAndRPU() {
        // BL slice (type 1), EL unspec63 (type 63 = 0x7E 0x01) with bare EL NAL,
        // second EL unspec63 already carrying Annex-B start code, RPU unspec62 (0x7C 0x01).
        let bl: [UInt8] = [0x02, 0x01, 0xAA, 0xBB]
        let el1: [UInt8] = [0x7E, 0x01, 0x40, 0x01, 0x11, 0x22]
        let el2: [UInt8] = [0x7E, 0x01, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x33]
        let rpu: [UInt8] = [0x7C, 0x01, 0x19, 0x08]

        let packet = Data(lengthPrefixed(bl) + lengthPrefixed(el1) + lengthPrefixed(el2) + lengthPrefixed(rpu))
        let extracted = DoviElExtractor.extractAnnexB(from: packet, isLengthPrefixed: true)

        let expected = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x11, 0x22,
            0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x33,
        ])
        XCTAssertEqual(extracted, expected)
    }

    func testAnnexBExtractsUnspec63() {
        let bl: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xAA]
        let el: [UInt8] = [0x00, 0x00, 0x01, 0x7E, 0x01, 0x26, 0x01, 0x55, 0x66]
        let rpu: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x7C, 0x01, 0x19]

        let extracted = DoviElExtractor.extractAnnexB(from: Data(bl + el + rpu), isLengthPrefixed: false)
        XCTAssertEqual(extracted, Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x55, 0x66]))
    }

    func testNoElReturnsNil() {
        let bl: [UInt8] = [0x02, 0x01, 0xAA, 0xBB]
        let rpu: [UInt8] = [0x7C, 0x01, 0x19, 0x08]
        XCTAssertNil(DoviElExtractor.extractAnnexB(from: Data(lengthPrefixed(bl) + lengthPrefixed(rpu)),
                                                   isLengthPrefixed: true))
    }

    func testElFramePairerHandlesBFrameReorderAndPruning() {
        var pairer = DoviElFramePairer<String>(capacity: 4, tolerance: 0.020)
        pairer.store("f3", pts: 0.125)
        pairer.store("f1", pts: 0.042)
        pairer.store("f2", pts: 0.083)

        // Exact & within-tolerance matches
        XCTAssertEqual(pairer.take(matching: 0.042), "f1")
        XCTAssertEqual(pairer.take(matching: 0.085), "f2")
        // Future PTS prunes stale entries and misses
        XCTAssertNil(pairer.take(matching: 0.500))
        XCTAssertEqual(pairer.count, 0)

        // Capacity eviction + clear
        for i in 0..<6 { pairer.store("e\(i)", pts: Double(i)) }
        XCTAssertEqual(pairer.count, 4)
        pairer.clear()
        XCTAssertEqual(pairer.count, 0)
    }
}
