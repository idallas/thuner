import Foundation

/// The SonoBus-style method. Each packet is written at its own place in time (its `sampleTime`), so packets that
/// arrive out of order just fill in. The read position trails the newest audio by a target delay that follows the
/// measured network jitter: quiet wired networks get a few milliseconds, Wi-Fi gets what it needs. Instead of
/// dropping samples, the read position advances at a rate a few hundred parts per million either side of 1,
/// steered by how far the buffer is from its target, which both follows the sender's clock and eases the buffer to
/// a new target without a jump. Audio that never arrives is faded out and back in.
public final class ResilientPlayout: Playout, @unchecked Sendable {
    public let method = StreamMethod.resilient
    /// The least extra buffer to keep beyond what the jitter calls for.
    public let minimumFrames: Int

    private let capacity = 32_768
    private let buffer: UnsafeMutablePointer<Float>
    /// The sender frame each slot holds, so a slot from a lost packet (or a lap ago) reads as missing.
    private let stamps: UnsafeMutablePointer<UInt64>

    private var streamID: UInt16?
    private var sampleRate = 48_000.0
    private var packetFrames = 128
    /// One past the newest frame received.
    private var newestEnd: UInt64 = 0
    /// Where playback is, in the sender's frames; nil until there's something to play.
    private var readPosition: Double?
    /// Output frames rendered since the last packet arrived.
    private var framesSincePacket = 0

    // Jitter: each packet's transit time (arrival minus its place in the stream) against the quickest recent one.
    private var blockStart = -Double.infinity
    private var currentMin = Double.infinity
    private var previousMin = Double.infinity
    private var peakLateness = 0.0
    private var peakAt = 0.0
    private var lastArrival = 0.0
    private var firstArrival: Double?
    /// The buffer ran dry: line up afresh at the next render rather than slew all the way back.
    private var resync = false

    // Steering.
    private var ratio = 1.0
    private var integral = 0.0
    private var fillAverage = 0.0
    private var renderFrames = 128
    private var ratioAverage = 0.0

    // Concealment: a gain that eases to 0 over missing audio and back, and the last real sample per channel.
    private var gain: Float = 0
    private var heldLeft: Float = 0
    private var heldRight: Float = 0
    private var wasMissing = false

    private var local = PlayoutStats()
    private let published = StatsBox()

    /// How fast the read rate may differ from 1, either way (0.5% is about 9 cents of pitch, only while catching up).
    private let maxSlew = 0.005
    private let kp = 2e-5
    private let ki = 2e-6

    /// The output's sample rate, when it differs from the stream's (0: the same). The read rate is then this ratio,
    /// steered as usual.
    public let outputRate: Double

    public init(minimumFrames: Int, outputRate: Double = 0) {
        self.minimumFrames = max(minimumFrames, 0)
        self.outputRate = outputRate
        buffer = .allocate(capacity: capacity * 2)
        buffer.initialize(repeating: 0, count: capacity * 2)
        stamps = .allocate(capacity: capacity)
        stamps.initialize(repeating: .max, count: capacity)
        local.method = .resilient
    }

    deinit {
        buffer.deallocate()
        stamps.deallocate()
    }

    public var stats: PlayoutStats { published.current }

    /// What the buffer aims for: an output buffer (plus interpolation), the jitter, and the floor.
    var targetFrames: Double {
        let jitter = peakLateness * sampleRate * 1.3
        return min(Double(renderFrames + 2 + minimumFrames) + jitter, sampleRate * 0.25)
    }

    /// Where the sender is now, in its frames, if packets always took the quickest recent transit time. Measuring
    /// the buffer against this rather than against the newest packet keeps it steady: the newest packet jumps
    /// with every arrival and with jitter.
    private func senderPosition(at now: Double) -> Double {
        (now - min(previousMin, currentMin)) * sampleRate
    }

    public func receive(_ header: AudioPacketHeader, samples: UnsafePointer<Float>, arrival: Double) {
        if header.streamID != streamID {
            streamID = header.streamID
            sampleRate = Double(header.sampleRate)
            newestEnd = 0
            readPosition = nil
            stamps.update(repeating: .max, count: capacity)
            blockStart = -.infinity
            currentMin = .infinity
            previousMin = .infinity
            peakLateness = 0
            firstArrival = nil
            local = PlayoutStats()
            local.method = .resilient
            local.sampleRate = sampleRate
        }
        packetFrames = header.frames
        let start = header.sampleTime
        let end = start + UInt64(header.frames)
        trackJitter(transit: arrival - Double(start) / sampleRate, arrival: arrival)
        if firstArrival == nil { firstArrival = arrival }
        framesSincePacket = 0
        local.received += 1

        if let position = readPosition {
            if Double(end) <= position {
                local.late += 1
                return
            }
            if Double(start) > position + Double(capacity / 2) {
                // Far ahead of playback (we'd stalled, or the sender jumped): start again from here.
                readPosition = nil
            }
        }
        for i in 0..<header.frames {
            let frame = start + UInt64(i)
            let slot = Int(frame % UInt64(capacity))
            buffer[slot * 2] = samples[i * 2]
            buffer[slot * 2 + 1] = samples[i * 2 + 1]
            stamps[slot] = frame
        }
        newestEnd = max(newestEnd, end)
    }

    private func trackJitter(transit: Double, arrival: Double) {
        // The quickest transit over the last 2–4 seconds is the baseline; it moves slowly with clock drift.
        if arrival - blockStart > 2 {
            previousMin = currentMin
            currentMin = transit
            blockStart = arrival
        } else {
            currentMin = min(currentMin, transit)
        }
        let lateness = max(0, transit - min(previousMin, currentMin))
        // Jump up to any new peak and hold it for 5 seconds (Wi-Fi hiccups tend to come back), then let it decay
        // with a 5 second half-life.
        if lateness >= peakLateness {
            peakLateness = lateness
            peakAt = arrival
        } else if arrival - peakAt > 5 {
            peakLateness = max(lateness, peakLateness * pow(0.5, max(arrival - lastArrival, 0) / 5))
        }
        lastArrival = arrival
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, now: Double) {
        defer { published.publish(local) }
        let nominal = outputRate > 0 ? sampleRate / outputRate : 1
        renderFrames = Int((Double(frames) * nominal).rounded(.up))
        framesSincePacket += renderFrames
        guard streamID != nil, newestEnd > 0, Double(framesSincePacket) < sampleRate * 0.25 else {
            // Nothing coming in: stop, and line up afresh when audio returns.
            readPosition = nil
            firstArrival = nil
            fadeOutToSilence(left, right, frames: frames)
            local.playing = false
            return
        }
        // Listen to the network for a moment before starting, so the buffer starts out the right size.
        guard let firstArrival, now - firstArrival >= 0.2 else {
            fadeOutToSilence(left, right, frames: frames)
            local.playing = false
            return
        }
        let target = targetFrames
        let sender = senderPosition(at: now)
        if resync {
            resync = false
            readPosition = nil
        }
        if readPosition == nil {
            readPosition = sender - target
            fillAverage = target
            integral = 0
            ratio = 1
            wasMissing = true
        }
        var position = readPosition!
        let fill = sender - position
        fillAverage += (fill - fillAverage) * min(Double(frames) / (0.3 * sampleRate), 1)
        if abs(fill - target) > max(2 * target, sampleRate * 0.1) {
            // Hopelessly off (a long stall): jump rather than slew.
            position = sender - target
            fillAverage = target
            integral = 0
        }

        let error = fillAverage - target
        let dt = Double(renderFrames) / sampleRate
        // Integrate only near the target: while the buffer is still moving to a new target, the error says nothing
        // about the clocks, and integrating it would wind up and overshoot.
        if abs(error) < 48 { integral = max(-0.001 / ki, min(integral + error * dt, 0.001 / ki)) }
        ratio = 1 + max(-maxSlew, min(kp * error + ki * integral, maxSlew))

        for i in 0..<frames {
            let whole = position.rounded(.down)
            let t = Float(position - whole)
            let base = Int64(whole)
            var present = true
            var l0: Float = 0, l1: Float = 0, l2: Float = 0, l3: Float = 0
            var r0: Float = 0, r1: Float = 0, r2: Float = 0, r3: Float = 0
            sample(base - 1, &l0, &r0, &present)
            sample(base, &l1, &r1, &present)
            sample(base + 1, &l2, &r2, &present)
            sample(base + 2, &l3, &r3, &present)
            if present {
                heldLeft = l1
                heldRight = r1
                gain = min(gain + 1 / 32, 1)
            } else {
                if !wasMissing {
                    // Past the newest audio: the buffer ran dry. Behind it: a packet that never came.
                    if base + 2 >= Int64(newestEnd) {
                        local.underruns += 1
                        resync = true
                    } else {
                        local.lost += 1
                    }
                }
                gain = max(gain - 1 / 32, 0)
            }
            wasMissing = !present
            left[i] = gain * hermite(l0, l1, l2, l3, t)
            right[i] = gain * hermite(r0, r1, r2, r3, t)
            position += ratio * nominal
        }
        readPosition = position
        local.playing = true
        local.bufferedFrames = fillAverage
        local.targetFrames = target
        local.jitterFrames = peakLateness * sampleRate
        // Over time the buffer can't grow or shrink for good, so the average read rate is the clock difference.
        ratioAverage += (ratio - 1 - ratioAverage) * min(Double(frames) / (30 * sampleRate), 1)
        local.driftPPM = ratioAverage * 1_000_000
    }

    /// One frame of audio, or the held value if it's missing.
    @inline(__always)
    private func sample(_ frame: Int64, _ l: inout Float, _ r: inout Float, _ present: inout Bool) {
        if frame >= 0 {
            let slot = Int(frame % Int64(capacity))
            if stamps[slot] == UInt64(frame) {
                l = buffer[slot * 2]
                r = buffer[slot * 2 + 1]
                return
            }
        }
        l = heldLeft
        r = heldRight
        present = false
    }

    private func fadeOutToSilence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        wasMissing = true
        for i in 0..<frames {
            gain = max(gain - 1 / 32, 0)
            left[i] = gain * heldLeft
            right[i] = gain * heldRight
        }
    }
}
