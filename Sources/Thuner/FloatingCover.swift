import AppKit
import SwiftUI

/// An always-on-top, borderless, square window showing the current cover. Drag anywhere to move, drag an
/// edge to resize, hover for the track details. Position and size are remembered.
@MainActor
final class FloatingCoverController {
    private var panel: NSPanel?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// Whether it's showing or fading in (as opposed to hidden or fading out).
    private(set) var isVisible = false

    func show() {
        guard let model, !isVisible else { return }
        isVisible = true
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
                styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentAspectRatio = NSSize(width: 1, height: 1)
            panel.minSize = NSSize(width: 96, height: 96)
            panel.maxSize = NSSize(width: 1000, height: 1000)
            panel.contentView = DraggableHostingView(rootView: FloatingCoverView(model: model))
            if !panel.setFrameUsingName("FloatingCover") {
                if let screen = NSScreen.main?.visibleFrame {
                    panel.setFrameOrigin(NSPoint(x: screen.maxX - 240, y: screen.minY + 20))
                }
            }
            panel.setFrameAutosaveName("FloatingCover")
            self.panel = panel
        }
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Also brings it back if it was mid-fade-out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Shown again while fading out: leave it up.
                if !self.isVisible { panel.orderOut(nil) }
            }
        })
    }
}

/// NSHostingView swallows mouse-downs, so isMovableByWindowBackground alone doesn't let you drag the window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct FloatingCoverView: View {
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let track = model.shownTrack
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let url = track?.artworkURL.map(Self.secure) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.4))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    } else {
                        placeholder
                    }
                }
                .id(url)
            } else {
                placeholder
            }

            if hovering {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing").font(.headline).lineLimit(2)
                    if let track {
                        Text(track.artist).font(.subheadline).lineLimit(1)
                        if let album = track.album {
                            Text(album).font(.caption).opacity(0.75).lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu {
            Button("Hide Floating Cover") { model.showFloatingCover = false }
        }
    }

    /// App Transport Security blocks plain-http image loads, and the Tuneshine-friendly URLs are http.
    /// Every artwork CDN we use also serves https.
    static func secure(_ url: URL) -> URL {
        guard url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        return c.url ?? url
    }

    private var placeholder: some View {
        Image(systemName: "opticaldisc")
            .font(.system(size: 40))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
