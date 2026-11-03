import Foundation

/// Which other ThUNER this Mac gives way to. While that Mac is playing, this one keeps its mic off, shows that Mac's
/// track, and leaves the Tuneshine and the scrobbling of what it hears to it.
///
/// It's the Mac whose stream this one is playing, else the one chosen in Settings ("Defer to"), else none.
public struct Deferral: Equatable, Sendable {
    /// The Mac to give way to now, if any.
    public var target: String?
    /// Because this Mac is playing that Mac's stream (not the setting).
    public var viaStream: Bool
    /// The Mac this one would give way to gives way to this one too.
    public var mutual: Bool
    /// That other Mac, while `mutual` (also when this Mac is the one that stopped deferring).
    public var mutualWith: String?

    public static let none = Deferral(target: nil, viaStream: false, mutual: false, mutualWith: nil)

    public init(target: String?, viaStream: Bool, mutual: Bool, mutualWith: String? = nil) {
        self.target = target
        self.viaStream = viaStream
        self.mutual = mutual
        self.mutualWith = mutualWith
    }

    /// - Parameters:
    ///   - chosen: Settings' "Defer to", nil for no one.
    ///   - streamingFrom: the Mac whose stream this one is playing.
    ///   - me: this Mac's names (computer name first, then host name).
    ///   - peersDeferTo: what each other ThUNER says it defers to, by its name.
    public static func resolve(chosen: String?, streamingFrom: String?, me: [String],
                               peersDeferTo: [String: String]) -> Deferral {
        guard let target = streamingFrom ?? chosen else { return .none }
        let viaStream = streamingFrom != nil
        let back = peersDeferTo.first { sameMac($0.key, target) }?.value
        guard let back, me.contains(where: { sameMac($0, back) }) else {
            return Deferral(target: target, viaStream: viaStream, mutual: false)
        }
        // Two Macs giving way to each other would leave the Tuneshine to neither while both play. The one whose
        // name sorts first stops deferring until it's sorted out; both Macs reach the same answer on their own.
        if let mine = me.first, normalized(mine) < normalized(target) {
            return Deferral(target: nil, viaStream: viaStream, mutual: true, mutualWith: target)
        }
        return Deferral(target: target, viaStream: viaStream, mutual: true, mutualWith: target)
    }

    /// Whether two names are the same Mac. A Mac's computer name ("Dallas's Mac mini") and its Bonjour host name
    /// ("Dallass-Mac-mini.local") differ only in punctuation, case and the domain.
    public static func sameMac(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }

    static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        for suffix in [".local.", ".local"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return String(String.UnicodeScalarView(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
