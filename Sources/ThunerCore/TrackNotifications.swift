import Foundation

/// What a track-change notification says, and when one is due. Which sources notify is a `SourceSwitches`
/// (`forNotifications()` for the defaults).
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
