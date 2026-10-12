import XCTest
#if canImport(VideoToolbox)
import VideoToolbox
#endif
@testable import PlayerKit

final class FormatDetectorTests: XCTestCase {
    func testH264IsHardwareDecodable() {
        XCTAssertTrue(FormatDetector.isHardwareDecodable(codecId: "h264"))
    }

    func testHEVCIsHardwareDecodable() {
        XCTAssertTrue(FormatDetector.isHardwareDecodable(codecId: "hevc"))
    }

    /// zyno#107: av1 used to be a hardcoded `true` (a lie on pre-M3/A17 Pro
    /// devices). It must now agree with the device's actual VT capability.
    func testAV1MatchesDeviceCapability() {
        let reported = FormatDetector.isHardwareDecodable(codecId: "av1")
        #if canImport(VideoToolbox)
        XCTAssertEqual(reported, VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        #else
        XCTAssertFalse(reported)
        #endif
    }

    func testVP9IsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "vp9"))
    }

    func testVC1IsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "vc1"))
    }

    func testUnknownCodecIsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "flv1"))
    }
}
