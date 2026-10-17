/// The receiver's first check on every audio packet: does it belong to the stream being played?
///
/// It locks onto a stream (its ID, sample rate, sequence numbers and timeline) and lets through packets that fit:
/// reordered ones, resends, and the sender's own timeline skips (an input glitch jumps its sample time ahead while
/// the sequence carries on). A different stream (the sender restarted) takes over only after `confirmations`
/// packets in a row that agree with each other, so one stray or forged datagram can't reset playback, mute it
/// (a sequence far ahead makes every real packet look late) or push its arithmetic to extremes.
public struct StreamGate: Sendable {
    public let confirmations: Int
    /// Sequence numbers further than this either side of the newest aren't this stream (~2.7 s at 128 frames).
    public let maxSequenceJump: Int32
    /// Nor are sample times more than this many seconds either side of the newest.
    public let maxTimeJump: Double

    private struct Position: Sendable {
        var streamID: UInt16
        var sampleRate: UInt32
        var sequence: UInt32
        var sampleTime: UInt64
        var count = 1
    }
    private var locked: Position?
    private var candidate: Position?

    public init(confirmations: Int = 8, maxSequenceJump: Int32 = 1_024, maxTimeJump: Double = 60) {
        self.confirmations = confirmations
        self.maxSequenceJump = maxSequenceJump
        self.maxTimeJump = maxTimeJump
    }

    /// Whether to accept the packet (and, if it confirms a new stream, switch to it).
    public mutating func admit(_ header: AudioPacketHeader) -> Bool {
        if let locked, fits(header, after: locked) {
            if Int32(bitPattern: header.sequence &- locked.sequence) > 0 {
                self.locked?.sequence = header.sequence
                self.locked?.sampleTime = header.sampleTime
            }
            candidate = nil
            return true
        }
        // Not the current stream: a new one only counts once several packets in a row agree.
        if let c = candidate, header.sequence == c.sequence &+ 1, fits(header, after: c) {
            candidate = Position(streamID: header.streamID, sampleRate: header.sampleRate, sequence: header.sequence,
                                 sampleTime: header.sampleTime, count: c.count + 1)
        } else {
            candidate = Position(streamID: header.streamID, sampleRate: header.sampleRate, sequence: header.sequence,
                                 sampleTime: header.sampleTime)
        }
        guard let c = candidate, c.count >= confirmations else { return false }
        locked = c
        candidate = nil
        return true
    }

    private func fits(_ header: AudioPacketHeader, after p: Position) -> Bool {
        guard header.streamID == p.streamID, header.sampleRate == p.sampleRate else { return false }
        let ds = Int32(bitPattern: header.sequence &- p.sequence)
        guard abs(Int64(ds)) <= Int64(maxSequenceJump) else { return false }
        let dt = Int64(bitPattern: header.sampleTime &- p.sampleTime)
        guard abs(Double(dt)) <= maxTimeJump * Double(p.sampleRate) else { return false }
        // Time moves the same way as the sequence (a skip only ever jumps ahead).
        return ds == 0 || (ds > 0) == (dt > 0)
    }
}
