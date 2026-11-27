import SwiftUI

/// HDR / Dolby Vision 字幕亮度压制策略（对标 Infuse / mpv `sub-hdr-peak`）。
///
/// 在 EDR / HDR 显示模式下，纯白 SDR 参考白（`#FFFFFF`）在暗场中极易刺眼。
/// 通过降低前景灰度（文本用 `Color(white:)`，PGS/ASS 位图用 `.colorMultiply`）
/// 而非 `.opacity`，在压低峰值亮度的同时保持 100% 不透明度与纯黑描边锐度。
public enum SubtitleHDRDimming {
    /// 默认 HDR/DV 字幕亮度系数（sRGB 0.72 ≈ 线性亮度 48%）。
    public static let defaultHDRBrightness: Double = 0.72
    /// 用户可调范围（40%–100%，100% = 关闭压制）。
    public static let range: ClosedRange<Double> = 0.4...1.0

    /// 判断片源是否为 HDR（PQ / HLG / 未标记 HDR10）或 Dolby Vision。
    public static func isHDRContent(_ info: VideoInfo?) -> Bool {
        guard let info else { return false }
        if info.isDolbyVision || info.isHDR { return true }
        let t = info.transfer?.lowercased() ?? ""
        return t.contains("2084") || t.contains("pq")
            || t.contains("hlg") || t.contains("2100") || t.contains("b67")
    }

    /// 计算当前片源生效的字幕亮度系数：SDR 恒为 1.0，HDR/DV 按 `hdrBrightness` 钳制。
    public static func effectiveBrightness(videoInfo: VideoInfo?,
                                           hdrBrightness: Double) -> Double {
        guard isHDRContent(videoInfo) else { return 1.0 }
        return min(max(hdrBrightness, range.lowerBound), range.upperBound)
    }
}

/// Transparent subtitle overlay. Place on top of PlayerView in a ZStack:
/// ```swift
/// ZStack {
///     PlayerView(player: player)
///     SubtitleOverlayView(player: player)
/// }
/// ```
public struct SubtitleOverlayView: View {
    public let player: Player
    /// User-adjustable vertical offset in points (positive = move down, negative = move up).
    public var verticalOffset: CGFloat = 0
    /// User-adjustable horizontal offset in points (positive = move right, negative = move left).
    public var horizontalOffset: CGFloat = 0
    /// User-adjustable scale factor for subtitle size (1.0 = original, 1.5 = 50% larger, 0.8 = 20% smaller).
    public var scale: CGFloat = 1.0
    /// Preferred font family for text subtitles (nil = system font). Bitmap
    /// (PGS/VOBSUB) and ASS typeset subtitles ignore this — ASS font choice
    /// goes through `Player.subtitleFontFamily`.
    public var fontFamily: String? = nil
    /// Target subtitle brightness multiplier on HDR/DV content (0.4...1.0, 1.0 = no dimming).
    /// Automatically ignored (1.0) on SDR content.
    public var hdrBrightness: Double = SubtitleHDRDimming.defaultHDRBrightness

    public init(player: Player, verticalOffset: CGFloat = 0, horizontalOffset: CGFloat = 0,
                scale: CGFloat = 1.0, fontFamily: String? = nil,
                hdrBrightness: Double = SubtitleHDRDimming.defaultHDRBrightness) {
        self.player = player
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
        self.scale = scale
        self.fontFamily = fontFamily
        self.hdrBrightness = hdrBrightness
    }

    public var body: some View {
        let brightness = SubtitleHDRDimming.effectiveBrightness(
            videoInfo: player.state.videoInfo,
            hdrBrightness: hdrBrightness
        )
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo)
            // Use videoRect as the alignment frame so subtitles align to the
            // bottom of the video (not the full screen). In portrait with
            // letterbox bars, the video is centered — aligning to screen
            // bottom would put subtitles in the bottom black bar, not on
            // the video.
            ZStack(alignment: .bottom) {
                if let text = player.state.currentSubtitleText {
                    textSubtitle(text, videoRect: videoRect, brightness: brightness)
                        .transition(.opacity)
                }
                if let image = player.state.currentSubtitleImage {
                    bitmapSubtitle(image, rect: player.state.currentSubtitleImageRect,
                                   in: geo, videoRect: videoRect, brightness: brightness)
                        .transition(.opacity)
                }
            }
            .frame(width: videoRect.width, height: videoRect.height, alignment: .bottom)
            .position(x: videoRect.midX, y: videoRect.midY)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleText)
        .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleImage != nil)
    }

    /// Compute the actual video display rect (aspect-fit) within the overlay's geometry.
    /// PGS subtitle normalized coordinates are relative to the video frame, not the full
    /// screen — without mapping to the letterboxed rect, subtitles drift off-screen when
    /// the video is pillarboxed/letterboxed (especially in landscape on phones).
    @MainActor
    private func videoDisplayRect(in geo: GeometryProxy) -> CGRect {
        guard let info = player.state.videoInfo,
              info.width > 0, info.height > 0 else {
            return CGRect(origin: .zero, size: geo.size)
        }
        let aspect = CGFloat(info.width) / CGFloat(info.height)
        let boundsAspect = geo.size.width / geo.size.height
        if aspect > boundsAspect {
            let h = geo.size.width / aspect
            return CGRect(x: 0,
                          y: (geo.size.height - h) / 2,
                          width: geo.size.width, height: h)
        } else {
            let w = geo.size.height * aspect
            return CGRect(x: (geo.size.width - w) / 2,
                          y: 0,
                          width: w, height: geo.size.height)
        }
    }

    private var textSubtitleFont: Font {
        if let family = fontFamily, !family.isEmpty {
            return .custom(family, size: 20 * scale).weight(.semibold)
        }
        return .system(size: 20 * scale, weight: .semibold)
    }

    private func textSubtitle(_ text: String, videoRect: CGRect, brightness: Double) -> some View {
        Text(text)
            .font(textSubtitleFont)
            .foregroundStyle(Color(white: brightness))
            .multilineTextAlignment(.center)
            .lineSpacing(4 * scale)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: -1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: -1)
            .shadow(color: .black.opacity(0.6),  radius: 3 * scale)
            .padding(.horizontal, 24)
            .frame(maxWidth: videoRect.width - 16)
            .padding(.bottom, 20)
            .offset(x: horizontalOffset, y: verticalOffset)
    }

    private func bitmapSubtitle(_ image: CGImage, rect: CGRect,
                                in geo: GeometryProxy, videoRect: CGRect,
                                brightness: Double) -> some View {
        // Center the bitmap subtitle horizontally within the video rect,
        // placed at the bottom (same layout as text subtitles).
        // Ignore PGS's original x/y — BD placement is often off-center.
        let scaledWidth = rect.width * videoRect.width * scale
        let scaledHeight = rect.height * videoRect.height * scale
        return Image(decorative: image, scale: 1)
            .resizable()
            .colorMultiply(brightness < 0.999 ? Color(white: brightness) : .white)
            .frame(width: scaledWidth, height: scaledHeight)
            .padding(.bottom, 20)
            .offset(x: horizontalOffset, y: verticalOffset)
    }
}
