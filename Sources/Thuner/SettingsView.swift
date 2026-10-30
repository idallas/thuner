import SwiftUI
import UniformTypeIdentifiers
import ThunerCore

/// Settings: General (this Mac's role, login, Apple Music and Spotify, permission status), Listening, Streaming,
/// Display, Controls, Scrobbling, Updates.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var enteringTuneshineAddress = false
    @State private var addingService = false
    @State private var managingInputs = false

    /// The settings window is an NSTabViewController with toolbar tabs (AppWindows); each tab shows one pane.
    enum Pane: String, CaseIterable {
        case general, listening, streaming, display, controls, scrobbling, updates

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .listening: "waveform"
            case .streaming: "dot.radiowaves.left.and.right"
            case .display: "rectangle.on.rectangle"
            case .controls: "slider.horizontal.3"
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
                        Toggle("Animate menu bar icon while playing", isOn: $model.animateMenuBarIcon)
                    } footer: {
                        Text("While the turntable Mac hears music, a secondary Mac turns its mic off and shows what the turntable Mac plays. Listen Here in the menu overrides that until it goes quiet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("Apple Music", isOn: $model.useAppleMusic)
                        Toggle("Spotify", isOn: $model.useSpotify)
                    } header: {
                        Text("Follow players on this Mac")
                    } footer: {
                        Text("While one of these plays, ThUNER takes the track from it instead of listening. It notices a player at its next track change or play/pause.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("Follow websites", isOn: $model.useWebScrobbler)
                        if model.webDisplayEnabled {
                            LabeledContent("Webhook URL") {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.webScrobblerURL, forType: .string)
                                }
                            }
                            .disabled(!model.useWebScrobbler)
                        } else {
                            LabeledContent("Needs ThUNER's web server (Display)") {
                                Button("Turn On") { model.webDisplayEnabled = true }
                            }
                        }
                    } header: {
                        Text("Websites through Web Scrobbler")
                    } footer: {
                        Text("For YouTube Music, Bandcamp, SoundCloud and the other sites the Web Scrobbler browser extension knows. In its settings, add a Webhook with this URL (any application name) and let it reach localhost when the browser asks. Turn off Web Scrobbler's own Last.fm, or plays are scrobbled twice: ThUNER scrobbles them. A new API token (Controls) changes the URL.")
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
                        Toggle("Ask before listening when Apple Music or Spotify stops", isOn: $model.askBeforeMicAfterPlayer)
                            .disabled(!model.micEnabled)
                        LabeledContent("Inputs") {
                            Button("Show and Name Inputs…") { managingInputs = true }
                        }
                        .disabled(!model.micEnabled)
                    } footer: {
                        Text("Off: ThUNER never uses the microphone or Shazam, and only follows Apple Music, Spotify and a turntable Mac. Choose the input in the menu. Asking keeps the mic off when a player stops, until you click Listen in the menu.")
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
                        Text("Turns listening off when no music has been identified for this long. It wakes when Apple Music or Spotify starts, an app on this Mac plays sound, or you open ThUNER.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Only with System Audio as the input: nothing here matters otherwise.
                    if model.usingSystemAudio {
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
                            Text("System Audio identifies what this Mac plays, like YouTube Music in a browser. Apps that played sound recently are listed. Safari plays through a shared WebKit service, so it can't be picked out on its own.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                    }
                }
                .formStyle(.grouped)
                .sheet(isPresented: $managingInputs) { InputsSheet(model: model) }

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
                    }
                    Section {
                        Toggle("Show the floating cover", isOn: $model.showFloatingCover)
                        Toggle("Dim when nothing's playing", isOn: $model.floatingCoverDims)
                            .disabled(!model.showFloatingCover)
                    } header: {
                        Text("Floating cover")
                    } footer: {
                        Text("An always-on-top cover window. Drag it anywhere; hover it for playback controls (Apple Music, Spotify) or × to close it. After 5 minutes with nothing playing it dims, on the last cover.")
                            .font(.caption).foregroundStyle(.secondary)
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
                        Text("What's playing, in any browser on your network. M switches between the Tuneshine look and a large cover, F goes full screen. The Control API (Controls) uses the same server.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

            case .controls:
                Form {
                    Section {
                        if model.webDisplayEnabled {
                            LabeledContent("Address") {
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
                        } else {
                            LabeledContent("Off, with the web display") {
                                Button("Turn On") { model.webDisplayEnabled = true }
                            }
                        }
                    } header: {
                        Text("Control API")
                    } footer: {
                        Text("For Home Assistant, Stream Deck, scripts and the like: GET /api/controls (live at /api/events), POST /api/controls/<id>. Changing needs the token, except from scripts on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("Offer ThUNER's controls to other apps", isOn: $model.twistCommandoEnabled)
                        if model.twistCommandoEnabled {
                            LabeledContent("Using them now", value: model.controlConsumers.isEmpty
                                ? "No apps" : model.controlConsumers.joined(separator: ", "))
                        }
                    } header: {
                        Text("Other apps")
                    } footer: {
                        Text("Listening, the silence threshold, levels and meters, now playing, scrobbling, the Tuneshine and more, for apps on this Mac that speak Applug, like Twist Commando (any knob or pad) and Action Hero.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("ThUNER's actions are in the Shortcuts app (search for ThUNER), for automations, Siri and Spotlight.")
                            .foregroundStyle(.secondary)
                        Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                    } header: {
                        Text("Shortcuts")
                    }
                }
                .formStyle(.grouped)

            case .scrobbling:
                Form {
                    Section {
                        Toggle("Scrobble from this Mac", isOn: $model.scrobblingEnabled)
                        Toggle("Pause scrobbling for now", isOn: $model.radioMode)
                            .disabled(!model.scrobblingEnabled)
                            .help("Keep listening and showing covers, but don't scrobble anything until you turn it back on. Also the Scrobble button in the menu.")
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

            case .streaming:
                StreamingSettings(model: model)

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
                        Toggle("Get test builds", isOn: Bindable(model.updater).getsTestBuilds)
                            .help("New versions arrive here before everyone else gets them, to try them out. Turning it off keeps the version you have until a newer regular release comes out.")
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

        /// An example address for the server field, in this service's name.
        var examplePrompt: String {
            switch self {
            case .listenBrainz, .other: "https://scrobbles.example.com"
            case .maloja: "https://maloja.example.com"
            case .koito: "https://koito.example.com"
            case .multiScrobbler: "https://multi-scrobbler.example.com"
            }
        }

        /// What the service itself calls the secret: Maloja's and Koito's pages say "API key".
        var tokenLabel: String {
            switch self {
            case .listenBrainz: "User token"
            case .maloja, .koito: "API key"
            case .multiScrobbler: "Token"
            case .other: "Token or API key"
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
                    TextField("Server address", text: $serverURL, prompt: Text(preset.examplePrompt))
                }
                SecureField(preset.tokenLabel, text: $token)
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

/// Streaming: share this Mac's input, or listen to another ThUNER's, with a choice of playout method.
private struct StreamingSettings: View {
    @Bindable var model: AppModel
    @State private var passwordDraft = ""
    @FocusState private var editingPassword: Bool

    var body: some View {
        Form {
            if !model.streamSource.isEmpty {
                Section("Stream") {
                    StreamMeter(model: model, compact: true)
                    LabeledContent("Latency, totals and earlier sessions") {
                        Button("Open Stream Window") { AppWindows.shared.show(.stream) }
                    }
                }
            }

            Section {
                // Saved on Return or leaving the field, not per keystroke (each change re-derives the key and
                // restarts the stream).
                SecureField("Stream password", text: $passwordDraft, prompt: Text("None"))
                    .onSubmit { model.streamPassword = passwordDraft }
                    .focused($editingPassword)
                    .onChange(of: editingPassword) { _, editing in if !editing { model.streamPassword = passwordDraft } }
                    // And a second after typing stops (each save re-derives the key and restarts the stream).
                    .task(id: passwordDraft) {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled, passwordDraft != model.streamPassword { model.streamPassword = passwordDraft }
                    }
                    .onAppear { passwordDraft = model.streamPassword }
            } header: {
                Text("Password")
            } footer: {
                Text("Optional. With one set, only Macs with the same password can listen to this one or be listened to, and the audio is encrypted on the network. Set the same on both Macs; on a Mac without a screen, `defaults write com.idallas.thuner streamPassword …` (ThUNER moves it into the Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Share this Mac's input with other ThUNERs", isOn: $model.streamSharing)
                if model.streamSharing {
                    LabeledContent("Listening now", value: model.streamListeners.isEmpty ? "Nobody" : model.streamListeners.joined(separator: ", "))
                }
            } header: {
                Text("Share")
            } footer: {
                Text("Sends the input ThUNER is listening to (\(model.selectedDevice?.name ?? "the default input")) as uncompressed audio, only to ThUNERs on your network that ask for it. Stops while listening is paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Listen to", selection: $model.streamSource) {
                    Text("Off").tag("")
                    ForEach(model.otherThuners, id: \.self) { Text(AppModel.shown($0)).tag($0) }
                    if !model.streamSource.isEmpty, model.streamSource != AppModel.streamThisMac,
                       !model.otherThuners.contains(model.streamSource) {
                        Text("\(AppModel.shown(model.streamSource)) (not found)").tag(model.streamSource)
                    }
                    Divider()
                    Text("This Mac (test)").tag(AppModel.streamThisMac)
                }
                Picker("Method", selection: $model.streamMethod) {
                    ForEach(StreamMethod.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Picker(model.streamMethod == .raw ? "Safety margin" : "Minimum buffer", selection: $model.streamMarginMs) {
                    ForEach([0.5, 1, 2, 3, 5, 10, 20], id: \.self) { ms in
                        Text(ms < 1 ? "0.5 ms" : "\(Int(ms)) ms").tag(ms)
                    }
                }
                Picker("Output", selection: $model.streamOutputUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.outputDevices) { Text($0.name).tag(Optional($0.uid)) }
                }
                if let device = model.selectedStreamOutput, device.inputChannels > 2 {
                    Picker("Channels", selection: $model.streamOutputChannel) {
                        ForEach(device.channelPairs, id: \.first) { pair in
                            Text(pair.label).tag(pair.first)
                        }
                    }
                }
            } header: {
                Text("Listen")
            } footer: {
                Text(methodHelp).font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear { model.refreshOutputDevices() }
        .onDisappear { model.streamPassword = passwordDraft }
    }

    private var methodHelp: String {
        switch model.streamMethod {
        case .raw:
            "Raw plays packets as they arrive, with just the safety margin on top of the output buffer. Lowest latency, but every late or lost packet is a dropout: use it when both Macs are on Ethernet."
        case .resilient:
            "Resilient puts packets back in order, asks again for lost ones, grows the buffer to cover the network's measured jitter (and room for resends after a loss; it shrinks again when things calm down), follows the other Mac's clock smoothly, and fades over audio that still doesn't arrive. A few ms on Ethernet, more on Wi-Fi."
        }
    }
}

/// Settings → Listening → Show and Name Inputs…: which inputs the menu offers, and names for them.
private struct InputsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                    Text("Shown in the menu")
                } footer: {
                    Text("Hide inputs you'd never listen to, like the ones Zoom, Teams or Steam add.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InputNameSection(model: model)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
    }
}

/// Names for inputs ("Turntable" for an interface's 3–4): one for the input selected now, and the ones given before.
private struct InputNameSection: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        Section {
            if let device = model.selectedDevice {
                TextField(device.inputChannels > 2 ? "Name for \(device.name) \(channels(device))" : "Name for \(device.name)",
                          text: $draft, prompt: Text("None"))
                    .focused($editing)
                    .onSubmit(save)
                    .onChange(of: editing) { _, now in if !now { save() } }
                    .task(id: draft) {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { save() }
                    }
                    .onAppear { draft = model.selectedInputName ?? "" }
                    .onChange(of: model.inputDeviceUID) { draft = model.selectedInputName ?? "" }
                    .onChange(of: model.firstChannel) { draft = model.selectedInputName ?? "" }
            } else {
                Text("Choose an input in the menu to name it (System default and System Audio can't be named).")
                    .foregroundStyle(.secondary)
            }
            ForEach(named, id: \.key) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Text(entry.input).foregroundStyle(.secondary)
                    Button {
                        model.inputNames[entry.key] = nil
                        if entry.key == currentKey { draft = "" }
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Forget this name")
                }
            }
        } header: {
            Text("Input names")
        } footer: {
            Text("A name for the input (or channel pair) in use, like \"Turntable\" for an interface's 3–4. Shown in the menu, and to Macs listening to this one's stream.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var currentKey: String? {
        model.selectedDevice.map { "\($0.uid)#\($0.inputChannels <= 2 ? 0 : model.firstChannel)" }
    }

    private func channels(_ device: AudioInputDevice) -> String {
        let first = model.firstChannel
        return first + 1 < device.inputChannels ? "\(first + 1)–\(first + 2)" : "\(first + 1)"
    }

    private func save() {
        guard let device = model.selectedDevice else { return }
        guard draft != (model.selectedInputName ?? "") else { return }
        model.setInputName(draft, for: device, first: model.firstChannel)
    }

    /// Every name given, with the input it's for ("M4 3–4"), or the device's ID if it isn't connected.
    private var named: [(key: String, name: String, input: String)] {
        model.inputNames.sorted { $0.value < $1.value }.map { key, name in
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let uid = String(parts.first ?? "")
            let first = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            guard let device = model.devices.first(where: { $0.uid == uid }) else { return (key, name, "not connected") }
            let channels = device.inputChannels <= 2 ? "" : (first + 1 < device.inputChannels ? " \(first + 1)–\(first + 2)" : " \(first + 1)")
            return (key, name, device.name + channels)
        }
    }
}
