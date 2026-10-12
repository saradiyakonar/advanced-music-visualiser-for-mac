import AudioToolbox
import CoreAudio
import Foundation

enum AudioTapError: Error, CustomStringConvertible {
    case noAudioProcess(String)
    case coreAudio(String, OSStatus)

    var description: String {
        switch self {
        case .noAudioProcess(let id): "No audio process found for \(id) (is it playing?)"
        case .coreAudio(let what, let status): "\(what) failed (OSStatus \(status))"
        }
    }
}

/// Captures one app's audio output through a Core Audio process tap (macOS 14.2+) and
/// delivers it as mono Float32 with the buffer's host time in seconds.
///
/// The tap is private and unmuted: the music keeps playing normally.
final class AudioTapCapture {
    private(set) var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "album-visualiser.audio-tap", qos: .userInteractive)
    private var mono: [Float] = []

    var isRunning: Bool { procID != nil }

    /// Audio process objects whose bundle id is `bundleID` or one of its helpers
    /// (Spotify plays audio from a helper process).
    static func audioProcesses(forBundleID bundleID: String) -> [AudioObjectID] {
        CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .filter { obj in
                guard let bid = CoreAudioProperty.string(obj, kAudioProcessPropertyBundleID) else { return false }
                return bid == bundleID || bid.hasPrefix(bundleID + ".")
            }
    }

    func start(bundleID: String, onSamples: @escaping (UnsafeBufferPointer<Float>, Double) -> Void) throws {
        stop()
        let processes = Self.audioProcesses(forBundleID: bundleID)
        guard !processes.isEmpty else { throw AudioTapError.noAudioProcess(bundleID) }

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "Album Visualiser"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw AudioTapError.coreAudio("Create process tap", status) }
        tapID = tap

        let format = CoreAudioProperty.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        let outputID: AudioObjectID = CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                              kAudioHardwarePropertyDefaultOutputDevice,
                                                              default: AudioObjectID(kAudioObjectUnknown))
        let outputUID = CoreAudioProperty.string(outputID, kAudioDevicePropertyDeviceUID) ?? ""

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Album Visualiser Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { stop(); throw AudioTapError.coreAudio("Create aggregate device", status) }
        aggregateID = agg

        let channels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inData, inTime, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = buffers.first, let data = first.mData else { return }
            let hostSeconds = Double(AudioConvertHostTimeToNanos(inTime.pointee.mHostTime)) / 1e9

            if interleaved {
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let src = data.assumingMemoryBound(to: Float.self)
                if self.mono.count != frames { self.mono = [Float](repeating: 0, count: frames) }
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += src[f * channels + c] }
                    self.mono[f] = sum / Float(channels)
                }
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                if self.mono.count != frames { self.mono = [Float](repeating: 0, count: frames) }
                for i in 0..<frames { self.mono[i] = 0 }
                for b in buffers {
                    guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { self.mono[i] += p[i] }
                }
                let n = Float(buffers.count)
                for i in 0..<frames { self.mono[i] /= n }
            }
            self.mono.withUnsafeBufferPointer { onSamples($0, hostSeconds) }
        }
        guard status == noErr, let proc else { stop(); throw AudioTapError.coreAudio("Create IO proc", status) }
        procID = proc

        status = AudioDeviceStart(agg, proc)
        guard status == noErr else { stop(); throw AudioTapError.coreAudio("Start device", status) }
    }

    func stop() {
        if let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
