import Foundation
import Network
import os

/// ThUNER's small HTTP server: the web display, and an API to ThUNER's controls for anything on the network
/// (Home Assistant, Stream Deck/Companion, scripts, dashboards).
///
///   GET  /                    the display page (Tuneshine look; `?mode=cover` for the large cover)
///   GET  /now.json            what's playing, with a version number that changes when it does
///   GET  /api                 a short description of the API
///   GET  /api/controls        every control with its current value / text / on
///   GET  /api/events          Server-Sent Events: a snapshot, then every control and now-playing change
///                             (?levels=1 adds the live input meter, about 10 a second)
///   POST /api/controls/<id>   {"value": 0.5} turns a level, {"press": true} presses, {"on": true} sets a toggle
///
/// Reading is open to the network (that's what lets other screens show the display). Changing anything needs
/// the API token (`Authorization: Bearer <token>` or `?token=`), except from programs on this Mac itself.
/// Web pages always need it, even on this Mac: see `authorized`.
final class WebDisplayServer: @unchecked Sendable {
    struct NowPlaying: Codable, Equatable, Sendable {
        /// "playing", "identifying" or "idle".
        var state = "idle"
        var title: String?
        var artist: String?
        var album: String?
        var artwork: String?
        /// Where it came from: "Shazam", "Apple Music", "Spotify", or the turntable Mac's name.
        var source: String?
    }

    struct ControlInfo: Sendable {
        var definition: ControlSurface.Definition
        var state: ControlSurface.State
    }

    enum Action: Sendable {
        case turn(Double)
        case press
        case set(Bool)
    }

    static let defaultPort: UInt16 = 47_480

    /// Called (on the main queue) to carry out an authorized action on a control.
    var onAction: (@Sendable (_ id: String, _ action: Action) -> Void)?

    private let queue = DispatchQueue(label: "com.idallas.thuner.web")
    private let lock = NSLock()
    private var listener: NWListener?
    private var current = NowPlaying()
    private var version = 1
    private var controls: [ControlInfo] = []
    private var token = ""
    /// Open event streams, and whether each asked for live meter levels (?levels=1).
    private var eventStreams: [ObjectIdentifier: (connection: NWConnection, levels: Bool)] = [:]
    /// Controls whose changes are meter readings, only sent to streams that ask for them.
    private static let meterControls: Set<String> = ["inputLevel"]
    private var keepAlive: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.idallas.thuner", category: "web")

    private(set) var port: UInt16 = defaultPort
    var isRunning: Bool { listener != nil }

    /// - Parameter localOnly: listen on loopback only, so nothing else on the network can reach the server.
    func start(port: UInt16, localOnly: Bool = false) {
        stop()
        self.port = port
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if localOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            }
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.log.notice("Web display and API at http://localhost:\(port)/")
                case .failed(let error): self?.log.error("Web server failed: \(error.localizedDescription, privacy: .public)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            startKeepAlive()
        } catch {
            log.error("Couldn't start the web server on port \(port): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        keepAlive?.cancel()
        keepAlive = nil
        lock.lock()
        let streams = eventStreams.values.map(\.connection)
        eventStreams.removeAll()
        lock.unlock()
        streams.forEach { $0.cancel() }
    }

    // MARK: State from the app

    func setToken(_ token: String) {
        lock.lock(); self.token = token; lock.unlock()
    }

    func update(_ nowPlaying: NowPlaying) {
        lock.lock()
        guard nowPlaying != current else { lock.unlock(); return }
        current = nowPlaying
        version += 1
        lock.unlock()
        broadcast(["type": "nowPlaying", "nowPlaying": Self.json(nowPlaying)])
    }

    func setControls(_ controls: [ControlInfo]) {
        lock.lock(); self.controls = controls; lock.unlock()
    }

    func controlChanged(_ id: String, _ state: ControlSurface.State) {
        lock.lock()
        if let i = controls.firstIndex(where: { $0.definition.id == id }) { controls[i].state = state }
        lock.unlock()
        var event: [String: Any] = ["type": "control", "id": id]
        Self.addState(state, to: &event)
        broadcast(event, meter: Self.meterControls.contains(id))
    }

    // MARK: Requests

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    /// Whether a connection's request has arrived; touched only on `queue`.
    private final class Pending {
        var answered = false
    }

    /// How long a client gets to send its whole request. Without a limit, connections that open and never
    /// finish (slowly or on purpose) would pile up.
    private static let requestTimeout: TimeInterval = 10

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let pending = Pending()
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            if !pending.answered { connection.cancel() }
        }
        read(connection, buffer: Data(), pending: pending)
    }

    /// The most a request (headers and body) may be. Anything bigger is dropped.
    private static let maxRequestSize = 1_000_000

    private enum Parsed {
        case incomplete
        case invalid
        case request(Request)
    }

    /// Reads until the headers and the whole body (by Content-Length) have arrived.
    private func read(_ connection: NWConnection, buffer: Data, pending: Pending) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                pending.answered = true
                self.respond(to: request, on: connection)
            case .invalid:
                pending.answered = true
                self.sendJSON(connection, ["error": "bad request"], status: "400 Bad Request")
            case .incomplete:
                if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer, pending: pending)
                }
            }
        }
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerEnd.upperBound
        // A missing Content-Length means no body. A negative, non-numeric or huge one is a bad request, not
        // something to slice by.
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0, parsed <= maxRequestSize - bodyStart else { return .invalid }
            length = parsed
        } else {
            length = 0
        }
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(Request(method: String(requestLine[0]).uppercased(), path: components?.path ?? target, query: query,
                                headers: headers, body: data[bodyStart..<(bodyStart + length)]))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            send(connection, status: "204 No Content", type: "text/plain", body: Data())
        case ("GET", "/"), ("GET", "/index.html"), ("GET", "/cover"), ("GET", "/tuneshine"):
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebDisplayPage.html.utf8))
        case ("GET", "/now.json"):
            lock.lock()
            var payload = Self.json(current)
            payload["version"] = version
            lock.unlock()
            sendJSON(connection, payload)
        case ("GET", "/api"):
            sendJSON(connection, [
                "name": "ThUNER",
                "endpoints": [
                    "GET /api/controls": "every control with its current value, text and on",
                    "GET /api/events": "Server-Sent Events: a snapshot, then control and nowPlaying changes (?levels=1 adds the live input meter, ~10/s)",
                    "POST /api/controls/<id>": "{\"value\": 0-1} turns a level, {\"press\": true} presses, {\"on\": bool} sets a toggle",
                    "GET /now.json": "what's playing",
                ],
                "auth": "POST needs 'Authorization: Bearer <token>' or ?token=<token> (token in ThUNER Settings → Display), except from scripts on this Mac; web pages always need it",
            ])
        case ("GET", "/api/controls"):
            sendJSON(connection, ["controls": controlsJSON()])
        case ("GET", "/api/events"):
            openEventStream(connection, levels: request.query["levels"] == "1")
        case ("POST", let path) where path.hasPrefix("/api/controls/"):
            act(on: String(path.dropFirst("/api/controls/".count)), request: request, connection: connection)
        default:
            sendJSON(connection, ["error": "not found"], status: "404 Not Found")
        }
    }

    private func act(on id: String, request: Request, connection: NWConnection) {
        guard authorized(request, connection) else {
            sendJSON(connection, ["error": "unauthorized: send the API token from ThUNER's Settings"], status: "401 Unauthorized")
            return
        }
        lock.lock()
        let control = controls.first { $0.definition.id == id }
        lock.unlock()
        guard let control else {
            sendJSON(connection, ["error": "no control '\(id)'"], status: "404 Not Found")
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let action: Action
        if let value = (body["value"] as? NSNumber)?.doubleValue {
            guard control.definition.kind == .level, !control.definition.readOnly else {
                sendJSON(connection, ["error": "'\(id)' can't be turned"], status: "400 Bad Request")
                return
            }
            action = .turn(value)
        } else if let on = body["on"] as? Bool, control.definition.kind == .toggle {
            action = .set(on)
        } else if body["press"] as? Bool == true || body.isEmpty, control.definition.kind != .level {
            action = .press
        } else {
            sendJSON(connection, ["error": "send {\"value\": 0-1}, {\"press\": true} or {\"on\": true|false}"], status: "400 Bad Request")
            return
        }
        let handler = onAction
        DispatchQueue.main.async { handler?(id, action) }
        sendJSON(connection, ["ok": true])
    }

    /// Changing things needs the token, unless the request comes from a program on this Mac.
    ///
    /// A web page in a browser on this Mac is also a loopback client, and any site could POST here from the
    /// user's browser (the responses allow every origin so dashboards elsewhere can use the API). Browsers
    /// always send an Origin header with such requests, and curl, scripts and Shortcuts don't, so a request
    /// with an Origin needs the token wherever it comes from.
    private func authorized(_ request: Request, _ connection: NWConnection) -> Bool {
        if request.headers["origin"] == nil, case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address) where address == .loopback: return true
            case .ipv6(let address) where address == .loopback: return true
            default: break
            }
        }
        lock.lock(); let token = self.token; lock.unlock()
        guard !token.isEmpty else { return false }
        let bearer = request.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        return Self.matches(bearer, token) || Self.matches(request.query["token"], token)
    }

    /// Compares in constant time, so response timing says nothing about how much of a guess was right.
    private static func matches(_ candidate: String?, _ token: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Server-Sent Events

    /// Enough for every screen and dashboard in a house; stops a flood of connections from piling up memory.
    private static let maxEventStreams = 32

    private func openEventStream(_ connection: NWConnection, levels: Bool) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
        lock.lock()
        guard eventStreams.count < Self.maxEventStreams else {
            lock.unlock()
            sendJSON(connection, ["error": "too many event streams open"], status: "503 Service Unavailable")
            return
        }
        var nowPlaying = Self.json(current)
        nowPlaying["version"] = version
        let snapshot: [String: Any] = ["type": "snapshot", "controls": controlsJSONLocked(), "nowPlaying": nowPlaying]
        eventStreams[ObjectIdentifier(connection)] = (connection, levels)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.dropStream(connection) }
            if case .cancelled = state { self.dropStream(connection) }
        }
        connection.send(content: Data(head.utf8) + Self.event(snapshot), completion: .contentProcessed { _ in })
    }

    private func broadcast(_ payload: [String: Any], meter: Bool = false) {
        lock.lock(); let streams = eventStreams.values.filter { !meter || $0.levels }.map(\.connection); lock.unlock()
        guard !streams.isEmpty else { return }
        let data = Self.event(payload)
        for stream in streams {
            stream.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.dropStream(stream) }
            })
        }
    }

    private func dropStream(_ connection: NWConnection) {
        lock.lock(); eventStreams[ObjectIdentifier(connection)] = nil; lock.unlock()
        connection.cancel()
    }

    /// A comment line every 25 seconds keeps idle event streams open through proxies and sleepy clients.
    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let streams = self.eventStreams.values.map(\.connection); self.lock.unlock()
            for stream in streams { stream.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in }) }
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: Encoding

    private func controlsJSON() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return controlsJSONLocked()
    }

    private func controlsJSONLocked() -> [[String: Any]] {
        controls.map { info in
            var item: [String: Any] = [
                "id": info.definition.id, "name": info.definition.name, "kind": info.definition.kind.rawValue,
                "group": info.definition.group, "readOnly": info.definition.readOnly,
            ]
            Self.addState(info.state, to: &item)
            return item
        }
    }

    private static func addState(_ state: ControlSurface.State, to object: inout [String: Any]) {
        if let value = state.value { object["value"] = value }
        if let text = state.text { object["text"] = text }
        if let on = state.on { object["on"] = on }
    }

    private static func json(_ nowPlaying: NowPlaying) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(nowPlaying))) as? [String: Any] ?? [:]
    }

    private static func event(_ payload: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    private func sendJSON(_ connection: NWConnection, _ object: Any, status: String = "200 OK") {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        send(connection, status: status, type: "application/json", body: body)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
