import AppKit
import SwiftUI

/// Settings, History and About, as plain AppKit windows hosting their SwiftUI views. The panel isn't a SwiftUI
/// scene, so it can't use openWindow; opening these directly works from anywhere.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    enum Kind {
        case settings, history, about, welcome, stream
    }

    static let shared = AppWindows()
    var model: AppModel?
    /// Set by AppDelegate: point at the menu bar icon, and open the panel (used by the tour).
    var pulseMenuBarIcon: () -> Void = {}
    var openPanel: () -> Void = {}
    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind) {
        guard let model else { return }
        let window = windows[kind] ?? make(kind, model: model)
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Settings opens with nothing selected: otherwise its first text field (the stream password, an input's
        // name) takes the cursor and the pane scrolls down to it.
        if kind == .settings || kind == .stream { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
    }

    /// Settings, on a particular tab.
    func showSettings(_ pane: SettingsView.Pane) {
        show(.settings)
        if let tabs = windows[.settings]?.contentViewController as? NSTabViewController,
           let index = SettingsView.Pane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
            DispatchQueue.main.async { tabs.view.window?.makeFirstResponder(nil) }
        }
    }

    private func make(_ kind: Kind, model: AppModel) -> NSWindow {
        let window: NSWindow
        switch kind {
        case .settings:
            // Classic Mac settings: toolbar tabs with icons, the window titled after the selected tab.
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            for pane in SettingsView.Pane.allCases {
                let host = NSHostingController(rootView: SettingsView(model: model, pane: pane))
                // A fixed size for every pane (the form scrolls inside it), and the pane's name for the window title.
                host.sizingOptions = []
                host.preferredContentSize = NSSize(width: 540, height: 620)
                host.title = pane.title
                let item = NSTabViewItem(viewController: host)
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
                tabs.addTabViewItem(item)
            }
            window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.delegate = self
            window.toolbarStyle = .preference
        case .history:
            window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
            window.title = "ThUNER History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 520))
        case .stream:
            window = FocusClearingWindow(contentViewController: NSHostingController(rootView: StreamWindowView(model: model)))
            window.title = "ThUNER Stream"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 760))
        case .welcome:
            let tour = OnboardingView(model: model, showIcon: { [weak self] in self?.pulseMenuBarIcon() }, finish: { [weak self] in
                self?.windows[.welcome]?.close()
                self?.openPanel()
            })
            window = NSWindow(contentViewController: NSHostingController(rootView: tour))
            window.title = "Welcome to ThUNER"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.delegate = self
        case .about:
            window = NSWindow(contentViewController: NSHostingController(rootView: AboutView(model: model)))
            window.title = "About ThUNER"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.isReleasedWhenClosed = false
        if kind == .welcome {
            window.center()
            return window
        }
        // Where it was last time (if that's still on a display), AppKit's saved frame from before, or centred.
        if let frame = WindowFrames.saved(Self.frameKey(kind)) {
            window.setFrame(frame, display: false)
        } else if !window.setFrameUsingName("ThUNER-\(kind)") {
            window.center()
        }
        window.delegate = self
        return window
    }

    /// Every move and resize is saved straight away (the autosave alone sometimes missed one, and the window came
    /// back where it was before), by ThUNER itself: AppKit's own saved frames put a window on a secondary display
    /// back on the main one.
    func windowDidMove(_ notification: Notification) { saveFrame(notification) }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame(notification) }

    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key, kind != .welcome else { return }
        WindowFrames.save(window.frame, Self.frameKey(kind))
    }

    private static func frameKey(_ kind: Kind) -> String { "windowFrame-\(kind)" }

    /// Closing Settings ends any editing first, so a field being typed in (the stream password, an input's name)
    /// is saved. Closing the tour early counts as skipping it: start everything it would have.
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === windows[.settings] {
            window.makeFirstResponder(nil)
        }
        // A closed window is let go, not kept for next time: hidden, its SwiftUI views went on following the
        // model (the Stream window laid itself out twice a second, Settings all seven tabs), about a tenth of a
        // core with nothing on screen. It's rebuilt when it's next opened, where it was.
        if let window = notification.object as? NSWindow, let kind = windows.first(where: { $0.value === window })?.key {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.windows[kind] === window, !window.isVisible else { return }
                self.windows[kind] = nil
                window.contentViewController = nil
            }
        }
        guard notification.object as? NSWindow === windows[.welcome], let model, !model.onboardingComplete else { return }
        model.finishOnboarding()
    }
}

/// Settings' tabs: switching to one doesn't put the cursor in its first text field (which scrolled the pane).
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
    }
}

/// Esc lets go of the keyboard focus (a control reached with Tab), wherever it is in the window.
private final class FocusClearingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
    }
}

/// Window positions, saved by ThUNER rather than AppKit's frame autosave (which moved a window saved on a
/// secondary display onto the main one when it restored it).
enum WindowFrames {
    static func save(_ frame: NSRect, _ key: String) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
    }

    /// The saved frame, if enough of it (its title bar, at least) is on a display that's connected now.
    static func saved(_ key: String) -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: key) else { return nil }
        let frame = NSRectFromString(string)
        guard frame.width > 50, frame.height > 50 else { return nil }
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        let onScreen = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(titleBar)
            return overlap.width >= min(100, frame.width) && overlap.height > 0
        }
        return onScreen ? frame : nil
    }
}
