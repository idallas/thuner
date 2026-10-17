/// The listening side of resending: notices gaps in the sequence numbers, says which packets to ask for, asks
/// again a couple of times if they don't come, and gives up once they'd be too late to play.
public struct ResendTracker: Sendable {
    /// How long to wait for a resend before asking again, and how long before giving up on a packet.
    public var retryInterval: Double
    public var giveUpAfter: Double
    public var maxAttempts: Int

    /// Packets asked for, packets that came back in time to be asked about no longer, and packets given up on.
    public private(set) var requested = 0
    public private(set) var recovered = 0
    public private(set) var abandoned = 0

    private var highest: UInt32?
    private var pending: [UInt32: (first: Double, last: Double, attempts: Int)] = [:]
    /// A jump bigger than this is a new stream (or a long outage), not something to ask for packet by packet.
    private let maxGap = 128

    public init(retryInterval: Double = 0.004, giveUpAfter: Double = 0.06, maxAttempts: Int = 3) {
        self.retryInterval = retryInterval
        self.giveUpAfter = giveUpAfter
        self.maxAttempts = maxAttempts
    }

    /// A packet arrived (`resent`: in answer to a request). Returns the packets newly found missing, to ask for now.
    public mutating func received(_ sequence: UInt32, resent: Bool, at now: Double) -> [UInt32] {
        if pending.removeValue(forKey: sequence) != nil, resent { recovered += 1 }
        guard let highest else {
            self.highest = sequence
            return []
        }
        let gap = Int(Int32(bitPattern: sequence &- highest))
        guard abs(gap) <= maxGap else {
            // Far off either way: the sender started over (or this is the first packet after a long silence).
            self.highest = sequence
            pending.removeAll()
            return []
        }
        guard gap > 0 else { return [] }
        self.highest = sequence
        guard gap > 1 else { return [] }
        var missing: [UInt32] = []
        var s = highest &+ 1
        while s != sequence {
            pending[s] = (now, now, 1)
            missing.append(s)
            s &+= 1
        }
        requested += missing.count
        return missing
    }

    /// Packets to ask for again now; drops the ones that have been waited for too long.
    public mutating func due(at now: Double) -> [UInt32] {
        guard !pending.isEmpty else { return [] }
        var again: [UInt32] = []
        for (sequence, entry) in pending {
            if now - entry.first > giveUpAfter || (entry.attempts >= maxAttempts && now - entry.last >= retryInterval) {
                pending[sequence] = nil
                abandoned += 1
            } else if now - entry.last >= retryInterval, entry.attempts < maxAttempts {
                pending[sequence] = (entry.first, now, entry.attempts + 1)
                again.append(sequence)
            }
        }
        requested += again.count
        return again.sorted { Int32(bitPattern: $0 &- $1) < 0 }
    }

    public var waiting: Int { pending.count }
}

/// The sending side of resending: the last few hundred packets sent, by sequence number. Used only from the
/// sending thread.
public final class PacketHistory: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let sequences: UnsafeMutablePointer<UInt32>

    public init(capacity: Int = 512) {
        self.capacity = capacity
        storage = .allocate(byteCount: capacity * StreamWire.maxDatagram, alignment: 16)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
        sequences = .allocate(capacity: capacity)
        sequences.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deallocate()
        sequences.deallocate()
    }

    /// Keeps a copy of an audio packet.
    public func store(_ packet: UnsafeRawBufferPointer) {
        guard let header = StreamWire.audioHeader(packet), packet.count <= StreamWire.maxDatagram else { return }
        let slot = Int(header.sequence % UInt32(capacity))
        (storage + slot * StreamWire.maxDatagram).copyMemory(from: packet.baseAddress!, byteCount: packet.count)
        lengths[slot] = packet.count
        sequences[slot] = header.sequence
    }

    /// The packet with this sequence number, marked as a resend, if it's still kept.
    public func resend(_ sequence: UInt32, _ body: (UnsafeRawBufferPointer) -> Void) {
        let slot = Int(sequence % UInt32(capacity))
        guard lengths[slot] > 0, sequences[slot] == sequence else { return }
        let packet = storage + slot * StreamWire.maxDatagram
        packet.storeBytes(of: StreamWire.Kind.resentAudio.rawValue, toByteOffset: 5, as: UInt8.self)
        body(UnsafeRawBufferPointer(start: packet, count: lengths[slot]))
    }
}
