import CoreAudio
import os

/// Plays two channels into any pair of an output device's channels (an Apollo's VIRTUAL 1–2, say) straight from a
/// Core Audio IOProc, at the device's own I/O buffer size. Core Audio mixes it with whatever else plays there, and
/// the device's other channels are left alone.
final class DeviceOutputTap {
    typealias Render = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    let device: AudioDeviceID
    let sampleRate: Double
    /// The I/O buffer the device actually gave us.
    private(set) var ioBufferFrames = 0
    private let requestedIOFrames: Int
    private var proc: AudioDeviceIOProcID?
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private static let maxFrames = 8_192

    /// `firstChannel` is zero-based across all of the device's output channels. On a mono device (or the last odd
    /// channel) the two sides are mixed.
    init(device: AudioDeviceID, firstChannel: Int, ioBufferFrames: Int, render: @escaping Render) throws {
        self.device = device
        guard let rate = AudioDevices.nominalSampleRate(device) else {
            throw DeviceInputTap.TapError.coreAudio("read the output's sample rate", -1)
        }
        sampleRate = rate
        let layout = try DeviceInputTap.layout(device, scope: kAudioDevicePropertyScopeOutput)
        guard layout.allFloat else { throw DeviceInputTap.TapError.unsupportedFormat }
        let total = layout.channelsPerBuffer.reduce(0, +)
        let first = min(max(firstChannel, 0), max(total - 1, 0))
        let mono = first + 1 >= total
        let leftAt = DeviceInputTap.locate(first, in: layout.channelsPerBuffer)
        let rightAt = DeviceInputTap.locate(mono ? first : first + 1, in: layout.channelsPerBuffer)

        let l = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count > max(leftAt.buffer, rightAt.buffer),
                  let lData = buffers[leftAt.buffer].mData, let rData = buffers[rightAt.buffer].mData else { return }
            let lStride = Int(buffers[leftAt.buffer].mNumberChannels)
            let rStride = Int(buffers[rightAt.buffer].mNumberChannels)
            let frames = min(Int(buffers[leftAt.buffer].mDataByteSize) / (4 * max(lStride, 1)), Self.maxFrames)
            render(l, r, frames)
            let ld = lData.assumingMemoryBound(to: Float.self)
            let rd = rData.assumingMemoryBound(to: Float.self)
            if mono {
                for i in 0..<frames { ld[i * lStride + leftAt.offset] = 0.5 * (l[i] + r[i]) }
            } else {
                for i in 0..<frames {
                    ld[i * lStride + leftAt.offset] = l[i]
                    rd[i * rStride + rightAt.offset] = r[i]
                }
            }
        }
        guard status == noErr, procID != nil else {
            l.deallocate()
            r.deallocate()
            throw DeviceInputTap.TapError.coreAudio("open the output", status)
        }
        proc = procID
        left = l
        right = r
        requestedIOFrames = ioBufferFrames
    }

    func start() throws {
        guard let proc else { return }
        DeviceInputTap.setStreamUsage(device: device, proc: proc, scope: kAudioDevicePropertyScopeInput, enabled: false)
        // Before starting, so the first buffers are already small (switching after start cost a dropout).
        ioBufferFrames = AudioCapture.setIOBufferFrames(requestedIOFrames, device: device)
        let status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw DeviceInputTap.TapError.coreAudio("start the output", status) }
        latencyFrames = AudioDevices.latencyFrames(device, scope: kAudioDevicePropertyScopeOutput) + ioBufferFrames
    }

    /// From rendering a buffer to it leaving the jacks, roughly, once started.
    private(set) var latencyFrames = 0

    deinit {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        left.deallocate()
        right.deallocate()
    }
}
