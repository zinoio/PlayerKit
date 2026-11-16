import XCTest
@testable import PlayerKit

final class DoviNalRewriterTests: XCTestCase {

    private func nal(_ type: UInt8, payload: [UInt8]) -> Data {
        Data([(type << 1) & 0x7F, 0x01] + payload)
    }

    private func packet(includeEL: Bool = true) -> Data {
        var d = Data()
        for n in [nal(35, payload: [0x50]),            // AUD
                  nal(32, payload: [0x0c, 0x01]),      // VPS
                  nal(33, payload: [0x01, 0x02]),      // SPS
                  nal(34, payload: [0x03, 0x04])] {     // PPS
            d.append(contentsOf: [0, 0, 0, 1]); d.append(n)
        }
        if includeEL {
            d.append(contentsOf: [0, 0, 0, 1])
            d.append(nal(62, payload: [0xAA, 0xBB, 0xCC])) // 原始 EL/RPU
        }
        d.append(contentsOf: [0, 0, 0, 1])
        d.append(nal(19, payload: [0x11, 0x22, 0x33, 0x44])) // IDR
        return d
    }

    func testStripsELAndInjectsConvertedRPUAtSamePosition() {
        let converted = nal(62, payload: [0x99, 0x88])
        let out = DoviNalRewriter.rewrite(packet: packet(), injecting: converted)
        let bytes = [UInt8](out)

        // 原始 EL payload 不再出现
        XCTAssertFalse(bytes.containsSubsequence([0xAA, 0xBB, 0xCC]))
        // 转换态 RPU 恰好出现一次
        XCTAssertEqual(count(of: [0x99, 0x88], in: bytes), 1)
        // 参数集与 VCL 保留
        XCTAssertTrue(bytes.containsSubsequence([0x0c, 0x01]))
        XCTAssertTrue(bytes.containsSubsequence([0x01, 0x02]))
        XCTAssertTrue(bytes.containsSubsequence([0x03, 0x04]))
        XCTAssertTrue(bytes.containsSubsequence([0x11, 0x22, 0x33, 0x44]))
        // AUD 保留且在最前
        XCTAssertTrue(bytes.containsSubsequence([0x50]))
    }

    func testStripOnlyDoesNotInject() {
        let out = DoviNalRewriter.rewrite(packet: packet(), injecting: nil)
        let bytes = [UInt8](out)
        XCTAssertFalse(bytes.containsSubsequence([0xAA, 0xBB, 0xCC]))
        XCTAssertTrue(bytes.containsSubsequence([0x11, 0x22, 0x33, 0x44]))
    }

    func testInjectsBeforeFirstVCLWhenNoELNAL() {
        let converted = nal(62, payload: [0x77])
        let out = DoviNalRewriter.rewrite(packet: packet(includeEL: false), injecting: converted)
        let bytes = [UInt8](out)
        XCTAssertEqual(count(of: [0x77], in: bytes), 1)
        XCTAssertTrue(bytes.containsSubsequence([0x11, 0x22, 0x33, 0x44]))
    }

    func testMalformedPacketPassesThrough() {
        let junk = Data([0x12, 0x34, 0x56, 0x78, 0x9A]) // 无起始码,非 annexb
        let out = DoviNalRewriter.rewrite(packet: junk, injecting: nal(62, payload: [0x01]))
        XCTAssertEqual(out, junk)
    }

    // MARK: helpers

    private func count(of pattern: [UInt8], in bytes: [UInt8]) -> Int {
        guard pattern.count > 0, bytes.count >= pattern.count else { return 0 }
        var n = 0
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<i+pattern.count]) == pattern { n += 1 }
        return n
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        for i in 0...(count - pattern.count) where Array(self[i..<i+pattern.count]) == pattern { return true }
        return false
    }
}
