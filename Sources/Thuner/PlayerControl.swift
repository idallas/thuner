import AppKit
import Foundation
import os

/// Play/pause and skipping in Apple Music, Spotify and websites, for the playback controls. Reading what they play
/// needs no permission (PlayerMonitor listens to their notifications); controlling the apps is AppleScript, which
/// macOS asks about (Privacy & Security → Automation) the first time a control is used, never before.
///
/// A browser tab can't be scripted, so for a website ThUNER presses the keyboard's media keys: browsers answer them
/// (macOS sends them to whatever it thinks is playing). Faking a key press needs Accessibility permission, again
/// asked the first time, never before.
enum PlayerControl {
    enum Command: String, Sendable {
        case playPause, next, previous

        var script: String {
            switch self {
            case .playPause: "playpause"
            case .next: "next track"
            case .previous: "previous track"
            }
        }

        /// The media key that does the same (`NX_KEYTYPE_PLAY`, `_NEXT`, `_PREVIOUS` in IOKit's ev_keymap.h).
        var mediaKey: Int {
            switch self {
            case .playPause: 16
            case .next: 17
            case .previous: 18
            }
        }
    }

    enum Outcome: Sendable, Equatable {
        case done
        /// The app isn't open (nothing to control).
        case notRunning
        /// The user said no to ThUNER controlling it (or later turned it off).
        case notAllowed
        case failed(String)
    }

    /// The app to script; nil for a website (media keys instead).
    static func bundleID(_ source: PlayerMonitor.Source) -> String? {
        switch source {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .browser: nil
        }
    }

    static func isRunning(_ source: PlayerMonitor.Source) -> Bool {
        guard let id = bundleID(source) else { return false }
        return isRunning([id])
    }

    /// Whether there's something to control: the app is open, or for a website, its browser (if the webhook said
    /// which; otherwise assume so). With nothing open, the play key would start Apple Music instead.
    static func isRunning(_ player: PlayerMonitor.Snapshot) -> Bool {
        guard player.source == .browser else { return isRunning(player.source) }
        return player.browser.map { isRunning($0.bundleIDs) } ?? true
    }

    private static func isRunning(_ bundleIDs: [String]) -> Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Whether ThUNER may control the app, without asking: nil if it hasn't been asked yet (or the app isn't open).
    static func isAllowed(_ source: PlayerMonitor.Source) -> Bool? {
        guard let id = bundleID(source), let desc = NSAppleEventDescriptor(bundleIdentifier: id).aeDesc else { return nil }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil
        }
    }

    /// AppleScript runs on its own queue: the first use shows macOS's permission prompt and waits for an answer,
    /// which mustn't hold up the panel.
    private static let queue = DispatchQueue(label: "com.idallas.thuner.player-control", qos: .userInitiated)
    private static let log = Logger(subsystem: "com.idallas.thuner", category: "players")

    /// The current track's cover, straight from the Music app, for tracks Apple's catalogue search can't find.
    /// Only when ThUNER may already control Music (granted through the playback buttons): this never asks.
    static func currentArtwork(_ source: PlayerMonitor.Source) async -> Data? {
        guard source == .appleMusic, isRunning(source), isAllowed(source) == true, let id = bundleID(source) else { return nil }
        let script = "tell application id \"\(id)\" to get raw data of artwork 1 of current track"
        return await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                let data = error == nil ? result?.data : nil
                continuation.resume(returning: (data?.isEmpty ?? true) ? nil : data)
            }
        }
    }

    /// What the app is playing right now, in the same shape as its now-playing notification, or nil when it isn't
    /// playing, isn't open, or ThUNER may not control it yet (this never asks, and never launches the app).
    static func nowPlaying(_ source: PlayerMonitor.Source) async -> [AnyHashable: Any]? {
        guard isRunning(source), isAllowed(source) == true else { return nil }
        let script = switch source {
        case .appleMusic: """
            tell application id "com.apple.Music"
                if player state is not playing then return ""
                set t to current track
                return {name of t, artist of t, album of t, duration of t}
            end tell
            """
        case .spotify: """
            tell application id "com.spotify.client"
                if player state is not playing then return ""
                set t to current track
                return {name of t, artist of t, album of t, duration of t, id of t, player position}
            end tell
            """
        case .browser: ""
        }
        let result: NSAppleEventDescriptor? = await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result : nil)
            }
        }
        guard let list = result, list.numberOfItems >= 4,
              let name = list.atIndex(1)?.stringValue, let artist = list.atIndex(2)?.stringValue else { return nil }
        var info: [AnyHashable: Any] = ["Player State": "Playing", "Name": name, "Artist": artist]
        if let album = list.atIndex(3)?.stringValue { info["Album"] = album }
        let duration = list.atIndex(4)?.doubleValue ?? 0
        switch source {
        case .appleMusic:
            if duration > 0 { info["Total Time"] = duration * 1000 }  // seconds → ms, as the notification has it
        case .spotify:
            if duration > 0 { info["Duration"] = duration }  // already ms
            if let id = list.atIndex(5)?.stringValue { info["Track ID"] = id }
            if let position = list.atIndex(6)?.doubleValue { info["Playback Position"] = position }
        case .browser: break
        }
        return info
    }

    static func send(_ command: Command, to player: PlayerMonitor.Snapshot) async -> Outcome {
        guard isRunning(player) else { return .notRunning }
        let source = player.source
        guard let id = bundleID(source) else { return pressMediaKey(command) }
        let script = "tell application id \"\(id)\" to \(command.script)"
        return await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                let outcome: Outcome
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    outcome = code == Int(errAEEventNotPermitted) ? .notAllowed
                        : .failed(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")
                    log.error("\(command.rawValue, privacy: .public) to \(source.rawValue, privacy: .public) failed: \(code)")
                } else {
                    outcome = .done
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Whether ThUNER may press media keys, without asking.
    static var mayPressKeys: Bool { CGPreflightPostEventAccess() }

    /// Presses and releases a media key, as the keyboard would. The first time, macOS asks for Accessibility
    /// permission (its prompt leads to System Settings) and this reports `.notAllowed` until it's granted.
    private static func pressMediaKey(_ command: Command) -> Outcome {
        guard mayPressKeys || CGRequestPostEventAccess() else {
            log.notice("\(command.rawValue, privacy: .public) by media key: no Accessibility permission")
            return .notAllowed
        }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: command.mediaKey << 16 | state << 8, data2: -1)
            guard let event = event?.cgEvent else { return .failed("couldn't make the key press") }
            event.post(tap: .cghidEventTap)
        }
        return .done
    }
}
