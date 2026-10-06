import AppKit
import Observation
import Sparkle

/// Sparkle auto-updates. The feed is https://idallas.com/software/thuner/appcast.xml (SUFeedURL in Info.plist),
/// signed with the EdDSA key in the release Mac's Keychain (account "thuner").
@MainActor @Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        sendsUsageStats = UserDefaults.standard.object(forKey: "sendsUpdateCheckStats") as? Bool ?? true
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
    }

    var automaticallyChecks = true {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    /// Download and install in the background, without asking. Good for the headless Mac mini.
    /// On by default (SUAutomaticallyUpdate in Info.plist).
    var automaticallyInstalls = true {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    /// Report each update check to Umami (app version, macOS version, chip), so it's possible to see how many
    /// installs are active and on which versions.
    var sendsUsageStats = true {
        didSet { UserDefaults.standard.set(sendsUsageStats, forKey: "sendsUpdateCheckStats") }
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in
            if sendsUsageStats { await UsageStats.updateCheck() }
        }
    }

    // MARK: Silent installs

    /// A downloaded update waiting to be installed, and when it became ready.
    @ObservationIgnored private var pendingInstall: (install: () -> Void, since: Date)?
    /// The version waiting to be installed, for the Settings window.
    private(set) var pendingVersion: String?

    /// Sparkle normally installs an automatically downloaded update when the app quits, but a menu bar app
    /// (especially on the headless Mac mini) practically never quits. Take over: install it ourselves at a
    /// quiet moment via `installPendingUpdateIfQuiet(isQuiet:)`.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            pendingInstall = (immediateInstallHandler, Date())
            pendingVersion = version
        }
        return true
    }

    /// Call periodically. Installs and relaunches when nothing's playing, or after an hour regardless so a
    /// marathon listening session doesn't hold updates back forever.
    func installPendingUpdateIfQuiet(isQuiet: Bool) {
        guard let pending = pendingInstall, isQuiet || Date().timeIntervalSince(pending.since) > 3600 else { return }
        pendingInstall = nil
        pending.install()
    }

    // A menu bar app has no Dock icon, so let Sparkle remind gently instead of popping windows over other apps.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
