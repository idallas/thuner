import Foundation
import ThunerCore
import os

/// Watches the Music and Spotify apps on this Mac. Both post a distributed notification on every track
/// change and play/pause with the track's details, so this needs no permissions and no polling.
///
/// The notifications only fire on changes, so whatever was already playing when Thuner launched shows up at
/// the next track change or play/pause.
@MainActor
final class PlayerMonitor {
    enum Source: String {
        case appleMusic = "Apple Music"
        case spotify = "Spotify"
    }

    struct Snapshot: Equatable {
        var source: Source
        var track: Track
        var isPlaying: Bool
        /// Seconds into the track when the notification arrived, if the player says.
        var position: TimeInterval?
        var receivedAt: Date
    }

    /// Called with each change, after artwork has been looked up.
    var onChange: ((Snapshot) -> Void)?

    private(set) var latest: [Source: Snapshot] = [:]
    private let artwork = ArtworkLookup()
    private let log = Logger(subsystem: "com.idallas.thuner", category: "players")
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.receivedMusic(info) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.receivedSpotify(info) }
        })
    }

    private func receivedMusic(_ info: [AnyHashable: Any]) {
        let playing = info["Player State"] as? String == "Playing"
        guard let name = info["Name"] as? String, let artist = info["Artist"] as? String else {
            // "Stopped" arrives without track details.
            update(.appleMusic, track: latest[.appleMusic]?.track, playing: false, position: nil)
            return
        }
        var track = Track(title: name, artist: artist, album: info["Album"] as? String)
        if let ms = info["Total Time"] as? Double ?? (info["Total Time"] as? Int).map(Double.init) { track.duration = ms / 1000 }
        update(.appleMusic, track: track, playing: playing, position: nil)
    }

    private func receivedSpotify(_ info: [AnyHashable: Any]) {
        let playing = info["Player State"] as? String == "Playing"
        let id = info["Track ID"] as? String ?? ""
        // Ads and podcasts' interstitials aren't music.
        if id.hasPrefix("spotify:ad:") { return }
        guard let name = info["Name"] as? String, let artist = info["Artist"] as? String else {
            update(.spotify, track: latest[.spotify]?.track, playing: false, position: nil)
            return
        }
        var track = Track(title: name, artist: artist, album: info["Album"] as? String)
        if let ms = info["Duration"] as? Double ?? (info["Duration"] as? Int).map(Double.init) { track.duration = ms / 1000 }
        if id.hasPrefix("spotify:track:") { track.spotifyID = String(id.dropFirst("spotify:track:".count)) }
        update(.spotify, track: track, playing: playing, position: info["Playback Position"] as? Double)
    }

    private func update(_ source: Source, track: Track?, playing: Bool, position: TimeInterval?) {
        guard let track else { return }
        let receivedAt = Date()
        let previous = latest[source]
        // Same track as before (play/pause): keep the artwork we already found.
        if let previous, previous.track.isSameSong(as: track) {
            var t = track
            t.artworkURL = previous.track.artworkURL
            t.appleMusicID = previous.track.appleMusicID
            emit(Snapshot(source: source, track: t, isPlaying: playing, position: position, receivedAt: receivedAt))
            return
        }
        log.notice("\(source.rawValue, privacy: .public): \(playing ? "playing" : "paused", privacy: .public) \(track.displayName, privacy: .public)")
        Task {
            let found = await artwork.find(for: track)
            var t = track
            t.artworkURL = found.url
            t.appleMusicID = found.appleMusicID
            if t.duration == nil { t.duration = found.duration }
            emit(Snapshot(source: source, track: t, isPlaying: playing, position: position, receivedAt: receivedAt))
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
        guard let best, let art = best.artworkUrl100 else { return nil }
        return Found(
            url: URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
            appleMusicID: best.trackId.map(String.init),
            duration: best.trackTimeMillis.map { $0 / 1000 })
    }
}
