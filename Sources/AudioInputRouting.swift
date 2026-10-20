import AVFoundation
import CoreAudio
import AudioToolbox

// Choose an input for this engine only; do not change the system's audio settings.
enum AudioInputRouting {
    static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func device(preferBuiltIn: Bool) -> AudioDeviceID? {
        guard let current = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice), current != kAudioObjectUnknown else { return nil }
        let transport = value(current, kAudioDevicePropertyTransportType)
        guard preferBuiltIn, transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return current }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return current }
        guard size > 0 else { return current }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return current }
        return devices.first { id in
            guard value(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr && bytes > 0
        } ?? current
    }

}

// The audio callback writes one latest value; the UI samples it instead of queuing
// one MainActor task for every audio buffer. Silence detection has its own timestamp.
final class AudioLevelMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Double = 0
    private var sound = ContinuousClock.now
    func update(_ value: Double) { lock.lock(); level = value; if value > 0.22 { sound = .now }; lock.unlock() }
    func snapshot() -> (Double, ContinuousClock.Instant) { lock.lock(); defer { lock.unlock() }; return (level, sound) }
}
