import XCTest
@testable import PlayerKitNative

/// In-band parameter-set delivery regression (zinoio/zinora#492).
///
/// `annexBToLengthPrefixedClassified` used to strip VPS/SPS/PPS NAL units
/// from every packet. VT sessions built from codecpar (container hvcC/avcC)
/// therefore never saw parameter sets that activate MID-stream — common in
/// remuxed UHD titles carrying multiple SPS. Every frame after the switch
/// failed with `kVTVideoDecoderBadDataErr` (-12909) until the whole-stream
/// fallback demoted the session to FFmpeg software decode (4K HDR10 SW is
/// CPU-bound: stutter + `AudioQueue starved`).
///
/// VT honors in-band parameter sets delivered inside the sample buffer, so
/// the converter must length-prefix them like any other NAL unit. FFmpeg
/// software decode reads them from the stream — which is exactly why the
/// same frames decoded fine after the fallback.
final class VTInBandParamSetDeliveryTests: XCTestCase {

    // MARK: - helpers

    private typealias NAL = (header: UInt8, payload: [UInt8])

    /// Build an AnnexB byte stream from NAL pairs and run the converter.
    private func run(_ nals: [NAL], isH264: Bool) -> (isIDR: Bool, out: Data) {
        var bytes: [UInt8] = []
        for (header, payload) in nals {
            bytes.append(contentsOf: [0, 0, 0, 1])   // 4-byte start code
            bytes.append(header)
            bytes.append(contentsOf: payload)
        }
        var out = Data()
        let isIDR = bytes.withUnsafeBufferPointer {
            VTVideoDecoder.annexBToLengthPrefixedClassified($0, isH264: isH264, into: &out)
        }
        return (isIDR, out)
    }

    private func lengthPrefixedNALs(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var nals: [[UInt8]] = []
        var i = 0
        while i + 4 <= bytes.count {
            let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                    | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let start = i + 4
            let end = start + len
            guard end <= bytes.count else { break }
            nals.append(Array(bytes[start..<end]))
            i = end
        }
        return nals
    }

    /// Parse the first NAL type out of a length-prefixed NAL payload.
    private func nalType(_ nal: [UInt8], isH264: Bool) -> Int {
        isH264 ? Int(nal[0] & 0x1F) : Int((nal[0] >> 1) & 0x3F)
    }

    // MARK: - HEVC

    /// HEVC: VPS(32)/SPS(33)/PPS(34) must survive conversion alongside the
    /// IDR slice (type 20); conversion must still classify the packet as IDR.
    func testHEVCInBandParameterSetsAreDelivered() {
        let (isIDR, out) = run([
            (header: 0x40, payload: [0x01, 0x02]),          // VPS  type 32
            (header: 0x42, payload: [0x01, 0x02, 0x03]),    // SPS  type 33
            (header: 0x44, payload: [0x01]),                // PPS  type 34
            (header: 0x28, payload: [0x00, 0xFF, 0x00]),    // IDR_W_RADL type 20
        ], isH264: false)

        XCTAssertTrue(isIDR, "IDR classification must not be affected by parameter-set delivery")
        let nals = lengthPrefixedNALs(out)
        XCTAssertEqual(nals.count, 4, "all four NAL units must be delivered, parameter sets included")
        XCTAssertEqual(nals.map { nalType($0, isH264: false) }, [32, 33, 34, 20],
                       "VPS/SPS/PPS must reach VT before the IDR slice, in stream order")
    }

    /// Mid-stream switch case: a parameter-set-only packet (no slice) must
    /// still deliver its NALs and must NOT be misclassified as IDR.
    func testHEVCParameterSetOnlyPacketDeliversWithoutIDRMisclassification() {
        let (isIDR, out) = run([
            (header: 0x42, payload: [0x01, 0x02]),          // SPS  type 33
            (header: 0x44, payload: [0x01]),                // PPS  type 34
        ], isH264: false)

        XCTAssertFalse(isIDR, "a packet without slice NALs is not an IDR packet")
        let nals = lengthPrefixedNALs(out)
        XCTAssertEqual(nals.map { nalType($0, isH264: false) }, [33, 34],
                       "mid-stream SPS/PPS must reach the VT session")
    }

    // MARK: - H.264

    /// H.264: SPS(7)/PPS(8) must survive alongside the IDR slice (type 5).
    func testH264InBandParameterSetsAreDelivered() {
        let (isIDR, out) = run([
            (header: 0x67, payload: [0x01, 0x02]),          // SPS type 7
            (header: 0x68, payload: [0x01]),                // PPS type 8
            (header: 0x65, payload: [0x00, 0xFF]),          // IDR slice type 5
        ], isH264: true)

        XCTAssertTrue(isIDR)
        let nals = lengthPrefixedNALs(out)
        XCTAssertEqual(nals.count, 3, "all three NAL units must be delivered")
        XCTAssertEqual(nals.map { nalType($0, isH264: true) }, [7, 8, 5],
                       "SPS/PPS must reach VT before the IDR slice, in stream order")
    }

    // MARK: - baseline

    /// Non-parameter NALs keep flowing through unchanged (existing behavior).
    func testNonParameterTrailSliceStillDelivered() {
        let (isIDR, out) = run([
            (header: 0x02, payload: [0x00, 0x01]),          // HEVC TRAIL_R type 1
        ], isH264: false)

        XCTAssertFalse(isIDR)
        let nals = lengthPrefixedNALs(out)
        XCTAssertEqual(nals.map { nalType($0, isH264: false) }, [1])
    }
}
