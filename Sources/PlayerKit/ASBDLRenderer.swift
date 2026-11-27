import AVFoundation
import CoreVideo
import QuartzCore
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "asbdl")

/// Result of tone-mapping processing: the processed pixel buffer and the
/// color params that describe it. When tone mapping converts HDR → SDR,
/// the color params are updated to reflect the output (SDR transfer,
/// BT.709 matrix, full range) so ASBDL attaches the correct color tags.
public struct ProcessedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let colorParams: VideoColorParams

    public init(pixelBuffer: CVPixelBuffer, colorParams: VideoColorParams) {
        self.pixelBuffer = pixelBuffer
        self.colorParams = colorParams
    }
}

/// A processor that applies custom tone-mapping to a pixel buffer before
/// display. Implemented by PlayerKitPro's ToneMapProcessor for Pro users.
public protocol ToneMapping: AnyObject {
    func process(pixelBuffer: CVPixelBuffer,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> ProcessedFrame

    /// Phase 3 (macOS 软解完整 P7 FEL NLQ): optional EL pixel buffer overload.
    /// Default implementation forwards to the 4-argument `process(...)` so
    /// existing conformers remain source-compatible.
    func process(pixelBuffer: CVPixelBuffer,
                 elPixelBuffer: CVPixelBuffer?,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> ProcessedFrame
}

public extension ToneMapping {
    func process(pixelBuffer: CVPixelBuffer,
                 elPixelBuffer: CVPixelBuffer?,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> ProcessedFrame {
        process(pixelBuffer: pixelBuffer, colorParams: colorParams,
                metadata: metadata, strategy: strategy)
    }
}

/// Video renderer wrapping `AVSampleBufferDisplayLayer`.
///
/// `AVSampleBufferDisplayLayer` is a Core Animation layer that handles
/// pixel-buffer-to-display rendering natively via the video pipeline,
/// including HDR tone-mapping and display refresh coordination.
///
/// This renderer is best suited for:
/// - HDR (PQ/HLG) content where system-level EDR is desired.
/// - 10-bit pixel formats.
/// - Streams that don't require custom shader-based processing.
///
/// It is **not** suitable for:
/// - Dolby Vision Profile 5 (needs custom RPU injection).
/// - Real-time filter chains.
public class ASBDLRenderer: VideoRenderer {

    public let displayLayer: AVSampleBufferDisplayLayer
    public var layer: CALayer { displayLayer }

    public var prefersTenBit: Bool { true }

    public var displayCapability: DisplayCapability

    /// Optional tone-mapping processor (injected by PlayerKitPro for Pro users).
    /// When non-nil, pixel buffers are processed before enqueuing to the display layer.
    public var toneMapper: (any ToneMapping)?

    public init(displayCapability: DisplayCapability = .macSDR) {
        self.displayCapability = displayCapability
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Phase 2 route b: CoreVideo attachment keys consumed by iOS/tvOS
    /// backboardd HDRProcessing stack when rendering decoded 10-bit CVPixelBuffers.
    public static let doviRpuAttachmentKey: CFString = "DolbyVisionRPUData" as CFString
    public static let doviCompatIdAttachmentKey: CFString = "DolbyCompatibilityID" as CFString

    /// Attach or strip per-frame Dolby Vision RPU metadata on a `CVPixelBuffer`.
    /// Passing `nil` explicitly removes both keys so pooled pixel buffers never
    /// leak stale RPU across frames or strategy transitions.
    public static func applyRouteBAttachments(_ pb: CVPixelBuffer, rpuData: Data?) {
        if let rpuData, !rpuData.isEmpty {
            CVBufferSetAttachment(pb, doviRpuAttachmentKey, rpuData as CFData, .shouldPropagate)
            CVBufferSetAttachment(pb, doviCompatIdAttachmentKey, "1" as CFString, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(pb, doviRpuAttachmentKey)
            CVBufferRemoveAttachment(pb, doviCompatIdAttachmentKey)
        }
    }

    public nonisolated func render(
        pixelBuffer: CVPixelBuffer,
        pts: Double,
        colorParams: VideoColorParams,
        metadata: FrameMetadata,
        strategy: RendererStrategy?
    ) {
        render(pixelBuffer: pixelBuffer, elPixelBuffer: nil, pts: pts,
               colorParams: colorParams, metadata: metadata, strategy: strategy)
    }

    public nonisolated func render(
        pixelBuffer: CVPixelBuffer,
        elPixelBuffer: CVPixelBuffer?,
        pts: Double,
        colorParams: VideoColorParams,
        metadata: FrameMetadata,
        strategy: RendererStrategy?
    ) {
        let isRouteB = strategy == .doviRouteB
        let pb: CVPixelBuffer
        let cp: VideoColorParams
        if !isRouteB, let toneMapper {
            let result = toneMapper.process(
                pixelBuffer: pixelBuffer, elPixelBuffer: elPixelBuffer,
                colorParams: colorParams, metadata: metadata, strategy: strategy)
            pb = result.pixelBuffer
            cp = result.colorParams
        } else {
            pb = pixelBuffer
            cp = colorParams
        }
        attachColorParams(pb, colorParams: cp)
        Self.applyRouteBAttachments(pb, rpuData: isRouteB ? metadata.doviRpuData : nil)
        updatePreferredDynamicRangeIfNeeded(high: isRouteB)
        let cmPts = CMTime(seconds: pts, preferredTimescale: 90000)
        guard let sbuf = makeSampleBuffer(pixelBuffer: pb, pts: cmPts) else {
            logger.info("ASBDL: makeSampleBuffer failed at pts=\(pts)")
            return
        }
        // P2: render() runs on the display thread (CVDisplayLink / fallback
        // queue), not main. A CALayer property write there enters an implicit
        // CATransaction that is never committed (implicit transactions only
        // auto-commit on the main runloop) — the reveal never takes effect and
        // the layer stays hidden forever (black screen with normal audio, plus
        // "deleted thread with uncommitted CATransaction" at teardown).
        //
        // The write must NOT be wrapped in an explicit begin/commit here either:
        // an outermost commit on this thread also runs layout for every UIView
        // whose layout is pending, which touches the Auto Layout engine off-main
        // and throws (NSISEngine optimize → abort, zyno#337). So reveal only on
        // the first frame after clear() and do it on the main thread.
        if needsReveal.withLock({ shouldReveal in
            guard shouldReveal else { return false }
            shouldReveal = false
            return true
        }) {
            revealOnMain()
        }
        displayLayer.enqueue(sbuf)
    }

    /// True while the layer is hidden by `clear()` and the next rendered frame
    /// must reveal it. The layer starts visible, so this starts false.
    private let needsReveal = OSAllocatedUnfairLock(initialState: false)
    private let highDynamicRangeActive = OSAllocatedUnfairLock(initialState: false)

    private func updatePreferredDynamicRangeIfNeeded(high: Bool) {
#if os(iOS) || os(tvOS)
        let changed = highDynamicRangeActive.withLock { current -> Bool in
            guard current != high else { return false }
            current = high
            return true
        }
        guard changed else { return }
        if #available(iOS 26.0, tvOS 26.0, *) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let target = self.highDynamicRangeActive.withLock { $0 }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.displayLayer.preferredDynamicRange = target ? .high : .standard
                CATransaction.commit()
            }
        }
#endif
    }

    private func revealOnMain() {
        DispatchQueue.main.async { [weak self] in
            // clear() may have run again before this block got to execute.
            guard let self, !self.needsReveal.withLock({ $0 }) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.displayLayer.isHidden = false
            CATransaction.commit()
        }
    }

    private func attachColorParams(_ pb: CVPixelBuffer, colorParams: VideoColorParams) {
        let transfer: CFString
        let primaries: CFString
        let matrix: CFString
        switch colorParams.transfer {
        case .pq:  transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .sdr: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        switch colorParams.matrix {
        case .bt709:  primaries = kCVImageBufferColorPrimaries_ITU_R_709_2; matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .bt2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020; matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .bt601:  primaries = kCVImageBufferColorPrimaries_SMPTE_C; matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldNotPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldNotPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldNotPropagate)
    }

    public func flush() {
        displayLayer.flushAndRemoveImage()
    }

    public func clear() {
        displayLayer.flushAndRemoveImage()
        updatePreferredDynamicRangeIfNeeded(high: false)
        // Show black to satisfy the protocol "show black" contract.
        needsReveal.withLock { $0 = true }
        displayLayer.isHidden = true
    }

    public func configure(codedSize: CGSize, sampleAspectRatio: Double) {
        // ASBDL auto-configures from sample buffers; no explicit config needed.
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbufStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbufStatus == noErr, let sbuf = sampleBuffer else { return nil }
        return sbuf
    }
}
