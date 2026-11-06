import Foundation

/// On/off per source, for scrobbling and for notifications. A source is where a play came from, by the name
/// ThUNER shows for it: "Apple Music", "Spotify", "Shazam" (the mic or line-in here), a website ("YouTube
/// Music"), an app ("VOX"), an AirPlay sender ("KCRW (AirPlay)"), or another Mac's name for the records it
/// relays. Every source is on until it's switched off; the choice is remembered.
///
/// AirPlay senders form a group: the "AirPlay" switch is the default every sender follows, and a sender's own
/// switch overrides it. Flipping the group resets its senders, so "all AirPlay off" means all off, with no stale
/// overrides underneath. (Before 2026-11-04 every AirPlay play was named just "AirPlay", so that switch already
/// exists for anyone who used it; now macOS names the sender nearly every time.)
public struct SourceSwitches: Equatable, Sendable {
    /// The AirPlay group's name, and what plays were called before the sender was known.
    public static let airPlay = "AirPlay"
    private static let airPlaySuffix = " (AirPlay)"

    /// Sources switched off: top-level sources, the group, and senders overriding a group that's on.
    public var off: Set<String>
    /// Senders switched on while their group is off.
    public var on: Set<String>

    public init(off: Set<String> = [], on: Set<String> = []) {
        self.off = off
        self.on = on
    }

    /// Notifications: Apple Music and Spotify start off, since each shows its own banners (Music → Settings →
    /// General, Spotify → Settings).
    public static func forNotifications() -> SourceSwitches {
        SourceSwitches(off: [PlayHistory.Source.appleMusic.rawValue, PlayHistory.Source.spotify.rawValue])
    }

    /// The group a source follows: AirPlay senders follow "AirPlay".
    public static func group(of source: String) -> String? {
        source.hasSuffix(airPlaySuffix) && source != airPlay ? airPlay : nil
    }

    public static func isGroup(_ source: String) -> Bool { source == airPlay }

    public func allows(_ source: String) -> Bool {
        if on.contains(source) { return true }
        if off.contains(source) { return false }
        if let group = Self.group(of: source) { return !off.contains(group) }
        return true
    }

    /// Whether a sender has its own setting rather than following its group.
    public func overrides(_ source: String) -> Bool {
        Self.group(of: source) != nil && (on.contains(source) || off.contains(source))
    }

    public mutating func set(_ source: String, on value: Bool) {
        if Self.isGroup(source) {
            // The group's members start following it again.
            off = off.filter { Self.group(of: $0) != source }
            on = on.filter { Self.group(of: $0) != source }
            if value { off.remove(source) } else { off.insert(source) }
            return
        }
        on.remove(source)
        off.remove(source)
        if let group = Self.group(of: source) {
            // An override only where it differs from the group.
            let inherited = !off.contains(group)
            if value != inherited { if value { on.insert(source) } else { off.insert(source) } }
        } else if !value {
            off.insert(source)
        }
    }

    /// What the Scrobble button does: a press while a source is playing is about that source. Paused, it
    /// resumes (and makes sure that source is on, since that's what the press asked for); otherwise it flips the
    /// source, and the choice sticks. With nothing playing, it pauses or resumes everything.
    public static func press(source: String?, paused: Bool, sources: SourceSwitches) -> (paused: Bool, sources: SourceSwitches) {
        var sources = sources
        guard let source else { return (!paused, sources) }
        if paused {
            sources.set(source, on: true)
            return (false, sources)
        }
        sources.set(source, on: !sources.allows(source))
        return (false, sources)
    }

    // MARK: Listing, for Settings

    public struct Row: Equatable, Sendable {
        public var name: String
        /// The group this row sits under (indented), if any.
        public var group: String?
        public var isGroup: Bool
    }

    /// The rows Settings shows for a set of source names: sorted by name, each group's members indented under
    /// it (the group row is added whenever a member exists). Names that are switched on or off explicitly
    /// should be in `names` too, so a switch never disappears.
    public static func rows(for names: Set<String>) -> [Row] {
        func sorted(_ names: some Collection<String>) -> [String] {
            names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        var top = names.filter { group(of: $0) == nil }
        let members = Dictionary(grouping: names.filter { group(of: $0) != nil }, by: { group(of: $0)! })
        for group in members.keys { top.insert(group) }
        var rows: [Row] = []
        for name in sorted(top) {
            let isGroup = members[name] != nil || isGroup(name)
            rows.append(Row(name: name, group: nil, isGroup: isGroup))
            for member in sorted(members[name] ?? []) {
                rows.append(Row(name: member, group: name, isGroup: false))
            }
        }
        return rows
    }
}
