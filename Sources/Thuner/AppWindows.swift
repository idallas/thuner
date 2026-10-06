import AppKit
import SwiftUI

/// Settings, History and About, as plain AppKit windows hosting their SwiftUI views. The panel isn't a SwiftUI
/// scene, so it can't use openWindow; opening these directly works from anywhere.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    enum Kind {
        case settings, history, about, welcome
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
    }

    private func make(_ kind: Kind, model: AppModel) -> NSWindow {
        let window: NSWindow
        switch kind {
        case .settings:
            // Classic Mac settings: toolbar tabs with icons, the window titled after the selected tab.
            let tabs = NSTabViewController()
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
            window.toolbarStyle = .preference
        case .history:
            window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
            window.title = "ThUNER History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 520))
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
        window.center()
        if kind == .welcome { return window }
        window.setFrameAutosaveName("ThUNER-\(kind)")
        return window
    }

    /// Closing the tour early counts as skipping it: start everything it would have.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === windows[.welcome], let model, !model.onboardingComplete else { return }
        model.finishOnboarding()
    }
}
