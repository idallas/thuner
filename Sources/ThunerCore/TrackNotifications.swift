import Foundation

/// Which sources show a notification when their track changes. Keyed like `ScrobbleSources`, by the name shown
/// for the source. Apple Music and Spotify start switched off: each shows its own banners (Music → Settings →
/// General, Spotify → Settings → Display), so ThUNER's would double them. Everything else (Shazam here, another
/// Mac's records, websites, apps, AirPlay) starts on.
public struct NotificationSources: Equatable, Sendable {
    public static let defaultOff: Set<String> = [PlayHistory.Source.appleMusic.rawValue, PlayHistory.Source.spotify.rawValue]

    /// Sources switched off.
    public var off: Set<String>

    public init(off: Set<String> = NotificationSources.defaultOff) {
        self.off = off
    }

    public func allows(_ source: String) -> Bool { !off.contains(source) }

    public mutating func set(_ source: String, on: Bool) {
        if on { off.remove(source) } else { off.insert(source) }
    }
}

/// What a track-change notification says, and when one is due.
public enum TrackNotifications {
    public struct Content: Equatable, Sendable {
        public var title: String
        public var subtitle: String
        public var body: String
    }

    /// A notification is for a new song: not the first look at a restored track, and not the same song with its
    /// album, cover or length filled in (which changes the `Track` without changing what's playing).
    public static func isNewSong(from previous: Track?, to shown: Track?) -> Bool {
        guard let shown else { return false }
        guard let previous else { return true }
        return !previous.isSameSong(as: shown)
    }

    /// Title: the song. Subtitle: artist, and the album when known. Body: where it's playing.
    public static func content(for track: Track, source: PlayHistory.Source, sourceName: String) -> Content {
        var subtitle = track.artist
        if let album = track.album, !album.isEmpty, album != track.title { subtitle += " — " + album }
        let airPlaySuffix = " (AirPlay)"
        let body = switch source {
        case .shazam: "Identified with Shazam"
        case .anotherMac: "Playing on \(sourceName)"
        case .appleMusic, .spotify, .browser, .nowPlaying:
            if sourceName == "AirPlay" {
                "Playing over AirPlay"
            } else if sourceName.hasSuffix(airPlaySuffix) {
                "Playing from \(sourceName.dropLast(airPlaySuffix.count)) over AirPlay"
            } else {
                "Playing in \(sourceName)"
            }
        }
        return Content(title: track.title, subtitle: subtitle, body: body)
    }
}
