import CoreAudio
import Foundation

/// Changes only the default input route; the output route is never written.
enum SystemAudio {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var property = address(selector), value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &value) == noErr, value != 0 else { return nil }
        return value
    }
    static func uid(_ device: AudioDeviceID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static var inputUID: String? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(uid) }
    static func selectInput(uid target: String) throws {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        func check(_ status: OSStatus) throws {
            if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices))
        guard var device = devices.first(where: { uid($0) == target }) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadDeviceError))
        }
        var streams = address(kAudioDevicePropertyStreams)
        streams.mScope = kAudioDevicePropertyScopeInput
        var streamSize: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize))
        guard streamSize > 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadDeviceError)) }
        property = address(kAudioHardwarePropertyDefaultInputDevice)
        try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device))
        guard inputUID == target else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareUnspecifiedError)) }
    }
}
