import AppIntents
import Foundation

// ThUNER's actions in the Shortcuts app (and anything that runs shortcuts: `shortcuts run "Pause ThUNER"`, Action
// Hero, Siri, Spotlight). They go through the same `ControlSurface` as Twist Commando and the HTTP API where there's
// a control for it, and each returns a line of text saying what it did, for whatever ran it to show.
//
// The Shortcuts app finds them through `Contents/Resources/Metadata.appintents`, which Xcode generates and SwiftPM
// doesn't: `Scripts/build-app.sh` runs that step itself.

/// On, off, or the other way from now.
enum ThunerSwitch: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "On or Off"
    static let caseDisplayRepresentations: [ThunerSwitch: DisplayRepresentation] = [
        .on: "On", .off: "Off", .toggle: "Toggle",
    ]

    func resolve(current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

struct ThunerIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// The running app's model. Shortcuts may launch ThUNER to run an action, so give it a moment to finish starting.
@MainActor
private func thuner() async throws -> AppModel {
    for _ in 0..<50 {
        if let model = AppModel.current { return model }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ThunerIntentError(message: "ThUNER isn't ready yet")
}

// MARK: Listening

struct SetListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Listening"
    static let description = IntentDescription("Pauses or resumes ThUNER's listening (the microphone or input). A pause set here stays until it's resumed, like one from the menu.")
    static let openAppWhenRun = false

    @Parameter(title: "Listening", default: .toggle)
    var state: ThunerSwitch

    static var parameterSummary: some ParameterSummary { Summary("Turn ThUNER's listening \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        guard model.micEnabled else { throw ThunerIntentError(message: "Listening with a microphone or input is turned off in Settings") }
        let on = state.resolve(current: model.controls.states["listening"]?.on ?? false)
        model.controls.set("listening", on: on)
        return .result(value: on ? "Listening" : "Listening paused")
    }
}

struct IdentifyNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Identify Now"
    static let description = IntentDescription("Asks Shazam what's playing right away, instead of waiting for the next check.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.controls.press("identify")
        return .result(value: "Identifying")
    }
}

struct GetNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get What's Playing"
    static let description = IntentDescription("What ThUNER shows as playing: \"Artist – Title\", or \"Nothing playing\".")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        return .result(value: model.shownTrack?.displayName ?? "Nothing playing")
    }
}

struct SetRadioModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Radio Mode"
    static let description = IntentDescription("Radio mode keeps showing covers but doesn't scrobble.")
    static let openAppWhenRun = false

    @Parameter(title: "Radio mode", default: .toggle)
    var state: ThunerSwitch

    static var parameterSummary: some ParameterSummary { Summary("Turn ThUNER's radio mode \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.radioMode = state.resolve(current: model.radioMode)
        return .result(value: model.radioMode ? "Radio mode on" : "Radio mode off")
    }
}

// MARK: Playback (Apple Music and Spotify)

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses Apple Music or Spotify, whichever ThUNER is following. macOS asks once whether ThUNER may control each app.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await (try await thuner()).playbackResult(.playPause))
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in Apple Music or Spotify, whichever ThUNER is following.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await (try await thuner()).playbackResult(.next))
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Goes back a track in Apple Music or Spotify, whichever ThUNER is following.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await (try await thuner()).playbackResult(.previous))
    }
}

// MARK: Display

struct ClearTuneshineIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Tuneshine"
    static let description = IntentDescription("Takes ThUNER's cover off the Tuneshine, back to its own display.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.controls.press("clear")
        return .result(value: "Tuneshine cleared")
    }
}

struct SetTuneshineBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Tuneshine Brightness"
    static let openAppWhenRun = false

    @Parameter(title: "Brightness", description: "1 to 100", default: 60, inclusiveRange: (1, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary { Summary("Set the Tuneshine's brightness to \(\.$percent)%") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.setTuneshineBrightness(min(max(percent, 1), 100))
        return .result(value: "Tuneshine brightness \(min(max(percent, 1), 100))%")
    }
}

struct SetFloatingCoverIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Floating Cover"
    static let description = IntentDescription("Shows or hides the always-on-top cover window.")
    static let openAppWhenRun = false

    @Parameter(title: "Floating cover", default: .toggle)
    var state: ThunerSwitch

    static var parameterSummary: some ParameterSummary { Summary("Turn the floating cover \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.showFloatingCover = state.resolve(current: model.showFloatingCover)
        return .result(value: model.showFloatingCover ? "Floating cover shown" : "Floating cover hidden")
    }
}

// MARK: Streaming

struct SetSharingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Input Sharing"
    static let description = IntentDescription("Shares this Mac's input with other ThUNERs (or stops).")
    static let openAppWhenRun = false

    @Parameter(title: "Sharing", default: .toggle)
    var state: ThunerSwitch

    static var parameterSummary: some ParameterSummary { Summary("Turn sharing this Mac's input \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        model.streamSharing = state.resolve(current: model.streamSharing)
        return .result(value: model.streamSharing ? "Sharing this Mac's input" : "Not sharing")
    }
}

/// The Macs a stream can come from: the ThUNERs found on the network, and Off.
struct StreamSourceOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        ["Off"] + ((try? await thuner())?.otherThuners ?? [])
    }
}

struct ListenToStreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Listen to Stream"
    static let description = IntentDescription("Plays another ThUNER's shared input on this Mac (with the method and output set in Settings → Streaming), or stops.")
    static let openAppWhenRun = false

    @Parameter(title: "From", description: "Another Mac's name, as ThUNER lists it, or Off", optionsProvider: StreamSourceOptions())
    var source: String

    static var parameterSummary: some ParameterSummary { Summary("Listen to the stream from \(\.$source)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        let name = source.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.caseInsensitiveCompare("Off") == .orderedSame {
            model.streamSource = ""
            return .result(value: "Not listening to a stream")
        }
        model.streamSource = name
        let found = model.otherThuners.contains(name)
        return .result(value: found ? "Listening to \(name)" : "Listening to \(name) once it's found on the network")
    }
}

struct GetStreamStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Stream Status"
    static let description = IntentDescription("What the stream this Mac listens to is doing, in a line: playing (with its latency), nothing playing, a problem, or off.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await thuner()
        guard !model.streamSource.isEmpty else { return .result(value: "Off") }
        let from = AppModel.shown(model.streamSource)
        if let problem = model.streamProblem { return .result(value: "\(from): \(problem)") }
        if model.streamQuiet { return .result(value: "\(from): nothing playing") }
        guard let reading = model.streamReading(), reading.stats.playing else { return .result(value: "\(from): waiting for audio") }
        let latency = reading.latency.map { String(format: "≈ %.0f ms", $0.totalMs) } ?? String(format: "%.1f ms buffer", reading.stats.bufferedMs)
        return .result(value: "\(from): playing, \(latency)")
    }
}

// MARK: Ready-made shortcuts (Spotlight, Siri, the Shortcuts app's ThUNER section)

struct ThunerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetNowPlayingIntent(), phrases: ["What's playing on \(.applicationName)",
                                                             "What's \(.applicationName) playing"],
                    shortTitle: "What's Playing", systemImageName: "music.note")
        AppShortcut(intent: SetListeningIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)",
                                                            "Toggle \(.applicationName) listening"],
                    shortTitle: "Pause or Resume", systemImageName: "pause.circle")
        AppShortcut(intent: IdentifyNowIntent(), phrases: ["Identify with \(.applicationName)",
                                                           "\(.applicationName), what song is this"],
                    shortTitle: "Identify Now", systemImageName: "shazam.logo")
    }
}
