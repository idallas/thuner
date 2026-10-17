import Synchronization

/// The sending side, on the capture's real-time thread: collects frames into fixed-size packets, encodes them, and
/// queues them for the network thread.
public final class Packetizer: @unchecked Sendable {
    public let framesPerPacket: Int
    public let sampleRate: UInt32
    public let streamID: UInt16
    /// Finished datagrams, ready to send.
    public let packets: SPSCRing
    /// Packets thrown away because the network thread fell behind (counted on the capture thread, read anywhere).
    private let overflowCount = Atomic<Int>(0)
    public var overflows: Int { overflowCount.load(ordering: .relaxed) }
    /// The most frames handed over at once since the last `takeLargestAppend()`: the capture's real buffer size,
    /// whatever was asked for. For logs; not synchronized.
    private let largestAppend = Atomic<Int>(0)
    public func takeLargestAppend() -> Int { largestAppend.exchange(0, ordering: .relaxed) }

    private let staging: UnsafeMutablePointer<Float>
    private var staged = 0
    private var sequence: UInt32 = 0
    /// The sender's frame count at the first staged frame.
    private var sampleTime: UInt64 = 0
    /// With device timestamps: the first one seen (the stream's frame 0), and where the next buffer should start.
    private var timelineOrigin: Double?
    private var expectedInputTime: Double?
    /// Times the input skipped or repeated audio (its timestamps jumped), so the stream's timeline jumped with it.
    private let discontinuityCount = Atomic<Int>(0)
    public var discontinuities: Int { discontinuityCount.load(ordering: .relaxed) }

    /// Each new stream gets the next ID (from a random start), so a restart never reuses the one just before:
    /// a receiver would take the new stream's packets, numbered from 0 again, for very late ones.
    private static let nextStreamID = Atomic<UInt16>(.random(in: .min ... .max))
    public static func newStreamID() -> UInt16 { nextStreamID.wrappingAdd(1, ordering: .relaxed).newValue }

    public init(framesPerPacket: Int, sampleRate: Double, streamID: UInt16 = Packetizer.newStreamID(), queuedPackets: Int = 256) {
        self.framesPerPacket = min(max(framesPerPacket, 16), StreamWire.maxFramesPerPacket)
        self.sampleRate = UInt32(sampleRate.rounded())
        self.streamID = streamID
        packets = SPSCRing(slotSize: StreamWire.maxDatagram, capacity: queuedPackets)
        staging = .allocate(capacity: self.framesPerPacket * StreamWire.channels)
    }

    deinit { staging.deallocate() }

    /// Adds `frames` frames of one or two channels (pass the same pointer twice for mono). Returns how many packets
    /// were finished.
    ///
    /// `inputTime` is the input device's sample time for the first frame, if it has one. With it, the stream's
    /// timeline follows the device: if the device skips (a buffer size change, an overload), the stream skips too,
    /// and the receiver hears a short gap instead of everything after it arriving late.
    @discardableResult
    public func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, inputTime: Double? = nil) -> Int {
        if frames > largestAppend.load(ordering: .relaxed) { largestAppend.store(frames, ordering: .relaxed) }
        if let inputTime {
            if let expected = expectedInputTime, abs(inputTime - expected) >= 1, let origin = timelineOrigin {
                // Start a fresh packet at the device's new position; the partial one is dropped.
                staged = 0
                sampleTime = UInt64(max(inputTime - origin, Double(sampleTime)).rounded())
                discontinuityCount.add(1, ordering: .relaxed)
            }
            if timelineOrigin == nil { timelineOrigin = inputTime }
            expectedInputTime = inputTime + Double(frames)
        }
        var finished = 0
        var i = 0
        while i < frames {
            let n = min(frames - i, framesPerPacket - staged)
            for j in 0..<n {
                staging[(staged + j) * 2] = left[i + j]
                staging[(staged + j) * 2 + 1] = right[i + j]
            }
            staged += n
            i += n
            if staged == framesPerPacket {
                let header = AudioPacketHeader(streamID: streamID, sequence: sequence, sampleTime: sampleTime,
                                               sampleRate: sampleRate, frames: framesPerPacket)
                let queued = packets.push { StreamWire.writeAudio(header, samples: staging, to: $0) }
                if queued { finished += 1 } else { overflowCount.add(1, ordering: .relaxed) }
                // Sequence and time advance even for a dropped packet: to the receiver it's simply lost.
                sequence &+= 1
                sampleTime &+= UInt64(framesPerPacket)
                staged = 0
            }
        }
        return finished
    }
}
