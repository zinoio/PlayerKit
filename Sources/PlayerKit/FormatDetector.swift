import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif

public enum FormatDetector {
    public static func isHardwareDecodable(codecId: String) -> Bool {
        switch codecId {
        case "h264", "avc", "avc1":
            return true
        case "hevc", "h265", "hev1", "hvc1":
            return true
        case "av1":
            // AV1 hardware decode exists only on A17 Pro / M3 and later —
            // probe the actual device instead of claiming support everywhere.
            // (zyno#107; pairs with the VTVideoDecoder probe gate.)
            #if canImport(VideoToolbox)
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
            #else
            return false
            #endif
        default:
            return false
        }
    }
}
