import Foundation

/// Every play ThUNER saw, from any source, with what happened to its scrobble.
public struct PlayHistory: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case shazam = "Shazam"
        case appleMusic = "Apple Music"
        case spotify = "Spotify"
    }

    public enum ScrobbleStatus: Codable, Equatable, Sendable {
        /// Scrobbling off, or the play didn't run long enough.
        case notSent
        case scrobbled
        /// Waiting in the offline queue.
        case queued
        /// Not sent because it looked like a duplicate.
        case skippedDuplicate(String)
    }

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var track: Track
        public var startedAt: Date
        public var source: Source
        /// What happened at each scrobbling service, keyed by service id ("lastfm", or a ListenBrainz-style
        /// service's UUID).
        public var scrobbles: [String: ScrobbleStatus]

        public init(id: UUID = UUID(), track: Track, startedAt: Date, source: Source, scrobbles: [String: ScrobbleStatus] = [:]) {
            self.id = id
            self.track = track
            self.startedAt = startedAt
            self.source = source
            self.scrobbles = scrobbles
        }

        /// One status for the whole play: scrobbled if any service took it, else queued, else a duplicate.
        public var scrobble: ScrobbleStatus {
            let all = Array(scrobbles.values)
            if all.contains(.scrobbled) { return .scrobbled }
            if all.contains(.queued) { return .queued }
            return all.first { if case .skippedDuplicate = $0 { true } else { false } } ?? .notSent
        }

        private enum CodingKeys: String, CodingKey { case id, track, startedAt, source, scrobbles, scrobble }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            track = try c.decode(Track.self, forKey: .track)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            source = try c.decode(Source.self, forKey: .source)
            if let all = try c.decodeIfPresent([String: ScrobbleStatus].self, forKey: .scrobbles) {
                scrobbles = all
            } else {
                // History from before multiple services: the single status was Last.fm's.
                let old = try c.decodeIfPresent(ScrobbleStatus.self, forKey: .scrobble) ?? .notSent
                scrobbles = old == .notSent ? [:] : ["lastfm": old]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(track, forKey: .track)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(source, forKey: .source)
            try c.encode(scrobbles, forKey: .scrobbles)
        }
    }

    public static let maxEntries = 20_000

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Two start times this close together are the same play (picked back up after a gap, re-identified after
    /// a relaunch, reported by both Shazam and a player).
    public static func samePlayWindow(for track: Track) -> TimeInterval {
        max((track.duration ?? 300) * 0.8, 120)
    }

    /// Records a play and returns its entry id. A play that's already recorded is updated instead (filling in
    /// album, artwork and length if the new report has them), so the history has one row per play.
    @discardableResult
    public mutating func record(_ track: Track, startedAt: Date, source: Source) -> UUID {
        if let i = indexOfSamePlay(track, startedAt: startedAt) {
            var t = entries[i].track
            t.album = t.album ?? track.album
            t.artworkURL = t.artworkURL ?? track.artworkURL
            t.duration = t.duration ?? track.duration
            t.appleMusicID = t.appleMusicID ?? track.appleMusicID
            t.spotifyID = t.spotifyID ?? track.spotifyID
            entries[i].track = t
            // A player's report is more trustworthy than Shazam's.
            if entries[i].source == .shazam, source != .shazam { entries[i].source = source }
            return entries[i].id
        }
        let entry = Entry(track: track, startedAt: startedAt, source: source)
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        return entry.id
    }

    public mutating func setScrobble(_ status: ScrobbleStatus, service: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].scrobbles[service] = status
    }

    /// The entry for this play, if recorded.
    public func entry(for track: Track, startedAt: Date) -> Entry? {
        indexOfSamePlay(track, startedAt: startedAt).map { entries[$0] }
    }

    /// Whether ThUNER already scrobbled (or queued) this play to this service, e.g. before a relaunch.
    public func alreadyScrobbled(_ track: Track, startedAt: Date, service: String) -> Bool {
        let window = Self.samePlayWindow(for: track)
        return entries.contains {
            let status = $0.scrobbles[service]
            return (status == .scrobbled || status == .queued) && $0.track.isSameSong(as: track)
                && abs($0.startedAt.timeIntervalSince(startedAt)) < window
        }
    }

    private func indexOfSamePlay(_ track: Track, startedAt: Date) -> Int? {
        let window = Self.samePlayWindow(for: track)
        // Recent entries are at the end; plays being updated are almost always among the last few.
        return entries.indices.reversed().prefix(50).first {
            entries[$0].track.isSameSong(as: track) && abs(entries[$0].startedAt.timeIntervalSince(startedAt)) < window
        }
    }
}

/// A scrobble already on the user's Last.fm profile.
public struct RemoteScrobble: Equatable, Sendable {
    public var artist: String
    public var title: String
    public var date: Date

    public init(artist: String, title: String, date: Date) {
        self.artist = artist
        self.title = title
        self.date = date
    }

    /// The existing scrobble that's the same play as this one, if any (another scrobbler like Silicio,
    /// Spotify's own Last.fm link, or ThUNER on another Mac got there first).
    public static func duplicate(of track: Track, startedAt: Date, in recent: [RemoteScrobble]) -> RemoteScrobble? {
        let window = PlayHistory.samePlayWindow(for: track)
        return recent.first {
            track.isLikelySameSong(asTitle: $0.title, artistCredit: $0.artist) && abs($0.date.timeIntervalSince(startedAt)) < window
        }
    }
}
