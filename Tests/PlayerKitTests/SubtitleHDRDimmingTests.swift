import XCTest
@testable import PlayerKit

final class SubtitleHDRDimmingTests: XCTestCase {

    private func makeInfo(isHDR: Bool = false, transfer: String? = nil, isDolbyVision: Bool = false) -> VideoInfo {
        VideoInfo(
            width: 3840,
            height: 2160,
            codec: "hevc",
            isHDR: isHDR,
            transfer: transfer,
            isDolbyVision: isDolbyVision
        )
    }

    func testSDRAndNilVideoNeverDim() {
        XCTAssertFalse(SubtitleHDRDimming.isHDRContent(nil))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: nil, hdrBrightness: 0.6), 1.0)

        let sdr = makeInfo(transfer: "bt709", isDolbyVision: false)
        XCTAssertFalse(SubtitleHDRDimming.isHDRContent(sdr))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: sdr, hdrBrightness: 0.6), 1.0)
    }

    func testDolbyVisionAndHDRTransfersDimToConfiguredBrightness() {
        let dv = makeInfo(transfer: nil, isDolbyVision: true)
        XCTAssertTrue(SubtitleHDRDimming.isHDRContent(dv))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: dv, hdrBrightness: 0.72), 0.72, accuracy: 1e-6)

        let pq = makeInfo(transfer: "smpte2084", isDolbyVision: false)
        XCTAssertTrue(SubtitleHDRDimming.isHDRContent(pq))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: pq, hdrBrightness: 0.65), 0.65, accuracy: 1e-6)

        let hlg = makeInfo(transfer: "arib-std-b67", isDolbyVision: false)
        XCTAssertTrue(SubtitleHDRDimming.isHDRContent(hlg))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: hlg, hdrBrightness: 0.8), 0.8, accuracy: 1e-6)

        let flagHDR = makeInfo(isHDR: true, transfer: nil, isDolbyVision: false)
        XCTAssertTrue(SubtitleHDRDimming.isHDRContent(flagHDR))
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: flagHDR, hdrBrightness: 0.72), 0.72, accuracy: 1e-6)
    }

    func testClampsOutOfRangeValuesAndAllowsOptOut() {
        let pq = makeInfo(transfer: "PQ", isDolbyVision: false)
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: pq, hdrBrightness: 0.1), 0.4, accuracy: 1e-6)
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: pq, hdrBrightness: 1.5), 1.0, accuracy: 1e-6)
        XCTAssertEqual(SubtitleHDRDimming.effectiveBrightness(videoInfo: pq, hdrBrightness: 1.0), 1.0, accuracy: 1e-6)
    }
}
