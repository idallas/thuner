import Foundation

/// Running counts for a stream session. Kept across the output closing in quiet gaps (each reopening starts the
/// playout's own counts from zero again).
public struct StreamCounters: Codable, Sendable, Equatable {
    public var received = 0
    public var lost = 0
    public var late = 0
    public var dropouts = 0
    /// Raw: samples dropped or repeated to follow the sender's clock.
    public var corrections = 0
    /// Resilient: lost packets asked for again, and how many came back in time.
    public var resendsRequested = 0
    public var resendsRecovered = 0

    public init() {}

    static func + (a: Self, b: Self) -> Self {
        var sum = a
        sum.received += b.received
        sum.lost += b.lost
        sum.late += b.late
        sum.dropouts += b.dropouts
        sum.corrections += b.corrections
        sum.resendsRequested += b.resendsRequested
        sum.resendsRecovered += b.resendsRecovered
        return sum
    }
}

/// A minute of a session, for the long graph: the buffer (average and worst), its target, jitter, latency, and what
/// went wrong. Minutes with no audio playing at all aren't kept.
public struct StreamMinute: Codable, Sendable, Equatable {
    /// Seconds from the session's start to the start of this minute.
    public var offset: Double
    public var bufferMs: Double
    public var bufferMaxMs: Double
    public var targetMs: Double
    public var jitterMs: Double
    public var latencyMs: Double?
    public var dropouts: Int
    public var lost: Int
    /// Seconds of the minute with audio playing.
    public var playingSeconds: Double
}

/// One listening session: from choosing a Mac to listen to until stopping (or switching to another). Short breaks
/// (a settings change, ThUNER relaunching for an update) carry on the same session.
public struct StreamSession: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var source: String
    public var method: StreamMethod
    public var started: Date
    /// Last time it was recorded: the end, once it's over.
    public var ended: Date
    /// Time with audio actually playing (quiet gaps between records don't count).
    public var playingSeconds = 0.0
    public var counters = StreamCounters()
    public var bufferMaxMs = 0.0
    public var latencyMaxMs: Double?
    public var jitterMaxMs = 0.0
    public var minutes: [StreamMinute] = []
    /// Sums for the averages (per second of playing).
    var bufferSum = 0.0
    var latencySum = 0.0
    var latencyCount = 0.0

    public init(source: String, method: StreamMethod, started: Date) {
        self.source = source
        self.method = method
        self.started = started
        ended = started
    }

    public var averageBufferMs: Double? { playingSeconds > 0 ? bufferSum / playingSeconds : nil }
    public var averageLatencyMs: Double? { latencyCount > 0 ? latencySum / latencyCount : nil }
}

/// A moment of the stream, as the recorder sees it once a second.
public struct StreamSample: Sendable {
    public var stats: PlayoutStats?
    public var latencyMs: Double?
    /// Cumulative since the receiver started (it outlives the playout).
    public var resendsRequested: Int
    public var resendsRecovered: Int
    /// The output's own buffer, which the playout's buffer level includes and the latency counts as output: taken
    /// off the buffer and its target, as the live meter does.
    public var outputBufferMs: Double

    public init(stats: PlayoutStats?, latencyMs: Double?, resendsRequested: Int = 0, resendsRecovered: Int = 0,
                outputBufferMs: Double = 0) {
        self.stats = stats
        self.latencyMs = latencyMs
        self.outputBufferMs = outputBufferMs
        self.resendsRequested = resendsRequested
        self.resendsRecovered = resendsRecovered
    }
}

/// Builds a `StreamSession` from once-a-second samples. The playout's counts start again from zero whenever the
/// output reopens (and the receiver's when listening restarts), so it adds up the differences rather than taking the
/// counts as they are.
public struct StreamSessionRecorder: Sendable {
    public private(set) var session: StreamSession
    private var last: StreamCounters?
    private var lastAt: Date?
    private var minute: Accumulator?

    private struct Accumulator: Sendable {
        var index: Int
        var seconds = 0.0
        var buffer = 0.0
        var bufferMax = 0.0
        var target = 0.0
        var jitter = 0.0
        var latency = 0.0
        var latencyCount = 0.0
        var dropouts = 0
        var lost = 0
    }

    public init(session: StreamSession) {
        self.session = session
    }

    /// Carries on an earlier session after a short break (counts start again from the new receiver's zero).
    public init(continuing session: StreamSession) {
        self.session = session
    }

    public mutating func record(_ sample: StreamSample, at now: Date) {
        let elapsed = lastAt.map { min(max(now.timeIntervalSince($0), 0), 5) } ?? 0
        lastAt = now
        session.ended = now

        var current = StreamCounters()
        if let stats = sample.stats {
            current.received = stats.received
            current.lost = stats.lost
            current.late = stats.late
            current.dropouts = stats.underruns
            current.corrections = stats.adjustments
        }
        current.resendsRequested = sample.resendsRequested
        current.resendsRecovered = sample.resendsRecovered
        var delta = Self.delta(from: last, to: current)
        // The output just (re)opened: its first moments always count a dropout or two while it fills, at every
        // relaunch and whenever the sender starts again after a quiet spell. Not the network's doing, so not counted.
        if let stats = sample.stats, last == nil || current.received < (last?.received ?? 0) || stats.received == delta.received {
            delta.dropouts = 0
            delta.lost = 0
        }
        last = current
        session.counters = session.counters + delta

        let index = Int(now.timeIntervalSince(session.started) / 60)
        if let m = minute, m.index != index { closeMinute() }
        if minute == nil { minute = Accumulator(index: index) }
        minute!.dropouts += delta.dropouts
        minute!.lost += delta.lost

        guard let stats = sample.stats, stats.playing, elapsed > 0 else { return }
        let buffer = max(stats.bufferedMs - sample.outputBufferMs, 0)
        let target = max(stats.targetMs - sample.outputBufferMs, 0)
        session.playingSeconds += elapsed
        session.bufferSum += buffer * elapsed
        session.bufferMaxMs = max(session.bufferMaxMs, buffer)
        session.jitterMaxMs = max(session.jitterMaxMs, stats.jitterMs)
        if let latency = sample.latencyMs {
            session.latencySum += latency
            session.latencyCount += 1
            session.latencyMaxMs = max(session.latencyMaxMs ?? 0, latency)
        }
        minute!.seconds += elapsed
        minute!.buffer += buffer * elapsed
        minute!.bufferMax = max(minute!.bufferMax, buffer)
        minute!.target += target * elapsed
        minute!.jitter = max(minute!.jitter, stats.jitterMs)
        if let latency = sample.latencyMs {
            minute!.latency += latency
            minute!.latencyCount += 1
        }
    }

    /// The session so far, including the minute in progress (for showing it live, or saving it).
    public var snapshot: StreamSession {
        var copy = self
        copy.closeMinute()
        return copy.session
    }

    private mutating func closeMinute() {
        guard let m = minute else { return }
        minute = nil
        guard m.seconds > 0 || m.dropouts > 0 || m.lost > 0 else { return }
        let entry = StreamMinute(offset: Double(m.index) * 60,
                                 bufferMs: m.seconds > 0 ? m.buffer / m.seconds : 0,
                                 bufferMaxMs: m.bufferMax,
                                 targetMs: m.seconds > 0 ? m.target / m.seconds : 0,
                                 jitterMs: m.jitter,
                                 latencyMs: m.latencyCount > 0 ? m.latency / m.latencyCount : nil,
                                 dropouts: m.dropouts, lost: m.lost, playingSeconds: m.seconds)
        if let i = session.minutes.lastIndex(where: { $0.offset == entry.offset }) {
            session.minutes[i] = entry
        } else {
            session.minutes.append(entry)
        }
        // A session can run for weeks; the graph only goes back a week.
        let oldest = entry.offset - StreamLog.minutesKept
        if let first = session.minutes.first, first.offset < oldest {
            session.minutes.removeAll { $0.offset < oldest }
        }
    }

    /// What happened since the last sample. A count lower than last time means it started over (the output reopened,
    /// or the receiver restarted), so all of it is new.
    static func delta(from last: StreamCounters?, to now: StreamCounters) -> StreamCounters {
        guard let last else { return now }
        func d(_ a: Int, _ b: Int) -> Int { b >= a ? b - a : b }
        // The playout's counts restart together; judge them by `received`, which only ever grows otherwise.
        let restarted = now.received < last.received
        var out = StreamCounters()
        out.received = restarted ? now.received : d(last.received, now.received)
        out.lost = restarted ? now.lost : d(last.lost, now.lost)
        out.late = restarted ? now.late : d(last.late, now.late)
        out.dropouts = restarted ? now.dropouts : d(last.dropouts, now.dropouts)
        out.corrections = restarted ? now.corrections : d(last.corrections, now.corrections)
        out.resendsRequested = d(last.resendsRequested, now.resendsRequested)
        out.resendsRecovered = d(last.resendsRecovered, now.resendsRecovered)
        return out
    }
}

/// Past sessions, newest last, saved as JSON. Only sessions that played audio are kept.
public struct StreamLog: Codable, Sendable, Equatable {
    public static let keep = 100
    /// Minute-by-minute detail is kept for this long (the graph goes back 7 days); totals are kept for good.
    public static let minutesKept: TimeInterval = 8 * 86400
    /// A session that ended less than this long ago carries on rather than a new one starting.
    public static let continueWithin: TimeInterval = 120

    public var sessions: [StreamSession] = []

    public init() {}

    /// Adds or updates a session (matched by id).
    public mutating func save(_ session: StreamSession) {
        if let i = sessions.lastIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else if session.playingSeconds > 0 {
            sessions.append(session)
            if sessions.count > Self.keep { sessions.removeFirst(sessions.count - Self.keep) }
        }
        // Older sessions' minutes go once they're past the graph's reach.
        let cutoff = session.ended.addingTimeInterval(-Self.minutesKept)
        for i in sessions.indices where sessions[i].id != session.id && !sessions[i].minutes.isEmpty {
            let started = sessions[i].started
            sessions[i].minutes.removeAll { started.addingTimeInterval($0.offset) < cutoff }
        }
    }

    /// The last session, if it's the same source and method and ended only moments ago.
    public func resumable(source: String, method: StreamMethod, at now: Date) -> StreamSession? {
        guard let last = sessions.last, last.source == source, last.method == method,
              now.timeIntervalSince(last.ended) < Self.continueWithin else { return nil }
        return last
    }
}

/// One step of the long graph: some minutes of one or more sessions averaged together (the worst buffer and the
/// dropouts are kept as worst and total, not averaged).
public struct StreamPoint: Sendable, Equatable {
    public var time: Date
    public var bufferMs: Double
    public var bufferMaxMs: Double
    public var targetMs: Double
    public var latencyMs: Double?
    public var dropouts: Int
    public var lost: Int
    public var playingSeconds: Double
    /// Points in a row share a run; a gap (nothing played) starts a new one, so the lines break there.
    public var run: Int
}

public enum StreamTimeline {
    /// A step that gives at most about `points` points over `span`: a whole number of minutes, rounded up to a
    /// tidy one (1, 2, 5, 10, 15, 30 minutes, 1, 2, 4 hours).
    public static func step(for span: TimeInterval, points: Int = 120) -> TimeInterval {
        let wanted = span / Double(max(points, 1))
        let tidy: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 240].map { $0 * 60 }
        return tidy.first { $0 >= wanted } ?? tidy.last!
    }

    /// The minutes of `sessions` from `from` up to `to`, averaged into steps of `step` seconds.
    public static func points(_ sessions: [StreamSession], from: Date, to: Date, step: TimeInterval) -> [StreamPoint] {
        struct Sum {
            var seconds = 0.0, buffer = 0.0, bufferMax = 0.0, target = 0.0
            var latency = 0.0, latencyWeight = 0.0
            var dropouts = 0, lost = 0
        }
        var sums: [Int: Sum] = [:]
        for session in sessions {
            for minute in session.minutes {
                let time = session.started.addingTimeInterval(minute.offset)
                guard time >= from, time < to else { continue }
                let key = Int(time.timeIntervalSince(from) / step)
                var sum = sums[key] ?? Sum()
                let w = minute.playingSeconds
                sum.seconds += w
                sum.buffer += minute.bufferMs * w
                sum.bufferMax = max(sum.bufferMax, minute.bufferMaxMs)
                sum.target += minute.targetMs * w
                if let latency = minute.latencyMs, w > 0 {
                    sum.latency += latency * w
                    sum.latencyWeight += w
                }
                sum.dropouts += minute.dropouts
                sum.lost += minute.lost
                sums[key] = sum
            }
        }
        var points: [StreamPoint] = []
        var run = 0
        var previous: Int?
        for key in sums.keys.sorted() {
            let sum = sums[key]!
            if let previous, key != previous + 1 { run += 1 }
            previous = key
            let w = sum.seconds
            points.append(StreamPoint(time: from.addingTimeInterval(Double(key) * step),
                                      bufferMs: w > 0 ? sum.buffer / w : 0, bufferMaxMs: sum.bufferMax,
                                      targetMs: w > 0 ? sum.target / w : 0,
                                      latencyMs: sum.latencyWeight > 0 ? sum.latency / sum.latencyWeight : nil,
                                      dropouts: sum.dropouts, lost: sum.lost, playingSeconds: w, run: run))
        }
        return points
    }
}
