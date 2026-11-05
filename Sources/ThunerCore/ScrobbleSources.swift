import Foundation

/// Which sources scrobble. A source is where a play came from, by the name ThUNER shows for it: "Apple Music",
/// "Spotify", "Shazam" (the mic or line-in here), a website ("YouTube Music"), an app ("VOX", "KCRW (AirPlay)"),
/// or another Mac's name for the records it relays. Every source scrobbles until it's switched off; the choice
/// is remembered. Pausing everything for now (radio mode) is separate and sits on top.
public struct ScrobbleSources: Equatable, Sendable {
    /// Sources switched off.
    public var off: Set<String> = []

    public init(off: Set<String> = []) {
        self.off = off
    }

    public func allows(_ source: String) -> Bool { !off.contains(source) }

    public mutating func set(_ source: String, on: Bool) {
        if on { off.remove(source) } else { off.insert(source) }
    }

    /// What the Scrobble button does: a press while a source is playing is about that source. Paused, it
    /// resumes (and makes sure that source is on, since that's what the press asked for); otherwise it flips the
    /// source, and the choice sticks. With nothing playing, it pauses or resumes everything.
    public static func press(source: String?, paused: Bool, sources: ScrobbleSources) -> (paused: Bool, sources: ScrobbleSources) {
        var sources = sources
        guard let source else { return (!paused, sources) }
        if paused {
            sources.set(source, on: true)
            return (false, sources)
        }
        sources.set(source, on: !sources.allows(source))
        return (false, sources)
    }
}
