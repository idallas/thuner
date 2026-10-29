import Foundation
import ThunerCore
import os

/// Watches the Music and Spotify apps on this Mac. Both post a distributed notification on every track
/// change and play/pause with the track's details, so this needs no permissions and no polling. Websites come in
/// through the Web Scrobbler browser extension's webhook (`receivedWebScrobbler`), as a third player.
///
/// The notifications only fire on changes, so whatever was already playing when Thuner launched shows up at
/// the next track change or play/pause.
@MainActor
final class PlayerMonitor {
    enum Source: String {
        case appleMusic = "Apple Music"
        case spotify = "Spotify"
        /// A website, through Web Scrobbler. `Snapshot.site` says which.
        case browser = "Browser"
    }

    struct Snapshot: Equatable {
        var source: Source
        var track: Track
        var isPlaying: Bool
        /// Seconds into the track when the notification arrived, if the player says.
        var position: TimeInterval?
        var receivedAt: Date
        /// For `.browser`: the site ("YouTube Music", "Bandcamp"…).
        var site: String?

        /// What to call it: the app, or the website.
        var name: String { site ?? source.rawValue }
    }

    /// Called with each change, after artwork has been looked up.
    var onChange: ((Snapshot) -> Void)?
    /// A cover from the player itself, when the catalogue lookups find none (set by AppModel).
    var playerArtwork: ((Source) async -> URL?)?

    private(set) var latest: [Source: Snapshot] = [:]
    private let artwork = ArtworkLookup()
    private let log = Logger(subsystem: "com.idallas.thuner", category: "players")
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { _ = self?.receivedMusic(info) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { _ = self?.receivedSpotify(info) }
        })
    }

    /// What's already playing at launch: the apps only announce changes, so a track playing before ThUNER started
    /// would otherwise go unseen until the next one (and the mic would listen meanwhile). Asks Apple Music and
    /// Spotify directly, only those already open that ThUNER may already control (never launches or asks), and
    /// returns once a playing track (with its cover) has been passed on.
    func checkWhatsPlaying() async {
        for source in [Source.appleMusic, .spotify] {
            guard let info = await PlayerControl.nowPlaying(source) else { continue }
            let lookup = source == .appleMusic ? receivedMusic(info) : receivedSpotify(info)
            await lookup?.value
        }
    }

    /// An event from Web Scrobbler's webhook. Pausing ends the play; a scrobble or love changes nothing here (ThUNER
    /// counts plays itself, as for the apps).
    func receivedWebScrobbler(_ event: WebScrobblerEvent) {
        guard !event.isPodcast else { return }
        switch event.kind {
        case .nowPlaying, .resumed:
            update(.browser, track: event.track, playing: true, position: event.position,
                   site: event.site, siteArtwork: event.siteArtwork)
        case .paused:
            update(.browser, track: event.track, playing: false, position: event.position,
                   site: event.site, siteArtwork: event.siteArtwork)
        case .scrobble, .loved:
            break
        }
    }

    /// A website that went quiet without saying so (its tab closed, the browser quit): Web Scrobbler sends nothing
    /// then, so a play ends once the song should have finished, plus a little, or after 10 minutes without a length.
    func expireBrowser(at now: Date) {
        guard let browser = latest[.browser], browser.isPlaying else { return }
        let remaining = browser.track.duration.map { max($0 - (browser.position ?? 0), 0) } ?? 600
        guard now.timeIntervalSince(browser.receivedAt) > remaining + 30 else { return }
        log.notice("\(browser.name, privacy: .public): no word since the song should have ended; counting it as stopped")
        var stopped = browser
        stopped.isPlaying = false
        stopped.receivedAt = now
        emit(stopped)
    }

    @discardableResult
    private func receivedMusic(_ info: [AnyHashable: Any]) -> Task<Void, Never>? {
        let playing = info["Player State"] as? String == "Playing"
        guard let name = info["Name"] as? String, let artist = info["Artist"] as? String else {
            // "Stopped" arrives without track details.
            return update(.appleMusic, track: latest[.appleMusic]?.track, playing: false, position: nil)
        }
        var track = Track(title: name, artist: artist, album: info["Album"] as? String)
        if let ms = info["Total Time"] as? Double ?? (info["Total Time"] as? Int).map(Double.init) { track.duration = ms / 1000 }
        return update(.appleMusic, track: track, playing: playing, position: nil)
    }

    @discardableResult
    private func receivedSpotify(_ info: [AnyHashable: Any]) -> Task<Void, Never>? {
        let playing = info["Player State"] as? String == "Playing"
        let id = info["Track ID"] as? String ?? ""
        // Ads and podcasts' interstitials aren't music.
        if id.hasPrefix("spotify:ad:") { return nil }
        guard let name = info["Name"] as? String, let artist = info["Artist"] as? String else {
            return update(.spotify, track: latest[.spotify]?.track, playing: false, position: nil)
        }
        var track = Track(title: name, artist: artist, album: info["Album"] as? String)
        if let ms = info["Duration"] as? Double ?? (info["Duration"] as? Int).map(Double.init) { track.duration = ms / 1000 }
        if id.hasPrefix("spotify:track:") { track.spotifyID = String(id.dropFirst("spotify:track:".count)) }
        return update(.spotify, track: track, playing: playing, position: info["Playback Position"] as? Double)
    }

    /// Passes the change on, after looking up artwork for a new track; the returned task finishes once it has.
    @discardableResult
    private func update(_ source: Source, track: Track?, playing: Bool, position: TimeInterval?,
                        site: String? = nil, siteArtwork: URL? = nil) -> Task<Void, Never>? {
        guard let track else { return nil }
        let receivedAt = Date()
        let previous = latest[source]
        // Same track as before (play/pause): keep the artwork we already found.
        if let previous, previous.track.isSameSong(as: track) {
            var t = track
            t.artworkURL = previous.track.artworkURL
            t.appleMusicID = previous.track.appleMusicID
            t.duration = t.duration ?? previous.track.duration
            emit(Snapshot(source: source, track: t, isPlaying: playing, position: position, receivedAt: receivedAt, site: site))
            return nil
        }
        log.notice("\(site ?? source.rawValue, privacy: .public): \(playing ? "playing" : "paused", privacy: .public) \(track.displayName, privacy: .public)")
        return Task {
            let found = await artwork.find(for: track)
            var t = track
            t.artworkURL = found.url
            if t.artworkURL == nil, let playerArtwork { t.artworkURL = await playerArtwork(source) }
            // The site's own picture last: often a video thumbnail rather than the cover, and the Tuneshine has to
            // fetch it itself.
            if t.artworkURL == nil { t.artworkURL = siteArtwork }
            t.appleMusicID = found.appleMusicID
            if t.duration == nil { t.duration = found.duration }
            emit(Snapshot(source: source, track: t, isPlaying: playing, position: position, receivedAt: receivedAt, site: site))
        }
    }

    private func emit(_ snapshot: Snapshot) {
        // A newer notification may have landed while artwork was being looked up.
        if let current = latest[snapshot.source], current.receivedAt > snapshot.receivedAt { return }
        latest[snapshot.source] = snapshot
        onChange?(snapshot)
    }
}

/// Cover art for player tracks, without logging in anywhere: Spotify's public oEmbed endpoint for Spotify
/// tracks, the iTunes Search API for everything else.
actor ArtworkLookup {
    struct Found {
        var url: URL?
        var appleMusicID: String?
        var duration: TimeInterval?
    }

    private var cache: [String: Found] = [:]

    func find(for track: Track) async -> Found {
        let key = track.spotifyID.map { "spotify:\($0)" } ?? "\(track.artist)|\(track.title)"
        if let hit = cache[key] { return hit }
        // Apple's CDN first, even for Spotify tracks: it can hand us a 64x64 WebP to upload to the Tuneshine,
        // which is far more reliable than the device downloading the image itself.
        var found = await itunesSearch(track) ?? Found()
        if found.url == nil, let id = track.spotifyID {
            found.url = await spotifyArtwork(id: id)
        }
        cache[key] = found
        return found
    }

    private func spotifyArtwork(id: String) async -> URL? {
        guard let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id)") else { return nil }
        struct OEmbed: Decodable { var thumbnail_url: String? }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let embed = try? JSONDecoder().decode(OEmbed.self, from: data),
              let thumb = embed.thumbnail_url else { return nil }
        return URL(string: thumb)
    }

    private func itunesSearch(_ track: Track) async -> Found? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(track.title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        struct Response: Decodable {
            struct Item: Decodable {
                var trackId: Int?
                var trackName: String?
                var artistName: String?
                var collectionName: String?
                var artworkUrl100: String?
                var trackTimeMillis: Double?
            }
            var results: [Item]
        }
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let candidates = response.results.filter {
            Track(title: $0.trackName ?? "", artist: $0.artistName ?? "").isSameSong(as: track)
        }
        // Prefer the same album, so a compilation doesn't win over the original release.
        let best = candidates.first { $0.collectionName == track.album } ?? candidates.first
        guard let best, let art = best.artworkUrl100 else {
            // Apple's search misses some songs that are in the catalogue (NOFX's "Perfect Government" is track 7
            // of "Punk in Drublic", yet searching for it finds nothing), and tracks from your own library aren't
            // there at all. The album's other songs carry the same cover.
            return await albumArtwork(track).map { Found(url: $0) }
        }
        return Found(
            url: URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
            appleMusicID: best.trackId.map(String.init),
            duration: best.trackTimeMillis.map { $0 / 1000 })
    }

    /// The album's cover from Apple's catalogue (any song from it), if the artist and album name match.
    private func albumArtwork(_ track: Track) async -> URL? {
        guard let album = track.album, !album.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            // Songs, not albums: the album search misses some albums whose songs it finds, and every song on
            // the album carries the album's cover.
            URLQueryItem(name: "term", value: "\(track.artist) \(album)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        struct Response: Decodable {
            struct Item: Decodable {
                var artistName: String?
                var collectionName: String?
                var artworkUrl100: String?
            }
            var results: [Item]
        }
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        func simple(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        let artist = simple(track.artist), wanted = simple(album)
        let match = response.results.first {
            simple($0.artistName ?? "") == artist && simple($0.collectionName ?? "").hasPrefix(wanted)
        }
        guard let art = match?.artworkUrl100 else { return nil }
        return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}
