/// The simple method: packets go into a FIFO in arrival order and play out once one output buffer plus
/// `targetFrames` of safety margin has built up. The two clocks drift apart by a few frames a second, so the FIFO's
/// average fill is watched, and when it strays more than a few frames from that, one frame is dropped or repeated,
/// spread over 16 samples so there's no click. If the output runs at a different rate, it's read at that fixed ratio
/// (with linear interpolation); otherwise samples come out exactly as sent.
public final class RawPlayout: Playout, @unchecked Sendable {
    public let method = StreamMethod.raw
    /// Extra frames kept beyond one output buffer.
    public let targetFrames: Int

    private let capacity = 16_384
    private let buffer: UnsafeMutablePointer<Float>
    /// Frames written and read so far. `readPosition` is only fractional in the middle of an adjustment.
    private var written = 0
    private var readPosition = 0.0

    private var streamID: UInt16?
    private var expected: UInt32?
    private var sampleRate = 48_000.0
    private var priming = true
    private var lastArrival = 0.0
    private var packetFrames = 128

    /// Drift tracking: the running average fill, checked against where it should sit a few times a second.
    private let tolerance = 12.0
    private let rampLength = 16
    private var fillAverage = 0.0
    private var framesSinceCheck = 0
    private var rampRemaining = 0
    private var rampStep = 1.0
    private var netAdjustment = 0
    private var framesPlayed = 0
    /// Far too much buffered (the output's buffer shrank, or a burst arrived): jump ahead by `skipOffset` frames,
    /// crossfading from the old position to the new one over `skipLength` samples.
    private let skipThreshold = 64.0
    private let skipLength = 32
    private var skipRemaining = 0
    private var skipOffset = 0

    private var local = PlayoutStats()
    private let published = StatsBox()

    /// The output's sample rate, when it differs from the stream's (0: the same).
    public let outputRate: Double
    /// Stream frames per output frame.
    private var step = 1.0

    public init(targetFrames: Int, outputRate: Double = 0) {
        self.targetFrames = max(targetFrames, 0)
        self.outputRate = outputRate
        buffer = .allocate(capacity: capacity * 2)
        buffer.initialize(repeating: 0, count: capacity * 2)
        local.method = .raw
    }

    deinit { buffer.deallocate() }

    public var stats: PlayoutStats { published.current }

    public func receive(_ header: AudioPacketHeader, samples: UnsafePointer<Float>, arrival: Double) {
        if header.streamID != streamID {
            startOver()
            streamID = header.streamID
            expected = nil
            sampleRate = Double(header.sampleRate)
            local = PlayoutStats()
            local.method = .raw
            local.sampleRate = sampleRate
        }
        if let expected {
            let gap = Int(Int32(bitPattern: header.sequence &- expected))
            if gap < 0 {
                // A FIFO can't put it back in place; it's already been skipped.
                local.late += 1
                return
            }
            if gap > 0 {
                local.lost += gap
                // Fill short gaps with silence so the timing (and so the drift tracking) stays put.
                if gap <= 8 { write(nil, frames: gap * header.frames) }
            }
        }
        expected = header.sequence &+ 1
        write(samples, frames: header.frames)
        lastArrival = arrival
        packetFrames = header.frames
        local.received += 1
    }

    private func write(_ samples: UnsafePointer<Float>?, frames: Int) {
        let fill = written - Int(readPosition)
        if fill + frames > capacity - 4 {
            // Way more than we can use (the output stalled): skip ahead rather than fall further behind.
            readPosition += Double(fill + frames - capacity + 4)
        }
        for i in 0..<frames {
            let index = ((written + i) % capacity) * 2
            buffer[index] = samples?[i * 2] ?? 0
            buffer[index + 1] = samples?[i * 2 + 1] ?? 0
        }
        written += frames
    }

    private func startOver() {
        priming = true
        rampRemaining = 0
        skipRemaining = 0
    }

    /// The fill as if each packet trickled in over its own length instead of landing all at once. The real fill
    /// jumps by a packet with every arrival, and clock drift slowly slides arrivals past the output's requests, so
    /// averaging the real fill would wander by up to a packet; this is continuous. It's also the least the real
    /// fill gets to before the next packet lands, so it's what must stay above one output buffer.
    private func smoothFill(_ fill: Double, now: Double) -> Double {
        fill - Double(packetFrames) + min(max(now - lastArrival, 0) * sampleRate, Double(packetFrames))
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, now: Double) {
        defer { published.publish(local) }
        step = outputRate > 0 ? sampleRate / outputRate : 1
        let center = Double(frames) * step + Double(targetFrames)
        var fill = Double(written) - readPosition
        if priming {
            let smooth = smoothFill(fill, now: now)
            guard streamID != nil, smooth >= center else {
                silence(left, right, from: 0, to: frames)
                local.playing = false
                return
            }
            // Up to a packet more than needed may have built up: start right at the target instead.
            readPosition += (smooth - center).rounded(.down)
            fill = Double(written) - readPosition
            priming = false
            fillAverage = center
        }
        // One frame past the last one read, for interpolating mid-adjustment.
        guard fill >= Double(frames) * step + 2 + (rampRemaining > 0 ? 1 : 0) + Double(skipRemaining > 0 ? skipOffset : 0) else {
            // Ran dry: play what's left, fading it out, and wait for the buffer to refill.
            let available = min(max(Int((fill - 2) / step), 0), frames)
            read(left, right, frames: available)
            let fade = min(available, 32)
            for i in 0..<fade {
                let g = Float(fade - i) / Float(fade + 1)
                left[available - fade + i] *= g
                right[available - fade + i] *= g
            }
            silence(left, right, from: available, to: frames)
            local.underruns += 1
            local.playing = false
            startOver()
            return
        }
        local.playing = true
        read(left, right, frames: frames)
        trackDrift(fill: smoothFill(fill, now: now), center: center, frames: frames)
    }

    private func read(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let whole = Int(readPosition)
            let t = Float(readPosition - Double(whole))
            frame(whole, t, &left[i], &right[i])
            if skipRemaining > 0 {
                var l: Float = 0, r: Float = 0
                frame(whole + skipOffset, t, &l, &r)
                let w = Float(skipLength - skipRemaining + 1) / Float(skipLength + 1)
                left[i] += (l - left[i]) * w
                right[i] += (r - right[i]) * w
                skipRemaining -= 1
                if skipRemaining == 0 { readPosition += Double(skipOffset) }
            }
            if rampRemaining > 0 {
                readPosition += rampStep
                rampRemaining -= 1
                // 16 steps of 1 ± 1/16 add up to exactly 2 or 0 frames, so we land back on a whole frame.
                if rampRemaining == 0, step == 1 { readPosition = readPosition.rounded() }
            } else {
                readPosition += step
            }
        }
        framesPlayed += frames
    }

    @inline(__always)
    private func frame(_ whole: Int, _ t: Float, _ l: inout Float, _ r: inout Float) {
        let a = (whole % capacity) * 2
        if t == 0 {
            l = buffer[a]
            r = buffer[a + 1]
        } else {
            let b = ((whole + 1) % capacity) * 2
            l = buffer[a] + (buffer[b] - buffer[a]) * t
            r = buffer[a + 1] + (buffer[b + 1] - buffer[a + 1]) * t
        }
    }

    private func trackDrift(fill: Double, center: Double, frames: Int) {
        fillAverage += (fill - fillAverage) * min(Double(frames) / (0.5 * sampleRate), 1)
        framesSinceCheck += frames
        if framesSinceCheck >= Int(sampleRate / 4), rampRemaining == 0, skipRemaining == 0 {
            framesSinceCheck = 0
            let deviation = fillAverage - center
            if deviation > skipThreshold {
                // Not drift (that's a frame or two a second): catch up in one go rather than a frame at a time.
                skipOffset = Int(deviation.rounded(.down))
                skipRemaining = skipLength
                fillAverage -= Double(skipOffset)
                local.adjustments += 1
            } else if abs(deviation) > tolerance {
                let drop = deviation > 0
                rampStep = step + (drop ? 1.0 : -1.0) / Double(rampLength)
                rampRemaining = rampLength
                // We know exactly what this does to the fill; don't wait for the average to notice.
                fillAverage += drop ? -1 : 1
                netAdjustment += drop ? 1 : -1
                local.adjustments += 1
            }
        }
        local.bufferedFrames = fillAverage
        local.targetFrames = center
        if framesPlayed > 0 { local.driftPPM = Double(netAdjustment) / Double(framesPlayed) * 1_000_000 }
    }

    private func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, from: Int, to: Int) {
        guard to > from else { return }
        (left + from).update(repeating: 0, count: to - from)
        (right + from).update(repeating: 0, count: to - from)
    }
}
