import Synchronization

/// A single-producer, single-consumer queue of fixed-size byte slots, for handing data to or from a real-time
/// audio thread: no locks, and no allocation after init.
public final class SPSCRing: @unchecked Sendable {
    public let slotSize: Int
    public let capacity: Int
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    /// Slots written so far (producer) and read so far (consumer); they only ever grow.
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    public init(slotSize: Int, capacity: Int) {
        self.slotSize = slotSize
        self.capacity = capacity
        storage = .allocate(byteCount: slotSize * capacity, alignment: 16)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deallocate()
    }

    /// Producer: `fill` writes into the next free slot (up to `slotSize` bytes) and returns how many bytes it used,
    /// or 0 to write nothing. False if the queue is full.
    @discardableResult
    public func push(_ fill: (UnsafeMutableRawPointer) -> Int) -> Bool {
        let h = head.load(ordering: .relaxed)
        guard h - tail.load(ordering: .acquiring) < capacity else { return false }
        let used = fill(storage + (h % capacity) * slotSize)
        guard used > 0 else { return true }
        lengths[h % capacity] = min(used, slotSize)
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Consumer: hands the oldest slot to `read` and frees it. False if the queue is empty.
    @discardableResult
    public func pop(_ read: (UnsafeRawBufferPointer) -> Void) -> Bool {
        let t = tail.load(ordering: .relaxed)
        guard t != head.load(ordering: .acquiring) else { return false }
        read(UnsafeRawBufferPointer(start: storage + (t % capacity) * slotSize, count: lengths[t % capacity]))
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// Slots waiting to be read (approximate while the other side is busy).
    public var count: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }
}
