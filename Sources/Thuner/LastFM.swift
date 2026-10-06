import CryptoKit
import Foundation
import Security
import ThunerCore
import os

/// Last.fm Scrobbling API 2.0 client: desktop auth, now playing, and scrobbles with an offline queue.
/// https://www.last.fm/api/scrobbling
actor LastFM: ScrobbleService {
    nonisolated let id = "lastfm"
    var displayName: String { "Last.fm" }
    var isConnected: Bool { session != nil }

    struct Credentials: Codable, Equatable {
        var apiKey: String
        var secret: String
    }

    struct Session: Codable, Equatable {
        var username: String
        var key: String
    }

    struct PendingScrobble: Codable, Equatable {
        var artist: String
        var track: String
        var album: String?
        var duration: Int?
        var timestamp: Int
    }

    enum LastFMError: LocalizedError {
        case notConfigured
        case notConnected
        case api(code: Int, message: String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Last.fm API key and secret aren't set"
            case .notConnected: "Not connected to a Last.fm account"
            case .api(let code, let message): "Last.fm error \(code): \(message)"
            case .badResponse: "Unexpected response from Last.fm"
            }
        }

        /// Errors worth retrying later rather than dropping the scrobble: service offline / temporarily
        /// unavailable, and rate limiting.
        var isTemporary: Bool {
            if case .api(let code, _) = self { return [11, 16, 29].contains(code) }
            return false
        }

        /// The session key is no longer valid (revoked on last.fm, etc.).
        var isAuthFailure: Bool {
            if case .api(let code, _) = self { return [4, 9, 14].contains(code) }
            return false
        }
    }

    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let log = Logger(subsystem: "com.idallas.thuner", category: "lastfm")
    private let queueURL: URL

    private(set) var credentials: Credentials?
    private(set) var session: Session?
    private var pendingToken: String?
    private(set) var queue: [PendingScrobble] = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thuner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        queueURL = support.appendingPathComponent("scrobble-queue.json")
        // A key entered in Settings wins; otherwise use the one built into the app (Scripts/build-app.sh), so
        // each Mac only has to approve ThUNER on last.fm.
        credentials = Keychain.read(Credentials.self, account: "lastfm-credentials") ?? Self.bundledCredentials
        session = Keychain.read(Session.self, account: "lastfm-session")
        if let data = try? Data(contentsOf: queueURL) {
            queue = (try? JSONDecoder().decode([PendingScrobble].self, from: data)) ?? []
        }
    }

    private static var bundledCredentials: Credentials? {
        let info = Bundle.main.infoDictionary
        guard let key = info?["LastFMAPIKey"] as? String, let secret = info?["LastFMSharedSecret"] as? String,
              !key.isEmpty, !secret.isEmpty else { return nil }
        return Credentials(apiKey: key, secret: secret)
    }

    // MARK: Setup and auth (desktop flow: https://www.last.fm/api/desktopauth)

    func setCredentials(_ credentials: Credentials) {
        self.credentials = credentials
        Keychain.write(credentials, account: "lastfm-credentials")
    }

    /// Step 1: get a request token and return the URL where the user approves it.
    func beginAuth() async throws -> URL {
        guard let credentials else { throw LastFMError.notConfigured }
        let response = try await call("auth.getToken", [:], signed: true, post: false)
        guard let token = response["token"] as? String else { throw LastFMError.badResponse }
        pendingToken = token
        return URL(string: "https://www.last.fm/api/auth/?api_key=\(credentials.apiKey)&token=\(token)")!
    }

    /// Step 2, after the user approved in the browser: exchange the token for a permanent session key.
    func finishAuth() async throws -> Session {
        guard let token = pendingToken else { throw LastFMError.notConnected }
        let response = try await call("auth.getSession", ["token": token], signed: true, post: false)
        guard let s = response["session"] as? [String: Any], let name = s["name"] as? String,
              let key = s["key"] as? String else { throw LastFMError.badResponse }
        let session = Session(username: name, key: key)
        self.session = session
        pendingToken = nil
        Keychain.write(session, account: "lastfm-session")
        log.notice("Connected to Last.fm as \(name, privacy: .public)")
        return session
    }

    func disconnect() {
        session = nil
        pendingToken = nil
        Keychain.delete(account: "lastfm-session")
    }

    // MARK: Scrobbling

    func updateNowPlaying(_ track: Track) async throws {
        guard let session else { throw LastFMError.notConnected }
        var params = ["artist": track.artist, "track": track.title, "sk": session.key]
        if let album = track.album { params["album"] = album }
        if let d = track.duration { params["duration"] = String(Int(d)) }
        do {
            _ = try await call("track.updateNowPlaying", params, signed: true, post: true)
        } catch let error as LastFMError where error.isAuthFailure {
            disconnect()
            throw error
        }
    }

    /// Queues the scrobble (persisted to disk) and tries to send everything that's queued.
    func scrobble(_ track: Track, startedAt: Date) async throws {
        queue.append(PendingScrobble(
            artist: track.artist, track: track.title, album: track.album,
            duration: track.duration.map { Int($0) }, timestamp: Int(startedAt.timeIntervalSince1970)))
        saveQueue()
        try await flush()
    }

    /// Sends queued scrobbles, up to 50 per request. Network failures and temporary Last.fm errors leave
    /// them queued for the next attempt.
    func flush() async throws {
        guard let session else { throw LastFMError.notConnected }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(50))
            var params = ["sk": session.key]
            for (i, s) in batch.enumerated() {
                params["artist[\(i)]"] = s.artist
                params["track[\(i)]"] = s.track
                params["timestamp[\(i)]"] = String(s.timestamp)
                if let album = s.album { params["album[\(i)]"] = album }
                if let d = s.duration { params["duration[\(i)]"] = String(d) }
            }
            do {
                let response = try await call("track.scrobble", params, signed: true, post: true)
                let accepted = ((response["scrobbles"] as? [String: Any])?["@attr"] as? [String: Any])?["accepted"]
                log.notice("Scrobbled \(batch.count) (accepted: \(String(describing: accepted), privacy: .public))")
            } catch let error as LastFMError where error.isAuthFailure {
                disconnect()
                throw error
            } catch let error as LastFMError where !error.isTemporary {
                // Last.fm rejected the batch outright (bad parameters); retrying won't help.
                log.error("Dropping \(batch.count) scrobbles: \(error.localizedDescription, privacy: .public)")
            }
            // URLError and temporary errors propagate here, leaving the batch queued.
            queue.removeFirst(batch.count)
            saveQueue()
        }
    }

    var pendingCount: Int { queue.count }

    /// The user's scrobbles between two times (user.getRecentTracks), for duplicate checks. Excludes the
    /// "now playing" row, which has no timestamp.
    func recentScrobbles(from: Date, to: Date) async throws -> [RemoteScrobble]? {
        guard let session else { throw LastFMError.notConnected }
        let response = try await call("user.getRecentTracks", [
            "user": session.username,
            "from": String(Int(from.timeIntervalSince1970)),
            "to": String(Int(to.timeIntervalSince1970)),
            "limit": "50",
        ], signed: false, post: false)
        guard let recent = response["recenttracks"] as? [String: Any] else { throw LastFMError.badResponse }
        // A single result comes back as an object rather than a one-element array.
        let raw: [[String: Any]] = (recent["track"] as? [[String: Any]]) ?? ((recent["track"] as? [String: Any]).map { [$0] } ?? [])
        return raw.compactMap { t in
            guard let name = t["name"] as? String,
                  let artist = (t["artist"] as? [String: Any])?["#text"] as? String,
                  let uts = ((t["date"] as? [String: Any])?["uts"] as? String).flatMap(Double.init) else { return nil }
            return RemoteScrobble(artist: artist, title: name, date: Date(timeIntervalSince1970: uts))
        }
    }

    // MARK: Plumbing

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func call(_ method: String, _ params: [String: String], signed: Bool, post: Bool) async throws -> [String: Any] {
        guard let credentials else { throw LastFMError.notConfigured }
        var all = params
        all["method"] = method
        all["api_key"] = credentials.apiKey
        if signed {
            // api_sig: md5 of every parameter (except format/callback) as name+value, sorted by name, + secret.
            let base = all.keys.sorted().map { $0 + all[$0]! }.joined() + credentials.secret
            all["api_sig"] = Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        all["format"] = "json"

        // urlQueryAllowed leaves '+', '&' and '=' alone, but they're separators in a form body.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")

        var request: URLRequest
        if post {
            request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(encoded.utf8)
        } else {
            request = URLRequest(url: URL(string: Self.endpoint.absoluteString + "?" + encoded)!)
        }
        request.timeoutInterval = 20
        request.setValue("Thuner/0.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LastFMError.badResponse }
        if let code = json["error"] as? Int {
            throw LastFMError.api(code: code, message: json["message"] as? String ?? "")
        }
        return json
    }
}

/// Small generic-password Keychain wrapper for Codable values.
enum Keychain {
    private static let service = "com.idallas.thuner"

    static func read<T: Decodable>(_ type: T.Type, account: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
