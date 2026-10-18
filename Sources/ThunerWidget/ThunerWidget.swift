import AppKit
import SwiftUI
import WidgetKit

// ThUNER's desktop and Notification Center widget: what's playing, with its cover. It reads ThUNER's own
// http://127.0.0.1:47480/now.json (the web display's feed), so it needs nothing shared with the app but the network
// client entitlement; ThUNER asks WidgetKit to reload it whenever the track changes.

private struct NowPlayingJSON: Decodable {
    var state: String
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var source: String?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        if context.isPreview { return completion(.sample) }
        Task { completion(await Self.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        Task {
            let entry = await Self.load()
            // ThUNER reloads the widget when the track changes; this is only a backstop.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    static func load() async -> NowPlayingEntry {
        let session = URLSession(configuration: .ephemeral)
        guard let (data, _) = try? await session.data(from: URL(string: "http://127.0.0.1:47480/now.json")!),
              let now = try? JSONDecoder().decode(NowPlayingJSON.self, from: data) else {
            return NowPlayingEntry(date: .now, unreachable: true)
        }
        guard now.state != "idle", let title = now.title else { return NowPlayingEntry(date: .now) }
        var cover: NSImage?
        if let artwork = now.artwork, let url = URL(string: artwork),
           let (imageData, _) = try? await session.data(from: url) {
            cover = NSImage(data: imageData)
        }
        return NowPlayingEntry(date: .now, title: title, artist: now.artist, album: now.album, source: now.source, cover: cover)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            FamilyReader { NowPlayingView(entry: entry, family: $0) }
        }
        // The small and large layouts run the cover to the edges; the medium one pads itself.
        .contentMarginsDisabled()
        .configurationDisplayName("Now Playing")
        .description("What ThUNER hears or follows, with its cover.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Hands the view the widget's size (kept out of the view, so previews can pass any).
private struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder var content: (WidgetFamily) -> Content
    var body: some View { content(family) }
}

@main
struct ThunerWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
