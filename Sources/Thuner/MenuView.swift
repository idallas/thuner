import SwiftUI
import ThunerCore

struct MenuView: View {
    @Bindable var model: AppModel
    let actions: PanelActions
    @AppStorage("menuActivityExpanded") private var activityExpanded = true

    private var pinned: Bool { model.panelPinned }
    private var isPaused: Bool { model.pausedManually || model.autoPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nowPlaying
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
            if model.radioMode {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Radio mode: listening and showing covers, not scrobbling")
            }
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
                .init(title: isPaused ? "Resume Listening" : "Pause Listening",
                      symbol: isPaused ? "play.circle" : "pause.circle") { model.togglePause() },
                .init(title: "Identify Now", symbol: "waveform",
                      isEnabled: model.machine.state != .idle && model.activePlayer == nil) { model.identifyNow() },
                .init(title: "Clear Tuneshine", symbol: "xmark.square") { model.clearDisplay() },
                .separator,
                .init(title: "Floating Cover", isOn: model.showFloatingCover) { model.showFloatingCover.toggle() },
                .init(title: "Open Web Display", symbol: "safari", isEnabled: model.webDisplayEnabled) { model.openWebDisplay() },
                .init(title: "Radio Mode (Don't Scrobble)", isOn: model.radioMode) { model.radioMode.toggle() },
                .separator,
                .init(title: "History…") { open(.history) },
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
            .frame(width: 92, height: 92)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                if let track = model.shownTrack {
                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if let album = track.album {
                        Text(album).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if model.peerHasControl, let host = model.remote?.host {
                        Label("Playing on \(host)", systemImage: "opticaldisc")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                    } else if let entry = currentEntry {
                        playMeta(entry).padding(.top, 4)
                    }
                } else {
                    if model.peerHasControl, let host = model.remote?.host {
                        Text("Identifying…").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        Text("\(host) hears music").font(.system(size: 12)).foregroundStyle(.tertiary)
                    } else {
                        Text("Nothing playing").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        Text(model.pausedManually ? "Listening is paused" : "Listening for music")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)  // static: let drags through to the panel's drag handle
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
            if model.radioMode, entry.scrobble == .notSent {
                Text("·")
                Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                    .help("Radio mode: not scrobbling")
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
                Image(systemName: model.micOffReason == nil ? "mic" : "mic.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Picker("Input", selection: $model.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.menuDevices) { device in
                        Text(device.uid == SystemAudioTap.uid ? model.systemAudioLabel : device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(model.micOffReason != nil && model.activePlayer == nil)
                if let device = model.selectedDevice, device.inputChannels > 2 {
                    Picker("Channels", selection: $model.firstChannel) {
                        ForEach(Array(stride(from: 0, to: device.inputChannels, by: 2)), id: \.self) { first in
                            Text(first + 1 < device.inputChannels ? "Ch \(first + 1)–\(first + 2)" : "Ch \(first + 1)").tag(first)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                if model.micEnabled {
                Button { model.togglePause() } label: {
                    Image(systemName: isPaused ? "play.circle.fill" : "pause.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isPaused ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(isPaused ? "Resume listening" : "Pause listening")
                }
            }

            if let reason = model.micOffReason {
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
        }
    }

    @ViewBuilder
    private func micOff(_ reason: AppModel.MicOffReason) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch reason {
            case .disabled:
                Text("Microphone listening is off. ThUNER follows Apple Music and Spotify.")
            case .player(let name):
                Text("Mic is off while \(name) tells ThUNER what's playing.")
            case .paused:
                Text("Listening is paused.")
                Spacer()
                Button("Resume") { model.togglePause() }.controlSize(.small)
            case .autoPaused(let minutes):
                Text("Paused after \(minutes) minutes without music. Playing something wakes it.")
                Spacer()
                Button("Resume") { model.togglePause() }.controlSize(.small)
            case .peer(let host):
                Text("\(host) is playing, so this Mac is standing by.")
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
        if model.role == .secondary, !model.arbiterAllowsPush {
            Label("Deferring to \(model.lastPrimaryPeer ?? "the turntable Mac")", systemImage: "hand.raised")
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
        HStack {
            Button { open(.history) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

    private func open(_ kind: AppWindows.Kind) {
        actions.show(kind)
    }

    // MARK: State

    private var stateLabel: String {
        if model.peerHasControl { return model.remote?.track == nil ? "Identifying" : "Playing" }
        if model.pausedManually || model.autoPaused { return "Paused" }
        if model.activePlayer != nil { return "Playing" }
        return switch model.machine.state {
        case .idle: "Idle"
        case .identifying: "Identifying"
        case .playing: "Playing"
        }
    }

    private var stateDetail: String? {
        if model.peerHasControl { return model.remote?.host }
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
    private let orange = Color(red: 1.0, green: 0.50, blue: 0.13)

    var body: some View {
        (Text("T").fontWeight(.heavy).foregroundStyle(orange)
            + Text("h").fontWeight(.regular).foregroundStyle(.secondary)
            + Text("UNER").fontWeight(.heavy).foregroundStyle(orange))
            .tracking(1.5)
            .accessibilityLabel("ThUNER")
    }
}

