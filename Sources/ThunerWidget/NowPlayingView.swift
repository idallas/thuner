import AppKit
import SwiftUI
import WidgetKit

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

struct NowPlayingView: View {
    var entry: NowPlayingEntry
    var family: WidgetFamily

    var body: some View {
        content.containerBackground(for: .widget) { background }
    }

    /// Small and large: the cover fills the widget, with the words over a dark fade. Medium: cover beside words.
    private var fullBleed: Bool { family != .systemMedium && entry.cover != nil && entry.title != nil }

    @ViewBuilder var background: some View {
        if fullBleed, let image = entry.cover {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder var content: some View {
        if entry.title == nil {
            idle
        } else if fullBleed {
            overlay
        } else {
            sideBySide
        }
    }

    // MARK: Small and large

    private var overlay: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 3 : 1) {
            Spacer(minLength: 0)
            Text(entry.title ?? "")
                .font(.system(size: family == .systemLarge ? 22 : 15, weight: .bold))
                .lineLimit(3).minimumScaleFactor(0.6)
            Text(entry.artist ?? "")
                .font(.system(size: family == .systemLarge ? 16 : 12, weight: .medium))
                .lineLimit(2).minimumScaleFactor(0.7).opacity(0.9)
            if family == .systemLarge {
                if let album = entry.album {
                    Text(album).font(.system(size: 14)).lineLimit(2).minimumScaleFactor(0.75).opacity(0.75)
                }
                if let source = entry.source {
                    Label(source, systemImage: "waveform").font(.system(size: 11, weight: .medium))
                        .lineLimit(1).opacity(0.7).padding(.top, 4)
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(family == .systemLarge ? 18 : 12)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(maxHeight: .infinity)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black, location: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: Medium

    private var sideBySide: some View {
        HStack(spacing: 12) {
            cover
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "").font(.system(size: 16, weight: .bold))
                    .lineLimit(3).minimumScaleFactor(0.65)
                Text(entry.artist ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.75)
                if let album = entry.album {
                    Text(album).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(2).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                if let source = entry.source {
                    Label(source, systemImage: "waveform").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private var cover: some View {
        Group {
            if let image = entry.cover {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "opticaldisc").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Nothing to show

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

