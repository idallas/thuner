import Foundation

/// Turns a stream of RMS levels into "audio present" / "silent", with hysteresis and debounce so vinyl
/// surface noise, the quiet groove between tracks, and short dropouts don't flap the state.
public struct LevelGate: Sendable {
    public var thresholdDB: Double
    /// Level has to drop this far below the threshold to count as silence.
    public var hysteresisDB: Double
    /// How long the level must stay above the threshold before audio counts as present.
    public var attack: TimeInterval
    /// How long the level must stay below (threshold - hysteresis) before it counts as silence.
    public var release: TimeInterval

    public private(set) var isOpen = false
    private var crossingSince: Date?

    public init(thresholdDB: Double = -45, hysteresisDB: Double = 3, attack: TimeInterval = 1.0, release: TimeInterval = 8.0) {
        self.thresholdDB = thresholdDB
        self.hysteresisDB = hysteresisDB
        self.attack = attack
        self.release = release
    }

    public enum Transition: Equatable, Sendable { case opened, closed }

    /// Feed one level reading (dBFS). Returns a transition when the gate opens or closes.
    public mutating func feed(levelDB: Double, at now: Date) -> Transition? {
        let crossing = isOpen ? levelDB < thresholdDB - hysteresisDB : levelDB >= thresholdDB
        guard crossing else {
            crossingSince = nil
            return nil
        }
        let since = crossingSince ?? now
        crossingSince = since
        guard now.timeIntervalSince(since) >= (isOpen ? release : attack) else { return nil }
        isOpen.toggle()
        crossingSince = nil
        return isOpen ? .opened : .closed
    }

    public mutating func reset() {
        isOpen = false
        crossingSince = nil
    }
}
