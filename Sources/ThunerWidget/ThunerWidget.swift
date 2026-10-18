import AppKit
import SwiftUI
import WidgetKit

// ThUNER's desktop and Notification Center widget: what's playing, with its cover. It reads ThUNER's own
// http://127.0.0.1:47480/now.json (the web display's feed), so it needs nothing shared with the app but the network
// client entitlement; ThUNER asks WidgetKit to reload it whenever the track changes.

struct NowPlayingEntry: TimelineEntry {
    var date: Date
    var title: String?
    var artist: String?
    var album: String?
    var source: String?
    var cover: NSImage?
    /// Nothing from ThUNER (it's not running, or its web display is off).
    var unreachable = false

    static let sample = NowPlayingEntry(date: .now, title: "Swung from the Gutters", artist: "Tortoise", album: "TNT",
                                        source: "Mac mini")
}

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

struct NowPlayingView: View {
    var entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.title == nil {
                idle
            } else if family == .systemSmall {
                small
            } else {
                wide
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private var cover: some View {
        Group {
            if let image = entry.cover {
                Image(nsImage: image).resizable().aspectRatio(1, contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "opticaldisc").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            cover
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                Text(entry.artist ?? "").font(.caption2).lineLimit(1).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
    }

    private var wide: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title ?? "").font(.headline).lineLimit(2)
                Text(entry.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let album = entry.album, family != .systemSmall {
                    Text(album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let source = entry.source {
                    Label(source, systemImage: "waveform").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var idle: some View {
        VStack(spacing: 6) {
            Image(systemName: "opticaldisc").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(entry.unreachable ? "Can't reach ThUNER" : "Nothing playing")
                .font(.caption).foregroundStyle(.secondary)
            if entry.unreachable {
                // It reads the web display's feed.
                Text("Is it running, with its web display on?").font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What ThUNER hears or follows, with its cover.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ThunerWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
