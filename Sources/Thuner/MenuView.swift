import SwiftUI
import ThunerCore

struct MenuView: View {
    @State private var hoveringCover = false
    @Bindable var model: AppModel
    let actions: PanelActions
    @AppStorage("menuActivityExpanded") private var activityExpanded = true

    private var pinned: Bool { model.panelPinned }
    private var isPaused: Bool { model.pausedManually || model.autoPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nowPlaying
            QuickToggles(model: model)
            listening
            alerts
            activity
            footer
        }
        .padding(16)
        .frame(width: 330)
        .background {
            // Drag the panel from anywhere that isn't a control (static content ignores clicks so they land
            // here). Pulling it away from the menu bar pins it where it's let go.
            WindowDragHandle { actions.draggedTo() }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        // Covers crossfade when the track changes.
        .animation(.easeInOut(duration: 0.35), value: model.shownTrack?.artworkURL)
        // Size to the content, so the panel shrinks when Activity collapses instead of stretching the card.
        .fixedSize(horizontal: false, vertical: true)
        // The panel opens with keyboard focus on its first control, which drew a blue ring around the ⋯ menu.
        .focusEffectDisabled()
        .onAppear { model.refreshDevices() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Wordmark().font(.system(size: 14)).allowsHitTesting(false)
            Spacer()
            StatusPill(label: stateLabel, detail: stateDetail, color: stateColor).allowsHitTesting(false)
            Button {
                actions.togglePin()
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .rotationEffect(.degrees(pinned ? 0 : 45))
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(pinned ? "Unpin: go back to the menu bar" : "Pin open (or drag the panel away from the menu bar)")
            MoreMenuButton(items: [
                .init(title: "About ThUNER") { open(.about) },
                .init(title: "Welcome Tour…") { open(.welcome) },
                .separator,
                .init(title: isPaused ? "Unmute Mic" : "Mute Mic",
                      symbol: isPaused ? "mic" : "mic.slash") { model.togglePause() },
                .init(title: "Identify Now", symbol: "waveform",
                      isEnabled: model.machine.state != .idle && model.activePlayer == nil) { model.identifyNow() },
                .init(title: "Clear Tuneshine", symbol: "xmark.square") { model.clearDisplay() },
                .separator,
                .init(title: "Floating Cover", isOn: model.showFloatingCover) { model.showFloatingCover.toggle() },
                .init(title: "Open Web Display", symbol: "safari", isEnabled: model.webDisplayEnabled) { model.openWebDisplay() },
                .init(title: "Scrobble", isOn: model.canScrobble && !model.radioMode, isEnabled: model.canScrobble) {
                    model.radioMode.toggle()
                },
                .separator,
                .init(title: "History…") { open(.history) },
                .init(title: "Stream…") { open(.stream) },
                .init(title: "Settings…") { open(.settings) },
                .init(title: "Check for Updates…") { model.updater.checkForUpdates() },
                .separator,
                .init(title: "Quit ThUNER") { NSApplication.shared.terminate(nil) },
            ])
            .frame(width: 22, height: 22)
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: model.shownTrack?.artworkURL.map(FloatingCoverView.secure)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "opticaldisc").font(.system(size: 34)).foregroundStyle(.tertiary)
            }
            // A new image view for each cover: when a track had none, the old view kept showing the last track's.
            .id(model.shownTrack?.artworkURL)
            .frame(width: 92, height: 92)
            .background(.quaternary)
            .overlay {
                // Playback controls on hover, for Apple Music and Spotify.
                if hoveringCover, model.controllablePlayer != nil {
                    ZStack {
                        Color.black.opacity(0.25)
                        PlaybackButtons(model: model, size: 11)
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .onHover { inside in withAnimation(.easeInOut(duration: 0.15)) { hoveringCover = inside } }
            .allowsHitTesting(model.controllablePlayer != nil)

            VStack(alignment: .leading, spacing: 3) {
                if let track = model.shownTrack {
                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if let album = track.album {
                        Text(album).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if model.peerHasControl, let host = model.remote?.host {
                        Label("Playing on \(AppModel.shown(host))", systemImage: "opticaldisc")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                    } else if let entry = currentEntry {
                        playMeta(entry).padding(.top, 4)
                    }
                } else {
                    if model.peerHasControl, let host = model.remote?.host {
                        Text("Identifying…").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        Text("\(AppModel.shown(host)) hears music").font(.system(size: 12)).foregroundStyle(.tertiary)
                    } else {
                        Text("Nothing playing").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        Text(model.pausedManually ? "Mic muted" : "Listening for music")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .allowsHitTesting(false)
        }
        .padding(10)
        // Static, so drags go through to the panel's drag handle; only the cover takes clicks, and only while it
        // has playback controls to show.
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)).allowsHitTesting(false) }
    }

    /// The history entry for what's on screen, for its source and scrobble status.
    private var currentEntry: PlayHistory.Entry? {
        guard let shown = model.machine.displayed, let last = model.history.entries.last,
              last.track.isSameSong(as: shown) else { return nil }
        return last
    }

    private func playMeta(_ entry: PlayHistory.Entry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: HistoryView.symbol(for: entry.source))
            Text(entry.startedAt, format: .dateTime.hour().minute())
            if model.canScrobble, model.radioMode, entry.scrobble == .notSent {
                Text("·")
                Text("Not scrobbling")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Wordmark.deepOrange)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Wordmark.orange.opacity(0.16)))
                    .help("Scrobbling is off for now (the Scrobble button below turns it back on)")
            }
            switch entry.scrobble {
            case .scrobbled:
                Text("·")
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Scrobbled")
            case .queued:
                Text("·")
                Text("Scrobble queued").foregroundStyle(.orange)
            case .skippedDuplicate(let reason):
                Text("·")
                Text("Duplicate").foregroundStyle(.orange).help(reason)
            case .notSent:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Listening

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The mic icon is the mute button: crossed out (orange) while muted, plain mic while listening.
                if model.micEnabled {
                    Button { model.togglePause() } label: {
                        // Crossed out only when you muted it; off for another reason (a player or the turntable
                        // Mac in charge), a dimmed mic: it can still be muted.
                        Image(systemName: isPaused ? "mic.slash.fill" : "mic")
                            .font(.system(size: 13))
                            .foregroundStyle(isPaused ? Wordmark.deepOrange : Color.secondary.opacity(model.micOffReason == nil ? 1 : 0.45))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(isPaused ? "Unmute: listen again" : "Mute: stop listening until you unmute (\(micHelp.lowercased()))")
                } else {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .help(micHelp)
                }
                Picker("Input", selection: $model.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.menuDevices) { device in
                        Text(device.uid == SystemAudioTap.uid ? model.systemAudioLabel : model.deviceLabel(device)).tag(Optional(device.uid))
                    }
                }
                // Borderless: the name in plain text with a small chevron, like the rest of the panel, rather than
                // a boxed pop-up button. Each takes its own width, the device first.
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.micOffReason != nil && model.activePlayer == nil)
                .focusable(false)
                .fixedSize()
                if let device = model.selectedDevice, device.inputChannels > 2 {
                    Picker("Channels", selection: $model.firstChannel) {
                        ForEach(device.channelPairs, id: \.first) { pair in
                            Text(model.pairLabel(device, pair)).tag(pair.first)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .focusable(false)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }

            if let reason = model.micOffReason, !reason.isPlayer {
                micOff(reason)
            } else {
                LiveLevelMeter(model: model)
                HStack(spacing: 8) {
                    Text("Silence").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Slider(value: $model.thresholdDB, in: -80...(-10), step: 1).controlSize(.mini)
                    Text("\(Int(model.thresholdDB)) dB").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                if let notice = model.captureNotice {
                    Label(notice, systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let line = listeningStatus {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            if !model.streamSource.isEmpty {
                Button { open(.stream) } label: {
                    StreamMeter(model: model, compact: true).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    /// The mic icon's tooltip: why it's off, when it is.
    private var micHelp: String {
        switch model.micOffReason {
        case nil: return "Listening with this input"
        case .disabled: return "Listening with a microphone or input is off in Settings → Listening"
        case .player(let name): return "Mic is off while \(name) tells ThUNER what's playing"
        case .paused: return "Mic muted"
        case .autoPaused(let minutes): return "Paused after \(minutes) minutes without music; playing something wakes it"
        case .peer(let host): return "\(AppModel.shown(host)) is playing, so this Mac is standing by"
        }
    }

    private func micOff(_ reason: AppModel.MicOffReason) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch reason {
            case .disabled:
                Text("Mic listening is off (Settings → Listening).")
            case .player:
                EmptyView()
            case .paused:
                Text("Mic muted.")
                Spacer()
                Button("Unmute") { model.togglePause() }.controlSize(.small)
            case .autoPaused(let minutes):
                Text("Paused: no music for \(minutes) minutes.")
                    .help("Playing something wakes it")
                Spacer()
                Button("Resume") { model.togglePause() }.controlSize(.small)
            case .peer(let host):
                Text("\(AppModel.shown(host)) is playing; standing by.")
                Spacer()
                Button("Listen Here") { model.listenHereAnyway() }
                    .controlSize(.small)
                    .help("Listen and update the display from this Mac too, until \(host) goes quiet")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var listeningStatus: String? {
        if let candidate = model.machine.candidate {
            return "Heard \(candidate.displayName), confirming…"
        }
        guard model.machine.state != .idle, let next = model.machine.nextQueryAt else { return nil }
        let seconds = max(Int(next.timeIntervalSinceNow.rounded()), 0)
        let when = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return model.machine.state == .playing ? "Next check in \(when)" : "Identifying, next try in \(when)"
    }

    // MARK: Alerts

    @ViewBuilder
    private var alerts: some View {
        if let problem = model.playbackProblem {
            Label(problem, systemImage: "playpause")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        // (While standing by for the turntable Mac, the line above already says so.)
        if model.role == .secondary, !model.arbiterAllowsPush, !model.peerHasControl {
            Label("Deferring to \(model.lastPrimaryPeer.map(AppModel.shown) ?? "the turntable Mac")", systemImage: "hand.raised")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
        if model.hasPermissionProblem {
            Button { open(.settings) } label: {
                Label("A permission needs attention. Open Settings…", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .foregroundStyle(.red)
        } else if let error = model.captureError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    // MARK: Activity

    private var activity: some View {
        DisclosureGroup(isExpanded: $activityExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.log.prefix(6)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.tertiary).monospacedDigit()
                        Text(entry.text).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10.5))
                }
            }
            .padding(.top, 4)
            .allowsHitTesting(false)
        } label: {
            Text("Activity").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        // Plain grey text and icons, like the rest of the panel, rather than boxed buttons.
        HStack(spacing: 14) {
            Button { open(.history) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .focusable(false)
    }

    private func open(_ kind: AppWindows.Kind) {
        actions.show(kind)
    }

    // MARK: State

    private var stateLabel: String {
        if model.peerHasControl { return model.remote?.track == nil ? "Identifying" : "Playing" }
        if model.pausedManually { return "Muted" }
        if model.autoPaused { return "Paused" }
        if model.activePlayer != nil { return "Playing" }
        return switch model.machine.state {
        case .idle: "Idle"
        case .identifying: "Identifying"
        case .playing: "Playing"
        }
    }

    private var stateDetail: String? {
        if model.peerHasControl { return model.remote.map { AppModel.shown($0.host) } }
        if let player = model.activePlayer { return player.source.rawValue }
        return model.machine.state == .playing ? "Shazam" : nil
    }

    private var stateColor: Color {
        if model.peerHasControl { return model.remote?.track == nil ? .orange : .green }
        if model.pausedManually || model.autoPaused { return .gray }
        if model.activePlayer != nil { return .green }
        return switch model.machine.state {
        case .idle: .gray
        case .identifying: .orange
        case .playing: .green
        }
    }
}

private struct StatusPill: View {
    let label: String
    let detail: String?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).fontWeight(.semibold)
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Reads the level in its own body, so the 10-per-second level updates redraw just the meter, not the panel.
struct LiveLevelMeter: View {
    let model: AppModel

    var body: some View {
        LevelMeter(levelDB: model.levelDB, thresholdDB: model.thresholdDB, open: model.gateOpen)
    }
}

/// Live input level with the silence threshold marked, so it can be set just above vinyl surface noise.
struct LevelMeter: View {
    let levelDB: Double
    let thresholdDB: Double
    let open: Bool

    private let floor = -80.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(open ? Color.green : Color.secondary)
                    .frame(width: w * fraction(levelDB))
                    .animation(.linear(duration: 0.1), value: levelDB)
                Rectangle().fill(.red).frame(width: 2).offset(x: w * fraction(thresholdDB) - 1)
            }
        }
        .frame(height: 6)
        .help("Input \(Int(levelDB)) dBFS")
    }

    private func fraction(_ db: Double) -> Double {
        min(max((db - floor) / -floor, 0), 1)
    }
}

/// "ThUNER": the name comes from the nickname (Bethune) and puns on "tuner", so T·UNER is the bold
/// orange part and the "h" sits quietly in between.
struct Wordmark: View {
    static let orange = Color(red: 1.0, green: 0.50, blue: 0.13)
    /// A deeper orange for icons and small text on a light orange wash (the wordmark's orange there was too faint
    /// to read); lighter in dark mode, for the same contrast on a dark panel.
    static let deepOrange = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.62, blue: 0.32, alpha: 1)
            : NSColor(red: 0.74, green: 0.30, blue: 0.02, alpha: 1)
    })
    private var orange: Color { Self.orange }

    var body: some View {
        (Text("T").fontWeight(.heavy).foregroundStyle(orange)
            + Text("h").fontWeight(.regular).foregroundStyle(.secondary)
            + Text("UNER").fontWeight(.heavy).foregroundStyle(orange))
            .tracking(1.5)
            .accessibilityLabel("ThUNER")
    }
}


/// The switches people reach for most, one click each: scrobbling, the floating cover, listening to another
/// Mac's stream here, sharing this Mac's input. Tinted ThUNER's orange when on.
private struct QuickToggles: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            QuickToggle(title: "Scrobble", symbol: "music.note.list", isOn: model.canScrobble && !model.radioMode,
                        help: model.canScrobble
                            ? (model.radioMode ? "Not scrobbling: click to scrobble again" : "Scrobbling: click to pause it for now")
                            : "Set up scrobbling in Settings → Scrobbling") {
                model.radioMode.toggle()
            }
            .disabled(!model.canScrobble)
            QuickToggle(title: "Cover", symbol: "rectangle.on.rectangle", isOn: model.showFloatingCover,
                        help: model.showFloatingCover ? "Hide the floating cover" : "Show the floating cover") {
                model.showFloatingCover.toggle()
            }
            QuickToggle(title: "Listen", symbol: "headphones", isOn: !model.streamSource.isEmpty,
                        help: listenHelp) {
                model.toggleListening()
            }
            .disabled(model.streamSource.isEmpty && model.listenCandidate == nil)
            QuickToggle(title: "Share", symbol: "dot.radiowaves.left.and.right", isOn: model.streamSharing,
                        help: model.streamSharing ? "Stop sharing this Mac's input" : "Share this Mac's input with other ThUNERs") {
                model.streamSharing.toggle()
            }
        }
    }

    private var listenHelp: String {
        if !model.streamSource.isEmpty { return "Stop listening to \(AppModel.shown(model.streamSource))'s stream" }
        if let next = model.listenCandidate { return "Listen to \(AppModel.shown(next))'s stream here" }
        return "No other ThUNER on this network to listen to"
    }
}

private struct QuickToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // When on: a light orange wash and an orange icon, the label in ordinary text (orange on orange
                // was hard to read), so the row hints rather than outshining the cover.
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(height: 18)
                    .foregroundStyle(isOn ? Wordmark.deepOrange : Color.primary.opacity(isEnabled ? 0.55 : 0.25))
                Text(title).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(isEnabled ? (isOn ? 0.85 : 0.6) : 0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isOn ? Wordmark.orange.opacity(0.16) : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
