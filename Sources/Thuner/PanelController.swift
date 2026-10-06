import AppKit
import Observation
import SwiftUI

/// Actions the panel's SwiftUI content can trigger, wired up by PanelController.
@MainActor
final class PanelActions {
    var togglePin: () -> Void = {}
    /// The panel was dragged somewhere: pin it there.
    var draggedTo: () -> Void = {}
    var close: () -> Void = {}
    var show: (AppWindows.Kind) -> Void = { _ in }
}

/// ThUNER's menu bar icon and its panel, done by hand rather than with SwiftUI's MenuBarExtra, which always
/// opens its own panel when the icon is clicked. Owning both means:
/// - pinning keeps this same panel open (there's never a second window to double up with);
/// - clicking the icon while pinned just points at the panel, with no menu flashing open;
/// - the panel can be dragged by any non-control area, and dragging it away from the menu bar pins it.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: KeyablePanel
    private let actions = PanelActions()
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    /// The panel's top-left corner is kept fixed while its content grows or shrinks (Activity expanding etc.).
    private var anchoredTopLeft: NSPoint?
    private var isMovingProgrammatically = false

    private static let pinnedTopLeftKey = "PinnedPanelTopLeft"

    init(model: AppModel) {
        self.model = model
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingController(rootView: MenuView(model: model, actions: actions))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host

        actions.togglePin = { [weak self] in self?.togglePin() }
        actions.draggedTo = { [weak self] in self?.draggedTo() }
        actions.close = { [weak self] in self?.close() }
        actions.show = { [weak self] kind in
            if self?.model.panelPinned == false { self?.close() }
            AppWindows.shared.show(kind)
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "ThUNER"
        }
        statusItem.autosaveName = "ThUNER"
        observeIcon()

        if model.panelPinned { showPinnedAtLaunch() }
    }

    // MARK: Menu bar icon

    private func observeIcon() {
        withObservationTracking {
            statusItem.button?.image = MenuBarIcon.image(model.menuBarIconKind)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    @objc private func statusItemClicked() {
        // Opening ThUNER is a wake signal for an auto-pause. Waking restarts audio capture, which can take a
        // moment, so let the panel appear first and start listening right after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.model.wake("Opened ThUNER") }
        if model.panelPinned {
            // Like SoundSource: no menu while pinned, just point at the panel.
            shake()
        } else if panel.isVisible {
            close()
        } else {
            showUnderIcon()
        }
    }

    /// Opens the panel under the icon (if it isn't already showing).
    func openPanel() {
        if !panel.isVisible { showUnderIcon() }
    }

    /// Flashes the menu bar icon a few times, to point out where ThUNER lives.
    func pulseIcon() {
        guard let button = statusItem.button else { return }
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.22) { button.highlight(i % 2 == 0) }
        }
    }

    // MARK: Showing and hiding

    private var iconFrame: NSRect? { statusItem.button?.window?.frame }

    private func menuTopLeft() -> NSPoint? {
        guard let icon = iconFrame else { return nil }
        var x = icon.minX
        if let screen = statusItem.button?.window?.screen?.visibleFrame {
            x = min(x, screen.maxX - panel.frame.width - 8)
        }
        return NSPoint(x: x, y: icon.minY - 4)
    }

    private func showUnderIcon() {
        guard let topLeft = menuTopLeft() else { return }
        panel.level = .popUpMenu
        place(at: topLeft)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        startClosingOnOutsideClicks()
    }

    private func close() {
        guard panel.isVisible, !model.panelPinned else { return }
        stopClosingOnOutsideClicks()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !self.model.panelPinned { self.panel.orderOut(nil) }
                self.panel.alphaValue = 1
            }
        })
    }

    private func startClosingOnOutsideClicks() {
        stopClosingOnOutsideClicks()
        // Clicks in other apps (or the desktop) close it, like a menu. Clicks in ThUNER's own windows don't
        // arrive here, and the icon toggles it itself.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func stopClosingOnOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    private func place(at topLeft: NSPoint) {
        anchoredTopLeft = topLeft
        isMovingProgrammatically = true
        panel.setFrameTopLeftPoint(topLeft)
        isMovingProgrammatically = false
    }

    // MARK: Pinning

    private func togglePin() {
        model.panelPinned ? unpin() : pin()
    }

    private func pin() {
        model.panelPinned = true
        stopClosingOnOutsideClicks()
        panel.level = .floating
        saveTopLeft()
    }

    private func draggedTo() {
        if model.panelPinned { saveTopLeft() } else { pin() }
    }

    /// Slides back up under the icon and carries on as the menu.
    private func unpin() {
        model.panelPinned = false
        guard let topLeft = menuTopLeft() else { return }
        let target = NSRect(x: topLeft.x, y: topLeft.y - panel.frame.height,
                            width: panel.frame.width, height: panel.frame.height)
        isMovingProgrammatically = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.isMovingProgrammatically = false
                self.anchoredTopLeft = topLeft
                self.panel.level = .popUpMenu
                self.panel.makeKey()
                self.startClosingOnOutsideClicks()
            }
        })
    }

    private func showPinnedAtLaunch() {
        let saved = UserDefaults.standard.string(forKey: Self.pinnedTopLeftKey).map(NSPointFromString)
        guard let topLeft = saved ?? menuTopLeft() else { return }
        panel.level = .floating
        place(at: topLeft)
        panel.orderFrontRegardless()
    }

    private func saveTopLeft() {
        let frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        anchoredTopLeft = topLeft
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.pinnedTopLeftKey)
    }

    /// A quick side-to-side shake, to point out the pinned panel.
    private func shake() {
        let origin = panel.frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for offset in [-8.0, 7, -5, 3, 0] {
            path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y))
        }
        let animation = CAKeyframeAnimation()
        animation.path = path
        animation.duration = 0.35
        panel.animations = ["frameOrigin": animation]
        panel.orderFrontRegardless()
        isMovingProgrammatically = true
        panel.animator().setFrameOrigin(origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.isMovingProgrammatically = false }
    }

    // MARK: NSWindowDelegate

    /// Content changed size: keep the top edge where it was, so it grows downward like a menu.
    func windowDidResize(_ notification: Notification) {
        guard let topLeft = anchoredTopLeft, panel.frame.maxY != topLeft.y || panel.frame.minX != topLeft.x else { return }
        isMovingProgrammatically = true
        panel.setFrameTopLeftPoint(topLeft)
        isMovingProgrammatically = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isMovingProgrammatically else { return }
        let frame = panel.frame
        anchoredTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
    }
}

/// Borderless panels can't become key by default, which would leave its pickers and slider unusable.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
