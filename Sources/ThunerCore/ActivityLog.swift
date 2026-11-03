import Foundation

/// What ThUNER says and does, kept for the Activity window: the lines the panel shows (level `activity`) and
/// every other line it logs (level `detail`), from this Mac or another. The file form is JSON Lines
/// (`activity.jsonl`, one entry a line, appended), trimmed with `trimmed(_:now:)`: Activity lines are kept 30
/// days, detail lines 2 days, and the whole thing stays under about 5 MB.
public enum ActivityLog {
    public enum Level: String, Codable, Sendable, CaseIterable {
        /// What the panel's Activity shows: the lines ThUNER says in plain words.
        case activity
        /// Everything else: each Shazam query, peer message, stream report, Tuneshine request.
        case detail
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        /// A sequence number for this run (or the other Mac's run), so a client can ask for what came after.
        public var id: Int
        public var date: Date
        public var level: Level
        /// The logger's category: "app", "capture", "match", "players", "tuneshine", "peers", "stream", "web",
        /// "lastfm", "listenbrainz", "diagnostic".
        public var category: String
        public var message: String
        public var isError: Bool

        public init(id: Int, date: Date, level: Level, category: String, message: String, isError: Bool = false) {
            self.id = id
            self.date = date
            self.level = level
            self.category = category
            self.message = message
            self.isError = isError
        }

        /// About how much room the entry takes in the file.
        public var bytes: Int { message.utf8.count + category.utf8.count + 48 }
    }

    // MARK: Keeping

    public static let activityDays = 30.0
    public static let detailDays = 2.0
    public static let maxBytes = 5_000_000

    /// Drops what's too old (Activity lines after 30 days, detail lines after 2) and then the oldest lines until
    /// the rest fits the byte budget. Entries are expected oldest first.
    public static func trimmed(_ entries: [Entry], now: Date = Date(), maxBytes: Int = maxBytes) -> [Entry] {
        let activityCutoff = now.addingTimeInterval(-activityDays * 86_400)
        let detailCutoff = now.addingTimeInterval(-detailDays * 86_400)
        var kept = entries.filter { $0.date >= ($0.level == .activity ? activityCutoff : detailCutoff) }
        var total = kept.reduce(0) { $0 + $1.bytes }
        var drop = 0
        while total > maxBytes, drop < kept.count {
            total -= kept[drop].bytes
            drop += 1
        }
        if drop > 0 { kept.removeFirst(drop) }
        return kept
    }

    // MARK: The file

    private struct Line: Codable {
        var t: Double
        var l: String
        var c: String
        var m: String
        var x: Bool?
    }

    /// One JSON line (no newline) for the file.
    public static func line(for entry: Entry) -> String {
        let line = Line(t: entry.date.timeIntervalSince1970, l: entry.level == .activity ? "a" : "d",
                        c: entry.category, m: entry.message, x: entry.isError ? true : nil)
        guard let data = try? JSONEncoder().encode(line), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The entries in a file's contents, oldest first, numbered from `firstID`. Lines that don't parse are skipped.
    public static func entries(in text: String, firstID: Int = 1) -> [Entry] {
        var id = firstID
        var result: [Entry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            result.append(Entry(id: id, date: Date(timeIntervalSince1970: line.t), level: line.l == "a" ? .activity : .detail,
                                category: line.c, message: line.m, isError: line.x ?? false))
            id += 1
        }
        return result
    }

    // MARK: Showing

    /// What the window shows: a level, a category (nil for all) and a search.
    public struct Filter: Equatable, Sendable {
        public var level: Level
        public var category: String?
        public var search: String

        public init(level: Level = .activity, category: String? = nil, search: String = "") {
            self.level = level
            self.category = category
            self.search = search
        }

        /// Activity level shows the plain lines and every error; detail shows everything.
        public func matches(_ entry: Entry) -> Bool {
            if level == .activity, entry.level != .activity, !entry.isError { return false }
            if let category, entry.category != category { return false }
            let search = search.trimmingCharacters(in: .whitespaces)
            if !search.isEmpty, entry.message.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               entry.category.range(of: search, options: .caseInsensitive) == nil { return false }
            return true
        }
    }

    /// The categories as the window names them. Anything else is shown as it is.
    public static let categoryNames: [(id: String, name: String)] = [
        ("app", "App"), ("capture", "Capture"), ("match", "Matching"), ("players", "Players"),
        ("tuneshine", "Tuneshine"), ("lastfm", "Last.fm"), ("listenbrainz", "ListenBrainz"),
        ("peers", "Other Macs"), ("stream", "Stream"), ("web", "Web and API"), ("diagnostic", "Diagnostic"),
    ]

    public static func name(ofCategory id: String) -> String {
        categoryNames.first { $0.id == id }?.name ?? id.capitalized
    }

    /// Plain text for copying into a bug report: one line each, with the time and category.
    public static func text(_ entries: [Entry], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = timeZone
        return entries.map { entry in
            "\(formatter.string(from: entry.date))  \(entry.isError ? "ERROR " : "")[\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
