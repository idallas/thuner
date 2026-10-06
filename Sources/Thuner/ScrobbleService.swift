import Foundation
import ThunerCore

/// Something ThUNER can scrobble to: Last.fm, or a ListenBrainz-style server (ListenBrainz, Maloja, Koito,
/// multi-scrobbler).
protocol ScrobbleService: Actor {
    /// Stable id used in the play history: "lastfm", or the service's UUID.
    nonisolated var id: String { get }
    var displayName: String { get }
    var isConnected: Bool { get }
    var pendingCount: Int { get }

    func updateNowPlaying(_ track: Track) async throws
    /// Queues the scrobble (persisted to disk) and tries to send everything queued.
    func scrobble(_ track: Track, startedAt: Date) async throws
    func flush() async throws
    /// This user's scrobbles in a time range, for duplicate checks; nil if the service can't say.
    func recentScrobbles(from: Date, to: Date) async throws -> [RemoteScrobble]?
}

/// The offline queue shared by every service: plays waiting to be sent, persisted as JSON so they survive
/// relaunches and network outages.
struct ScrobbleQueue {
    struct Item: Codable, Equatable {
        var artist: String
        var track: String
        var album: String?
        var duration: Int?
        var timestamp: Int
        // Extra identifiers ListenBrainz-style servers can use.
        var isrc: String?
        var spotifyID: String?
        var appleMusicID: String?

        init(_ track: Track, startedAt: Date) {
            artist = track.artist
            self.track = track.title
            album = track.album
            duration = track.duration.map { Int($0) }
            timestamp = Int(startedAt.timeIntervalSince1970)
            isrc = track.isrc
            spotifyID = track.spotifyID
            appleMusicID = track.appleMusicID
        }
    }

    private let url: URL
    private(set) var items: [Item] = []

    init(fileName: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thuner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url) {
            items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        }
    }

    mutating func append(_ item: Item) {
        items.append(item)
        save()
    }

    mutating func removeFirst(_ n: Int) {
        items.removeFirst(min(n, items.count))
        save()
    }

    mutating func removeAll() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
