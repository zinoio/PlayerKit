import Foundation
import PlayerKit
import CFFmpeg

/// AVFormatContext → [ChapterInfo] extraction, shared by the standalone probe
/// and the live NativeBackend open path (zyno#101) so container chapters are
/// parsed identically in both.
enum FFmpegChapterParser {

    /// Walk `fmtCtx`'s chapter list. The format context must outlive the call.
    /// Returns [] for chapter-less containers (and for a nil context, e.g.
    /// MultiClipDemuxer's BDMV path, which carries chapters elsewhere).
    static func parse(_ fmtCtx: UnsafeMutablePointer<AVFormatContext>?) -> [ChapterInfo] {
        guard let fmtCtx else { return [] }
        var chapters: [ChapterInfo] = []
        let nbChapters = Int(fmtCtx.pointee.nb_chapters)
        for i in 0..<nbChapters {
            guard let chPtr = fmtCtx.pointee.chapters[i] else { continue }
            let ch = chPtr.pointee
            let tb = ch.time_base

            var chapterTitle: String?
            if let entry = av_dict_get(ch.metadata, "title", nil, 0) {
                chapterTitle = String(cString: entry.pointee.value)
            }

            let startSec = Double(ch.start) * Double(tb.num) / Double(tb.den)
            let endSec = Double(ch.end) * Double(tb.num) / Double(tb.den)
            chapters.append(ChapterInfo(title: chapterTitle, startDuration: startSec, endDuration: endSec))
        }
        return chapters
    }
}
