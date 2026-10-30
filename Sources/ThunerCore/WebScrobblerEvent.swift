import Foundation

/// One event from the Web Scrobbler browser extension's Webhook option, which POSTs
/// `{"eventName": …, "time": …, "data": {"song": …}}` to a URL of your choice whenever a song on a website
/// starts, pauses, resumes or counts as played. The song is Web Scrobbler's own object, serialized: what the
/// site showed (`parsed`), Web Scrobbler's corrections and your edits (`processed`), and `metadata`/`connector`
/// with the site's name.
public struct WebScrobblerEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case nowPlaying = "nowplaying"
        case paused
        case resumed = "resumedplaying"
        case scrobble
        case loved
    }

    public var kind: Kind
    public var track: Track
    /// The site, as Web Scrobbler names it: "YouTube Music", "Bandcamp", "SoundCloud"…
    public var site: String
    /// The site's own cover (or video thumbnail), if it showed one.
    public var siteArtwork: URL?
    /// The song's page on the site.
    public var pageURL: URL?
    /// Seconds into the song when the event was sent, if the site says.
    public var position: TimeInterval?
    /// When Web Scrobbler saw the song start.
    public var startedAt: Date?
    public var isPodcast: Bool
    /// The browser it came from, from the webhook request's User-Agent (not part of the body).
    public var browser: Browser?

    /// A browser family, as far as its User-Agent tells: the apps it may be (Brave, Arc and Chrome all say Chrome).
    public struct Browser: Equatable, Sendable {
        public var name: String
        public var bundleIDs: [String]

        public init?(userAgent: String) {
            // Most specific first: Edge and Opera also say Chrome, and Chrome says Safari.
            let families: [(token: String, name: String, bundleIDs: [String])] = [
                ("Edg/", "Edge", ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"]),
                ("OPR/", "Opera", ["com.operasoftware.Opera", "com.operasoftware.OperaGX"]),
                ("Vivaldi/", "Vivaldi", ["com.vivaldi.Vivaldi"]),
                ("Firefox/", "Firefox", ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
                                         "app.zen-browser.zen", "io.gitlab.librewolf-community", "net.waterfox.waterfox"]),
                ("Chrome/", "Chrome", ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                                       "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                                       "org.chromium.Chromium", "com.microsoft.edgemac", "com.operasoftware.Opera"]),
                ("Safari/", "Safari", ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
            ]
            guard let family = families.first(where: { userAgent.contains($0.token) }) else { return nil }
            name = family.name
            bundleIDs = family.bundleIDs
        }
    }

    public init(kind: Kind, track: Track, site: String, siteArtwork: URL? = nil, pageURL: URL? = nil,
                position: TimeInterval? = nil, startedAt: Date? = nil, isPodcast: Bool = false) {
        self.kind = kind
        self.track = track
        self.site = site
        self.siteArtwork = siteArtwork
        self.pageURL = pageURL
        self.position = position
        self.startedAt = startedAt
        self.isPodcast = isPodcast
    }

    /// The event in a webhook request's body, or nil for anything else (an unknown event, a song with no artist
    /// or title).
    public static func parse(_ body: Data) -> WebScrobblerEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let kind = (root["eventName"] as? String).flatMap(Kind.init(rawValue:)),
              let data = root["data"] as? [String: Any],
              let song = data["song"] as? [String: Any] else { return nil }
        let parsed = song["parsed"] as? [String: Any] ?? [:]
        let processed = song["processed"] as? [String: Any] ?? [:]
        let metadata = song["metadata"] as? [String: Any] ?? [:]
        let connector = song["connector"] as? [String: Any] ?? [:]

        /// Web Scrobbler's correction if it made one, else what the site showed.
        func field(_ key: String) -> String? {
            for source in [processed, parsed] {
                if let value = (source[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

        guard let artist = field("artist").map(withoutTopic), !artist.isEmpty, let title = field("track") else { return nil }
        var track = Track(title: title, artist: artist, album: field("album"))
        if let duration = number(parsed["duration"]) ?? number(processed["duration"]), duration > 0 {
            track.duration = duration
        }
        let site = metadata["label"] as? String ?? connector["label"] as? String ?? "Browser"
        let art = (parsed["trackArt"] as? String) ?? (metadata["trackArtUrl"] as? String)
        return WebScrobblerEvent(
            kind: kind,
            track: track,
            site: site,
            siteArtwork: art.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil },
            pageURL: (parsed["originUrl"] as? String).flatMap(URL.init(string:)),
            position: number(parsed["currentTime"]),
            startedAt: number(metadata["startTimestamp"]).map { Date(timeIntervalSince1970: $0) },
            isPodcast: parsed["isPodcast"] as? Bool ?? false)
    }

    /// YouTube's auto-generated channels are named "Artist - Topic", and Web Scrobbler doesn't always drop that.
    static func withoutTopic(_ artist: String) -> String {
        guard artist.hasSuffix(" - Topic") else { return artist }
        return String(artist.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespaces)
    }
}
