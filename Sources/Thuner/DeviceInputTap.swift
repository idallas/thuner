import CoreAudio
import ThunerCore
import os

/// Reads two channels of an input device straight from Core Audio (an IOProc on the device's real-time thread):
/// ThUNER's capture for listening, sharing and meters. AVAudioEngine hands its nodes 512-frame batches whatever
/// the device runs at, and after switching away from the default input it kept the default's sample rate and
/// (on a Mac whose devices then ran at different rates) delivered only silence. An IOProc gets each I/O buffer
/// as the device delivers it, at the device's own rate.
final class DeviceInputTap {
    enum TapError: LocalizedError {
        case unsupportedFormat
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "The input doesn't deliver floating-point audio"
            case .coreAudio(let what, let status): "Couldn't \(what) (OSStatus \(status))"
            }
        }
    }

    let sampleRate: Double
    /// The I/O buffer the device actually gave us.
    private(set) var ioBufferFrames = 0
    private let device: AudioDeviceID
    private var proc: AudioDeviceIOProcID?
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private static let maxFrames = 8_192
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// `firstChannel` is zero-based across all of the device's input channels; a mono device (or a last odd
    /// channel) comes out as both sides. Each buffer goes to `fifo` (for listening), `levels` (meters) and, when
    /// sharing, a packetizer made for the device's rate, calling `ready` when packets are done.
    init(device: AudioDeviceID, firstChannel: Int, ioBufferFrames: Int, fifo: FrameFIFO?, levels: PeakLevels?,
         packetizer makePacketizer: ((Double) -> Packetizer)?, ready: (() -> Void)?) throws {
        self.device = device
        guard let rate = AudioDevices.nominalSampleRate(device) else {
            throw TapError.coreAudio("read the input's sample rate", -1)
        }
        sampleRate = rate

        // Where each device channel lives: input streams arrive as one buffer each, channels interleaved within.
        let layout = try Self.layout(device, scope: kAudioDevicePropertyScopeInput)
        guard layout.allFloat else { throw TapError.unsupportedFormat }
        let total = layout.channelsPerBuffer.reduce(0, +)
        let first = min(max(firstChannel, 0), max(total - 1, 0))
        let second = first + 1 < total ? first + 1 : first
        let leftAt = Self.locate(first, in: layout.channelsPerBuffer)
        let rightAt = Self.locate(second, in: layout.channelsPerBuffer)
        channelLabel = second == first ? "\(first + 1)" : "\(first + 1)–\(second + 1)"

        let l = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let packetizer = makePacketizer?(rate)
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count > max(leftAt.buffer, rightAt.buffer),
                  let lData = buffers[leftAt.buffer].mData, let rData = buffers[rightAt.buffer].mData else { return }
            let lStride = Int(buffers[leftAt.buffer].mNumberChannels)
            let rStride = Int(buffers[rightAt.buffer].mNumberChannels)
            let frames = min(Int(buffers[leftAt.buffer].mDataByteSize) / (4 * max(lStride, 1)), Self.maxFrames)
            let ls = lData.assumingMemoryBound(to: Float.self)
            let rs = rData.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                l[i] = ls[i * lStride + leftAt.offset]
                r[i] = rs[i * rStride + rightAt.offset]
            }
            fifo?.write(left: l, right: r, frames: frames)
            levels?.record(left: l, right: r, frames: frames)
            if let packetizer {
                let time = inputTime.pointee.mFlags.contains(.sampleTimeValid) ? inputTime.pointee.mSampleTime : nil
                if packetizer.append(left: l, right: r, frames: frames, inputTime: time) > 0 { ready?() }
            }
        }
        guard status == noErr, procID != nil else {
            l.deallocate()
            r.deallocate()
            throw TapError.coreAudio("open the input", status)
        }
        proc = procID
        left = l
        right = r
        self.packetizer = packetizer
        requestedIOFrames = ioBufferFrames
    }

    /// When sharing.
    let packetizer: Packetizer?
    /// The device channels being read, for logs ("3–4").
    let channelLabel: String
    private let requestedIOFrames: Int

    func start() throws {
        guard let proc else { return }
        Self.setStreamUsage(device: device, proc: proc, scope: kAudioDevicePropertyScopeOutput, enabled: false)
        // Before starting, so the first buffers are already the size asked for.
        ioBufferFrames = AudioCapture.setIOBufferFrames(requestedIOFrames, device: device)
        let status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw TapError.coreAudio("start the input", status) }
        // The newest frame in each buffer is a buffer late already; then a packet may wait for the next buffer.
        let packet = packetizer?.framesPerPacket ?? 0
        latencyFrames = AudioDevices.latencyFrames(device, scope: kAudioDevicePropertyScopeInput) + ioBufferFrames
            + max(packet - ioBufferFrames, 0)
    }

    /// Jacks to sent packet, roughly, once started.
    private(set) var latencyFrames = 0

    /// Calls `handler` on the main queue if the device changes rate or goes away (capture has to start again).
    func onChange(_ handler: @escaping () -> Void) {
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        left.deallocate()
        right.deallocate()
    }

    struct Layout {
        var channelsPerBuffer: [Int]
        var allFloat: Bool
    }

    /// How a device's input or output channels are laid out in an IOProc's buffers, and whether they're float.
    static func layout(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Layout {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { throw TapError.coreAudio("read the device's channels", status) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw)
        guard status == noErr else { throw TapError.coreAudio("read the device's channels", status) }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.map { Int($0.mNumberChannels) }

        // IOProcs get each stream's virtual format, which is float on any normal device; check rather than assume.
        address.mSelector = kAudioDevicePropertyStreams
        status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        if status == noErr { status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) }
        var allFloat = true
        for stream in streams {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr {
                let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
                allFloat = allFloat && isFloat
            }
        }
        return Layout(channelsPerBuffer: channels, allFloat: allFloat)
    }

    /// Turns all of an IOProc's streams in one direction on or off. An IOProc runs both directions by default, so
    /// an output-only IOProc on an interface that also has inputs makes macOS count ThUNER as recording (the
    /// orange mic indicator), and an input-only one keeps the outputs running for nothing.
    static func setStreamUsage(device: AudioDeviceID, proc: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, enabled: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioHardwareIOProcStreamUsage>.size) else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        // Which IOProc to ask about goes in the structure itself.
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let streams = Int(usage.pointee.mNumberStreams)
        guard streams > 0, let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let flags = (raw + offset).assumingMemoryBound(to: UInt32.self)
        for i in 0..<streams { flags[i] = enabled ? 1 : 0 }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
        if status != noErr {
            Logger(subsystem: "com.idallas.thuner", category: "stream").error("Couldn't set IOProc stream usage (OSStatus \(status))")
        }
    }

    /// The buffer and the position within its frames of one of the device's channels.
    static func locate(_ channel: Int, in channelsPerBuffer: [Int]) -> (buffer: Int, offset: Int) {
        var remaining = channel
        for (index, count) in channelsPerBuffer.enumerated() {
            if remaining < count { return (index, remaining) }
            remaining -= count
        }
        return (0, 0)
    }
}
