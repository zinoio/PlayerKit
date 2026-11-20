import Foundation
#if os(macOS)
import CoreAudio
#elseif canImport(AVFAudio)
import AVFAudio
#endif

/// 输出设备原生采样率探测(PlayerKit#76)。
///
/// 音频输出链(AudioClock/AudioQueue/AudioUnit)必须运行在与设备一致的
/// 采样率域:内容率(如 AAC 44.1k)≠设备率(如 48k)时,AudioQueue 内部的
/// AQConverterThread 会让 时钟的内容域记账 与 设备实际消费 错位——实测
/// 44.1k 内容的视频被 paced 出 0.9× 的匀速拖帧(fps 25→22.5)。解码器侧
/// 把 PCM 重采样到设备率即可让计数域=消费域,时钟语义恢复正确。
enum AudioDeviceSampleRate {
    /// 设备原生率(Int32 Hz)。探测失败回落 48000(绝大多数输出设备的默认)。
    static func preferred() -> Int32 {
        #if os(macOS)
        if let hz = macOSDefaultOutputSampleRate() {
            return Int32(hz)
        }
        return 48000
        #elseif os(iOS) || os(tvOS)
        let hz = AVAudioSession.sharedInstance().sampleRate
        return hz > 0 ? Int32(hz) : 48000
        #else
        return 48000
        #endif
    }

    #if os(macOS)
    /// 默认输出设备的 nominal sample rate(CoreAudio)。失败返回 nil。
    private static func macOSDefaultOutputSampleRate() -> Float64? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // SDK 27.2 将 kAudioObjectSystemObject 导出为 Int32,显式转 AudioObjectID
        let systemObject = AudioObjectID(UInt32(kAudioObjectSystemObject))
        let devStatus = AudioObjectGetPropertyData(
            systemObject, &devAddr, 0, nil, &size, &deviceID)
        guard devStatus == noErr, deviceID != 0 else { return nil }

        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let rateStatus = AudioObjectGetPropertyData(
            deviceID, &rateAddr, 0, nil, &size, &rate)
        guard rateStatus == noErr, rate > 0 else { return nil }
        return rate
    }
    #endif
}
