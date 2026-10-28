import Foundation
import CoreMedia
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category:"dovi.system.fd")

/// Native DV system path, part 1: build the `CMVideoFormatDescription` the
/// system decoder needs to treat a length-prefixed HEVC sample as Dolby
/// Vision (design §5.2).
///
/// The codec type is `'dvh1'` (`kCMVideoCodecType_DolbyVisionHEVC`) and the DV
/// configuration atom (`dvcC` / `dvvC`) is re-serialized from the container's
/// `AVDOVIDecoderConfigurationRecord` — the spike proved the declaration in
/// the format description, not the container, is what switches the system
/// decoder into DV mode (design §3, conclusions 2/3).
enum SystemDVFormatDescription {

    /// Serialize a DV decoder configuration record into the 24-byte payload of
    /// a `dvcC` (profile ≤ 7) or `dvvC` (profile > 7) atom.
    ///
    /// Bit layout per ffmpeg `ff_isom_put_dvcc_dvvc` (libavformat/dovi_isom.c;
    /// byte-for-byte cross-checked against `Tests/scripts/patch_dvcc.py`):
    /// ```
    /// [0] dv_version_major   [1] dv_version_minor
    /// [2..3] profile(7b) | level(6b) | rpu_present(1b) | el_present(1b) | bl_present(1b)
    /// [4] bl_signal_compat_id(4b) | dv_md_compression(2b) | reserved(2b)
    /// [5..23] reserved = 0
    /// ```
    static func configBox(_ r: AVDOVIDecoderConfigurationRecord) -> (type: String, payload: Data) {
        var payload = [UInt8](repeating: 0, count: 24)
        payload[0] = r.dv_version_major
        payload[1] = r.dv_version_minor
        let word = (UInt16(r.dv_profile) << 9)
                 | (UInt16(r.dv_level) << 3)
                 | (UInt16(r.rpu_present_flag & 1) << 2)
                 | (UInt16(r.el_present_flag & 1) << 1)
                 | UInt16(r.bl_present_flag & 1)
        payload[2] = UInt8(word >> 8)
        payload[3] = UInt8(word & 0xFF)
        payload[4] = (r.dv_bl_signal_compatibility_id << 4)
                   | ((r.dv_md_compression & 0b11) << 2)
        let type = r.dv_profile > 7 ? "dvvC" : "dvcC"
        return (type, Data(payload))
    }

    /// Build the `dvh1` format description: `hvcC` (from the container's
    /// extradata, parsed by `VTVideoDecoder.parseHVCC` on the decode side) plus
    /// the DV config atom via `SampleDescriptionExtensionAtoms`.
    /// Returns nil when CoreMedia rejects the construction — callers treat nil
    /// as "system path unavailable, fall back to software".
    static func make(hvcC: [UInt8], width: Int32, height: Int32,
                     dovi: AVDOVIDecoderConfigurationRecord) -> CMVideoFormatDescription? {
        let (dvType, dvPayload) = configBox(dovi)
        let atoms: [String: Any] = [
            "hvcC": Data(hvcC),
            dvType: dvPayload,
        ]
        let ext: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms
        ]
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_DolbyVisionHEVC,
            width: width, height: height,
            extensions: ext as CFDictionary,
            formatDescriptionOut: &desc)
        if status != noErr {
            logger.error("dvh1 format description create failed: \(status)")
            return nil
        }
        logger.info("dvh1 FD created: \(dvType) profile=\(dovi.dv_profile) compat=\(dovi.dv_bl_signal_compatibility_id)")
        return desc
    }
}
