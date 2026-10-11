import AudioToolbox
import CoreAudio
import Foundation

/// CoreAudio helpers: pick the right microphone and duck playback while dictating.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBluetooth: Bool
        let isBuiltIn: Bool
    }

    private static func prop<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var s: Unmanaged<CFString>?
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s) == noErr, let v = s else { return "" }
        return v.takeRetainedValue() as String
    }

    static func inputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Has input channels?
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return nil }
            var transport: UInt32 = 0
            _ = prop(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
            return Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                          isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                          isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, &id) ? id : nil
    }

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id) ? id : nil
    }

    /// The mic to record from. "Automatic" avoids Bluetooth headset mics: using AirPods' mic flips them into the
    /// low-quality call profile (your music turns to mush) and clips your first words while it negotiates.
    static func chosenInput() -> Device? {
        let all = inputDevices()
        let uid = Settings.shared.micUID
        if !uid.isEmpty, let d = all.first(where: { $0.uid == uid }) { return d }
        let def = defaultInput().flatMap { id in all.first { $0.id == id } }
        if let def, !def.isBluetooth { return def }
        return all.first(where: \.isBuiltIn) ?? def ?? all.first
    }

    // MARK: Ducking

    private static func volume(_ dev: AudioDeviceID) -> Float32? {
        var v: Float32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    @discardableResult
    private static func setVolume(_ dev: AudioDeviceID, _ v: Float32) -> Bool {
        var v = v
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private static let duckKey = "duckedVolume"

    /// Lowers whatever is playing to 25% while you talk. The original level is saved first so a crash mid-dictation
    /// can't leave your Mac quiet (it's restored on next launch).
    static func duck() {
        guard Settings.shared.duckAudio, let dev = defaultOutput(), let v = volume(dev), v > 0.05,
              UserDefaults.standard.object(forKey: duckKey) == nil else { return }
        UserDefaults.standard.set(Double(v), forKey: duckKey)
        setVolume(dev, v * 0.25)
    }

    static func unduck() {
        guard let saved = UserDefaults.standard.object(forKey: duckKey) as? Double else { return }
        UserDefaults.standard.removeObject(forKey: duckKey)
        if let dev = defaultOutput() { setVolume(dev, Float32(saved)) }
    }
}
