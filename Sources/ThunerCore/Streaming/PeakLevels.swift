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
        Self.raise(left, to: pl)
        Self.raise(right, to: pr)
        fresh.store(true, ordering: .relaxed)
    }

    /// Raises a stored peak to `value` unless it's already higher; a reset in between can't make it lose `value`.
    private static func raise(_ peak: borrowing Atomic<UInt32>, to value: Float) {
        var current = peak.load(ordering: .relaxed)
        while value > Float(bitPattern: current) {
            let (exchanged, original) = peak.compareExchange(expected: current, desired: value.bitPattern, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
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
