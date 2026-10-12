import XCTest
import PlayerKit
@testable import PlayerKitNative

/// Track-language preference matching (zyno#100). Pure policy: no FFmpeg,
/// no fixtures — the cases below pin the normalization table, the
/// exact-over-prefix ordering, and every fallback rung of the pick chain.
final class TrackLanguageMatcherTests: XCTestCase {

    // MARK: - Normalization

    func testNormalizedMaps639Dash2To639Dash1() {
        XCTAssertEqual(TrackLanguageMatcher.normalized("chi"), "zh")
        XCTAssertEqual(TrackLanguageMatcher.normalized("zho"), "zh")
        XCTAssertEqual(TrackLanguageMatcher.normalized("ENG"), "en")
        XCTAssertEqual(TrackLanguageMatcher.normalized("jpn"), "ja")
        XCTAssertEqual(TrackLanguageMatcher.normalized("deu"), "de")
        // Already-639-1 codes pass through.
        XCTAssertEqual(TrackLanguageMatcher.normalized("zh"), "zh")
        XCTAssertEqual(TrackLanguageMatcher.normalized("en"), "en")
        // Unlisted codes compare verbatim (lowercased).
        XCTAssertEqual(TrackLanguageMatcher.normalized("und"), "und")
    }

    func testNormalizedKeepsRegionalVariant() {
        XCTAssertEqual(TrackLanguageMatcher.normalized("zh-CN"), "zh-cn")
        XCTAssertEqual(TrackLanguageMatcher.normalized("chi_TW"), "zh-tw")
        XCTAssertEqual(TrackLanguageMatcher.normalized("zho-Hans"), "zh-hans")
        XCTAssertEqual(TrackLanguageMatcher.normalized(" en "), "en")
        XCTAssertEqual(TrackLanguageMatcher.normalized(""), "")
    }

    // MARK: - Matches

    func testChinesePreferenceMatchesAllChineseTags() {
        for tag in ["zh", "chi", "zho", "zh-CN", "chi-TW", "zho_Hans", "ZHO"] {
            XCTAssertTrue(TrackLanguageMatcher.matches(preference: "zh", trackLang: tag),
                          "pref zh must match '\(tag)'")
        }
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "zh", trackLang: "eng"))
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "zh", trackLang: "en"))
    }

    func testPreferenceMatchesRegionalVariantOfItself() {
        XCTAssertTrue(TrackLanguageMatcher.matches(preference: "en", trackLang: "en-US"))
        XCTAssertTrue(TrackLanguageMatcher.matches(preference: "en", trackLang: "ENG"))
        XCTAssertTrue(TrackLanguageMatcher.matches(preference: "ja", trackLang: "jpn"))
        // "zh" must not match "zho"-derived… it must; but "en" must not match
        // "enx" (prefix without separator is a different code, not a variant).
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "en", trackLang: "enx"))
    }

    func testTrackWithoutLanguageNeverMatches() {
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "zh", trackLang: nil))
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "zh", trackLang: ""))
        XCTAssertFalse(TrackLanguageMatcher.matches(preference: "", trackLang: "chi"))
    }

    // MARK: - pickSubtitle

    private func track(_ id: Int, _ lang: String?, isDefault: Bool = false) -> TrackInfo {
        TrackInfo(id: id, lang: lang, isDefault: isDefault)
    }

    func testPickSubtitleWithoutPreferenceKeepsLegacyDefaultFirst() {
        let tracks = [track(1, "eng"), track(2, "chi", isDefault: true)]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: tracks, preference: nil)?.id, 2)
        // No default flag → first track (legacy behavior).
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(
            from: [track(1, "eng"), track(2, "chi")], preference: nil)?.id, 1)
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: [], preference: nil), nil)
    }

    func testPickSubtitlePrefersExactLanguageOverContainerDefault() {
        let tracks = [track(1, "eng", isDefault: true), track(2, "chi")]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: tracks, preference: "zh")?.id, 2)
    }

    func testPickSubtitleExactBeatsRegionalVariant() {
        // Both match "zh", but plain "chi" (exact after normalization) wins
        // over "zh-TW" (prefix-only).
        let tracks = [track(1, "zh-TW"), track(2, "chi")]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: tracks, preference: "zh")?.id, 2)
    }

    func testPickSubtitleFallsBackToContainerDefaultThenFirst() {
        // No language match → container default.
        let withDefault = [track(1, "eng", isDefault: true), track(2, "jpn")]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: withDefault, preference: "zh")?.id, 1)
        // No match, no default flag → first track.
        let noDefault = [track(1, "eng"), track(2, "jpn")]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: noDefault, preference: "zh")?.id, 1)
        // Tracks without language tags can't match — default fallback again.
        let untagged = [track(1, nil, isDefault: true), track(2, nil)]
        XCTAssertEqual(TrackLanguageMatcher.pickSubtitle(from: untagged, preference: "zh")?.id, 1)
    }

    // MARK: - pickAudio

    func testPickAudioNilOrDefaultKeepsDemuxerPick() {
        let tracks = [track(1, "eng"), track(2, "chi")]
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: nil), nil)
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: "default"), nil)
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: ""), nil)
    }

    func testPickAudioSelectsPreferredLanguage() {
        let tracks = [track(1, "eng", isDefault: true), track(2, "chi")]
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: "zh")?.id, 2)
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: "eng")?.id, 1)
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: "ja")?.id, nil,
                       "no match → nil, caller keeps the container default")
    }

    func testPickAudioExactBeatsRegionalVariant() {
        let tracks = [track(1, "zh-TW"), track(2, "chi")]
        XCTAssertEqual(TrackLanguageMatcher.pickAudio(from: tracks, preference: "zh")?.id, 2)
    }
}
