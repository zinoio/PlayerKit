import Foundation
import CoreGraphics
import CFFmpeg

/// 跨线程中断标志:`avio` 的 `interrupt_callback` 在网络阻塞读期间反复
/// 轮询它,回调返回非 0 时 FFmpeg 立即中止当前阻塞操作(以 `AVERROR_EXIT`
/// 返回),不必等 `rw_timeout`(15s)超时。
private final class FrameExtractorInterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// C 回调:返回非 0 表示"立即中止当前阻塞 I/O"。只读标志,不做分配。
private func frameExtractorInterruptCallback(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let flag = Unmanaged<FrameExtractorInterruptFlag>.fromOpaque(opaque).takeUnretainedValue()
    return flag.isSet ? 1 : 0
}

/// 按时间抽一帧缩略图(云模式 seek 预览用,zyno#445 ⑤)。
///
/// 与播放管线完全独立:自己的 `AVFormatContext` + 解码器,seek 到目标前
/// 关键帧后解一帧,经 libswscale 缩放成不超过 `Options.maxWidth×maxHeight`
/// 的 RGBA 位图。用内嵌 FFmpeg 是为了支持 **MKV**(AVFoundation 的
/// AVAssetImageGenerator 不能 demux Matroska,而云盘 UHD BluRay 几乎全是
/// MKV)——这是本类型存在的唯一理由。
///
/// 线程模型:所有 FFmpeg 状态只在私有串行队列上访问;公开方法 async 包装,
/// 调用方(通常是 UI 层防抖后的 Task)不会阻塞主线程。
///
/// 会话复用:同一 `url+headers` 的连续抽帧共用同一个 demuxer(只 seek,
/// 不重开);换链/失败后调用 `invalidate()` 强制下次重开。
///
/// 已知限制(HDR):预览帧不做 tone-map,PQ/BT.2020 片源的缩略图会比
/// 实际播放偏灰——缩略图场景可接受,不要用它判断最终画质。
public final class VideoFrameExtractor: @unchecked Sendable {

    public struct Options: Sendable {
        public var maxWidth: Int
        public var maxHeight: Int
        public init(maxWidth: Int = 320, maxHeight: Int = 180) {
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
        }
    }

    public enum ExtractError: Error, Equatable {
        case invalidTime
        case openFailed(Int32)
        case noVideoStream
        case decoderOpenFailed(Int32)
        case seekFailed(Int32)
        case decodeFailed
        case convertFailed
    }

    private let options: Options
    private let queue = DispatchQueue(label: "PlayerKit.VideoFrameExtractor")
    /// 阻塞 I/O 中断标志:invalidate() 置位后,卡在网络读上的 av_read_frame
    /// 尽快返回,不必等 rw_timeout(15s)超时。
    private let interruptFlag = FrameExtractorInterruptFlag()

    // 以下状态只在 queue 上访问。
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStreamIndex: Int32 = -1
    private var currentURL: String = ""
    private var currentHeadersBlob: String = ""

    public init(options: Options = Options()) {
        self.options = options
        avformat_network_init()
    }

    deinit {
        queue.sync { closeSession() }
    }

    /// 抽 `atSeconds` 处的一帧。同 url+headers 复用已打开的容器。
    public func frame(url: URL, headers: [String: String],
                      atSeconds: Double) async throws -> CGImage {
        guard atSeconds.isFinite, atSeconds >= 0 else { throw ExtractError.invalidTime }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let image = try self.extractSync(url: url, headers: headers,
                                                     atSeconds: atSeconds)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 作废当前会话(直链更换/失败重试前调用),下次 frame 会重开容器。
    /// 先置中断标志让阻塞中的网络读立即返回,再入队关闭(队列串行保证安全)。
    public func invalidate() async {
        interruptFlag.set(true)
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeSession()
                self.interruptFlag.set(false)
                continuation.resume()
            }
        }
    }

    // MARK: - queue-confined implementation

    private func extractSync(url: URL, headers: [String: String],
                             atSeconds: Double) throws -> CGImage {
        // invalidate() 的中断标志可能在任务入队前仍立着;每个任务开始复位,
        // 否则本次 open/read 会被立刻中断。
        interruptFlag.set(false)
        let blob = headers.isEmpty ? "" :
            headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
        if fmtCtx == nil || url.absoluteString != currentURL || blob != currentHeadersBlob {
            try open(urlString: url.absoluteString, headersBlob: blob)
        }
        return try decodeFrame(atSeconds: atSeconds)
    }

    private func open(urlString: String, headersBlob: String) throws {
        closeSession()
        var opts: OpaquePointer?
        if !headersBlob.isEmpty {
            av_dict_set(&opts, "headers", headersBlob, 0)
        }
        // 网络读超时(µs):直链失效时快速失败,交给调用方换链重试。
        av_dict_set(&opts, "rw_timeout", "15000000", 0)
        // 抽帧只需要找到视频流、解一帧,不需要完整探测:压低探测预算,
        // 少跟播放共用同一条 CDN 链路抢带宽(真机曾把播放侧读到 I/O error)。
        av_dict_set(&opts, "probesize", "1048576", 0)        // 1MB
        av_dict_set(&opts, "analyzeduration", "500000", 0)   // 0.5s

        // 预分配 AVFormatContext 并挂上中断回调:avformat_open_input /
        // av_read_frame 在网络阻塞读期间会轮询它,invalidate() 置位后立即
        // 中止,而不是干等 rw_timeout 的 15 秒。
        guard let allocated = avformat_alloc_context() else {
            throw ExtractError.openFailed(-1)
        }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: frameExtractorInterruptCallback,
            opaque: Unmanaged.passUnretained(interruptFlag).toOpaque())

        var ctx: UnsafeMutablePointer<AVFormatContext>? = allocated
        let openRet = avformat_open_input(&ctx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard openRet == 0, let ctx else { throw ExtractError.openFailed(openRet) }

        let infoRet = avformat_find_stream_info(ctx, nil)
        guard infoRet >= 0 else {
            var closing: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&closing)
            throw ExtractError.openFailed(infoRet)
        }

        let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard idx >= 0, let stream = ctx.pointee.streams[Int(idx)] else {
            var closing: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&closing)
            throw ExtractError.noVideoStream
        }

        let par = stream.pointee.codecpar.pointee
        guard let codec = avcodec_find_decoder(par.codec_id),
              let cctx = avcodec_alloc_context3(codec) else {
            var closing: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&closing)
            throw ExtractError.decoderOpenFailed(-1)
        }
        var setupRet = avcodec_parameters_to_context(cctx, stream.pointee.codecpar)
        if setupRet >= 0 { setupRet = avcodec_open2(cctx, codec, nil) }
        guard setupRet >= 0 else {
            var closingCtx: UnsafeMutablePointer<AVCodecContext>? = cctx
            avcodec_free_context(&closingCtx)
            var closing: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&closing)
            throw ExtractError.decoderOpenFailed(setupRet)
        }
        fmtCtx = ctx
        codecCtx = cctx
        videoStreamIndex = idx
        currentURL = urlString
        currentHeadersBlob = headersBlob
    }

    private func closeSession() {
        if codecCtx != nil {
            var cctx: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&cctx)
        }
        codecCtx = nil
        if fmtCtx != nil {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = fmtCtx
            avformat_close_input(&ctx)
        }
        fmtCtx = nil
        videoStreamIndex = -1
        currentURL = ""
        currentHeadersBlob = ""
    }

    private func decodeFrame(atSeconds target: Double) throws -> CGImage {
        guard let ctx = fmtCtx, let cctx = codecCtx,
              let stream = ctx.pointee.streams[Int(videoStreamIndex)] else {
            throw ExtractError.openFailed(-1)
        }
        let tb = stream.pointee.time_base
        guard tb.den > 0 else { throw ExtractError.seekFailed(-1) }

        // 目标时间(秒)→ 流时间基;向后 seek 到目标前最近关键帧。
        let targetTs = av_rescale_q(Int64(target * 1_000_000),
                                    AVRational(num: 1, den: 1_000_000), tb)
        let seekRet = av_seek_frame(ctx, videoStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD)
        guard seekRet >= 0 else { throw ExtractError.seekFailed(seekRet) }
        avcodec_flush_buffers(cctx)

        guard let frame = av_frame_alloc() else { throw ExtractError.decodeFailed }

        var packet = AVPacket()
        // 关键帧级预览(2026-11-04 降压改造):seek 已落在目标前最近关键帧,
        // 这里解出第一帧就返回——不逐帧解到精确目标。4K HEVC 片源下"解到
        // 精确目标"要读/解一整段 GOP(几十 MB、耗时数秒),频繁拖动会把
        // 播放侧的 CDN 连接一起拖垮(真机出现 demux I/O error);预览气泡
        // 对 ≤1 个 GOP 的偏差无感。
        while av_read_frame(ctx, &packet) >= 0 {
            if packet.stream_index != videoStreamIndex {
                av_packet_unref(&packet)
                continue
            }
            let sendRet = avcodec_send_packet(cctx, &packet)
            av_packet_unref(&packet)
            if sendRet < 0 { continue }

            while true {
                let recvRet = avcodec_receive_frame(cctx, frame)
                if recvRet != 0 { break }   // EAGAIN/EOF/错误:继续读包
                let image = convert(frame)
                freeFrame(frame)
                if let image { return image }
                throw ExtractError.convertFailed
            }
        }
        freeFrame(frame)
        throw ExtractError.decodeFailed
    }

    private func freeFrame(_ frame: UnsafeMutablePointer<AVFrame>?) {
        guard let frame else { return }
        var mutable: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&mutable)
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, min(Double(options.maxWidth) / Double(srcW),
                                 Double(options.maxHeight) / Double(srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))

        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
        guard let sws = sws_getContext(Int32(srcW), Int32(srcH), srcFormat,
                                       Int32(dstW), Int32(dstH), AV_PIX_FMT_RGBA,
                                       Int32(SWS_BILINEAR.rawValue),
                                       nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }

        let rowBytes = dstW * 4
        var buffer = [UInt8](repeating: 0, count: rowBytes * dstH)
        var srcSlice: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0),
            UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2),
            UnsafePointer(frame.pointee.data.3),
        ]
        var srcStride: [Int32] = [
            frame.pointee.linesize.0, frame.pointee.linesize.1,
            frame.pointee.linesize.2, frame.pointee.linesize.3,
        ]
        var dstStride = Int32(rowBytes)
        let wrote = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var dst: [UnsafeMutablePointer<UInt8>?] = [
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
            ]
            return sws_scale(sws, &srcSlice, &srcStride, 0, Int32(srcH),
                             &dst, &dstStride)
        }
        guard wrote > 0 else { return nil }

        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: dstW, height: dstH,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
