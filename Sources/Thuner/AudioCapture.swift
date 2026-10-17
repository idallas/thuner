import AVFoundation
import CoreAudio
import ThunerCore
import os

/// Where shared audio goes: each capture start hands it a fresh packetizer (nil on stop), and the capture thread
/// calls `packetsReady` whenever it finishes packets.
protocol StreamSink: AnyObject, Sendable {
    /// `latencyFrames`: from the input's jacks to a sent packet, roughly.
    func attach(_ packetizer: Packetizer?, source: String?, latencyFrames: Int)
    func packetsReady()
}

/// The last few seconds of mono audio, at a sample rate ShazamKit accepts.
final class SampleRing: @unchecked Sendable {
    let sampleRate: Double
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()

    init(sampleRate: Double, seconds: Double) {
        self.sampleRate = sampleRate
        storage = [Float](repeating: 0, count: Int(sampleRate * seconds))
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % storage.count
        }
        filled = min(filled + samples.count, storage.count)
    }

    /// The most recent `seconds` of audio, oldest first, or nil if there isn't that much yet.
    func latest(seconds: Double) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let n = Int(seconds * sampleRate)
        guard n <= filled else { return nil }
        let start = (writeIndex - n + storage.count) % storage.count
        if start + n <= storage.count { return Array(storage[start..<start + n]) }
        return Array(storage[start...] + storage[..<(n - (storage.count - start))])
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        filled = 0
    }
}

/// Captures from a specific Core Audio input device with AVAudioEngine, reports levels, and keeps a ring of
/// recent audio for matching.
final class AudioCapture: @unchecked Sendable {
    struct Config: Equatable {
        var deviceUID: String?
        /// Zero-based first channel to listen to, for multichannel interfaces.
        var firstChannel = 0
        var channelCount = 2
        /// For System Audio: which apps to capture, and the bundle IDs of the chosen ones.
        var systemAudioMode = SystemAudioTap.Mode.all
        var systemAudioApps: Set<String> = []
        /// Sharing this input with other ThUNERs: frames per packet, and the input's I/O buffer to ask for (smaller
        /// is lower latency, at a little more CPU). Nil when not sharing.
        var streamFrames: Int?
        var streamIOBufferFrames = 128
    }

    enum CaptureError: LocalizedError {
        case deviceNotFound(String)
        case cannotSelectDevice(OSStatus)
        case noChannels
        case waitingForApps(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): "Input device not found (\(uid))"
            case .cannotSelectDevice(let status): "Couldn't select input device (OSStatus \(status))"
            case .noChannels: "The input device has no channels"
            case .waitingForApps(let names): "Waiting for \(names) to play"
            }
        }
    }

    static let matchSampleRate: Double = 48_000

    let ring = SampleRing(sampleRate: AudioCapture.matchSampleRate, seconds: 15)
    /// RMS level in dBFS for each captured buffer. Called on the audio tap's thread.
    var onLevel: ((Double) -> Void)?
    /// The engine stopped on its own (device unplugged, format change). Called on the main queue.
    var onInterrupted: (() -> Void)?
    /// Gets the audio when `Config.streamFrames` is set.
    var streamSink: StreamSink?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.idallas.thuner", category: "capture")

    private(set) var activeDeviceName: String?
    /// Reads the input directly for sharing, alongside the engine (which can't deliver small buffers).
    private var inputTap: DeviceInputTap?
    /// The system audio tap while "System Audio" is the input; released (and torn down) on stop.
    private var systemTap: SystemAudioTap?
    /// For a filtered System Audio capture: the process objects it covers, and the filter, so a chosen app
    /// starting (or a helper process appearing) restarts capture with it included.
    private var capturedProcesses = Set<AudioObjectID>()
    private var watchedFilter: Config?
    private var watchingProcesses = false

    private func watchAudioProcesses(for config: Config) {
        watchedFilter = config.systemAudioMode == .all ? nil : config
        guard !watchingProcesses else { return }
        watchingProcesses = true
        AudioDevices.observeAudioProcesses { [weak self] in
            guard let self, let filter = self.watchedFilter else { return }
            let now = Set(AudioDevices.processObjects(for: filter.systemAudioApps))
            if now != self.capturedProcesses { self.onInterrupted?() }
        }
    }

    func start(_ config: Config) throws {
        stop()
        if config.deviceUID == SystemAudioTap.uid {
            try startSystemAudio(config)
            return
        }
        stopWatchingApps()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        let device: AudioInputDevice?
        if let uid = config.deviceUID {
            guard let d = AudioDevices.device(uid: uid) else { throw CaptureError.deviceNotFound(uid) }
            device = d
        } else {
            device = AudioDevices.defaultInputDevice()
        }
        if let device, config.deviceUID != nil, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureError.cannotSelectDevice(status) }
        }
        activeDeviceName = device?.name

        // AVAudioEngine hands us only the first couple of a multichannel interface's inputs, so a channel pair
        // further up (an M4's 3–4, say) has to be routed through the input unit's channel map: map the
        // engine's channels onto the device channels we want.
        var mapped: ClosedRange<Int>?
        // A stereo (or mono) device always uses its own channels, whatever was picked for a bigger interface.
        var config = config
        if let device, device.inputChannels <= 2 { config.firstChannel = 0 }
        if let device, config.firstChannel > 0, let unit = input.audioUnit {
            let engineChannels = Int(input.outputFormat(forBus: 0).channelCount)
            let first = min(config.firstChannel, device.inputChannels - 1)
            let last = min(first + max(config.channelCount, 1), device.inputChannels) - 1
            var map = (0..<max(engineChannels, 1)).map { i in Int32(first + i <= last ? first + i : -1) }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                              &map, UInt32(MemoryLayout<Int32>.size * map.count))
            if status == noErr {
                mapped = first...last
            } else {
                log.error("Couldn't map input channels (OSStatus \(status))")
            }
        }

        let format = input.outputFormat(forBus: 0)
        let engineChannels = Int(format.channelCount)
        guard engineChannels > 0 else { throw CaptureError.noChannels }
        let channels: Range<Int>
        if let mapped {
            channels = 0..<min(mapped.count, engineChannels)
        } else {
            let first = min(max(config.firstChannel, 0), engineChannels - 1)
            channels = first..<min(first + max(config.channelCount, 1), engineChannels)
        }
        let channelLabel = mapped.map { "\($0.lowerBound + 1)–\($0.upperBound + 1)" }
            ?? "\(channels.lowerBound + 1)–\(channels.upperBound)"

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.matchSampleRate, channels: 1, interleaved: false)!
        // Owned by this tap's closure, so a restart on the main thread never swaps it out under a callback
        // that's still running on the audio thread.
        let converter = format.sampleRate == Self.matchSampleRate ? nil : AVAudioConverter(from: mono, to: target)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer, channels: channels, mono: mono, target: target, converter: converter)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.configurationChanged(engine: engine, tapFormat: format)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        ring.clear()
        if let frames = config.streamFrames, let streamSink, let device {
            do {
                let tap = try DeviceInputTap(device: device.id, firstChannel: config.firstChannel,
                                             ioBufferFrames: config.streamIOBufferFrames,
                                             packetizer: { Packetizer(framesPerPacket: frames, sampleRate: $0) },
                                             ready: { streamSink.packetsReady() })
                try tap.start()
                inputTap = tap
                streamSink.attach(tap.packetizer, source: device.name, latencyFrames: tap.latencyFrames)
                log.notice("Sharing \(device.name, privacy: .public), I/O buffer \(tap.ioBufferFrames) frames")
            } catch {
                log.error("Couldn't share the input: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.notice("Capturing from \(self.activeDeviceName ?? "default input", privacy: .public), channels \(channelLabel, privacy: .public) @ \(format.sampleRate) Hz")
    }

    /// What this Mac is playing, read straight from a process tap (no AVAudioEngine involved).
    private func startSystemAudio(_ config: Config) throws {
        watchAudioProcesses(for: config)
        let processes = AudioDevices.processObjects(for: config.systemAudioApps)
        capturedProcesses = Set(processes)
        if config.systemAudioMode == .only, processes.isEmpty {
            // None of the chosen apps has opened audio yet; the process watcher restarts capture when one does.
            throw CaptureError.waitingForApps(config.systemAudioApps.count == 1 ? "the chosen app" : "the chosen apps")
        }
        let tap = try SystemAudioTap(mode: config.systemAudioMode, processes: processes)
        let format = tap.format
        let channels = 0..<min(Int(format.channelCount), 2)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.matchSampleRate, channels: 1, interleaved: false)!
        let converter = format.sampleRate == Self.matchSampleRate ? nil : AVAudioConverter(from: mono, to: target)
        var streamPacketizer: Packetizer?
        if let frames = config.streamFrames, streamSink != nil {
            streamPacketizer = Packetizer(framesPerPacket: frames, sampleRate: format.sampleRate)
        }
        let streamSink = streamSink
        try tap.start { [weak self] buffer in
            if let streamPacketizer, let streamSink, let data = buffer.floatChannelData {
                let right = buffer.format.channelCount > 1 ? data[1] : data[0]
                if streamPacketizer.append(left: data[0], right: right, frames: Int(buffer.frameLength)) > 0 { streamSink.packetsReady() }
            }
            self?.process(buffer, channels: channels, mono: mono, target: target, converter: converter)
        }
        systemTap = tap
        if let streamPacketizer {
            // The tap's buffers aren't asked to be small; guess at its usual 512.
            streamSink?.attach(streamPacketizer, source: SystemAudioTap.name, latencyFrames: 512 + streamPacketizer.framesPerPacket)
        }
        activeDeviceName = SystemAudioTap.name
        ring.clear()
        log.notice("Capturing system audio, \(channels.count) ch @ \(format.sampleRate) Hz")
    }

    /// AVAudioEngine stops itself on any configuration change, and selecting a non-default input device can
    /// post one right after starting (seen with a 44.1 kHz Loopback device). Rebuilding the engine selects the
    /// device again and triggers another, so when the input's format is unchanged just restart this engine;
    /// only a real change (device gone, new rate or channel count) gets a full restart.
    private func configurationChanged(engine: AVAudioEngine, tapFormat: AVAudioFormat) {
        guard engine === self.engine else { return }
        let now = engine.inputNode.outputFormat(forBus: 0)
        if now.sampleRate == tapFormat.sampleRate, now.channelCount == tapFormat.channelCount {
            if !engine.isRunning {
                do {
                    try engine.start()
                    log.notice("Audio configuration changed; resumed")
                } catch {
                    log.error("Couldn't resume after a configuration change: \(error.localizedDescription, privacy: .public)")
                    onInterrupted?()
                }
            }
            return
        }
        log.notice("Audio input format changed (\(tapFormat.sampleRate) → \(now.sampleRate) Hz); restarting")
        onInterrupted?()
    }

    func stop() {
        streamSink?.attach(nil, source: nil, latencyFrames: 0)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        systemTap = nil
        inputTap = nil
    }

    /// Asks for a small I/O buffer on the device. Core Audio gives every app on the device the smallest any of them
    /// asks for, and drops ThUNER's request when it stops using the device.
    /// Returns the size it got.
    @discardableResult
    static func setIOBufferFrames(_ frames: Int, device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            Logger(subsystem: "com.idallas.thuner", category: "capture").error("Couldn't set the I/O buffer to \(frames) frames (OSStatus \(status))")
        }
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return Int(value)
    }

    /// Stop watching for app changes (when System Audio isn't the input any more).
    private func stopWatchingApps() {
        watchedFilter = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer, channels: Range<Int>, mono: AVAudioFormat, target: AVAudioFormat,
                         converter: AVAudioConverter?) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return }
        mixed.frameLength = AVAudioFrameCount(frames)
        let out = mixed.floatChannelData![0]

        // Downmix the selected channels and measure RMS in one pass.
        let scale = 1 / Float(channels.count)
        var sumSquares: Float = 0
        for i in 0..<frames {
            var s: Float = 0
            for c in channels { s += data[c][i] }
            s *= scale
            out[i] = s
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(frames))
        onLevel?(rms > 0 ? 20 * log10(Double(rms)) : -160)

        guard let converter else {
            ring.append(UnsafeBufferPointer(start: out, count: frames))
            return
        }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / mono.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mixed
        }
        if let error {
            log.error("Sample rate conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        ring.append(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
}
