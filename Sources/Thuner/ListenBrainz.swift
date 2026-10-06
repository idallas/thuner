import Foundation
import ThunerCore
import os

/// A ListenBrainz-compatible scrobbling server: ListenBrainz itself, or self-hosted Maloja, Koito or
/// multi-scrobbler, which all accept `POST <base>/1/submit-listens` with `Authorization: Token <token>`.
///
/// Reading recent listens (for duplicate checks) isn't part of the shared protocol, so it's done with each
/// server's own API once the kind of server is known.
actor ListenBrainzService: ScrobbleService {
    struct Config: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case listenBrainz = "ListenBrainz"
            case maloja = "Maloja"
            case koito = "Koito"
            case multiScrobbler = "multi-scrobbler"
            case other = "Other"

            /// Where the ListenBrainz-compatible API lives, relative to the server address the user enters.
            var apiPath: String {
                switch self {
                case .maloja, .koito: "/apis/listenbrainz"
                case .listenBrainz, .multiScrobbler, .other: ""
                }
            }
        }

        var id = UUID()
        var name: String
        var kind: Kind
        /// For ListenBrainz: https://api.listenbrainz.org. Otherwise the server's address, e.g. https://maloja.example.com.
        var serverURL: String
        /// Filled in from validate-token.
        var username: String?
        var enabled = true

        /// The server's own address, normalized: trimmed, https:// if no scheme was given, no trailing slash,
        /// and without the ListenBrainz API path in case that's what was pasted.
        static func serverRoot(_ serverURL: String, kind: Kind?) -> URL? {
            var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            if !s.contains("://") { s = "https://" + s }
            let apiPath = "/apis/listenbrainz"
            if kind?.apiPath.isEmpty != true, s.hasSuffix(apiPath) { s.removeLast(apiPath.count) }
            return URL(string: s)
        }

        var serverRoot: URL? { Self.serverRoot(serverURL, kind: kind) }

        /// The server is reached over plain HTTP across a network, so the token would travel in the clear.
        /// Loopback, .local names and private (home network) addresses are allowed: that's where self-hosted
        /// servers usually live, and the traffic never leaves the LAN.
        static func isCleartextRemote(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
            if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host == "::1" { return false }
            let parts = host.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4 {
                if parts[0] == 127 || parts[0] == 10 { return false }
                if parts[0] == 192, parts[1] == 168 { return false }
                if parts[0] == 172, (16...31).contains(parts[1]) { return false }
            }
            return true
        }

        /// Where the ListenBrainz-compatible API lives.
        var apiBase: URL? {
            guard let root = serverRoot else { return nil }
            return URL(string: root.absoluteString + kind.apiPath)
        }
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case cleartext(String)
        case invalidToken(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The server address or token is missing"
            case .cleartext(let host): "\(host) is reached over plain http, which would send the token unencrypted across the internet. Use an https:// address."
            case .invalidToken(let message): "The server rejected the token\(message.isEmpty ? "" : ": \(message)")"
            case .http(let code, let body): "Server returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            }
        }

        /// Worth retrying later rather than dropping (server down, rate limited).
        var isTemporary: Bool {
            if case .http(let code, _) = self { return code == 429 || code >= 500 }
            return false
        }
    }

    nonisolated let id: String
    private(set) var config: Config
    private var queue: ScrobbleQueue
    private let log = Logger(subsystem: "com.idallas.thuner", category: "listenbrainz")

    init(config: Config) {
        self.config = config
        id = config.id.uuidString
        queue = ScrobbleQueue(fileName: "scrobble-queue-\(config.id.uuidString).json")
    }

    var displayName: String { config.name }
    var isConnected: Bool { config.enabled && token != nil && config.apiBase != nil }
    var pendingCount: Int { queue.items.count }

    private var token: String? { Keychain.read(String.self, account: Self.tokenAccount(config.id)) }

    static func tokenAccount(_ id: UUID) -> String { "listenbrainz-token-\(id.uuidString)" }

    func update(_ config: Config) {
        self.config = config
    }

    // MARK: Setup

    /// Checks the token with the server and returns the user name it belongs to.
    static func validate(_ config: Config, token: String) async throws -> String? {
        guard let base = config.apiBase else { throw ServiceError.notConfigured }
        if Config.isCleartextRemote(base) { throw ServiceError.cleartext(base.host ?? config.serverURL) }
        var request = URLRequest(url: base.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw code == 401 || code == 403
                ? ServiceError.invalidToken(json["message"] as? String ?? "")
                : ServiceError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let valid = json["valid"] as? Bool, !valid {
            throw ServiceError.invalidToken(json["message"] as? String ?? "")
        }
        return json["user_name"] as? String
    }

    /// Guesses what kind of server is at an address, so the user doesn't have to know.
    static func detectKind(serverURL: String) async -> Config.Kind? {
        if serverURL.contains("listenbrainz.org") { return .listenBrainz }
        guard let root = Config.serverRoot(serverURL, kind: nil)?.absoluteString else { return nil }
        func answers(_ path: String) async -> Bool {
            guard let url = URL(string: root + path) else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
        if await answers("/apis/mlj_1/serverinfo") { return .maloja }
        if await answers("/apis/web/v1/stats") { return .koito }
        return nil
    }

    // MARK: Scrobbling

    func updateNowPlaying(_ track: Track) async throws {
        // Maloja accepts playing_now but throws it away; skip the request.
        guard config.kind != .maloja else { return }
        var metadata = Self.metadata(ScrobbleQueue.Item(track, startedAt: Date()))
        metadata.removeValue(forKey: "listened_at")
        try await submit(listenType: "playing_now", payload: [metadata])
    }

    func scrobble(_ track: Track, startedAt: Date) async throws {
        queue.append(ScrobbleQueue.Item(track, startedAt: startedAt))
        try await flush()
    }

    func flush() async throws {
        while !queue.items.isEmpty {
            let batch = Array(queue.items.prefix(100))
            do {
                try await submit(listenType: batch.count == 1 ? "single" : "import", payload: batch.map(Self.metadata))
                log.notice("\(self.config.name, privacy: .public): sent \(batch.count) listen(s)")
            } catch let error as ServiceError where !error.isTemporary {
                if case .invalidToken = error { throw error }  // keep them queued until the token's fixed
                log.error("\(self.config.name, privacy: .public): dropping \(batch.count) listen(s): \(error.localizedDescription, privacy: .public)")
            }
            // Network errors and temporary server errors propagate above, leaving the batch queued.
            queue.removeFirst(batch.count)
        }
    }

    func recentScrobbles(from: Date, to: Date) async throws -> [RemoteScrobble]? {
        switch config.kind {
        case .listenBrainz: try await listenBrainzListens(from: from, to: to)
        case .maloja: try await malojaScrobbles(from: from, to: to)
        case .koito: try await koitoListens(from: from, to: to)
        case .multiScrobbler, .other: nil
        }
    }

    // MARK: Plumbing

    private static func metadata(_ item: ScrobbleQueue.Item) -> [String: Any] {
        var info: [String: Any] = [
            "submission_client": "ThUNER",
            "submission_client_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "media_player": "ThUNER",
        ]
        if let d = item.duration { info["duration_ms"] = d * 1000 }
        if let isrc = item.isrc { info["isrc"] = isrc }
        if let id = item.spotifyID { info["spotify_id"] = "https://open.spotify.com/track/\(id)" }
        if let id = item.appleMusicID { info["origin_url"] = "https://music.apple.com/song/\(id)" }
        var metadata: [String: Any] = [
            "artist_name": item.artist,
            "track_name": item.track,
            "additional_info": info,
        ]
        if let album = item.album { metadata["release_name"] = album }
        return ["listened_at": item.timestamp, "track_metadata": metadata]
    }

    private func submit(listenType: String, payload: [[String: Any]]) async throws {
        guard let base = config.apiBase, let token else { throw ServiceError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["listen_type": listenType, "payload": payload])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw code == 401 ? ServiceError.invalidToken(body) : ServiceError.http(code, body)
        }
    }

    private func getJSON(_ url: URL, authorized: Bool = false) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if authorized, let token { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ServiceError.http(code, "") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// GET /1/user/{name}/listens?min_ts=&max_ts=
    private func listenBrainzListens(from: Date, to: Date) async throws -> [RemoteScrobble]? {
        guard let base = config.apiBase, let user = config.username,
              var components = URLComponents(url: base.appendingPathComponent("1/user/\(user)/listens"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "min_ts", value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "count", value: "100"),
        ]
        let json = try await getJSON(components.url!) as? [String: Any]
        let listens = (json?["payload"] as? [String: Any])?["listens"] as? [[String: Any]] ?? []
        return listens.compactMap { l in
            guard let ts = l["listened_at"] as? Double, let m = l["track_metadata"] as? [String: Any],
                  let artist = m["artist_name"] as? String, let title = m["track_name"] as? String else { return nil }
            let date = Date(timeIntervalSince1970: ts)
            return date <= to ? RemoteScrobble(artist: artist, title: title, date: date) : nil
        }
    }

    /// Maloja's own API: GET /apis/mlj_1/scrobbles?from=&until= (dates as YYYY/MM/DD, so filter by time here).
    private func malojaScrobbles(from: Date, to: Date) async throws -> [RemoteScrobble]? {
        guard let root = config.serverRoot,
              var components = URLComponents(url: root.appendingPathComponent("apis/mlj_1/scrobbles"), resolvingAgainstBaseURL: false)
        else { return nil }
        let day = DateFormatter()
        day.dateFormat = "yyyy/MM/dd"
        day.timeZone = .current
        components.queryItems = [
            URLQueryItem(name: "from", value: day.string(from: from)),
            URLQueryItem(name: "until", value: day.string(from: to)),
            URLQueryItem(name: "perpage", value: "200"),
        ]
        let json = try await getJSON(components.url!) as? [String: Any]
        let list = json?["list"] as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let time = s["time"] as? Double, let track = s["track"] as? [String: Any],
                  let title = track["title"] as? String else { return nil }
            let artists = (track["artists"] as? [String]) ?? []
            let date = Date(timeIntervalSince1970: time)
            guard date >= from, date <= to else { return nil }
            return RemoteScrobble(artist: artists.joined(separator: ", "), title: title, date: date)
        }
    }

    /// Koito's web API: GET /apis/web/v1/listens?limit= (newest first).
    private func koitoListens(from: Date, to: Date) async throws -> [RemoteScrobble]? {
        guard let root = config.serverRoot,
              var components = URLComponents(url: root.appendingPathComponent("apis/web/v1/listens"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        let json = try await getJSON(components.url!, authorized: true)
        let list = (json as? [String: Any])?["items"] as? [[String: Any]] ?? (json as? [[String: Any]] ?? [])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return list.compactMap { l in
            guard let timeString = l["time"] as? String,
                  let date = iso.date(from: timeString) ?? plain.date(from: timeString),
                  let track = l["track"] as? [String: Any], let title = track["title"] as? String else { return nil }
            let artists = (track["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            guard date >= from, date <= to else { return nil }
            return RemoteScrobble(artist: artists.joined(separator: ", "), title: title, date: date)
        }
    }
}
