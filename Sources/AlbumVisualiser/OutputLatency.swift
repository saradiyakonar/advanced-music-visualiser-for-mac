import CoreAudio
import Foundation

struct OutputDeviceInfo: Equatable {
    var uid: String
    var name: String
    var isBluetooth: Bool
    /// Seconds between audio leaving the app and reaching the device's output, as reported.
    var reportedLatency: Double
}

/// The current default output device and how late its sound is, per Core Audio.
enum OutputLatency {
    static func current() -> OutputDeviceInfo? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let dev: AudioObjectID = CoreAudioProperty.value(system, kAudioHardwarePropertyDefaultOutputDevice,
                                                         default: AudioObjectID(kAudioObjectUnknown))
        guard dev != kAudioObjectUnknown else { return nil }

        let out = kAudioObjectPropertyScopeOutput
        let uid = CoreAudioProperty.string(dev, kAudioDevicePropertyDeviceUID) ?? "unknown"
        let name = CoreAudioProperty.string(dev, kAudioObjectPropertyName) ?? "Output"
        let transport: UInt32 = CoreAudioProperty.value(dev, kAudioDevicePropertyTransportType, default: 0)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

        let rate: Double = CoreAudioProperty.value(dev, kAudioDevicePropertyNominalSampleRate, default: 48_000)
        let deviceLatency: UInt32 = CoreAudioProperty.value(dev, kAudioDevicePropertyLatency, scope: out, default: 0)
        let safety: UInt32 = CoreAudioProperty.value(dev, kAudioDevicePropertySafetyOffset, scope: out, default: 0)
        let bufferFrames: UInt32 = CoreAudioProperty.value(dev, kAudioDevicePropertyBufferFrameSize, scope: out, default: 0)
        let streamLatency: UInt32 = CoreAudioProperty.array(dev, kAudioDevicePropertyStreams, scope: out).first
            .map { CoreAudioProperty.value($0, kAudioStreamPropertyLatency, default: UInt32(0)) } ?? 0

        let frames = Double(deviceLatency) + Double(safety) + Double(bufferFrames) + Double(streamLatency)
        return OutputDeviceInfo(uid: uid, name: name, isBluetooth: isBluetooth,
                                reportedLatency: rate > 0 ? frames / rate : 0)
    }

    /// Calls `handler` on the main queue whenever the default output device changes.
    static func observeChanges(_ handler: @escaping () -> Void) {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
    }
}
