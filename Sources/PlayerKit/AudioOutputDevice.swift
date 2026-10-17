#if os(macOS)
import CoreAudio
import Foundation

/// 系统识别到的一个音频**输出**设备(MacBook 扬声器、HDMI/DP 显示器、USB 声卡、蓝牙、AirPlay……)。
/// zyno#223:供设置页列出并选择,只影响本应用,不改系统默认输出。
public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public enum Transport: Sendable, Equatable {
        case builtIn, hdmi, displayPort, usb, bluetooth, airPlay
        case thunderbolt, pci, virtual, aggregate, other
    }

    /// CoreAudio 的 AudioDeviceID(进程内有效,拔插后会变;持久化请用 `uid`)。
    public let id: UInt32
    /// 稳定的设备 UID,持久化与跨会话匹配都用它。
    public let uid: String
    public let name: String
    public let transport: Transport

    public init(id: UInt32, uid: String, name: String, transport: Transport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    /// 物理设备。虚拟声卡(录屏/回环软件)与聚合设备默认不展示给用户。
    public var isPhysical: Bool { transport != .virtual && transport != .aggregate }

    /// CoreAudio transport type → 本模型的 Transport(纯映射,便于单测)。
    public static func transport(fromRaw raw: UInt32) -> Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }
}

/// CoreAudio 输出设备枚举与变化监听。
public enum AudioOutputDevices {
    /// 所有「有输出声道」的设备(含虚拟/聚合,过滤由调用方按 `isPhysical` 决定)。
    public static func all() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(device(for:))
    }

    /// 系统当前默认输出设备的 UID。
    public static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// UID → 当前的 AudioDeviceID;设备已拔出返回 nil(调用方应回退「跟随系统」)。
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }.map { AudioDeviceID($0.id) }
    }

    /// 设备列表或默认输出变化时回调(主线程)。返回的 token 持有监听,释放即取消。
    public static func observeChanges(_ handler: @escaping () -> Void) -> AnyObject {
        DeviceObserver(handler: handler)
    }

    // MARK: - Private

    private static func device(for id: AudioDeviceID) -> AudioOutputDevice? {
        guard outputChannelCount(id) > 0,
              !boolProperty(id, kAudioDevicePropertyIsHidden),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioOutputDevice(id: UInt32(id), uid: uid, name: name,
                                 transport: AudioOutputDevice.transport(fromRaw: transportType(id)))
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func boolProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// 监听「设备列表」与「默认输出设备」两个全局属性。
    private final class DeviceObserver {
        private let handler: () -> Void
        private var blocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        init(handler: @escaping () -> Void) {
            self.handler = handler
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handler() }
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                       DispatchQueue.main, block) == noErr {
                    blocks.append((address, block))
                }
            }
        }

        deinit {
            for (var address, block) in blocks {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                       DispatchQueue.main, block)
            }
        }
    }
}
#endif
