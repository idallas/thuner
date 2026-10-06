import Foundation

public struct Track: Equatable, Sendable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    public var artworkURL: URL?
    public var shazamID: String?
    public var isrc: String?
    public var appleMusicID: String?
    public var spotifyID: String?
    /// Track length in seconds, when known (ShazamKit doesn't provide it; filled in from an iTunes lookup).
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, artworkURL: URL? = nil,
                shazamID: String? = nil, isrc: String? = nil, appleMusicID: String? = nil,
                spotifyID: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.shazamID = shazamID
        self.isrc = isrc
        self.appleMusicID = appleMusicID
        self.spotifyID = spotifyID
        self.duration = duration
    }

    /// Two results "agree" when they're the same song, even if they came back as different catalog entries
    /// (album version vs. compilation, etc.).
    public func isSameSong(as other: Track) -> Bool {
        if let a = shazamID, let b = other.shazamID, a == b { return true }
        if let a = isrc, let b = other.isrc, a == b { return true }
        if let a = spotifyID, let b = other.spotifyID, a == b { return true }
        return Track.normalize(title) == Track.normalize(other.title)
            && Track.normalize(artist) == Track.normalize(other.artist)
    }

    public var displayName: String { "\(artist) – \(title)" }

    /// The individual artists in a credit like "A & B", "A feat. B", "A, B" or "A x B", normalized.
    public static func artistNames(_ credit: String) -> Set<String> {
        var s = " " + credit.lowercased() + " "
        for separator in [",", "&", ";", "/", " and ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " x ", " vs. ", " vs "] {
            s = s.replacingOccurrences(of: separator, with: "|")
        }
        let names = s.split(separator: "|").map { normalize(String($0)) }.filter { !$0.isEmpty }
        return Set(names).union([normalize(credit)])
    }

    /// Same title and at least one artist in common, for matching against other services' records, which
    /// split or join collaborations differently ("A & B" vs. ["A", "B"]).
    public func isLikelySameSong(asTitle otherTitle: String, artistCredit otherArtist: String) -> Bool {
        guard Track.normalize(title) == Track.normalize(otherTitle) else { return false }
        return !Track.artistNames(artist).isDisjoint(with: Track.artistNames(otherArtist))
    }

    static func normalize(_ s: String) -> String {
        var s = s.lowercased()
        // Drop "(Remastered 2011)", "[Live]", " - Single Version" style suffixes.
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let o = s.range(of: open), let c = s.range(of: close, range: o.upperBound..<s.endIndex) {
                s.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }
        return s.filter { $0.isLetter || $0.isNumber }
    }
}

/// One successful ShazamKit match.
public struct MatchObservation: Equatable, Sendable {
    public var track: Track
    /// Position within the track (seconds) at `observedAt`.
    public var offset: TimeInterval
    public var observedAt: Date

    public init(track: Track, offset: TimeInterval, observedAt: Date) {
        self.track = track
        self.offset = offset
        self.observedAt = observedAt
    }

    /// When the track should end, if we know its duration.
    public var predictedEnd: Date? {
        guard let d = track.duration, d > offset else { return nil }
        return observedAt.addingTimeInterval(d - offset)
    }
}

public enum MatchOutcome: Equatable, Sendable {
    case match(MatchObservation)
    case noMatch
    case error(String)
}
