import SwiftUI
import UniformTypeIdentifiers
import ThunerCore

/// Settings: General (this Mac's role, login, permission status), Listening, Display, Scrobbling, Updates.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var enteringTuneshineAddress = false
    @State private var addingService = false

    /// The settings window is an NSTabViewController with toolbar tabs (AppWindows); each tab shows one pane.
    enum Pane: String, CaseIterable {
        case general, listening, display, scrobbling, updates

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .listening: "waveform"
            case .display: "rectangle.on.rectangle"
            case .scrobbling: "music.note.list"
            case .updates: "arrow.down.circle"
            }
        }
    }

    var pane = Pane.general

    var body: some View {
        Group {
            switch pane {
            case .general:
                Form {
                    Section {
                        Picker("This Mac", selection: $model.role) {
                            Text("Turntable (has priority)").tag(PushArbiter.Role.primary)
                            Text("Secondary").tag(PushArbiter.Role.secondary)
                        }
                        Toggle("Launch at login", isOn: $model.launchAtLogin)
                    } footer: {
                        Text("While the turntable Mac hears music, a secondary Mac turns its mic off and shows what the turntable Mac is playing. Use Listen Here in the menu to override until it goes quiet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        StatusRow(title: "Microphone", state: micState, detail: micDetail) {
                            model.openPrivacySettings("Privacy_Microphone")
                        }
                        StatusRow(title: "Local Network", state: networkState, detail: networkDetail) {
                            model.openPrivacySettings("Privacy_LocalNetwork")
                        }
                        StatusRow(title: "ShazamKit", state: shazamState, detail: shazamDetail, action: nil)
                    } header: {
                        HStack {
                            Text("Status")
                            Spacer()
                            if model.checkingTuneshine { ProgressView().controlSize(.small) }
                            Button("Check Again") { Task { await model.checkTuneshine() } }
                                .controlSize(.small)
                                .disabled(model.checkingTuneshine)
                        }
                    }

                }
                .formStyle(.grouped)

            case .listening:
                Form {
                    Section {
                        Toggle("Listen with a microphone or input", isOn: $model.micEnabled)
                    } footer: {
                        Text("Off: ThUNER never uses the microphone or Shazam, and follows Apple Music and Spotify (and a turntable Mac, if you have one) only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        Picker("Listen to", selection: $model.systemAudioMode) {
                            Text("Everything this Mac plays").tag(SystemAudioTap.Mode.all)
                            Text("Only these apps").tag(SystemAudioTap.Mode.only)
                            Text("Everything except these apps").tag(SystemAudioTap.Mode.except)
                        }
                        if model.systemAudioMode != .all {
                            ForEach(systemAudioCandidates) { app in
                                Toggle(isOn: Binding(
                                    get: { model.systemAudioApps.contains(app) },
                                    set: { _ in model.toggleSystemAudioApp(app) }
                                )) {
                                    HStack(spacing: 8) {
                                        if let icon = appIcon(app.bundleID) {
                                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                        }
                                        Text(app.name)
                                    }
                                }
                            }
                            Button("Add App…") { addSystemAudioApp() }
                        }
                    } header: {
                        Text("System Audio")
                    } footer: {
                        Text("Choose System Audio as the input to identify what this Mac plays, like YouTube Music in a browser, with no microphone. Apps that played sound recently are listed; it doesn't matter which speakers an app plays through. Safari plays through a shared WebKit service, so it can't be picked out on its own.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        Picker("Pause after silence", selection: $model.autoPauseMinutes) {
                            Text("Never").tag(0.0)
                            Text("15 minutes").tag(15.0)
                            Text("30 minutes").tag(30.0)
                            Text("1 hour").tag(60.0)
                            Text("2 hours").tag(120.0)
                        }
                        .disabled(!model.micEnabled)
                    } header: {
                        Text("Auto-pause")
                    } footer: {
                        Text("Turns the mic off after this long with no music identified and nothing playing. It wakes when Apple Music or Spotify starts, any app on this Mac starts playing sound, or you open ThUNER. Just using the Mac doesn't wake it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Sources") {
                        Toggle("Use Apple Music when it's playing", isOn: $model.useAppleMusic)
                        Toggle("Use Spotify when it's playing", isOn: $model.useSpotify)
                        Text("While the Music or Spotify app on this Mac is playing, ThUNER takes the track from the app and doesn't run Shazam. It picks up a player at its next track change or play/pause.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        ForEach(model.devices) { device in
                            Toggle(isOn: Binding(
                                get: { !model.hiddenInputUIDs.contains(device.uid) },
                                set: { model.setInput(device, visible: $0) }
                            )) {
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text(device.inputChannels == 1 ? "1 channel" : "\(device.inputChannels) channels")
                                        .foregroundStyle(.secondary)
                                    if device.uid == model.inputDeviceUID {
                                        Text("In use").font(.caption).foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Inputs shown in the menu")
                    } footer: {
                        Text("Hide inputs you'd never listen to, like the ones Zoom, Teams or Steam add.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                }
                .formStyle(.grouped)

            case .display:
                Form {
                    Section("Tuneshine") {
                        Picker("Tuneshine", selection: tuneshineChoice) {
                            Text(automaticLabel).tag("")
                            ForEach(model.discoveredTuneshines) { device in
                                Text("\(device.name) (\(device.host))").tag(device.host)
                            }
                            if isCustomAddress {
                                Text(model.tuneshineHost).tag(model.tuneshineHost)
                            }
                            Divider()
                            Text("Enter an Address…").tag(Self.otherTag)
                        }
                        if enteringTuneshineAddress || isCustomAddress {
                            TextField("Address", text: $model.tuneshineHost, prompt: Text("tuneshine-xxxx.local or an IP address"))
                        }
                        Picker("Clear after silence", selection: $model.idleImageMinutes) {
                            Text("Never").tag(0.0)
                            Text("2 min").tag(2.0)
                            Text("5 min").tag(5.0)
                            Text("15 min").tag(15.0)
                        }
                        Toggle("Floating cover", isOn: $model.showFloatingCover)
                        Toggle("Only while music is playing", isOn: $model.floatingCoverOnlyWhilePlaying)
                            .disabled(!model.showFloatingCover)
                            .padding(.leading, 18)
                    }
                    Section {
                        Toggle("Web display", isOn: $model.webDisplayEnabled)
                        if model.webDisplayEnabled {
                            Picker("Reachable from", selection: $model.webDisplayLocalOnly) {
                                Text("Any device on the network").tag(false)
                                Text("This Mac only").tag(true)
                            }
                            LabeledContent("Address") {
                                Text(model.webDisplayURL.absoluteString).textSelection(.enabled)
                            }
                            HStack {
                                Button("Open Tuneshine View") { model.openWebDisplay(mode: "tuneshine") }
                                Button("Open Cover View") { model.openWebDisplay(mode: "cover") }
                            }
                        }
                    } header: {
                        Text("Web display")
                    } footer: {
                        Text("Show what's playing on any screen on your network: open the address in a browser. Press M to switch between the Tuneshine look and a large cover, F for full screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.webDisplayEnabled {
                        Section {
                            LabeledContent("API") {
                                Text(model.webDisplayURL.absoluteString + "api").textSelection(.enabled)
                            }
                            LabeledContent("Token") {
                                HStack {
                                    Text(model.apiToken).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(model.apiToken, forType: .string)
                                    }
                                    Button("New Token") { model.regenerateAPIToken() }
                                }
                            }
                        } header: {
                            Text("Control API")
                        } footer: {
                            Text("Home Assistant, Stream Deck, scripts and the like can read ThUNER's controls (GET /api/controls, live at /api/events) and change them (POST /api/controls/<id>). Changing needs the token, except from scripts on this Mac (web pages always need it).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Toggle("Twist Commando", isOn: $model.twistCommandoEnabled)
                        if model.twistCommandoEnabled {
                            LabeledContent("Status", value: model.twistCommandoVersion.map { "Connected (Twist Commando \($0))" }
                                ?? "Waiting for Twist Commando")
                        }
                    } header: {
                        Text("Controllers")
                    } footer: {
                        Text("Offers ThUNER's controls (listening, silence threshold, input level, now playing, radio mode, Tuneshine brightness and more) to Twist Commando's App Link, to put on any knob or pad.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("On this Mac") {
                        Toggle("Animate menu bar icon while playing", isOn: $model.animateMenuBarIcon)
                    }
                }
                .formStyle(.grouped)

            case .scrobbling:
                Form {
                    Section {
                        Toggle("Scrobble from this Mac", isOn: $model.scrobblingEnabled)
                        Toggle("Radio mode", isOn: $model.radioMode)
                            .disabled(!model.scrobblingEnabled)
                            .help("Keep listening and showing covers, but don't scrobble anything. Also in the menu's ⋯.")
                        Toggle("Skip plays a service already has", isOn: $model.skipDuplicateScrobbles)
                            .help("Before scrobbling, checks the service's recent plays for the same play from another scrobbler or Mac (where the service allows reading them)")
                    } header: {
                        Text("Scrobbling")
                    } footer: {
                        Text("Sends Spotify and Apple Music plays on this Mac, plus Shazam matches, to every service below that's switched on. Don't also run Silicio or a service's own Spotify link for the same account. A secondary Mac doesn't scrobble Shazam matches while the turntable Mac is active.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Last.fm") {
                        if let user = model.lastFMUser {
                            LabeledContent("Account") {
                                HStack {
                                    Text(user)
                                    Button("Disconnect") { model.disconnectLastFM() }
                                }
                            }
                            if model.lastFMPending > 0 {
                                Text("\(model.lastFMPending) scrobbles waiting to send").font(.caption)
                            }
                        } else if !model.lastFMHasCredentials {
                            Text("Create an API account at last.fm/api/account/create (any name and description; leave the callback URL empty), then paste its key and shared secret here.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("API key", text: $apiKey)
                            SecureField("Shared secret", text: $secret)
                            Button("Save") { model.setLastFMCredentials(apiKey: apiKey, secret: secret) }
                                .disabled(apiKey.isEmpty || secret.isEmpty)
                        } else if model.lastFMAwaitingApproval {
                            Text("Approve ThUNER on the Last.fm page that opened in your browser, then come back here.")
                                .font(.caption)
                            HStack {
                                Button("I've Approved It") { model.finishLastFMConnect() }
                                Button("Open Again") { model.beginLastFMConnect() }
                            }
                        } else {
                            Button("Connect Last.fm Account…") { model.beginLastFMConnect() }
                        }
                        if let error = model.lastFMError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }

                    Section {
                        ForEach(model.listenBrainzConfigs) { config in
                            ListenBrainzRow(model: model, config: config)
                        }
                        Button("Add a Service…") { addingService = true }
                    } header: {
                        Text("ListenBrainz, Maloja, Koito and others")
                    } footer: {
                        Text("Any server that speaks the ListenBrainz API: ListenBrainz itself, self-hosted Maloja or Koito, or a multi-scrobbler relay.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

            case .updates:
                Form {
                    Section("Updates") {
                        LabeledContent("Version", value: model.updater.currentVersion)
                        Toggle("Check for updates automatically", isOn: Bindable(model.updater).automaticallyChecks)
                        Toggle("Install updates automatically", isOn: Bindable(model.updater).automaticallyInstalls)
                            .disabled(!model.updater.automaticallyChecks)
                            .help("Downloads in the background and installs the next time nothing's playing (ThUNER relaunches itself in a second or two).")
                        if let pending = model.updater.pendingVersion {
                            Text("Version \(pending) will install the next time nothing's playing.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if UsageStats.isAvailable {
                            Toggle("Share anonymous update-check stats", isOn: Bindable(model.updater).sendsUsageStats)
                                .help("Each update check reports ThUNER's version, the macOS version and the chip type to the website's stats. Nothing about what you listen to.")
                        }
                        Button("Check Now") { model.updater.checkForUpdates() }
                    }

                }
                .formStyle(.grouped)
            }
        }
        .sheet(isPresented: $addingService) { AddServiceSheet(model: model) }
        .task { await model.checkTuneshine() }
        .onAppear { model.refreshDevices() }
        // Fill whatever the window gives it: a fixed size larger than the window was centered and lost its
        // first and last rows off the top and bottom.
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }
}

extension SettingsView {
    private var micState: StatusRow.State {
        if !model.micEnabled { return .ok }
        return switch model.micStatus {
        case .authorized: .ok
        case .notDetermined: .unknown
        default: .problem
        }
    }

    private var micDetail: String {
        if !model.micEnabled { return "Not used: microphone listening is off (Settings → Listening)" }
        return switch model.micStatus {
        case .authorized: "Allowed"
        case .notDetermined: "Not asked yet"
        default: "Denied. Turn on ThUNER under Microphone."
        }
    }

    private var networkState: StatusRow.State {
        switch model.tuneshineHealth {
        case .ok: .ok
        case .localNetworkDenied: .problem
        case .unreachable: .warning
        case nil: .unknown
        }
    }

    private var networkDetail: String {
        switch model.tuneshineHealth {
        case .ok(let name, let firmware): "Reached \(name) (firmware \(firmware))"
        case .localNetworkDenied: "Blocked by macOS. Turn ThUNER off and on again under Local Network, then Check Again."
        case .unreachable(let reason): "Allowed, but the Tuneshine didn't answer: \(reason)"
        case nil: "Checking…"
        }
    }

    private var shazamState: StatusRow.State {
        switch model.shazamStatus {
        case .ok: .ok
        case .serviceNotEnabled: .problem
        case .unknown: .unknown
        }
    }

    private var shazamDetail: String {
        switch model.shazamStatus {
        case .ok: "Matching works"
        case .serviceNotEnabled: "The ShazamKit App Service isn't enabled for \(Bundle.main.bundleIdentifier ?? "this app") (error 102)"
        case .unknown: "Not tried yet; it checks on the next match"
        }
    }
}

private struct StatusRow: View {
    enum State { case ok, warning, problem, unknown }

    let title: String
    let state: State
    let detail: String
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action, state != .ok {
                Button("Open Settings", action: action).controlSize(.small)
            }
        }
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .unknown: "circle.dotted"
        }
    }

    private var color: Color {
        switch state {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .unknown: .secondary
        }
    }
}

extension SettingsView {
    fileprivate static let otherTag = "__other__"

    private var automaticLabel: String {
        if let first = model.discoveredTuneshines.first { return "Automatic (\(first.name))" }
        return "Automatic (searching…)"
    }

    /// An address typed in that isn't one of the discovered devices.
    private var isCustomAddress: Bool {
        !model.tuneshineHost.isEmpty
            && !model.discoveredTuneshines.contains { $0.host.caseInsensitiveCompare(model.tuneshineHost) == .orderedSame }
    }

    private var tuneshineChoice: Binding<String> {
        Binding(
            get: {
                if enteringTuneshineAddress { return Self.otherTag }
                // Match a discovered device even if the saved address differs in case.
                return model.discoveredTuneshines.first {
                    $0.host.caseInsensitiveCompare(model.tuneshineHost) == .orderedSame
                }?.host ?? model.tuneshineHost
            },
            set: { choice in
                if choice == Self.otherTag {
                    enteringTuneshineAddress = true
                } else {
                    enteringTuneshineAddress = false
                    model.tuneshineHost = choice
                }
            })
    }
}

private struct ListenBrainzRow: View {
    let model: AppModel
    let config: ListenBrainzService.Config

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { config.enabled }, set: { model.setListenBrainzService(config.id, enabled: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name)
                    Text([config.username, config.serverURL].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let pending = model.pendingScrobbles[config.id.uuidString], pending > 0 {
                        Text("\(pending) waiting to send").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button("Remove", role: .destructive) { model.removeListenBrainzService(config.id) }
                .controlSize(.small)
        }
    }
}

private struct AddServiceSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Preset: String, CaseIterable, Identifiable {
        case listenBrainz = "ListenBrainz"
        case maloja = "Maloja"
        case koito = "Koito"
        case multiScrobbler = "multi-scrobbler"
        case other = "Other (detect automatically)"
        var id: Self { self }

        var kind: ListenBrainzService.Config.Kind? {
            switch self {
            case .listenBrainz: .listenBrainz
            case .maloja: .maloja
            case .koito: .koito
            case .multiScrobbler: .multiScrobbler
            case .other: nil
            }
        }

        var tokenHelp: String {
            switch self {
            case .listenBrainz: "Your user token is at listenbrainz.org/settings."
            case .maloja: "Create an API key in Maloja's settings (Settings → API Keys), one per app."
            case .koito: "Create an API key in Koito's settings."
            case .multiScrobbler: "The token set for multi-scrobbler's ListenBrainz endpoint."
            case .other: "The token or API key the server gave you."
            }
        }
    }

    @State private var preset = Preset.maloja
    @State private var name = ""
    @State private var serverURL = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Scrobbling Service").font(.headline)
            Form {
                Picker("Service", selection: $preset) {
                    ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                }
                if preset == .listenBrainz {
                    LabeledContent("Server", value: "api.listenbrainz.org")
                } else {
                    TextField("Server address", text: $serverURL, prompt: Text("https://maloja.example.com"))
                }
                SecureField("Token", text: $token)
                TextField("Name", text: $name, prompt: Text(preset == .other ? "Shown in ThUNER" : preset.rawValue))
            }
            .formStyle(.columns)
            Text(preset.tokenHelp).font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || token.isEmpty || (preset != .listenBrainz && serverURL.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        working = true
        error = nil
        let url = preset == .listenBrainz ? "https://api.listenbrainz.org" : serverURL
        let displayName = name.isEmpty && preset != .other ? preset.rawValue : name
        Task {
            do {
                try await model.addListenBrainzService(name: displayName, kind: preset.kind, serverURL: url, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

extension SettingsView {
    /// The chosen apps, then recent ones not chosen yet.
    fileprivate var systemAudioCandidates: [AudioDevices.AudioApp] {
        model.systemAudioApps + model.recentAudioApps.filter { !model.systemAudioApps.contains($0) }
    }

    fileprivate func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    fileprivate func addSystemAudioApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let app = AudioDevices.AudioApp(bundleID: id, name: name)
            if !model.systemAudioApps.contains(app) { model.systemAudioApps.append(app) }
        }
    }
}
