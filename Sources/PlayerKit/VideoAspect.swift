import Foundation
import QuartzCore
import AVFoundation

/// User-selectable video display geometry (feat/player-reskin, reflux issue
/// #444 P1 — the aspect-ratio presets in the tuning panel).
public enum VideoAspectMode: String, Sendable, CaseIterable {
    /// Original aspect ratio, letterbox/pillarbox within the view (fit).
    /// Legacy behavior before aspect modes existed.
    case source
    /// Force a 16:9 presentation window regardless of the source aspect.
    case ratio169
    /// Scale to fill the whole view, cropping the overflow (cover).
    case fill
}

/// Shared frame/gravity computation for the native video views.
/// `PlayerNativeViewMac.layout()` and `PlayerNativeViewiOS.layoutSubviews()`
/// both consume this so the three platforms agree on the geometry.
public enum VideoAspectLayout {
    /// Display-layer frame for `mode` inside `bounds`.
    /// - source: aspect-fit rect of the video (letterbox/pillarbox bars come
    ///   from the parent view's black background), falling back to `bounds`
    ///   before video info is known.
    /// - ratio169: aspect-fit rect of a *virtual* 16:9 source.
    /// - fill: the full bounds (overflow is cropped by resizeAspectFill).
    public static func frame(in bounds: CGRect, videoInfo: VideoInfo?,
                             mode: VideoAspectMode) -> CGRect {
        let aspect: CGFloat
        switch mode {
        case .fill:
            return bounds
        case .ratio169:
            aspect = 16.0 / 9.0
        case .source:
            guard let info = videoInfo, info.width > 0, info.height > 0 else {
                return bounds
            }
            aspect = CGFloat(info.width) / CGFloat(info.height)
        }
        let boundsAspect = bounds.width / bounds.height
        if aspect > boundsAspect {
            // Letterbox: black bars top and bottom
            let h = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            // Pillarbox: black bars left and right
            let w = bounds.height * aspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }

    /// Display-layer video gravity for the given mode + computed frame.
    /// - fill: resizeAspectFill (crops overflow).
    /// - ratio169: resizeAspect — the layer is the 16:9 window; a non-16:9
    ///   source must fit *inside* it with bars, never stretch to fill it.
    /// - source: resize when the layer is exactly the video rect (the layer
    ///   itself is the fitted rect); resizeAspect as the unknown-video
    ///   fallback where frame == bounds.
    public static func gravity(frame: CGRect, bounds: CGRect,
                               mode: VideoAspectMode) -> AVLayerVideoGravity {
        switch mode {
        case .fill:
            return .resizeAspectFill
        case .ratio169:
            return .resizeAspect
        case .source:
            return (frame == bounds) ? .resizeAspect : .resize
        }
    }
}

public extension Notification.Name {
    /// Posted on the main thread when `Player.videoAspectMode` changes.
    /// PlayerNativeView (macOS and iOS) observes this to re-layout the video
    /// layer — the frame depends on the mode, so an instant switch mid-play
    /// needs a new layout pass.
    static let playerKitVideoAspectDidChange =
        Notification.Name("PlayerKit.videoAspectDidChange")
}
