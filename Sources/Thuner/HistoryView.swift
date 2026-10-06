import AppKit
import SwiftUI
import ThunerCore
import UniformTypeIdentifiers

/// Everything ThUNER heard, filterable by day, exportable as a plain list (handy for playlist importers
/// like Soundiiz or TuneMyMusic) or a CSV with Apple Music / Spotify links.
struct HistoryView: View {
    let model: AppModel

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case yesterday = "Yesterday"
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case all = "All"
        var id: Self { self }
    }

    @State private var range = Range.today
    @State private var selection = Set<PlayHistory.Entry.ID>()

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Table(rows, selection: $selection) {
                TableColumn("Time") { e in
                    Text(e.startedAt, format: range == .today || range == .yesterday
                         ? .dateTime.hour().minute()
                         : .dateTime.month(.abbreviated).day().hour().minute())
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90, max: 130)
                TableColumn("Artist") { e in Text(e.track.artist) }
                TableColumn("Title") { e in Text(e.track.title) }
                TableColumn("Album") { e in Text(e.track.album ?? "").foregroundStyle(.secondary) }
                TableColumn("Source") { e in
                    Label(e.source.rawValue, systemImage: Self.symbol(for: e.source)).labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110, max: 140)
                TableColumn("Scrobbled") { e in
                    ScrobbleBadge(status: e.scrobble).help(detail(e))
                }
                    .width(min: 70, ideal: 130, max: 220)
            }
            .contextMenu(forSelectionType: PlayHistory.Entry.ID.self) { ids in
                Button("Copy as Text") { copy(rows.filter { ids.contains($0.id) }) }
            }

            Divider()
            HStack {
                Text(selection.isEmpty ? "\(rows.count) plays" : "\(selection.count) of \(rows.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy as Text") { copy(exportRows(rows)) }
                Menu("Export") {
                    Button("Text List…") { export(exportRows(rows), as: .plainText) }
                    Button("CSV…") { export(exportRows(rows), as: .commaSeparatedText) }
                }
                .fixedSize()
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 360)
        .onChange(of: range) { selection.removeAll() }
    }

    // MARK: Data

    private var filtered: [PlayHistory.Entry] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let entries = model.history.entries.reversed()
        let result: [PlayHistory.Entry] = switch range {
        case .today: entries.filter { $0.startedAt >= startOfToday }
        case .yesterday:
            entries.filter {
                $0.startedAt < startOfToday && $0.startedAt >= calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            }
        case .week: entries.filter { $0.startedAt >= calendar.date(byAdding: .day, value: -6, to: startOfToday)! }
        case .month: entries.filter { $0.startedAt >= calendar.date(byAdding: .day, value: -29, to: startOfToday)! }
        case .all: Array(entries)
        }
        return result
    }

    /// The selection if there is one, otherwise everything shown; oldest first, the order they played.
    private func exportRows(_ rows: [PlayHistory.Entry]) -> [PlayHistory.Entry] {
        let chosen = selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
        return chosen.sorted { $0.startedAt < $1.startedAt }
    }

    /// Per-service results, e.g. "Last.fm: scrobbled · Maloja: already there at 3:13 PM".
    private func detail(_ e: PlayHistory.Entry) -> String {
        guard !e.scrobbles.isEmpty else { return "Not scrobbled" }
        return e.scrobbles.sorted { $0.key < $1.key }.map { id, status in
            let name = model.scrobbleServiceName(id)
            return switch status {
            case .scrobbled: "\(name): scrobbled"
            case .queued: "\(name): queued"
            case .notSent: "\(name): not sent"
            case .skippedDuplicate(let reason): "\(name): skipped (\(reason))"
            }
        }.joined(separator: " · ")
    }

    // MARK: Export

    static func textList(_ rows: [PlayHistory.Entry]) -> String {
        rows.map { "\($0.track.artist) – \($0.track.title)" }.joined(separator: "\n") + "\n"
    }

    func csv(_ rows: [PlayHistory.Entry]) -> String {
        func field(_ s: String?) -> String {
            var s = s ?? ""
            // A title that starts like a formula ("=1+1", "-foo", "@bar") would be run by Excel and Numbers
            // when the CSV is opened; a leading apostrophe makes them treat it as text.
            if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
            return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        let iso = ISO8601DateFormatter()
        var lines = ["played_at,artist,title,album,source,scrobbled_to,apple_music_url,spotify_url"]
        for e in rows {
            let scrobbledTo = e.scrobbles.filter { $0.value == .scrobbled }.keys
                .map(model.scrobbleServiceName).sorted().joined(separator: "; ")
            lines.append([
                iso.string(from: e.startedAt), field(e.track.artist), field(e.track.title), field(e.track.album),
                e.source.rawValue, field(scrobbledTo),
                e.track.appleMusicID.map { "https://music.apple.com/song/\($0)" } ?? "",
                e.track.spotifyID.map { "https://open.spotify.com/track/\($0)" } ?? "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func copy(_ rows: [PlayHistory.Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.textList(rows), forType: .string)
    }

    private func export(_ rows: [PlayHistory.Entry], as type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "ThUNER \(range.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = type == .commaSeparatedText ? csv(rows) : Self.textList(rows)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func symbol(for source: PlayHistory.Source) -> String {
        switch source {
        case .shazam: "shazam.logo"
        case .appleMusic: "music.note"
        case .spotify: "dot.radiowaves.left.and.right"
        }
    }
}

private struct ScrobbleBadge: View {
    let status: PlayHistory.ScrobbleStatus

    var body: some View {
        switch status {
        case .scrobbled:
            Label("Scrobbled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .queued:
            Label("Queued", systemImage: "clock").foregroundStyle(.orange)
        case .notSent:
            Text("–").foregroundStyle(.tertiary)
        case .skippedDuplicate(let reason):
            Label("Duplicate", systemImage: "square.on.square").foregroundStyle(.orange).help(reason)
        }
    }
}
