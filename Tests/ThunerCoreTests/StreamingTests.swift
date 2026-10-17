import Foundation
import Testing
@testable import ThunerCore

@Suite struct StreamWireTests {
    @Test func audioPacketRoundTrips() {
        let frames = 128
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<samples.count { samples[i] = sin(Float(i) * 0.05) * 0.9 }
        samples[0] = 1.5  // clamps
        samples[1] = -1
        let header = AudioPacketHeader(streamID: 77, sequence: 4_000_000_000, sampleTime: 1 << 40, sampleRate: 48_000, frames: frames)
        var datagram = [UInt8](repeating: 0, count: StreamWire.maxDatagram)
        let size = datagram.withUnsafeMutableBytes { StreamWire.writeAudio(header, samples: samples, to: $0.baseAddress!) }
        #expect(size == StreamWire.headerSize + frames * 2 * 3)

        var decoded = [Float](repeating: 0, count: frames * 2)
        datagram.withUnsafeBytes { raw in
            let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<size])
            #expect(StreamWire.kind(of: bytes) == .audio)
            let parsed = StreamWire.audioHeader(bytes)
            #expect(parsed == header)
            StreamWire.readSamples(bytes, header: header, into: &decoded)
        }
        #expect(abs(decoded[0] - 1) < 1e-6)
        #expect(abs(decoded[1] + 1) < 1e-6)
        for i in 2..<samples.count { #expect(abs(decoded[i] - samples[i]) < 1.0 / 8_000_000) }
    }

    @Test func rejectsTruncatedAndForeignPackets() {
        let samples = [Float](repeating: 0.1, count: 256)
        var datagram = [UInt8](repeating: 0, count: StreamWire.maxDatagram)
        let size = datagram.withUnsafeMutableBytes {
            StreamWire.writeAudio(AudioPacketHeader(streamID: 1, sequence: 0, sampleTime: 0, sampleRate: 48_000, frames: 128),
                                  samples: samples, to: $0.baseAddress!)
        }
        datagram.withUnsafeBytes { raw in
            #expect(StreamWire.audioHeader(UnsafeRawBufferPointer(rebasing: raw[0..<(size - 1)])) == nil)
            #expect(StreamWire.kind(of: UnsafeRawBufferPointer(rebasing: raw[1..<size])) == nil)
        }
    }

    @Test func controlMessagesRoundTrip() {
        let data = StreamWire.control(.subscribe, StreamWire.Subscribe(host: "studio-mac", method: .resilient))
        data.withUnsafeBytes { bytes in
            #expect(StreamWire.kind(of: bytes) == .subscribe)
            #expect(StreamWire.controlBody(StreamWire.Subscribe.self, from: bytes) == .init(host: "studio-mac", method: .resilient))
        }
    }

    @Test func ringKeepsOrderAndRefusesWhenFull() {
        let ring = SPSCRing(slotSize: 8, capacity: 4)
        for i in 0..<4 { #expect(ring.push { $0.storeBytes(of: UInt8(i), as: UInt8.self); return 1 }) }
        #expect(!ring.push { _ in 1 })
        var seen: [UInt8] = []
        while ring.pop({ seen.append($0[0]) }) {}
        #expect(seen == [0, 1, 2, 3])
    }

    @Test func packetizerSplitsArbitraryBuffers() {
        let packetizer = Packetizer(framesPerPacket: 128, sampleRate: 48_000, streamID: 9)
        let left = [Float](repeating: 0.25, count: 500)
        let right = [Float](repeating: -0.25, count: 500)
        var finished = 0
        finished += packetizer.append(left: left, right: right, frames: 100)
        finished += packetizer.append(left: left, right: right, frames: 300)
        #expect(finished == 3)
        var times: [UInt64] = []
        while packetizer.packets.pop({ times.append(StreamWire.audioHeader($0)!.sampleTime) }) {}
        #expect(times == [0, 128, 256])
    }
}

/// Two Macs in simulation: a sender ticking on its clock, a network that delays, jitters, reorders and loses
/// packets, and an output ticking on the receiver's clock.
struct StreamSimulation {
    var senderRate = 48_000.0
    /// The output device's rate (nil: the same as the sender's).
    var outputRate: Double?
    /// Sender clock error in parts per million (positive: it runs fast).
    var driftPPM = 0.0
    var packetFrames = 128
    var renderFrames = 128
    /// The output's buffer size changing partway (as it does when a smaller one is asked for after starting).
    var renderFramesChange: (at: Double, frames: Int)?
    var latency = 0.0005
    /// Extra random delay per packet, up to this many seconds.
    var jitter = 0.0
    var lossRate = 0.0
    /// Occasional big delay spikes (Wi-Fi): probability per packet, and size.
    var spikeRate = 0.0
    var spike = 0.0
    /// Ask for lost packets again (as the receiver does for resilient), with this round trip; nil: don't.
    var resendRoundTrip: Double?
    var seconds = 60.0

    struct Result {
        var stats: PlayoutStats
        /// Output, left channel, for checking the signal came through intact.
        var output: [Float]
        var input: [Float]
    }

    func run(_ playout: Playout, seed: UInt64 = 1, keepAudio: Bool = false) -> Result {
        var rng = SplitMix(seed: seed)
        let senderPeriod = Double(packetFrames) / (senderRate * (1 + driftPPM / 1_000_000))
        var renderFrames = self.renderFrames
        var renderPeriod = Double(renderFrames) / (outputRate ?? senderRate)
        var nextSend = 0.0
        var nextRender = 0.0
        var sequence: UInt32 = 0
        var inFlight: [(arrival: Double, header: AudioPacketHeader, samples: [Float])] = []
        var sent: [UInt32: (header: AudioPacketHeader, samples: [Float])] = [:]
        var tracker = ResendTracker()
        let most = max(renderFrames, renderFramesChange?.frames ?? 0)
        var left = [Float](repeating: 0, count: most)
        var right = [Float](repeating: 0, count: most)
        var output: [Float] = []
        var input: [Float] = []
        var phase = 0.0

        while nextRender < seconds {
            if nextSend <= nextRender {
                var samples = [Float](repeating: 0, count: packetFrames * 2)
                for i in 0..<packetFrames {
                    // A 440 Hz tone at the sender's notion of time.
                    let v = Float(sin(phase) * 0.5)
                    phase += 2 * .pi * 440 / senderRate
                    samples[i * 2] = v
                    samples[i * 2 + 1] = -v
                    if keepAudio { input.append(v) }
                }
                let header = AudioPacketHeader(streamID: 1, sequence: sequence, sampleTime: UInt64(sequence) * UInt64(packetFrames),
                                               sampleRate: UInt32(senderRate), frames: packetFrames)
                sequence += 1
                if resendRoundTrip != nil { sent[header.sequence] = (header, samples) }
                if rng.unit() >= lossRate {
                    var delay = latency + rng.unit() * jitter
                    if rng.unit() < spikeRate { delay += spike }
                    inFlight.append((nextSend + delay, header, samples))
                }
                nextSend += senderPeriod
            } else {
                // Deliver everything that has arrived by now, in arrival order.
                inFlight.sort { $0.arrival < $1.arrival }
                while let first = inFlight.first, first.arrival <= nextRender {
                    first.samples.withUnsafeBufferPointer { playout.receive(first.header, samples: $0.baseAddress!, arrival: first.arrival) }
                    inFlight.removeFirst()
                    if let rtt = resendRoundTrip {
                        let asked = tracker.received(first.header.sequence, resent: first.header.resent, at: first.arrival)
                            + tracker.due(at: first.arrival)
                        for s in asked {
                            // The resend can be lost too.
                            guard var copy = sent[s], rng.unit() >= lossRate else { continue }
                            copy.header.resent = true
                            inFlight.append((first.arrival + rtt, copy.header, copy.samples))
                        }
                        inFlight.sort { $0.arrival < $1.arrival }
                    }
                }
                if let change = renderFramesChange, nextRender >= change.at, renderFrames != change.frames {
                    renderFrames = change.frames
                    renderPeriod = Double(renderFrames) / (outputRate ?? senderRate)
                }
                playout.render(left: &left, right: &right, frames: renderFrames, now: nextRender)
                if keepAudio { output.append(contentsOf: left[0..<renderFrames]) }
                nextRender += renderPeriod
            }
        }
        return Result(stats: playout.stats, output: output, input: input)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

@Suite struct RawPlayoutTests {
    @Test func cleanNetworkPlaysBitExactWithNoAdjustments() {
        let result = StreamSimulation(seconds: 5).run(RawPlayout(targetFrames: 64), keepAudio: true)
        #expect(result.stats.underruns == 0)
        #expect(result.stats.adjustments == 0)
        // Playback starts partway into the tone: find where, then compare sample for sample (24-bit
        // quantization aside).
        let start = result.output.firstIndex { $0 != 0 }!
        let offset = (0..<1_000).min { a, b in
            (0..<64).reduce(0) { $0 + abs(result.output[start + $1] - result.input[a + $1]) }
                < (0..<64).reduce(0) { $0 + abs(result.output[start + $1] - result.input[b + $1]) }
        }!
        let worst = (0..<10_000).map { abs(result.output[start + $0] - result.input[offset + $0]) }.max()!
        #expect(worst < 1e-6)
    }

    @Test(arguments: [-80.0, -20.0, 20.0, 80.0])
    func followsClockDriftWithoutUnderruns(ppm: Double) {
        let result = StreamSimulation(driftPPM: ppm, seconds: 120).run(RawPlayout(targetFrames: 64))
        #expect(result.stats.underruns == 0)
        #expect(abs(result.stats.driftPPM - ppm) < 15, "measured \(result.stats.driftPPM) ppm")
        #expect(abs(result.stats.bufferedFrames - result.stats.targetFrames) < 20)
    }

    @Test func ridesJitterShorterThanAPacket() {
        // 2 ms: less than a packet, so nothing arrives out of order.
        let result = StreamSimulation(driftPPM: 30, jitter: 0.002, seconds: 30).run(RawPlayout(targetFrames: 128))
        #expect(result.stats.underruns == 0)
        #expect(result.stats.late == 0)
    }

    @Test func catchesUpWhenTheOutputBufferShrinks() {
        let sim = StreamSimulation(renderFrames: 512, renderFramesChange: (at: 1, frames: 128), seconds: 5)
        let result = sim.run(RawPlayout(targetFrames: 64))
        #expect(result.stats.underruns == 0)
        #expect(abs(result.stats.bufferedFrames - result.stats.targetFrames) < 20, "\(result.stats)")
    }

    @Test func playsToAnOutputAtAnotherRate() {
        let result = StreamSimulation(outputRate: 44_100, driftPPM: 30, seconds: 60)
            .run(RawPlayout(targetFrames: 64, outputRate: 44_100), keepAudio: true)
        #expect(result.stats.underruns == 0)
        #expect(abs(result.stats.driftPPM - 30) < 15, "measured \(result.stats.driftPPM) ppm")
        // 48 kHz worth of tone in, 44.1 kHz out: the output holds 44.1/48 as many samples of it.
        #expect(abs(Double(result.output.count) / Double(result.input.count) - 44_100.0 / 48_000) < 0.01)
    }

    @Test func dropsPacketsThatArriveOutOfOrder() {
        // Jitter longer than a packet reorders them; a FIFO can only throw the stragglers away.
        let result = StreamSimulation(jitter: 0.006, seconds: 10).run(RawPlayout(targetFrames: 512))
        #expect(result.stats.late > 100)
    }

    @Test func countsLostPackets() {
        let result = StreamSimulation(lossRate: 0.01, seconds: 20).run(RawPlayout(targetFrames: 64))
        #expect(result.stats.lost > 30)
        // With less buffer than a packet, a missing packet leaves nothing to play: raw starts over.
        #expect(result.stats.underruns <= result.stats.lost)
        #expect(result.stats.playing)
    }
}

@Suite struct ResilientPlayoutTests {
    @Test func cleanNetworkSettlesNearTheMinimum() {
        let result = StreamSimulation(seconds: 20).run(ResilientPlayout(minimumFrames: 32))
        #expect(result.stats.underruns == 0)
        #expect(result.stats.lost == 0)
        // Output buffer + half a packet + minimum, in ms: about 5 ms.
        #expect(result.stats.targetMs < 6)
        #expect(abs(result.stats.bufferedFrames - result.stats.targetFrames) < 20)
    }

    @Test(arguments: [-100.0, -20.0, 20.0, 100.0])
    func followsClockDrift(ppm: Double) {
        let result = StreamSimulation(driftPPM: ppm, seconds: 120).run(ResilientPlayout(minimumFrames: 32))
        #expect(result.stats.underruns == 0)
        #expect(abs(result.stats.driftPPM - ppm) < 10, "measured \(result.stats.driftPPM) ppm")
        #expect(abs(result.stats.bufferedFrames - result.stats.targetFrames) < 20)
    }

    @Test(arguments: [44_100.0, 96_000.0])
    func playsToAnOutputAtAnotherRate(rate: Double) {
        let result = StreamSimulation(outputRate: rate, driftPPM: -40, jitter: 0.001, seconds: 60)
            .run(ResilientPlayout(minimumFrames: 32, outputRate: rate))
        #expect(result.stats.underruns == 0)
        #expect(result.stats.lost == 0)
        #expect(abs(result.stats.driftPPM + 40) < 10, "measured \(result.stats.driftPPM) ppm")
    }

    @Test func growsTheBufferForJitterAndReordering() {
        // Up to 8 ms of jitter reorders packets constantly at 2.7 ms each.
        let result = StreamSimulation(driftPPM: 40, jitter: 0.008, seconds: 60).run(ResilientPlayout(minimumFrames: 32))
        #expect(result.stats.targetMs > 8)
        #expect(result.stats.targetMs < 20)
        #expect(result.stats.underruns + result.stats.lost < 5, "\(result.stats)")
    }

    @Test func ridesOutWiFiSpikes() {
        let wifi = StreamSimulation(driftPPM: -30, jitter: 0.003, spikeRate: 0.002, spike: 0.03, seconds: 60)
        let result = wifi.run(ResilientPlayout(minimumFrames: 32))
        #expect(result.stats.targetMs < 60)
        // The first spike or two get through before the buffer has grown for them.
        #expect(result.stats.underruns + result.stats.lost < 10, "\(result.stats)")
    }

    @Test func lostPacketsAreConcealedNotFatal() {
        let result = StreamSimulation(lossRate: 0.01, seconds: 20).run(ResilientPlayout(minimumFrames: 32))
        // Each loss is faded over (whether it shows as lost or, right at the edge, as an underrun), and loss
        // isn't jitter, so the buffer doesn't grow for it.
        #expect(result.stats.lost + result.stats.underruns > 30)
        #expect(result.stats.targetMs < 6)
        #expect(result.stats.playing)
    }

    @Test func startsOverWhenTheStreamRestarts() {
        let playout = ResilientPlayout(minimumFrames: 32)
        _ = StreamSimulation(seconds: 2).run(playout)
        var samples = [Float](repeating: 0.1, count: 256)
        var left = [Float](repeating: 0, count: 128), right = left
        for n in 0..<150 {
            let header = AudioPacketHeader(streamID: 2, sequence: UInt32(n), sampleTime: UInt64(n * 128), sampleRate: 44_100, frames: 128)
            playout.receive(header, samples: &samples, arrival: 100 + Double(n) * 128 / 44_100)
            playout.render(left: &left, right: &right, frames: 128, now: 100 + Double(n) * 128 / 44_100 + 0.0001)
        }
        #expect(playout.stats.sampleRate == 44_100)
        #expect(playout.stats.playing)
        #expect(abs(left[100] - 0.1) < 1e-3)
    }
}

@Suite struct PacketizerTimelineTests {
    @Test func followsTheDeviceTimelineAcrossSkips() {
        let packetizer = Packetizer(framesPerPacket: 128, sampleRate: 48_000, streamID: 3)
        let audio = [Float](repeating: 0.5, count: 512)
        packetizer.append(left: audio, right: audio, frames: 256, inputTime: 1_000)
        packetizer.append(left: audio, right: audio, frames: 256, inputTime: 1_256)
        // The device skipped 512 frames (and this buffer starts mid-packet relative to the old timeline).
        packetizer.append(left: audio, right: audio, frames: 256, inputTime: 2_024)
        var times: [UInt64] = []
        while packetizer.packets.pop({ times.append(StreamWire.audioHeader($0)!.sampleTime) }) {}
        #expect(times == [0, 128, 256, 384, 1_024, 1_152])
        #expect(packetizer.discontinuities == 1)
    }
}

@Suite struct ResendTests {
    @Test func asksForGapsOnceThenRetriesThenGivesUp() {
        var tracker = ResendTracker(retryInterval: 0.004, giveUpAfter: 0.02, maxAttempts: 3)
        #expect(tracker.received(10, resent: false, at: 0).isEmpty)
        #expect(tracker.received(13, resent: false, at: 0.001) == [11, 12])
        // 12 comes back; 11 doesn't.
        #expect(tracker.received(12, resent: true, at: 0.002).isEmpty)
        #expect(tracker.recovered == 1)
        #expect(tracker.due(at: 0.003).isEmpty)
        #expect(tracker.due(at: 0.0055) == [11])
        #expect(tracker.due(at: 0.0096) == [11])
        #expect(tracker.due(at: 0.014).isEmpty)  // three attempts made: given up
        #expect(tracker.abandoned == 1)
        #expect(tracker.waiting == 0)
    }

    @Test func aReorderedOriginalCancelsTheRequest() {
        var tracker = ResendTracker()
        _ = tracker.received(1, resent: false, at: 0)
        #expect(tracker.received(3, resent: false, at: 0) == [2])
        _ = tracker.received(2, resent: false, at: 0.001)
        #expect(tracker.waiting == 0)
        #expect(tracker.recovered == 0)
    }

    @Test func aBigJumpIsANewStreamNotLoss() {
        var tracker = ResendTracker()
        _ = tracker.received(5, resent: false, at: 0)
        #expect(tracker.received(5_000, resent: false, at: 0.01).isEmpty)
        // The sender started over, lower down.
        #expect(tracker.received(3, resent: false, at: 0.02).isEmpty)
        #expect(tracker.received(5, resent: false, at: 0.03) == [4])

        var wrapping = ResendTracker()
        _ = wrapping.received(UInt32.max - 1, resent: false, at: 0)
        #expect(wrapping.received(1, resent: false, at: 0.01) == [UInt32.max, 0])
    }

    @Test func historyResendsMarkedCopies() {
        let history = PacketHistory(capacity: 8)
        let samples = [Float](repeating: 0.25, count: 256)
        var datagram = [UInt8](repeating: 0, count: StreamWire.maxDatagram)
        for seq in UInt32(0)..<10 {
            let size = datagram.withUnsafeMutableBytes {
                StreamWire.writeAudio(AudioPacketHeader(streamID: 1, sequence: seq, sampleTime: UInt64(seq) * 128, sampleRate: 48_000, frames: 128),
                                      samples: samples, to: $0.baseAddress!)
            }
            datagram.withUnsafeBytes { history.store(UnsafeRawBufferPointer(rebasing: $0[0..<size])) }
        }
        var got: AudioPacketHeader?
        history.resend(9) { got = StreamWire.audioHeader($0) }
        #expect(got?.sequence == 9 && got?.resent == true)
        var old = false
        history.resend(1) { _ in old = true }  // overwritten by 9
        #expect(!old)
    }

    @Test func resendingRecoversMostLosses() {
        let lossy = StreamSimulation(driftPPM: 20, jitter: 0.001, lossRate: 0.02, seconds: 30)
        var withResend = lossy
        withResend.resendRoundTrip = 0.001
        let plain = lossy.run(ResilientPlayout(minimumFrames: 64))
        let playout = ResilientPlayout(minimumFrames: 64)
        playout.setResendRoundTrip(0.001)
        let recovered = withResend.run(playout)
        let before = plain.stats.lost + plain.stats.underruns
        let after = recovered.stats.lost + recovered.stats.underruns
        #expect(before > 150)
        #expect(after * 20 < before, "\(before) → \(after)")
        // It keeps room for one packet and the round trip (plus a margin), not more: resends don't count as jitter.
        #expect(recovered.stats.targetMs < plain.stats.targetMs + 2.7 + 2 + 0.5, "\(plain.stats.targetMs) → \(recovered.stats.targetMs)")
    }
}

