import AppKit
import SwiftUI

@main
struct ThunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Everything visible is AppKit-managed (PanelController, AppWindows); SwiftUI needs at least one scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        AppModel.current = model
        AppWindows.shared.model = model
        let panel = PanelController(model: model)
        self.panel = panel
        AppWindows.shared.pulseMenuBarIcon = { [weak panel] in panel?.pulseIcon() }
        AppWindows.shared.openPanel = { [weak panel] in panel?.openPanel() }
        if !model.onboardingComplete { AppWindows.shared.show(.welcome) }
        // `open Thuner.app --args -openSettingsPane streaming`: straight to a settings tab (for checking UI, or a
        // headless Mac over Screen Sharing).
        if let pane = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["openSettingsPane"] as? String,
           let target = SettingsView.Pane(rawValue: pane) {
            AppWindows.shared.showSettings(target)
        }
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["openPanel"] != nil {
            panel.openPanel()
        }
    }
}
