import Foundation

/// Decides whether this Mac may update the display. The turntable Mac (primary) always may; the main Mac
/// (secondary) only when it hasn't heard from the primary for `quietWindow`.
public struct PushArbiter: Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable {
        case primary, secondary
    }

    public var role: Role
    public var quietWindow: TimeInterval
    public private(set) var lastPrimaryActivity: Date?

    public init(role: Role, quietWindow: TimeInterval = 300) {
        self.role = role
        self.quietWindow = quietWindow
    }

    /// Call when a push or "still playing" heartbeat arrives from a primary peer.
    public mutating func primaryWasActive(at date: Date) {
        if let last = lastPrimaryActivity, last > date { return }
        lastPrimaryActivity = date
    }

    /// The primary said it went quiet: no need to wait out the window.
    public mutating func primaryWentIdle() {
        lastPrimaryActivity = nil
    }

    public func mayPush(at now: Date) -> Bool {
        switch role {
        case .primary:
            return true
        case .secondary:
            guard let last = lastPrimaryActivity else { return true }
            return now.timeIntervalSince(last) >= quietWindow
        }
    }
}
