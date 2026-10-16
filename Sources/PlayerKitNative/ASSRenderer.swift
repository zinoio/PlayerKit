// Sources/PlayerKitNative/ASSRenderer.swift
import Foundation
import CoreGraphics
import CAss

/// Renders ASS/SSA subtitle streams to bitmaps via libass (CoreText font
/// provider; fontconfig/harfbuzz deliberately not built — see
/// scripts/build_libass.sh).  One instance per selected subtitle stream:
/// feed the codec extradata at init, per-packet Matroska-format events via
/// `processPacket`, and `renderFrame` on the display loop's video PTS.
/// Output plugs into the existing bitmap-subtitle pipeline
/// (state.currentSubtitleImage/Rect), same shape as the PGS path (zyno#158).
///
/// Thread-safety: processPacket runs on the demux thread, renderFrame on the
/// display thread; all libass calls are serialized on one internal lock.
final class ASSRenderer: @unchecked Sendable {

    struct Frame {
        let image: CGImage
        /// Normalized position within the video frame (origin top-left, 0...1
        /// each axis) — matches FFmpegSubtitleDecoder.Cue.rect semantics.
        let rect: CGRect
    }

    private let lock = NSLock()
    private var library: OpaquePointer?    // ASS_Library* (opaque → OpaquePointer)
    private var renderer: OpaquePointer?   // ASS_Renderer* (opaque → OpaquePointer)
    private var track: UnsafeMutablePointer<ASS_Track>?  // fully defined struct in ass_types.h
    /// Subtracted from every packet's raw PTS — same start_time normalization
    /// FFmpegSubtitleDecoder applies for PGS (MKV remuxes of BD subs often
    /// keep disc-absolute timestamps while video/audio start at 0).
    private let startOffsetSecs: Double
    private let videoSize: CGSize
    /// Cached last composite; returned verbatim when libass reports no change
    /// so NativeBackend's CGImage-identity check suppresses redundant UI hops.
    private var lastFrame: Frame?

    init?(extradata: Data, videoSize: CGSize, startOffsetSecs: Double) {
        guard videoSize.width > 0, videoSize.height > 0, !extradata.isEmpty else { return nil }
        guard let lib = ass_library_init() else { return nil }
        library = lib
        guard let rend = ass_renderer_init(lib) else {
            ass_library_done(lib)
            library = nil
            return nil
        }
        renderer = rend

        let tr = ass_new_track(lib)
        track = tr
        extradata.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ass_process_codec_private(tr, base, Int32(extradata.count))
        }

        ass_set_frame_size(rend, Int32(videoSize.width), Int32(videoSize.height))
        // CoreText provider on Darwin (autodetected); fallback fonts allowed so
        // CJK/Latin glyphs missing from the styled font still render.
        ass_set_fonts(rend, nil, nil, Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)

        self.videoSize = videoSize
        self.startOffsetSecs = startOffsetSecs
    }

    deinit {
        // libass done/free functions take the pointer itself (unlike FFmpeg's
        // double-pointer free style).
        if let tr = track { ass_free_track(tr) }
        if let rend = renderer { ass_renderer_done(rend) }
        if let lib = library { ass_library_done(lib) }
    }

    /// Feed one Matroska-format ASS event (the raw AV_CODEC_ID_ASS packet
    /// payload: ReadOrder,Layer,Style,...,Text).  ptsSecs/durationSecs are in
    /// subtitle-stream time_base seconds; duration ≤ 0 falls back to 5s like
    /// the legacy text-cue path.
    func processPacket(_ data: Data, ptsSecs: Double, durationSecs: Double) {
        let startMs = Int64(((ptsSecs - startOffsetSecs) * 1000.0).rounded())
        let durMs = durationSecs > 0 ? Int64((durationSecs * 1000.0).rounded()) : 5000
        lock.withLock {
            guard let tr = track else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                ass_process_chunk(tr, base, Int32(data.count), startMs, durMs)
            }
        }
    }

    /// Render the active ASS events at `ptsSecs` (video PTS seconds — NOT
    /// offset-adjusted; packets were normalized on ingest).  Returns nil when
    /// nothing is active.  Returns the previous Frame instance unchanged when
    /// libass reports nothing changed.
    func renderFrame(ptsSecs: Double) -> Frame? {
        lock.withLock {
            guard let rend = renderer, let tr = track else { return nil }
            var detectChange: Int32 = 0
            let nowMs = Int64((ptsSecs * 1000.0).rounded())
            guard let head = ass_render_frame(rend, tr, nowMs, &detectChange) else {
                lastFrame = nil
                return nil
            }
            if detectChange == 0, let cached = lastFrame { return cached }
            guard let frame = Self.compose(head: head, videoSize: videoSize) else {
                lastFrame = nil
                return nil
            }
            lastFrame = frame
            return frame
        }
    }

    /// Drop all queued events (seek / track switch).  Rendering before the
    /// next processPacket yields an empty frame.
    func flushEvents() {
        lock.withLock {
            if let tr = track { ass_flush_events(tr) }
            lastFrame = nil
        }
    }

    // MARK: - Composition

    /// Blend the ASS_Image list (A8 masks × solid color) into one premultiplied
    /// RGBA bitmap covering the union of all placement rects, and normalize
    /// that union to the video frame.
    private static func compose(head: UnsafeMutablePointer<ASS_Image>,
                                videoSize: CGSize) -> Frame? {
        var minX = Int32.max, minY = Int32.max
        var maxX = Int32.min, maxY = Int32.min
        var cursor: UnsafeMutablePointer<ASS_Image>? = head
        while let cur = cursor {
            let im = cur.pointee
            if im.w > 0, im.h > 0 {
                minX = min(minX, im.dst_x); minY = min(minY, im.dst_y)
                maxX = max(maxX, im.dst_x + im.w); maxY = max(maxY, im.dst_y + im.h)
            }
            cursor = im.next
        }
        guard maxX > minX, maxY > minY,
              maxX <= Int32(videoSize.width), maxY <= Int32(videoSize.height) else { return nil }

        let w = Int(maxX - minX), h = Int(maxY - minY)
        var buf = [UInt8](repeating: 0, count: w * h * 4)

        cursor = head
        while let cur = cursor {
            let im = cur.pointee
            if im.w > 0, im.h > 0, let mask = im.bitmap {
                // libass packs color as 0xRRGGBBAA (ass_bswap32 of the &HAABBGGRR text
                // libass packs color as 0xRRGGBBAA (ass_bswap32 of the
                // &HAABBGGRR text value; alpha in the lowest byte).
                let r = Int((im.color >> 24) & 0xff)
                let g = Int((im.color >> 16) & 0xff)
                let b = Int((im.color >> 8) & 0xff)
                let a = 255 - Int(im.color & 0xff)  // ASS alpha: 0=opaque, 255=transparent
                let ox = Int(im.dst_x - minX), oy = Int(im.dst_y - minY)
                for row in 0..<Int(im.h) {
                    let maskRow = mask.advanced(by: row * Int(im.stride))
                    let dstRowBase = (oy + row) * w
                    for col in 0..<Int(im.w) {
                        let coverage = Int(maskRow[col])
                        if coverage == 0 { continue }
                        let sa = coverage * a / 255           // combined alpha
                        let inv = 255 - sa
                        let di = (dstRowBase + ox + col) * 4
                        // premultiplied-over: out = src·sa + dst·(1−sa)
                        buf[di]     = UInt8(min(255, r * sa / 255 + Int(buf[di])     * inv / 255))
                        buf[di + 1] = UInt8(min(255, g * sa / 255 + Int(buf[di + 1]) * inv / 255))
                        buf[di + 2] = UInt8(min(255, b * sa / 255 + Int(buf[di + 2]) * inv / 255))
                        buf[di + 3] = UInt8(min(255, sa          + Int(buf[di + 3]) * inv / 255))
                    }
                }
            }
            cursor = im.next
        }

        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }

        let rect = CGRect(x: CGFloat(minX) / videoSize.width,
                          y: CGFloat(minY) / videoSize.height,
                          width: CGFloat(w) / videoSize.width,
                          height: CGFloat(h) / videoSize.height)
        return Frame(image: cg, rect: rect)
    }
}
