import AppKit
import SwiftUI

/// An always-on-top, borderless, square window showing the current cover. Drag anywhere to move, drag an
/// edge to resize, hover for the track details. Position and size are remembered.
@MainActor
final class FloatingCoverController {
    private var panel: NSPanel?
    private weak var model: AppModel?
    private var frameObservers: [NSObjectProtocol] = []

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
            // ThUNER's own saved frame (AppKit's put one saved on a secondary display back on the main one),
            // then AppKit's from before, then the bottom-right corner.
            if let frame = WindowFrames.saved("windowFrame-floatingCover") {
                panel.setFrame(frame, display: false)
            } else if !panel.setFrameUsingName("FloatingCover"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 240, y: screen.minY + 20))
            }
            // Saved on every move and resize, not left to the autosave: moves made by SwiftUI's WindowDragGesture
            // weren't always written, so the cover came back where it was before.
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { _ in
                    MainActor.assumeIsolated { WindowFrames.save(panel.frame, "windowFrame-floatingCover") }
                })
            }
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

/// Dragging is SwiftUI's WindowDragGesture on the cover (see FloatingCoverView), so the playback buttons still get
/// their clicks; the first click works without bringing ThUNER forward first.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FloatingCoverView: View {
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let track = model.shownTrack ?? model.lastShownTrack
        ZStack(alignment: .bottomLeading) {
            // The cover: dragging it moves the window.
            ZStack {
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
            }
            .gesture(WindowDragGesture())

            if hovering {
                // The words over a fade; clicks and drags go through to the cover.
                ZStack(alignment: .bottomLeading) {
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
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Last, so nothing covers them.
            if hovering, model.controllablePlayer != nil {
                PlaybackButtons(model: model, size: 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            if hovering {
                Button { model.showFloatingCover = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Close the floating cover (Settings → Display, or ⋯ → Floating Cover, brings it back)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(7)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Nothing's played for a while: dimmed, back to full while the pointer's over it.
        .opacity(model.floatingCoverDimmed && !hovering ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.6), value: model.floatingCoverDimmed)
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
