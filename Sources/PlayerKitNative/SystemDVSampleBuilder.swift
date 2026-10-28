import Foundation
import CoreMedia
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "dovi.system.builder")

/// C 宏 AV_NOPTS_VALUE 不进 Swift;仓内惯例(NativeBackend 同值)。
private let nopts = Int64(bitPattern: 0x8000000000000000)

/// Native DV system path, part 2: wrap demuxed compressed packets into
/// `CMSampleBuffer`s carrying the `dvh1` format description (design §5.2).
///
/// One builder per playback session: the format description is built once from
/// the stream's `hvcC` extradata + DV config record. Parameter-set changes
/// mid-stream (multi-clip disc timelines) are phase 2 (design §8) and will
/// need a rebuild hook — v1 returns nil from `makeSample` on nil-input paths
/// and the session falls back instead.
///
/// The builder does not own packets: sample data is copied into a
/// `CMBlockBuffer` at construction time, so the demux loop can free the
/// `AVPacket` immediately after enqueueing.
final class SystemDVSampleBuilder {

    private let formatDescription: CMVideoFormatDescription
    /// Stream time_base in seconds — packet dts/duration are stream units.
    private let timeBase: Double

    /// - Parameters:
    ///   - stream: demuxer's video stream (for `hvcC` extradata + time_base).
    ///   - dovi: demuxer's parsed DV configuration record.
    /// Returns nil when the system path can't be set up (no usable hvcC, or
    /// CoreMedia rejects the format description) → strategy falls back.
    init?(stream: UnsafeMutablePointer<AVStream>, dovi: AVDOVIDecoderConfigurationRecord) {
        let cp = stream.pointee.codecpar.pointee
        guard let hvcC = VTVideoDecoder.realExtradata(cp),
              let fd = SystemDVFormatDescription.make(
                  hvcC: hvcC, width: cp.width, height: cp.height, dovi: dovi)
        else {
            logger.error("system DV sample builder init failed: no hvcC or FD rejected")
            return nil
        }
        self.formatDescription = fd
        let tb = stream.pointee.time_base
        self.timeBase = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
    }

    /// Wrap one packet.
    ///
    /// - Parameters:
    ///   - packet: demuxed packet (data is copied, not retained).
    ///   - pts: presentation timestamp in **global seconds** — the caller
    ///     (NativeBackend) has already validated/rebased it.
    ///   - doNotDisplay: true for fine-seek pre-roll frames (FineSeekPolicy).
    func makeSample(packet: UnsafePointer<AVPacket>, pts: Double,
                    doNotDisplay: Bool) -> CMSampleBuffer? {
        let pkt = packet.pointee
        let size = Int(pkt.size)
        guard size > 0, let data = pkt.data else { return nil }

        // 1. Copy payload into a CMBlockBuffer (independent of the packet).
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: size, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            logger.error("block buffer create failed: \(status)")
            return nil
        }
        status = CMBlockBufferReplaceDataBytes(with: data, blockBuffer: bb,
                                               offsetIntoDestination: 0, dataLength: size)
        guard status == kCMBlockBufferNoErr else {
            logger.error("block buffer copy failed: \(status)")
            return nil
        }

        // 2. Timing: pts comes in seconds; dts/duration convert from stream
        //    time_base. Missing dts → invalid (the layer tolerates it; B-frame
        //    reordering info is only a hint for the system decoder).
        let duration: CMTime = pkt.duration > 0
            ? CMTime(seconds: Double(pkt.duration) * timeBase, preferredTimescale: 90_000)
            : .invalid
        let dts: CMTime = pkt.dts != nopts
            ? CMTime(seconds: Double(pkt.dts) * timeBase, preferredTimescale: 90_000)
            : .invalid
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            decodeTimeStamp: dts)

        var sample: CMSampleBuffer?
        var sampleSize = size
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sb = sample else {
            logger.error("sample buffer create failed: \(status)")
            return nil
        }

        // 3. Attachments: keyframe = sync; fine-seek pre-roll gets DoNotDisplay.
        let isKey = pkt.flags & AV_PKT_FLAG_KEY != 0
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           let dict = (arr as NSArray).firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_NotSync] = isKey ? kCFBooleanFalse : kCFBooleanTrue
            if doNotDisplay {
                dict[kCMSampleAttachmentKey_DoNotDisplay] = kCFBooleanTrue
            }
        }
        return sb
    }
}
