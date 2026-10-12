import Foundation
import PlayerKit

/// Language-preference matching for stream auto-selection (zyno#100).
///
/// Containers tag languages inconsistently: MKV uses ISO 639-2/B ("chi",
/// "eng"), MP4 often 639-2/T ("zho") or 639-1 ("zh"), and regional variants
/// appear as "zh-CN"/"en-US" (or the underscore form "zh_CN"). A user
/// preference of "zh" must therefore match "chi"/"zho"/"zh" and their
/// variants; everything else compares on the normalized base code.
///
/// All functions are pure so the selection policy is unit-testable without
/// any FFmpeg state.
enum TrackLanguageMatcher {

    /// ISO 639-2/B and 639-2/T → 639-1 for the codes a user can actually
    /// pick in settings (zh/en/ja today) plus frequent neighbours. Unlisted
    /// codes (and already-639-1 codes) compare verbatim.
    private static let iso2: [String: String] = [
        "chi": "zh", "zho": "zh",
        "eng": "en",
        "jpn": "ja",
        "ger": "de", "deu": "de",
        "fre": "fr", "fra": "fr",
        "spa": "es",
        "kor": "ko",
        "rus": "ru",
        "ita": "it",
        "por": "pt",
        "tha": "th",
    ]

    /// Lowercase, trim, map the 639-2 base to 639-1, keep regional/script
    /// suffixes: "chi-TW" → "zh-tw", "ENG" → "en", "zho_Hans" → "zh-hans".
    static func normalized(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = lower.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let base = parts.first, !base.isEmpty else { return "" }
        let mapped = iso2[String(base)] ?? String(base)
        guard parts.count > 1 else { return mapped }
        return mapped + "-" + parts.dropFirst().joined(separator: "-")
    }

    /// True if `trackLang` matches `preference`: equal after normalization,
    /// or a regional variant of it ("zh" matches "zh-cn"/"chi"/"zho-TW").
    /// Tracks without a language tag never match — they fall through to the
    /// container-default fallback at the call site.
    static func matches(preference: String, trackLang: String?) -> Bool {
        guard let trackLang, !trackLang.isEmpty else { return false }
        let pref = normalized(preference)
        guard !pref.isEmpty else { return false }
        let track = normalized(trackLang)
        return track == pref || track.hasPrefix(pref + "-")
    }

    /// Subtitle pick for a set preference: exact language match > prefix
    /// match > container default > first track. With no preference, keeps
    /// the legacy default-first behavior. ("off" is decided by the caller —
    /// it means select nothing — not here.)
    static func pickSubtitle(from tracks: [TrackInfo], preference: String?) -> TrackInfo? {
        guard !tracks.isEmpty else { return nil }
        guard let preference, !preference.isEmpty else {
            return tracks.first(where: { $0.isDefault }) ?? tracks.first
        }
        return byPreference(tracks, preference)
            ?? tracks.first(where: { $0.isDefault })
            ?? tracks.first
    }

    /// Audio pick for a set preference: exact language match > prefix match.
    /// Returns nil when the preference is unset/"default" or nothing matches
    /// — the caller then keeps the demuxer's container-default selection.
    static func pickAudio(from tracks: [TrackInfo], preference: String?) -> TrackInfo? {
        guard let preference, !preference.isEmpty, preference != "default" else { return nil }
        return byPreference(tracks, preference)
    }

    /// Exact (normalized-equal) matches beat regional-variant matches: for
    /// preference "zh" a plain "chi" track wins over "zh-TW".
    private static func byPreference(_ tracks: [TrackInfo], _ preference: String) -> TrackInfo? {
        let pref = normalized(preference)
        if let exact = tracks.first(where: { $0.lang.map(normalized) == pref }) {
            return exact
        }
        return tracks.first(where: { matches(preference: preference, trackLang: $0.lang) })
    }
}
