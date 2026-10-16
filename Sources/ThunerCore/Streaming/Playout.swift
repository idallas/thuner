import Synchronization

/// How a stream is doing, for the UI. Frame counts are at the stream's sample rate.
public struct PlayoutStats: Sendable, Equatable {
    public var method: StreamMethod = .raw
    public var sampleRate = 0.0
    public var received = 0
    /// Audio missing when it was due (packets lost, or so late they were useless).
    public var lost = 0
    /// Packets that arrived after their audio had already been played (or, for raw, out of order).
    public var late = 0
    /// Times the buffer ran dry and playback had to start over.
    public var underruns = 0
    /// Average audio waiting when the output asks for more, and what the buffer aims for.
    public var bufferedFrames = 0.0
    public var targetFrames = 0.0
    /// Measured clock difference between the two Macs, in parts per million (positive: the sender runs fast).
    public var driftPPM = 0.0
    /// Raw: samples dropped or repeated to follow the sender's clock.
    public var adjustments = 0
    /// Resilient: how late packets have been arriving lately, compared with the quickest (recent peak).
    public var jitterFrames = 0.0
    /// Playing now (rather than waiting for audio).
    public var playing = false

    public init() {}

    public var bufferedMs: Double { sampleRate > 0 ? bufferedFrames / sampleRate * 1000 : 0 }
    public var targetMs: Double { sampleRate > 0 ? targetFrames / sampleRate * 1000 : 0 }
    public var jitterMs: Double { sampleRate > 0 ? jitterFrames / sampleRate * 1000 : 0 }
}

/// The receiving side's buffer: takes packets in and plays them out on the output's clock. Both methods are called
/// only from the output's real-time render thread (packets are handed over through an `SPSCRing`), so neither locks
/// or allocates; `stats` is the one thing read from elsewhere.
public protocol Playout: AnyObject, Sendable {
    var method: StreamMethod { get }
    /// A decoded packet: `samples` holds `header.frames` interleaved stereo frames. `arrival` is when it came off
    /// the network, in seconds on any steady clock.
    func receive(_ header: AudioPacketHeader, samples: UnsafePointer<Float>, arrival: Double)
    /// Fills `frames` frames of output. `now` is when the output asked, on the same clock as `arrival`.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, now: Double)
    /// The latest stats; safe from any thread.
    var stats: PlayoutStats { get }
}

/// Stats written on the render thread (without ever waiting) and read anywhere.
final class StatsBox: Sendable {
    private let value = Mutex(PlayoutStats())
    func publish(_ stats: PlayoutStats) { _ = value.withLockIfAvailable { $0 = stats } }
    var current: PlayoutStats { value.withLock { $0 } }
}

/// Four-point Hermite interpolation between y1 and y2, `t` in 0..<1.
@inline(__always)
func hermite(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
    let c1 = 0.5 * (y2 - y0)
    let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
    let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
    return ((c3 * t + c2) * t + c1) * t + y1
}
