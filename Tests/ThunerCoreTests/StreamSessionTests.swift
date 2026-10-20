import Foundation
import Testing
@testable import ThunerCore

@Suite struct StreamSessionTests {
    private func stats(received: Int, lost: Int = 0, dropouts: Int = 0, buffer: Double = 5, playing: Bool = true) -> PlayoutStats {
        var s = PlayoutStats()
        s.method = .resilient
        s.sampleRate = 48_000
        s.received = received
        s.lost = lost
        s.underruns = dropouts
        s.bufferedFrames = buffer / 1000 * 48_000
        s.targetFrames = 4.0 / 1000 * 48_000
        s.playing = playing
        return s
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsCarryOnWhenTheOutputReopens() {
        var recorder = StreamSessionRecorder(session: StreamSession(source: "echo", method: .resilient, started: start))
        recorder.record(StreamSample(stats: stats(received: 100, lost: 1, dropouts: 1), latencyMs: 8), at: start)
        recorder.record(StreamSample(stats: stats(received: 500, lost: 2, dropouts: 1), latencyMs: 8), at: start + 1)
        // Quiet: the output closes, and there's no playout for a while.
        recorder.record(StreamSample(stats: nil, latencyMs: nil), at: start + 2)
        // It reopens with fresh counts.
        recorder.record(StreamSample(stats: stats(received: 50, lost: 1, dropouts: 0), latencyMs: 9), at: start + 3)
        let session = recorder.snapshot
        #expect(session.counters.received == 550)
        // Only the loss in between counts: the first moments after the output opens (twice here) don't.
        #expect(session.counters.lost == 1)
        #expect(session.counters.dropouts == 0)
    }

    @Test func playingTimeAndAverages() {
        var recorder = StreamSessionRecorder(session: StreamSession(source: "echo", method: .resilient, started: start))
        for i in 0...10 {
            recorder.record(StreamSample(stats: stats(received: i * 375, buffer: i < 5 ? 4 : 8), latencyMs: 10), at: start + Double(i))
        }
        // Silence doesn't count as playing time.
        recorder.record(StreamSample(stats: stats(received: 4000, playing: false), latencyMs: nil), at: start + 11)
        let session = recorder.snapshot
        #expect(session.playingSeconds == 10)
        #expect(session.bufferMaxMs == 8)
        #expect(abs((session.averageBufferMs ?? 0) - 6.4) < 0.01)
        #expect(session.averageLatencyMs == 10)
    }

    @Test func minutesAreKeptForTheLongGraph() {
        var recorder = StreamSessionRecorder(session: StreamSession(source: "echo", method: .resilient, started: start))
        var dropouts = 0
        for second in 0..<180 {
            // (The very first sample's counts are the output starting, so there's nothing to drop at second 0.)
            if second == 90 { dropouts += 2 }
            recorder.record(StreamSample(stats: stats(received: second * 375, dropouts: dropouts), latencyMs: 8), at: start + Double(second))
        }
        let minutes = recorder.snapshot.minutes
        #expect(minutes.map(\.offset) == [0, 60, 120])
        #expect(minutes.map(\.dropouts) == [0, 2, 0])
        #expect(minutes[1].playingSeconds == 60)
    }

    @Test func logKeepsOnlySessionsThatPlayedAndResumesRecentOnes() {
        var log = StreamLog()
        log.save(StreamSession(source: "echo", method: .raw, started: start))
        #expect(log.sessions.isEmpty)

        var recorder = StreamSessionRecorder(session: StreamSession(source: "echo", method: .raw, started: start))
        recorder.record(StreamSample(stats: stats(received: 10), latencyMs: nil), at: start)
        recorder.record(StreamSample(stats: stats(received: 20), latencyMs: nil), at: start + 1)
        log.save(recorder.snapshot)
        #expect(log.sessions.count == 1)
        #expect(log.resumable(source: "echo", method: .raw, at: start + 60) != nil)
        #expect(log.resumable(source: "echo", method: .resilient, at: start + 60) == nil)
        #expect(log.resumable(source: "echo", method: .raw, at: start + 600) == nil)

        // Carrying on: the new receiver's counts start from zero again.
        var resumed = StreamSessionRecorder(continuing: log.sessions[0])
        resumed.record(StreamSample(stats: stats(received: 5), latencyMs: nil), at: start + 70)
        log.save(resumed.snapshot)
        #expect(log.sessions.count == 1)
        #expect(log.sessions[0].counters.received == 25)
    }
}

@Suite struct StreamLogCodingTests {
    @Test func roundTrips() throws {
        var recorder = StreamSessionRecorder(session: StreamSession(source: "echo", method: .raw, started: Date()))
        var s = PlayoutStats()
        s.sampleRate = 48_000
        s.playing = true
        s.received = 10
        recorder.record(StreamSample(stats: s, latencyMs: 9), at: Date())
        s.received = 20
        recorder.record(StreamSample(stats: s, latencyMs: 9), at: Date() + 1)
        var log = StreamLog()
        log.save(recorder.snapshot)
        let data = try JSONEncoder().encode(log)
        let back = try JSONDecoder().decode(StreamLog.self, from: data)
        #expect(back == log)
    }
}

@Suite struct StreamTimelineTests {
    private func session(start: Date, minutes: [(offset: Double, buffer: Double, dropouts: Int)]) -> StreamSession {
        var s = StreamSession(source: "echo", method: .resilient, started: start)
        s.minutes = minutes.map {
            StreamMinute(offset: $0.offset, bufferMs: $0.buffer, bufferMaxMs: $0.buffer + 1, targetMs: 4, jitterMs: 0,
                         latencyMs: 10, dropouts: $0.dropouts, lost: 0, playingSeconds: 60)
        }
        return s
    }

    @Test func tidySteps() {
        #expect(StreamTimeline.step(for: 3600) == 60)
        #expect(StreamTimeline.step(for: 6 * 3600) == 300)
        #expect(StreamTimeline.step(for: 24 * 3600) == 900)
        #expect(StreamTimeline.step(for: 7 * 86400) == 7200)
    }

    @Test func averagesMinutesIntoStepsAndBreaksAtGaps() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = session(start: t0, minutes: [(0, 4, 0), (60, 6, 1), (120, 8, 0), (180, 10, 2)])
        // A second session after a half-hour gap.
        let b = session(start: t0 + 2100, minutes: [(0, 5, 0)])
        let points = StreamTimeline.points([a, b], from: t0, to: t0 + 3600, step: 120)
        #expect(points.count == 3)
        #expect(points[0].bufferMs == 5)
        #expect(points[0].bufferMaxMs == 7)
        #expect(points[0].dropouts == 1)
        #expect(points[1].bufferMs == 9)
        #expect(points[1].dropouts == 2)
        #expect(points[0].run == points[1].run)
        #expect(points[2].run == points[1].run + 1)
        #expect(points[2].latencyMs == 10)
    }
}

@Suite struct StreamLogTrimTests {
    @Test func minutesOlderThanAWeekAreDropped() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var old = StreamSession(source: "echo", method: .raw, started: t0)
        old.playingSeconds = 60
        old.minutes = [StreamMinute(offset: 0, bufferMs: 3, bufferMaxMs: 3, targetMs: 3, jitterMs: 0, latencyMs: nil,
                                    dropouts: 0, lost: 0, playingSeconds: 60)]
        var log = StreamLog()
        log.save(old)
        var recent = StreamSession(source: "echo", method: .raw, started: t0 + 9 * 86400)
        recent.playingSeconds = 60
        log.save(recent)
        #expect(log.sessions.count == 2)
        #expect(log.sessions[0].minutes.isEmpty)
        #expect(log.sessions[0].playingSeconds == 60)
    }
}
