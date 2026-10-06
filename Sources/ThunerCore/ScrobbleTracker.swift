import Foundation

/// Decides when to send Last.fm "now playing" and "scrobble" for what the state machine has confirmed.
///
/// Last.fm's rules: only tracks longer than 30 seconds, scrobbled once they've played for half their length or
/// 4 minutes, whichever comes first, timestamped with when the track started.
public struct ScrobbleTracker: Sendable {
    public enum Action: Equatable, Sendable {
        case nowPlaying(Track)
        case scrobble(Track, startedAt: Date)
    }

    public struct Play: Equatable, Sendable {
        public var track: Track
        /// When the track started, worked back from the match offset (so a late confirmation still counts
        /// the part we heard before it was identified).
        public var startedAt: Date
        public var scrobbled = false
    }

    public private(set) var play: Play?
    private var lastScrobbled: Play?

    public init() {}

    /// How long a track has to play before it can be scrobbled, or nil if it never qualifies.
    public static func threshold(for track: Track) -> TimeInterval? {
        guard let duration = track.duration else { return 240 }
        guard duration > 30 else { return nil }
        return min(duration / 2, 240)
    }

    /// Call after every state machine change and on each clock tick.
    /// - Parameters:
    ///   - confirmed: the machine's confirmed match while Playing, else nil.
    ///   - audible: false once the audio has gone silent (machine Idle), which ends the play.
    public mutating func update(confirmed: MatchObservation?, audible: Bool, at now: Date) -> [Action] {
        var actions: [Action] = []

        if !audible {
            play = nil
        } else if let m = confirmed, play.map({ !$0.track.isSameSong(as: m.track) }) ?? true {
            let track = m.track
            var new = Play(track: track, startedAt: m.observedAt.addingTimeInterval(-m.offset))
            // Picking the same song back up after a short gap: don't scrobble it twice.
            if let last = lastScrobbled, last.track.isSameSong(as: track),
               abs(last.startedAt.timeIntervalSince(new.startedAt)) < 90 {
                new.scrobbled = true
            }
            play = new
            actions.append(.nowPlaying(track))
        }
        // While Identifying (current nil, still audible) the previous track keeps counting until something
        // new is confirmed.

        if var p = play, !p.scrobbled, let threshold = Self.threshold(for: p.track),
           now.timeIntervalSince(p.startedAt) >= threshold {
            p.scrobbled = true
            play = p
            lastScrobbled = p
            actions.append(.scrobble(p.track, startedAt: p.startedAt))
        }
        return actions
    }
}
