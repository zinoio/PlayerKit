import Foundation

/// Phase 3 (macOS 软解完整 P7 FEL): extracts Dolby Vision Enhancement Layer (EL)
/// Annex-B HEVC bitstreams carried inside `NAL_UNSPEC63` (NAL unit type 63)
/// sub-NALUs of single-track MKV/MP4 or Annex-B P7 packets.
///
/// In single-track P7 MKV/Remux packets:
///   `AUD | VPS/SPS/PPS | SEI | BL VCL | EL unspec63 × N | RPU unspec62`
/// Each `UNSPEC63` NALU carries a 2-byte HEVC NAL header (`0x7E 0x01`) followed
/// by the raw EL HEVC NALU (either already starting with a 3/4-byte Annex-B
/// start code, or a bare HEVC NALU requiring a `00 00 00 01` prefix).
public enum DoviElExtractor {

    /// Extract all `NAL_UNSPEC63` payloads from `packet` and concatenate them
    /// into an Annex-B HEVC frame ready for an independent HEVC EL decoder.
    /// Returns `nil` when the packet contains no EL NALUs (zero-cost fast path
    /// for non-P7 / MEL / P8 / SDR packets).
    public static func extractAnnexB(from packet: Data, isLengthPrefixed: Bool) -> Data? {
        let count = packet.count
        guard count >= 6 else { return nil }
        return packet.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var out = [UInt8]()
            var foundEl = false

            if isLengthPrefixed {
                var i = 0
                while i + 4 <= count {
                    let nalLen = (Int(base[i]) << 24)
                        | (Int(base[i + 1]) << 16)
                        | (Int(base[i + 2]) << 8)
                        | Int(base[i + 3])
                    let hdr = i + 4
                    guard nalLen >= 2, hdr + nalLen <= count else { break }
                    let nalType = (base[hdr] >> 1) & 0x3F
                    if nalType == 63, nalLen > 2 {
                        appendElPayload(base + hdr + 2, length: nalLen - 2, to: &out)
                        foundEl = true
                    }
                    i = hdr + nalLen
                }
            } else {
                var i = 0
                while i + 3 < count {
                    let scLen: Int
                    if i + 4 <= count, base[i] == 0, base[i + 1] == 0, base[i + 2] == 0, base[i + 3] == 1 {
                        scLen = 4
                    } else if base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
                        scLen = 3
                    } else {
                        i += 1
                        continue
                    }
                    let start = i + scLen
                    guard start + 2 <= count else { break }
                    var end = start + 1
                    while end + 3 <= count {
                        if base[end] == 0, base[end + 1] == 0,
                           (base[end + 2] == 1 || (end + 3 < count && base[end + 2] == 0 && base[end + 3] == 1)) {
                            break
                        }
                        end += 1
                    }
                    if end + 3 > count { end = count }
                    let nalLen = end - start
                    if nalLen > 2 {
                        let nalType = (base[start] >> 1) & 0x3F
                        if nalType == 63 {
                            appendElPayload(base + start + 2, length: nalLen - 2, to: &out)
                            foundEl = true
                        }
                    }
                    i = end
                }
            }

            return foundEl && !out.isEmpty ? Data(out) : nil
        }
    }

    private static func appendElPayload(_ ptr: UnsafePointer<UInt8>, length: Int, to out: inout [UInt8]) {
        let hasStartCode = (length >= 4 && ptr[0] == 0 && ptr[1] == 0 && ptr[2] == 0 && ptr[3] == 1)
            || (length >= 3 && ptr[0] == 0 && ptr[1] == 0 && ptr[2] == 1)
        if !hasStartCode {
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        }
        out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: length))
    }
}

/// Bounded PTS-indexed cache pairing decoded EL frames with decoded BL frames.
/// Handles slight B-frame reorder skew between independent BL and EL decoders
/// while bounding memory and dropping stale frames cleanly.
public struct DoviElFramePairer<Frame> {
    private struct Entry {
        let pts: Double
        let frame: Frame
    }

    private var entries: [Entry] = []
    public let capacity: Int
    public let tolerance: Double

    public init(capacity: Int = 16, tolerance: Double = 0.020) {
        self.capacity = max(1, capacity)
        self.tolerance = max(0, tolerance)
    }

    public var count: Int { entries.count }

    public mutating func store(_ frame: Frame, pts: Double) {
        guard pts.isFinite else { return }
        if let idx = entries.firstIndex(where: { abs($0.pts - pts) <= 1e-6 }) {
            entries[idx] = Entry(pts: pts, frame: frame)
        } else {
            entries.append(Entry(pts: pts, frame: frame))
            entries.sort { $0.pts < $1.pts }
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Pop the closest EL frame within `tolerance` of `pts`, pruning any older
    /// entries strictly before `pts - tolerance`.
    public mutating func take(matching pts: Double) -> Frame? {
        guard pts.isFinite, !entries.isEmpty else { return nil }
        entries.removeAll { $0.pts < pts - tolerance }
        var bestIdx: Int?
        var bestDiff = tolerance
        for (i, e) in entries.enumerated() {
            let diff = abs(e.pts - pts)
            if diff <= bestDiff {
                bestDiff = diff
                bestIdx = i
            }
        }
        guard let idx = bestIdx else { return nil }
        return entries.remove(at: idx).frame
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
