import Foundation
import Network
import os

/// Twist Commando's App Link: ThUNER offers named controls (levels, toggles, buttons) that the user can put on
/// any knob, fader or pad, and keeps their rings, lights and screen text in sync with its real state.
/// https://twistcommando.com/developers/
///
/// Newline-delimited JSON over TCP to 127.0.0.1:9034. Twist Commando may start after ThUNER, so a failed or
/// dropped connection is retried every few seconds.
@MainActor
final class AppLinkClient {
    enum Kind: String { case level, steps, toggle, button }

    struct Control {
        var id: String
        var name: String
        var kind: Kind
        var group: String?
        /// Offered as a meter with this many channels where Twist Commando supports meters (protocol 2);
        /// otherwise it's the plain `kind` above.
        var meterChannels: Int?
    }

    /// The current state of one control, as last reported by the app.
    struct State: Equatable {
        var value: Double?
        var text: String?
        var on: Bool?
    }

    static let port: UInt16 = 9034

    /// Twist Commando said it knows meters (protocol 2's welcome).
    private(set) var supportsMeters = false
    /// Meters something in Twist Commando is showing, so their levels are wanted.
    private(set) var subscribedMeters: Set<String> = []
    var onMeterSubscriptionsChange: (() -> Void)?

    var onTurn: ((_ id: String, _ value: Double?, _ steps: Int?) -> Void)?
    var onPress: ((_ id: String, _ down: Bool) -> Void)?
    /// Twist Commando's version once connected, nil while not.
    private(set) var connectedVersion: String?
    var onConnectionChange: ((String?) -> Void)?

    private let controls: [Control]
    private var states: [String: State] = [:]
    private var sent: [String: State] = [:]
    private var connection: NWConnection?
    private var buffer = Data()
    private var enabled = false
    private var retry: DispatchWorkItem?
    /// Seconds before the next attempt: 4 at first, doubling to a minute while Twist Commando isn't there (on a
    /// Mac without it, every attempt fills the system log with connection messages).
    private var retryDelay = 4.0
    private let log = Logger(subsystem: "com.idallas.thuner", category: "applink")

    init(controls: [Control]) {
        self.controls = controls
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        connect()
    }

    func stop() {
        enabled = false
        retry?.cancel()
        connection?.cancel()
        connection = nil
        setConnected(nil)
        setSubscribed([])
    }

    /// Records a control's current state; sends an update if connected and it changed.
    func set(_ id: String, value: Double? = nil, text: String? = nil, on: Bool? = nil) {
        let state = State(value: value.map { min(max($0, 0), 1) }, text: text, on: on)
        states[id] = state
        guard connectedVersion != nil, sent[id] != state, !isMeter(id) else { return }
        sent[id] = state
        send(Self.fields(["type": "update", "id": id], state))
    }

    /// A meter's peak levels in dBFS since the last call; sent only while Twist Commando wants them.
    func sendMeter(_ id: String, levels: [Double]) {
        guard connectedVersion != nil, subscribedMeters.contains(id) else { return }
        send(["type": "meter", "id": id, "levels": levels.map { ($0 * 10).rounded() / 10 }])
    }

    private func isMeter(_ id: String) -> Bool {
        supportsMeters && controls.contains { $0.id == id && $0.meterChannels != nil }
    }

    private func setSubscribed(_ meters: Set<String>) {
        guard meters != subscribedMeters else { return }
        subscribedMeters = meters
        log.notice("Meters wanted: \(meters.sorted().joined(separator: ", "), privacy: .public)")
        onMeterSubscriptionsChange?()
    }

    // MARK: Connection

    private func connect() {
        guard enabled, connection == nil else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state, connection) }
        }
        connection.start(queue: .main)
    }

    private func stateChanged(_ state: NWConnection.State, _ connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            retryDelay = 4
            buffer.removeAll()
            send(["type": "hello", "app": Bundle.main.bundleIdentifier ?? "com.idallas.thuner", "name": "ThUNER", "protocol": 2])
            receive(on: connection)
        case .waiting, .failed, .cancelled:
            // Not running (connection refused) or gone: try again in a few seconds.
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.connection = nil
            setConnected(nil)
            setSubscribed([])
            scheduleRetry()
        default:
            break
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        guard enabled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 60)
    }

    private func setConnected(_ version: String?) {
        guard version != connectedVersion else { return }
        connectedVersion = version
        onConnectionChange?(version)
        if let version {
            log.notice("Connected to Twist Commando \(version, privacy: .public)\(self.supportsMeters ? ", with meters" : "", privacy: .public)")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, connection === self.connection else { return }
                if let data { self.buffer.append(data); self.drainLines() }
                if isComplete || error != nil {
                    self.stateChanged(.cancelled, connection)
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = message["type"] as? String else { continue }
            handle(type, message)
        }
    }

    private func handle(_ type: String, _ message: [String: Any]) {
        switch type {
        case "welcome":
            // Protocol 2 and up can take meters; earlier versions would reject the kind.
            supportsMeters = message["meters"] as? Bool ?? false
            // Declare the controls before anything (including the connection callback) sends updates for them.
            sendControls()
            setConnected(message["version"] as? String ?? "?")
        case "turn":
            guard let id = message["id"] as? String else { return }
            onTurn?(id, (message["value"] as? NSNumber)?.doubleValue, (message["steps"] as? NSNumber)?.intValue)
        case "press":
            guard let id = message["id"] as? String else { return }
            onPress?(id, message["down"] as? Bool ?? false)
        case "meterSubscribe":
            guard let id = message["id"] as? String else { return }
            var meters = subscribedMeters
            if message["on"] as? Bool ?? false { meters.insert(id) } else { meters.remove(id) }
            setSubscribed(meters)
        case "error":
            log.error("Twist Commando: \(message["message"] as? String ?? "error", privacy: .public)")
        default:
            break
        }
    }

    private func sendControls() {
        let list: [[String: Any]] = controls.map { control in
            var item: [String: Any] = ["id": control.id, "name": control.name, "kind": control.kind.rawValue]
            if let group = control.group { item["group"] = group }
            if supportsMeters, let channels = control.meterChannels {
                item["kind"] = "meter"
                item["channels"] = channels
            } else if let state = states[control.id] {
                item = Self.fields(item, state)
            }
            return item
        }
        sent = states.filter { !isMeter($0.key) }
        send(["type": "controls", "controls": list])
    }

    private func send(_ message: [String: Any]) {
        guard let connection, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .idempotent)
    }

    private static func fields(_ base: [String: Any], _ state: State) -> [String: Any] {
        var out = base
        if let value = state.value { out["value"] = value }
        if let text = state.text { out["text"] = text }
        if let on = state.on { out["on"] = on }
        return out
    }
}
