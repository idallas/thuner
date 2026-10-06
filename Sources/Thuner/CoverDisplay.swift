import Darwin
import Foundation
import Network
import ThunerCore
import os

/// Where confirmed cover art goes.
protocol CoverDisplay: Sendable {
    func show(_ track: Track) async throws
    /// Back to the device's own idle / default view after a long silence.
    func showIdle() async throws
}

/// The Tuneshine's local HTTP API (firmware 2.3.0+; spec at http://<device>/openapi.json).
///
/// - `POST /image` with JSON `{imageUrl, trackName, artistName, albumName, …}` shows an image. It overrides
///   whatever the Tuneshine server (Last.fm, Spotify…) is sending until it's removed.
/// - `DELETE /image` removes it, so the device goes back to its server-driven or idle view. Same as the
///   "Clear Tuneshine" shortcut.
struct TuneshineDisplay: CoverDisplay {
    enum TuneshineError: LocalizedError {
        case unresolvable(String)
        case http(Int, String)
        case imageFailed(String)
        case localNetworkDenied

        var errorDescription: String? {
            switch self {
            case .unresolvable(let host): "Couldn't find \(host) on the network"
            case .http(let code, let body): "Tuneshine returned HTTP \(code): \(body)"
            case .imageFailed(let code): "Tuneshine couldn't load the artwork (\(code))"
            case .localNetworkDenied: "macOS is blocking ThUNER from the local network. Turn on ThUNER in System Settings → Privacy & Security → Local Network."
            }
        }
    }

    /// e.g. "tuneshine-1a2b.local" or an IP address.
    let host: String
    private let log = Logger(subsystem: "com.idallas.thuner", category: "tuneshine")

    func show(_ track: Track) async throws {
        var body: [String: Any] = [
            "trackName": track.title,
            "artistName": track.artist,
            "serviceName": "ThUNER",
            "contentType": "track",
        ]
        if let album = track.album { body["albumName"] = album }
        if let id = track.shazamID { body["itemId"] = "shazam:\(id)" }
        // Best path: fetch a 64x64 WebP ourselves and upload it, so the device doesn't have to download
        // anything over its flaky Wi-Fi. Apple's image CDN (Shazam and Apple Music artwork) serves WebP at
        // any size.
        if let url = track.artworkURL, let webpURL = Self.webpArtworkURL(url), let webp = await Self.download(webpURL) {
            try await upload(webp, metadata: body)
            log.notice("Uploaded \(track.displayName, privacy: .public)")
            return
        }

        guard let url = track.artworkURL else {
            // Metadata only; keeps whatever image is up.
            _ = try await send("POST", path: "/image", body: body)
            return
        }
        body["imageUrl"] = Self.deviceFriendlyArtworkURL(url).absoluteString
        // The device fetches the image itself and its Wi-Fi fetches fail fairly often (FETCH_DEADLINE_ERROR,
        // HTTP_TRUNCATED_ERROR), while POST /image still returns 200. The POST returns once the fetch is done,
        // so check /state afterwards and retry.
        body["timeoutMs"] = 30_000
        var lastError = "unknown"
        for attempt in 1...3 {
            _ = try await send("POST", path: "/image", body: body)
            guard let error = try await lastImageError() else {
                log.notice("Pushed \(track.displayName, privacy: .public) (attempt \(attempt))")
                return
            }
            lastError = error
            log.error("Tuneshine image load failed (\(error, privacy: .public)), attempt \(attempt)")
            try await Task.sleep(for: .seconds(2))
        }
        throw TuneshineError.imageFailed(lastError)
    }

    /// mzstatic artwork URL rewritten to a 64x64 WebP, the size and format the device takes as an upload.
    static func webpArtworkURL(_ url: URL) -> URL? {
        guard url.host?.hasSuffix("mzstatic.com") == true else { return nil }
        var s = url.absoluteString
        guard let r = s.range(of: #"/\d+x\d+bb\.\w+$"#, options: .regularExpression) else { return nil }
        s.replaceSubrange(r, with: "/64x64bb.webp")
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        return URL(string: s)
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8),
              data.count <= 768_000 else { return nil }
        return data
    }

    /// POST /image as multipart/form-data: the WebP plus the metadata as a JSON string.
    private func upload(_ webp: Data, metadata: [String: Any]) async throws {
        let address = try await Self.ipv4Address(for: host)
        let boundary = "thuner-\(UUID().uuidString)"
        var body = Data()
        func part(_ headers: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"image\"; filename=\"cover.webp\"\r\nContent-Type: image/webp", webp)
        part("Content-Disposition: form-data; name=\"metadata\"", try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://\(address)/image")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.dataRetryingLocalNetwork(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw TuneshineError.localNetworkDenied
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TuneshineError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// `localMetadata.lastImageError` from GET /state: nil when the last local image loaded.
    private func lastImageError() async throws -> String? {
        let data = try await send("GET", path: "/state", body: nil)
        struct State: Decodable {
            struct Local: Decodable { var lastImageError: String? }
            var localMetadata: Local?
        }
        return try JSONDecoder().decode(State.self, from: data).localMetadata?.lastImageError
    }

    enum Health: Equatable {
        case ok(name: String, firmware: String)
        case localNetworkDenied
        case unreachable(String)
    }

    /// Actually talks to the device, which is the only reliable way to tell whether macOS lets Thuner on
    /// the local network: there's no API to read the Local Network privacy setting.
    func health() async -> Health {
        do {
            let data = try await send("GET", path: "/state", body: nil)
            struct State: Decodable {
                var name: String?
                var firmwareVersion: String
            }
            let state = try JSONDecoder().decode(State.self, from: data)
            return .ok(name: state.name ?? host, firmware: state.firmwareVersion)
        } catch TuneshineError.localNetworkDenied {
            return .localNetworkDenied
        } catch TuneshineError.unresolvable {
            // A denied app can't resolve .local names either; mDNS reports that as PolicyDenied.
            return await Self.dnsPolicyDenied(host) ? .localNetworkDenied : .unreachable("\(host) wasn't found on the network")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private static func dnsPolicyDenied(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
            // Everything below runs on this serial queue, so `finished` needs no lock.
            let queue = DispatchQueue(label: "thuner.localnetwork-check")
            nonisolated(unsafe) var finished = false
            let finish: @Sendable (Bool) -> Void = { denied in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: denied)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(false)
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        finish(true)
                    } else if case .failed = state {
                        finish(false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
    }

    /// The Tuneshine's brightness while showing art (1–100), from GET /state.
    func brightness() async -> Int? {
        guard let data = try? await send("GET", path: "/state", body: nil),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = json["config"] as? [String: Any],
              let brightness = config["brightness"] as? [String: Any] else { return nil }
        return (brightness["active"] as? NSNumber)?.intValue
    }

    /// POST /brightness: sets the brightness while showing art (1–100).
    func setBrightness(_ percent: Int) async throws {
        _ = try await send("POST", path: "/brightness", body: ["active": min(max(percent, 1), 100)])
    }

    func showIdle() async throws {
        _ = try await send("DELETE", path: "/image", body: nil)
        log.notice("Cleared the local image")
    }

    /// The display is 64×64, so there's no point making the device download and decode an 800px image. Apple's
    /// image CDN serves any size by rewriting the "{w}x{h}bb" path component. The Shortcut also downgraded
    /// to http, which saves the device a TLS handshake.
    static func deviceFriendlyArtworkURL(_ url: URL) -> URL {
        var s = url.absoluteString
        if let r = s.range(of: #"/\d+x\d+bb\."#, options: .regularExpression) {
            s.replaceSubrange(r, with: "/300x300bb.")
        }
        if s.hasPrefix("https://"), url.host?.hasSuffix("mzstatic.com") == true {
            s = "http://" + s.dropFirst("https://".count)
        }
        return URL(string: s) ?? url
    }

    @discardableResult
    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        // Tuneshine's docs warn that some clients try IPv6 first for .local names, which the device doesn't
        // support, so resolve to IPv4 ourselves.
        let address = try await Self.ipv4Address(for: host)
        var request = URLRequest(url: URL(string: "http://\(address)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 40
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.dataRetryingLocalNetwork(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            // What URLSession reports for a LAN address when Local Network privacy denies the app.
            throw TuneshineError.localNetworkDenied
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TuneshineError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    /// Right after launch macOS can briefly refuse LAN connections even when Local Network access is
    /// allowed (seen at launch: denied at +1s, fine at +25s), so retry a few times before believing it.
    private static func dataRetryingLocalNetwork(for request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .notConnectedToInternet && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func ipv4Address(for host: String) async throws -> String {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                throw TuneshineError.unresolvable(host)
            }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            return String(cString: buffer)
        }.value
    }
}
