/// Rolling estimate of the video stream bitrate from demuxed packet sizes
/// (EMA over bytes × 8 × fps). Fallback for containers that do not declare a
/// stream bitrate; the backend reads it out periodically for the transport HUD.
struct VideoBitrateEstimator {
    private(set) var bpsEMA: Double = 0

    /// Feed one video packet. Unusable inputs (no frame rate, empty packet)
    /// are ignored so the estimate stays meaningful.
    mutating func record(packetBytes: Int, frameRate: Double) {
        guard packetBytes > 0, frameRate > 0 else { return }
        let sample = 8.0 * Double(packetBytes) * frameRate
        bpsEMA = bpsEMA == 0 ? sample : bpsEMA * 0.9 + sample * 0.1
    }

    /// Current rolling estimate in bits/second (0 until the first sample).
    var bitsPerSecond: Int64 { Int64(bpsEMA) }
}
