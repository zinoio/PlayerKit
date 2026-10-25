import Foundation
import CFFmpeg
import PlayerKit

/// The demux-surface `NativeBackend`'s demux loop and stream-metadata reads
/// need. Implemented by `FFmpegDemuxer` (single file / concat list) and
/// `MultiClipDemuxer` (multi-clip disc playback, delegating to whichever
/// clip's `FFmpegDemuxer` is currently active).
///
/// Member set is exactly NativeBackend's access surface on
/// `self.demuxer` — the protocol exists so the backend can hold either
/// implementation behind one existential without knowing which one it has.
///
/// NOT @MainActor-isolated: the demux loop calls `readPacket()`/`seek()` on
/// a background GCD thread. Both conformers are `@unchecked Sendable` (all
/// mutable state is guarded by the demux lock / confined to the read thread),
/// which is why the protocol carries `Sendable` so the existential stays
/// usable across the queue hop.
protocol PacketDemuxing: AnyObject, Sendable {
    var formatContext: UnsafeMutablePointer<AVFormatContext>? { get }
    var videoStream: UnsafeMutablePointer<AVStream>? { get }
    var audioStream: UnsafeMutablePointer<AVStream>? { get }
    var subtitleStream: UnsafeMutablePointer<AVStream>? { get }
    var videoStreamIndex: Int32 { get }
    var audioStreamIndex: Int32 { get }
    var subtitleStreamIndex: Int32 { get }
    var downloadedUpToOffset: Int64 { get }
    var totalFileBytes: Int64 { get }
    var isPassthroughCodec: Bool { get }
    var isDolbyVision: Bool { get }
    var doviProfile: UInt8 { get }
    var doviBLSignalCompatibilityId: UInt8 { get }
    var hasHDR10Plus: Bool { get }
    /// HDR-relevant stream attributes for the renderer strategy decision
    /// (`decideRendererStrategy`). nil when there is no active video stream.
    func videoStreamAttributes() -> VideoStreamAttributes?
    /// Diagnostics: comma-separated side data type names on the video codecpar.
    var sideDataTypesDescription: String { get }
    var audioIsAtmos: Bool { get }
    var sampleAspectRatio: Double { get }
    func selectAudioStream(by id: Int) -> Bool
    /// 所有音频流下标;`setCachedAudioStreams` 让这些备选音轨的包也被解复用返回
    /// (zyno#171 切轨免 seek)。默认实现:不支持(多片段等),返回空/不做事。
    var audioStreamIndices: [Int32] { get }
    func setCachedAudioStreams(_ indices: Set<Int32>)
    func selectSubtitleStream(by id: Int?)
    func readPacket() -> (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>, didSwitchClip: Bool)?
    /// The reader/media error behind the most recent readPacket() failure,
    /// nil when readPacket() returned nil because the stream genuinely ended.
    /// Lets the demux loop tell a thrown reader error (network blackhole,
    /// risk-control block, gone cloud file) apart from a natural EOF — the
    /// former must surface as a playback error, the latter is "played to end".
    var lastDemuxError: Error? { get }
    /// zyno#360: true when the most recent readPacket() returned nil because an
    /// audio-track switch interrupted the read — a deliberate pause, not a
    /// failure and never EOF. Default false for demuxers that can't interrupt.
    var lastDemuxInterrupted: Bool { get }
    /// zyno#360: abort an in-flight network read before the switch takes
    /// `demuxLock`. Returns a generation token (0 = reader has no interruption
    /// support). Default no-op.
    func interruptPendingReads() -> UInt64
    /// zyno#360: clear the interruption once the switch holds `demuxLock`, so
    /// the switch's own seek reads work. Default no-op.
    func resumeReads(after token: UInt64)
    func seek(to time: Double) -> Bool
    /// The video PTS the most recent seek() physically landed on, when the
    /// demuxer knows it. Non-nil only for byte-domain seeks
    /// (FFmpegDemuxer.seekByByteOffset — raw indexless MPEG-TS / BDMV clips),
    /// which probe an actual video PTS while converging; index-guided
    /// av_seek_frame seeks don't pay a probe and report nil. NativeBackend
    /// uses the gap between this and the requested target to arm
    /// discard-until-target fine-seek (zyno#142); nil keeps those paths on
    /// their historical land-on-GOP-boundary behavior.
    var lastSeekLandedPTS: Double? { get }
    func close()
}

extension FFmpegDemuxer: PacketDemuxing {}

extension PacketDemuxing {
    var audioStreamIndices: [Int32] { [] }
    func setCachedAudioStreams(_ indices: Set<Int32>) {}
    var lastDemuxInterrupted: Bool { false }
    func interruptPendingReads() -> UInt64 { 0 }
    func resumeReads(after token: UInt64) {}
}
