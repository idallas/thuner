import AVFoundation
import SwiftUI
import ThunerCore

/// The first-launch tour. Each permission is asked for at the step that needs it, with a line on why, instead
/// of macOS prompts arriving out of nowhere at launch.
struct OnboardingView: View {
    @Bindable var model: AppModel
    /// Point at the menu bar icon (it pulses).
    var showIcon: () -> Void = {}
    /// Close the tour and open the panel.
    var finish: () -> Void = {}

    enum Step: Int, CaseIterable {
        case welcome, listening, display, scrobbling, done
    }

    @State private var step = Step.welcome
    @State private var launchAtLogin = true
    @State private var searchedNetwork = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .listening: listening
                case .display: display
                case .scrobbling: scrobbling
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Wordmark().font(.system(size: 34))
            Text("Knows what's playing, from the turntable or anywhere else, and puts the cover on your Tuneshine.")
                .font(.title3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("It listens to an input with Shazam, or reads Apple Music and Spotify directly, then shows the cover and scrobbles the play.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("ThUNER lives in your menu bar:")
                Image(nsImage: MenuBarIcon.image(.playing))
                Button("Show Me") { showIcon() }.controlSize(.small)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Listening", "ThUNER identifies music by listening to a microphone or an input like a turntable's line-in.")
            if !model.micEnabled {
                Label("No microphone: ThUNER will follow Apple Music and Spotify only", systemImage: "mic.slash")
                Button("Use a Microphone After All") { model.micEnabled = true }
            } else if model.micAuthorized {
                Label("Microphone access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Picker("Input", selection: $model.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.devices) { Text($0.name).tag(Optional($0.uid)) }
                }
                LiveLevelMeter(model: model).frame(maxWidth: .infinity)
                HStack {
                    Text("Silence below")
                    Slider(value: $model.thresholdDB, in: -80...(-10), step: 1)
                    Text("\(Int(model.thresholdDB)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                Text("With the music off, set the red line just above the bar, so surface noise or the room doesn't count as music.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.micDenied {
                Label("Microphone access is off", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Turn on ThUNER in System Settings → Privacy & Security → Microphone, then come back.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_Microphone") }
            } else {
                Text("macOS will ask to let ThUNER use the microphone. It only listens to work out what's playing; audio goes to Shazam as an anonymous fingerprint and isn't recorded.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow Microphone") { model.startListening() }.controlSize(.large).buttonStyle(.borderedProminent)
                    Button("No Microphone, Just Apple Music and Spotify") { model.micEnabled = false }.controlSize(.large)
                }
            }
            Divider().padding(.vertical, 4)
            Toggle("Use Apple Music when it's playing", isOn: $model.useAppleMusic)
            Toggle("Use Spotify when it's playing", isOn: $model.useSpotify)
            Text("While one of those apps plays on this Mac, ThUNER reads the track from it and turns the mic off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Tuneshine and other Macs", "ThUNER finds your Tuneshine, and any other Mac running ThUNER, on your network.")
            if !searchedNetwork {
                Text("macOS will ask to let ThUNER find devices on your local network.")
                    .foregroundStyle(.secondary)
                Button("Find My Tuneshine") {
                    searchedNetwork = true
                    model.startNetwork()
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
            } else {
                if let device = model.discoveredTuneshines.first {
                    Label("Found \(device.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.tuneshineHealth == .localNetworkDenied {
                    Label("Local network access is off", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_LocalNetwork") }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Looking for a Tuneshine…") }
                    Text("No Tuneshine? That's fine: the menu, a floating cover and the web display work without one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.otherThuners.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Also found ThUNER on \(model.otherThuners.joined(separator: ", ")).")
                    Picker("This Mac", selection: $model.role) {
                        Text("Is the turntable Mac (has priority)").tag(PushArbiter.Role.primary)
                        Text("Is another Mac (stands by while the turntable plays)").tag(PushArbiter.Role.secondary)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            Divider().padding(.vertical, 4)
            Toggle("Floating cover window", isOn: $model.showFloatingCover)
            Toggle("Web display for other screens (\(model.webDisplayURL.host() ?? "this Mac"):\(String(WebDisplayServer.defaultPort)))",
                   isOn: $model.webDisplayEnabled)
        }
    }

    private var scrobbling: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Scrobbling", "Optional: keep a record of what you play on Last.fm.")
            if let user = model.lastFMUser {
                Label("Connected to Last.fm as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Toggle("Scrobble from this Mac", isOn: $model.scrobblingEnabled)
            } else if model.lastFMAwaitingApproval {
                Text("Approve ThUNER on the Last.fm page that opened in your browser, then come back.")
                HStack {
                    Button("I've Approved It") {
                        model.finishLastFMConnect()
                        model.scrobblingEnabled = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Again") { model.beginLastFMConnect() }
                }
            } else if !model.lastFMHasCredentials {
                Text("This copy of ThUNER has no Last.fm API key built in. You can add your own in Settings → Scrobbling.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Connect Last.fm") { model.beginLastFMConnect() }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            }
            if let error = model.lastFMError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("ListenBrainz, Maloja, Koito and other self-hosted services can be added later in Settings → Scrobbling. Radio mode, in the menu, keeps showing covers without scrobbling.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("All set", "ThUNER is listening. Click its menu bar icon any time to see what's playing.")
            Toggle("Open ThUNER when you log in", isOn: $launchAtLogin)
            Toggle("Install updates automatically", isOn: Bindable(model.updater).automaticallyInstalls)
            Text("Updates install quietly the next time nothing's playing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Everything here can be changed later in Settings, and this tour is in the ⋯ menu.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    // MARK: Pieces

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { go(Step(rawValue: step.rawValue - 1)!) }
            }
            if step == .done {
                Button("Start Listening") {
                    model.launchAtLogin = launchAtLogin
                    model.finishOnboarding()
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(Step(rawValue: step.rawValue + 1)!) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func go(_ next: Step) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}
