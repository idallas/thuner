import CoreAudio
import ThunerCore
import os

/// Reads two channels of an input device straight from Core Audio (an IOProc on the device's real-time thread),
/// for sharing. AVAudioEngine hands its nodes 512-frame batches whatever the device runs at, which is 10 ms of
/// latency and burstiness on its own; an IOProc gets each I/O buffer as the device delivers it.
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

    /// `firstChannel` is zero-based across all of the device's input channels; a mono device (or a last odd
    /// channel) is sent as both sides.
    init(device: AudioDeviceID, firstChannel: Int, ioBufferFrames: Int, packetizer makePacketizer: (Double) -> Packetizer,
         ready: @escaping () -> Void) throws {
        self.device = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw TapError.coreAudio("read the input's sample rate", status) }
        sampleRate = rate

        // Where each device channel lives: input streams arrive as one buffer each, channels interleaved within.
        let layout = try Self.inputLayout(device)
        guard layout.allFloat else { throw TapError.unsupportedFormat }
        let total = layout.channelsPerBuffer.reduce(0, +)
        let first = min(max(firstChannel, 0), max(total - 1, 0))
        let second = first + 1 < total ? first + 1 : first
        let leftAt = Self.locate(first, in: layout.channelsPerBuffer)
        let rightAt = Self.locate(second, in: layout.channelsPerBuffer)

        let l = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let packetizer = makePacketizer(rate)
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
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
            let time = inputTime.pointee.mFlags.contains(.sampleTimeValid) ? inputTime.pointee.mSampleTime : nil
            if packetizer.append(left: l, right: r, frames: frames, inputTime: time) > 0 { ready() }
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

    let packetizer: Packetizer
    private let requestedIOFrames: Int

    func start() throws {
        guard let proc else { return }
        let status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw TapError.coreAudio("start the input", status) }
        // After starting, so nothing else in this process sets it back.
        ioBufferFrames = AudioCapture.setIOBufferFrames(requestedIOFrames, device: device)
    }

    deinit {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        left.deallocate()
        right.deallocate()
    }

    private struct Layout {
        var channelsPerBuffer: [Int]
        var allFloat: Bool
    }

    private static func inputLayout(_ device: AudioDeviceID) throws -> Layout {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { throw TapError.coreAudio("read the input's channels", status) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw)
        guard status == noErr else { throw TapError.coreAudio("read the input's channels", status) }
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

    /// The buffer and the position within its frames of one of the device's channels.
    private static func locate(_ channel: Int, in channelsPerBuffer: [Int]) -> (buffer: Int, offset: Int) {
        var remaining = channel
        for (index, count) in channelsPerBuffer.enumerated() {
            if remaining < count { return (index, remaining) }
            remaining -= count
        }
        return (0, 0)
    }
}
