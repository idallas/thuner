import AppKit
import SwiftUI

/// Hands back the NSWindow a SwiftUI view lives in, for the few things SwiftUI doesn't expose.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Put behind a view to make it a handle that drags its window. SwiftUI swallows the clicks that AppKit's
/// own "drag by background" relies on, so this starts the window drag itself, then reports once the mouse is
/// released whether the window actually moved.
struct WindowDragHandle: NSViewRepresentable {
    var onMoved: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HandleView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandleView)?.onMoved = onMoved
    }

    private final class HandleView: NSView {
        var onMoved: (() -> Void)?
        private var releaseTimer: Timer?

        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = window.frame.origin
            window.performDrag(with: event)
            // performDrag may return before the drag ends; wait for the button to come up, then compare.
            releaseTimer?.invalidate()
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self, weak window] timer in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                MainActor.assumeIsolated {
                    guard let window else { return }
                    let end = window.frame.origin
                    if hypot(end.x - start.x, end.y - start.y) > 4 { self?.onMoved?() }
                }
            }
        }
    }
}
