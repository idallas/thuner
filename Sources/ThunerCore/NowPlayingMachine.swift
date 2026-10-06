import Foundation

/// The Idle / Identifying / Playing state machine from CLAUDE.md.
///
/// It's a pure value type: the app feeds it events (audio started/stopped, match results, clock ticks) and
/// performs the `Action`s it returns. Nothing in here touches audio, the network, or real time.
public struct NowPlayingMachine: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case idle, identifying, playing
    }

    public enum Action: Equatable, Sendable {
        /// Take a signature from the most recent audio and run it through ShazamKit.
        case query
        /// Show this track's cover art.
        case push(Track)
        /// Silence has lasted `idleImageDelay`; show the "nothing playing" image.
        case showIdleImage
    }

    public struct Timing: Equatable, Sendable {
        /// Seconds of audio a signature needs; also the wait before the first query once audio starts.
        public var sampleDuration: TimeInterval = 10
        /// Query interval while Identifying.
        public var identifyInterval: TimeInterval = 12
        /// Spot-check interval while Playing when the track's length is unknown.
        public var spotCheckInterval: TimeInterval = 75
        /// When the length is known, check this long after the predicted end.
        public var endOfTrackLead: TimeInterval = 5
        /// Never wait longer than this between checks while Playing, even if the predicted end is further off.
        public var maxPlayingCheckInterval: TimeInterval = 300
        /// Retry interval after a no-match while Playing.
        public var playingNoMatchRetry: TimeInterval = 30
        /// Silence this long shows the "nothing playing" image. nil = keep the last cover up forever.
        public var idleImageDelay: TimeInterval? = 300

        public init() {}
    }

    public var timing: Timing
    public private(set) var state: State = .idle
    /// What the display is showing (or would be, if pushes are suppressed by the other Mac).
    public private(set) var displayed: Track?
    /// The confirmed match while Playing.
    public private(set) var current: MatchObservation?
    /// A single unconfirmed result waiting for a second, agreeing one.
    public private(set) var candidate: Track?
    public private(set) var nextQueryAt: Date?
    public private(set) var queryInFlight = false
    public private(set) var idleImageShown = false
    private var silentSince: Date?

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    // MARK: Events

    public mutating func audioStarted(at now: Date) -> [Action] {
        guard state == .idle else { return [] }
        state = .identifying
        candidate = nil
        silentSince = nil
        nextQueryAt = now.addingTimeInterval(timing.sampleDuration)
        return []
    }

    public mutating func audioStopped(at now: Date) -> [Action] {
        guard state != .idle else { return [] }
        state = .idle
        candidate = nil
        current = nil
        nextQueryAt = nil
        silentSince = now
        return []
    }

    /// Run a query as soon as possible (the "Identify now" button). Does nothing while Idle.
    public mutating func requestQuery(at now: Date) -> [Action] {
        guard state != .idle else { return [] }
        nextQueryAt = now
        return tick(at: now)
    }

    public mutating func tick(at now: Date) -> [Action] {
        var actions: [Action] = []
        if state != .idle, !queryInFlight, let due = nextQueryAt, now >= due {
            queryInFlight = true
            nextQueryAt = nil
            actions.append(.query)
        }
        if state == .idle, !idleImageShown, let delay = timing.idleImageDelay, let since = silentSince,
           now.timeIntervalSince(since) >= delay {
            idleImageShown = true
            displayed = nil
            actions.append(.showIdleImage)
        }
        return actions
    }

    public mutating func handle(_ outcome: MatchOutcome, at now: Date) -> [Action] {
        queryInFlight = false
        // A result that lands after the audio went quiet is stale.
        guard state != .idle else { return [] }

        switch (state, outcome) {
        case (.identifying, .match(let m)):
            if let c = candidate, c.isSameSong(as: m.track) {
                return confirm(m, at: now)
            }
            // Picking back up after a short gap: the cover is already up, so one agreeing result is enough.
            if let d = displayed, d.isSameSong(as: m.track) {
                return confirm(m, at: now)
            }
            candidate = m.track
            nextQueryAt = now.addingTimeInterval(timing.identifyInterval)

        case (.identifying, _):
            candidate = nil
            nextQueryAt = now.addingTimeInterval(timing.identifyInterval)

        case (.playing, .match(let m)):
            if let cur = current, cur.track.isSameSong(as: m.track) {
                var refreshed = m
                refreshed.track.duration = m.track.duration ?? cur.track.duration
                current = refreshed
                scheduleWhilePlaying(at: now)
            } else {
                // Something new; it needs a second agreeing result before the display changes.
                state = .identifying
                current = nil
                candidate = m.track
                nextQueryAt = now.addingTimeInterval(timing.identifyInterval)
            }

        case (.playing, _):
            nextQueryAt = now.addingTimeInterval(timing.playingNoMatchRetry)

        case (.idle, _):
            break
        }
        return []
    }

    /// Something other than Shazam (Spotify, Apple Music) put `track` on the display. Recording it means a
    /// later Shazam match of the same song (heard through the speakers) won't push again, and anything
    /// different will.
    public mutating func displayedExternally(_ track: Track) {
        displayed = track
        // Whoever put it there decides when to clear it; an old silence timer here mustn't.
        idleImageShown = true
    }

    /// The display was cleared outside the machine (the "Clear" button, an external source going idle).
    public mutating func displayCleared() {
        displayed = nil
        idleImageShown = true
    }

    // MARK: Helpers

    private mutating func confirm(_ m: MatchObservation, at now: Date) -> [Action] {
        state = .playing
        current = m
        candidate = nil
        idleImageShown = false
        scheduleWhilePlaying(at: now)
        if let d = displayed, d.isSameSong(as: m.track) { return [] }
        displayed = m.track
        return [.push(m.track)]
    }

    private mutating func scheduleWhilePlaying(at now: Date) {
        var next = now.addingTimeInterval(timing.spotCheckInterval)
        if let end = current?.predictedEnd {
            let afterEnd = end.addingTimeInterval(timing.endOfTrackLead)
            // Don't re-query instantly if the prediction is already behind us (bad duration, a repeat, etc.).
            if afterEnd > now.addingTimeInterval(timing.identifyInterval) {
                next = min(afterEnd, now.addingTimeInterval(timing.maxPlayingCheckInterval))
            }
        }
        nextQueryAt = next
    }
}
