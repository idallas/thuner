import AppKit
import Foundation
import Observation
import ThunerCore
import UniformTypeIdentifiers
import UserNotifications

/// macOS notifications when the track changes (Settings → Display → Notifications): a banner with the cover,
/// song, artist and where it's playing, like Apple Music's own for its songs. Each new one replaces the last in
/// Notification Center rather than piling up, and clicking one opens the panel.
///
/// Not available from `swift run`: the notification center needs an app bundle (it aborts without one).
@MainActor @Observable
final class TrackNotifier: NSObject {
    /// What macOS says about ThUNER's notifications, for Settings: nil until asked.
    private(set) var authorization: UNAuthorizationStatus?

    static let available = Bundle.main.bundleURL.pathExtension == "app"

    private static let identifier = "nowplaying"
    private let log = ThunerLogger("notifications")
    @ObservationIgnored private var attachmentTask: Task<Void, Never>?
    @ObservationIgnored private var serial = 0

    /// Call once at launch, so a click on a notification reaches ThUNER (even one that launched it).
    func install() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    func refreshAuthorization() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.authorization = status }
        }
    }

    /// Asks macOS once (its own dialog); afterwards the answer lives in System Settings → Notifications.
    func requestAuthorization() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { self.log.error("Couldn't ask to show notifications: \(error.localizedDescription)") }
            Task { @MainActor in
                self.refreshAuthorization()
                if !granted { self.log.activity("Notifications are off for ThUNER in System Settings") }
            }
        }
    }

    /// Where System Settings keeps ThUNER's switch.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.idallas.thuner"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func notify(_ track: Track, content: TrackNotifications.Content) {
        guard Self.available else { return }
        serial += 1
        let serial = serial
        attachmentTask?.cancel()
        attachmentTask = Task { [weak self] in
            let attachment = await Self.attachment(for: track.artworkURL)
            guard !Task.isCancelled, let self, self.serial == serial else { return }
            let note = UNMutableNotificationContent()
            note.title = content.title
            note.subtitle = content.subtitle
            note.body = content.body
            note.threadIdentifier = Self.identifier
            if let attachment { note.attachments = [attachment] }
            let center = UNUserNotificationCenter.current()
            // The same identifier replaces the last one that's still showing.
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            let request = UNNotificationRequest(identifier: Self.identifier, content: note, trigger: nil)
            do {
                try await center.add(request)
                self.log.info("Notified: \(track.displayName) (\(content.body))")
            } catch {
                self.log.error("Couldn't show the notification for \(track.displayName): \(error.localizedDescription)")
            }
        }
    }

    /// The cover as a file the notification can show. Apple's CDN serves any size by path, so ask for 300 px
    /// rather than the 800 px the panel shows; local covers (the Music app's, ThUNER's own server) come as they
    /// are. The system moves the file into its own store, so it's always a fresh copy.
    private static func attachment(for url: URL?) async -> UNNotificationAttachment? {
        guard let url else { return nil }
        var s = url.absoluteString
        if let r = s.range(of: #"/\d+x\d+bb\."#, options: .regularExpression) {
            s.replaceSubrange(r, with: "/300x300bb.")
        }
        guard let source = URL(string: s) ?? Optional(url) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: source)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            let type = response.mimeType.flatMap { UTType(mimeType: $0) }
                ?? UTType(filenameExtension: source.pathExtension) ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("thuner-cover-\(UUID().uuidString).\(ext)")
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "cover", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: type.identifier])
        } catch {
            ThunerLogger("notifications").debug("No cover for the notification: \(error.localizedDescription)")
            return nil
        }
    }
}

extension TrackNotifier: UNUserNotificationCenterDelegate {
    /// Show it even while ThUNER counts as the active app (its panel open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in AppWindows.shared.openPanel() }
        }
        completionHandler()
    }
}
