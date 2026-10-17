import Foundation
import Synchronization

/// Left and right peak levels, recorded on a real-time audio thread and collected (and reset) by a reader.
public final class PeakLevels: Sendable {
    private let left = Atomic<UInt32>(0)
    private let right = Atomic<UInt32>(0)
    /// Something was recorded since the last take.
    private let fresh = Atomic<Bool>(false)

    public init() {}

    /// Notes the loudest sample of each channel. Real-time safe: two loads and two stores.
    public func record(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames: Int) {
        var pl: Float = 0, pr: Float = 0
        for i in 0..<frames {
            pl = max(pl, abs(l[i]))
            pr = max(pr, abs(r[i]))
        }
        // One writer, so load-then-store is enough; a reset landing in between just keeps a peak one read longer.
        if pl > Float(bitPattern: left.load(ordering: .relaxed)) { left.store(pl.bitPattern, ordering: .relaxed) }
        if pr > Float(bitPattern: right.load(ordering: .relaxed)) { right.store(pr.bitPattern, ordering: .relaxed) }
        fresh.store(true, ordering: .relaxed)
    }

    /// Like `take()`, but nil if no audio came since the last call (the capture delivers in batches, or stopped),
    /// which isn't the same as silence.
    public func takeIfFresh() -> (left: Double, right: Double)? {
        guard fresh.load(ordering: .relaxed) else { return nil }
        return take()
    }

    /// The peaks since the last call, in dBFS (-160 for silence), and starts again.
    public func take() -> (left: Double, right: Double) {
        fresh.store(false, ordering: .relaxed)
        let l = Float(bitPattern: left.exchange(0, ordering: .relaxed))
        let r = Float(bitPattern: right.exchange(0, ordering: .relaxed))
        return (Self.dB(l), Self.dB(r))
    }

    public static func dB(_ amplitude: Float) -> Double { amplitude > 0 ? max(20 * log10(Double(amplitude)), -160) : -160 }
}
