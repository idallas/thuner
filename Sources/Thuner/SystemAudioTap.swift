import AVFoundation
import CoreAudio
import Foundation
import os

/// "System Audio" as an input: what this Mac is playing (YouTube Music in a browser, any app), captured with a
/// Core Audio process tap (macOS 14.2+). No microphone and no virtual audio device: the tap is wrapped in a
/// private aggregate device that only ThUNER can see, and AudioCapture records from it like any other input.
///
/// macOS asks once for "System Audio Recording" permission (NSAudioCaptureUsageDescription).
final class SystemAudioTap {
    /// Which apps to capture.
    enum Mode: String, CaseIterable, Sendable {
        /// Everything this Mac plays.
        case all
        /// Only the chosen apps.
        case only
        /// Everything except the chosen apps.
        case except
    }

    /// Never captured by `.all` or `.except`: ThUNER itself (its playback of another Mac's stream). Not Rogue
    /// Amoeba's arkaudiod: with SoundSource running, apps' audio reaches a tap only through it.
    static let alwaysExcluded: Set<String> = [Bundle.main.bundleIdentifier ?? "com.idallas.thuner"]

    /// The input picker's id for this pseudo-device.
    static let uid = "com.idallas.thuner.system-audio"
    static let name = "System Audio"

    enum TapError: LocalizedError {
        case noOutputDevice
        case createTap(OSStatus)
        case createAggregate(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: "No audio output device to capture from"
            case .createTap(let status): "Couldn't capture system audio (OSStatus \(status)). Allow ThUNER under System Settings → Privacy & Security → Screen & System Audio Recording."
            case .createAggregate(let status): "Couldn't set up system audio capture (OSStatus \(status))"
            }
        }
    }

    /// The private aggregate device to record from.
    let deviceID: AudioDeviceID
    private let tapID: AudioObjectID
    /// The output device whose clock the aggregate runs on.
    private let outputID: AudioDeviceID
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// The tap's audio format (what the IO callback delivers).
    let format: AVAudioFormat
    private var ioProc: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.idallas.thuner.system-audio", qos: .userInteractive)
    private let log = Logger(subsystem: "com.idallas.thuner", category: "capture")

    /// - Parameter processes: the Core Audio process objects to capture (`.only`) or leave out (`.all`, `.except`).
    init(mode: Mode = .all, processes: [AudioObjectID] = []) throws {
        let description: CATapDescription = switch mode {
        case .only: CATapDescription(stereoMixdownOfProcesses: processes)
        case .all, .except: CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        }
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "ThUNER"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw TapError.createTap(tapStatus) }

        guard let (outputID, outputUID) = Self.defaultOutput() else {
            AudioHardwareDestroyProcessTap(tap)
            throw TapError.noOutputDevice
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ThUNER System Audio",
            kAudioAggregateDeviceUIDKey: "com.idallas.thuner.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var device = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw TapError.createAggregate(aggregateStatus)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let tapRate = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamDescription) == noErr
            ? streamDescription.mSampleRate : 0
        // The aggregate delivers the tap at its own rate, its output device's, whatever the tap's format says: with
        // the Studio Display at 44.1 kHz the tap said 48 kHz, so everything sent to Shazam played 9% fast and high,
        // and nothing matched.
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var deviceRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &deviceRate) == noErr, deviceRate > 0 {
            streamDescription.mSampleRate = deviceRate
        }
        guard tapRate > 0, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            throw TapError.createAggregate(-1)
        }
        tapID = tap
        deviceID = device
        self.outputID = outputID
        self.format = format
        log.notice("System audio tap ready: \(format.channelCount) ch @ \(format.sampleRate) Hz (tap says \(tapRate) Hz)\(format.isInterleaved ? " interleaved" : "", privacy: .public)")
    }

    /// Starts reading the tap; `handler` gets each buffer (non-interleaved float) on a background queue.
    /// Starting IO is what triggers macOS's System Audio Recording permission prompt.
    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let format = self.format
        let planar = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                   channels: format.channelCount, interleaved: false)!
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, ioQueue) { _, input, _, _, _ in
            guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  source.frameLength > 0 else { return }
            if !format.isInterleaved {
                handler(source)
                return
            }
            // Interleaved float: split into channels for the downmix.
            guard let samples = source.floatChannelData?[0] ?? (input.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)),
                  let out = AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: source.frameLength) else { return }
            out.frameLength = source.frameLength
            let channels = Int(format.channelCount)
            for c in 0..<channels {
                let dst = out.floatChannelData![c]
                for i in 0..<Int(source.frameLength) { dst[i] = samples[i * channels + c] }
            }
            handler(out)
        }
        guard status == noErr, let proc else { throw TapError.createAggregate(status) }
        let startStatus = AudioDeviceStart(deviceID, proc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, proc)
            throw TapError.createTap(startStatus)
        }
        ioProc = proc
    }

    /// Calls `handler` on the main queue when the output device's rate changes (or the device goes away): capture
    /// has to start again at the new rate.
    func onChange(_ handler: @escaping () -> Void) {
        for (object, selector) in [(outputID, kAudioDevicePropertyNominalSampleRate), (outputID, kAudioDevicePropertyDeviceIsAlive),
                                   (deviceID, kAudioDevicePropertyNominalSampleRate)] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    deinit {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        AudioHardwareDestroyAggregateDevice(deviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    private static func defaultOutput() -> (AudioDeviceID, String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return (device, uid.takeRetainedValue() as String)
    }
}
