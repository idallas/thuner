import Foundation

/// ThUNER's controls, defined once: what they are, their current state, and what turning or pressing them
/// does. Adapters expose them to the outside: Twist Commando's App Link and ThUNER's own HTTP API.
@MainActor
final class ControlSurface {
    enum Kind: String, Codable, Sendable {
        /// A value from 0 to 1 (a knob or fader). Some are display-only, like the input meter.
        case level
        /// On or off; pressing flips it.
        case toggle
        /// A one-shot action.
        case button
    }

    struct Definition: Sendable {
        var id: String
        var name: String
        var kind: Kind
        var group: String
        /// Display-only levels can't be turned.
        var readOnly = false
    }

    struct State: Equatable, Sendable {
        var value: Double?
        var text: String?
        var on: Bool?
    }

    let definitions: [Definition] = [
        .init(id: "listening", name: "Listening", kind: .toggle, group: "Listening"),
        .init(id: "threshold", name: "Silence Threshold", kind: .level, group: "Listening"),
        .init(id: "inputLevel", name: "Input Level", kind: .level, group: "Listening", readOnly: true),
        .init(id: "identify", name: "Identify Now", kind: .button, group: "Listening"),
        .init(id: "listenHere", name: "Listen Here", kind: .button, group: "Listening"),
        .init(id: "nowPlaying", name: "Now Playing", kind: .level, group: "Now Playing", readOnly: true),
        .init(id: "radio", name: "Radio Mode", kind: .toggle, group: "Now Playing"),
        .init(id: "brightness", name: "Tuneshine Brightness", kind: .level, group: "Display"),
        .init(id: "clear", name: "Clear Tuneshine", kind: .button, group: "Display"),
        .init(id: "floatingCover", name: "Floating Cover", kind: .toggle, group: "Display"),
    ]

    private(set) var states: [String: State] = [:]
    /// Called with each control whose state changed.
    var observers: [(String, State) -> Void] = []

    private unowned let model: AppModel
    private static let thresholdRange = -80.0 ... -10.0

    init(model: AppModel) {
        self.model = model
    }

    func definition(_ id: String) -> Definition? { definitions.first { $0.id == id } }

    // MARK: Actions

    enum ActionResult { case done, unknownControl, notAllowed }

    /// Turn a level to a value from 0 to 1.
    @discardableResult
    func turn(_ id: String, to value: Double) -> ActionResult {
        guard let control = definition(id) else { return .unknownControl }
        guard control.kind == .level, !control.readOnly else { return .notAllowed }
        let value = min(max(value, 0), 1)
        switch id {
        case "threshold":
            let r = Self.thresholdRange
            model.thresholdDB = (r.lowerBound + value * (r.upperBound - r.lowerBound)).rounded()
        case "brightness":
            model.setTuneshineBrightness(max(1, Int((value * 100).rounded())))
        default:
            return .notAllowed
        }
        refresh()
        return .done
    }

    /// Press a toggle (flips it) or a button.
    @discardableResult
    func press(_ id: String) -> ActionResult {
        guard let control = definition(id) else { return .unknownControl }
        guard control.kind != .level else { return .notAllowed }
        switch id {
        case "listening": model.togglePause()
        case "identify": model.identifyNow()
        case "listenHere": if model.peerHasControl { model.listenHereAnyway() }
        case "radio": model.radioMode.toggle()
        case "clear": model.clearDisplay()
        case "floatingCover": model.showFloatingCover.toggle()
        default: return .unknownControl
        }
        refresh()
        return .done
    }

    /// Set a toggle to a specific state (presses it only if that changes anything).
    @discardableResult
    func set(_ id: String, on: Bool) -> ActionResult {
        guard let control = definition(id), control.kind == .toggle else { return definition(id) == nil ? .unknownControl : .notAllowed }
        if states[id]?.on != on { return press(id) }
        return .done
    }

    // MARK: State

    /// Works out every control's state from the model and tells observers about the ones that changed.
    func refresh(at now: Date = Date()) {
        let r = Self.thresholdRange
        update("listening", State(on: model.micEnabled && !model.pausedManually && !model.autoPaused))
        update("threshold", State(value: (model.thresholdDB - r.lowerBound) / (r.upperBound - r.lowerBound),
                                  text: "\(Int(model.thresholdDB)) dB"))
        update("radio", State(on: model.radioMode))
        update("floatingCover", State(on: model.showFloatingCover))
        if let b = model.tuneshineBrightness { update("brightness", State(value: Double(b) / 100, text: "\(b)%")) }
        if let track = model.shownTrack {
            // Rounded, so the ring moves a few times a minute rather than on every tick.
            let progress = model.nowPlayingProgress(at: now).map { (min($0, 1) * 100).rounded() / 100 } ?? 0
            update("nowPlaying", State(value: progress, text: track.displayName))
        } else {
            update("nowPlaying", State(value: 0, text: model.pausedManually ? "Paused" : "Nothing playing"))
        }
        refreshInputLevel()
    }

    /// The input level as a meter, from −80 dB to full scale. Called on every level update (about 10/s).
    func refreshInputLevel() {
        let off = model.micSuspended
        let db = off ? -80 : max(model.levelDB, -80)
        update("inputLevel", State(value: ((db + 80) / 80 * 50).rounded() / 50, text: off ? "Off" : "\(Int(db)) dB"))
    }

    private func update(_ id: String, _ state: State) {
        guard states[id] != state else { return }
        states[id] = state
        for observer in observers { observer(id, state) }
    }
}
