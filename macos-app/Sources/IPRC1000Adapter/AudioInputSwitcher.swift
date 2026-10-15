import CoreAudio
import Foundation

/// 切换 macOS 的默认输入设备。
///
/// 用途：遥控器语音经「HCI 流 → 解码 → BlackHole 2ch」后，需要把**系统默认输入**
/// 指向 BlackHole 2ch，输入法/听写（豆包等）才会把它当麦克风。
///
/// 全部走 CoreAudio 公开 API，不需要额外权限，随时可切回内置麦克风。
enum AudioInputSwitcher {

    static let blackHoleNames = ["BlackHole 2ch", "BlackHole 2ch (2ch)", "BlackHole 16ch"]

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - 查询

    static func deviceName(_ device: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        // 拿的是 CFStringRef（指针），size 要用可选指针的大小
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return result == noErr ? (name as String) : "<未知设备 \(device)>"
    }

    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    static func defaultInput() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    // MARK: - 查找与切换

    static func findInputDevice(named names: [String]) -> AudioDeviceID? {
        for device in allDevices() {
            guard inputChannelCount(device) > 0 else { continue }
            let name = deviceName(device)
            if names.contains(where: { name == $0 || name.hasPrefix($0) }) { return device }
        }
        return nil
    }

    @discardableResult
    static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        ) == noErr
    }

    /// 找出系统里第一个**非 BlackHole** 的输入设备（用于「切回来」）。
    static func firstNonBlackHoleInput() -> AudioDeviceID? {
        for device in allDevices() {
            guard inputChannelCount(device) > 0 else { continue }
            let name = deviceName(device)
            if !name.localizedCaseInsensitiveContains("BlackHole") { return device }
        }
        return nil
    }
}
