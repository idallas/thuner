import Synchronization

/// Stereo audio handed from a real-time thread to a background one: the writer never waits or allocates, and if
/// the reader falls more than `capacity` frames behind, the oldest audio is lost rather than the newest.
public final class FrameFIFO: @unchecked Sendable {
    public let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Frames written and read so far; they only grow.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Writer (real-time thread).
    public func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        for i in 0..<frames {
            left[(w + i) % capacity] = l[i]
            right[(w + i) % capacity] = r[i]
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Reader: up to `max` frames into `l` and `r`; returns how many.
    public func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let w = written.load(ordering: .acquiring)
        var start = read.load(ordering: .relaxed)
        // Fell too far behind: skip to the newest audio that's still intact (keeping clear of the writer).
        if w - start > capacity - 1_024 { start = w - (capacity - 1_024) }
        let n = Swift.min(w - start, max)
        for i in 0..<n {
            l[i] = left[(start + i) % capacity]
            r[i] = right[(start + i) % capacity]
        }
        read.store(start + n, ordering: .relaxed)
        return Swift.max(n, 0)
    }
}
