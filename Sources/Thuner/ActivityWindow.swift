import AppKit
import SwiftUI
import ThunerCore

/// The Activity window: what ThUNER is doing right now, and everything it has said and done, on this Mac or on
/// another ThUNER on the network. Opened from the panel's Activity header, the ⋯ menu, or a Mac picked at the top.
struct ActivityWindowView: View {
    @Bindable var model: AppModel
    /// "" for this Mac, else another ThUNER's name (from `otherThuners`).
    @State private var mac = ""
    @AppStorage("activityLevel") private var level = ActivityLog.Level.activity
    @State private var category: String?
    @State private var search = ""
    @State private var remote = RemoteActivity()
    @State private var stripHeight: CGFloat = 70
    @State private var tokenDraft = ""
    @State private var copied = false

    private var feed: ActivityFeed { ActivityFeed.shared }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if mac.isEmpty {
                // Its numbers change every second (the countdown) and ten times a second (the meter): a hosting
                // view of its own, so the list isn't laid out again each time.
                IsolatedView(content: ActivityStrip(model: model), height: $stripHeight)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            } else {
                remoteStrip.padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            ActivityList(entries: shownEntries, filter: filter)
        }
        .frame(minWidth: 560, minHeight: 360)
        .task(id: mac) {
            guard !mac.isEmpty else { return }
            await remote.follow(host: mac, address: model.addressOfThuner(mac))
        }
        .onChange(of: model.otherThuners) {
            if !mac.isEmpty, !model.otherThuners.contains(mac) { mac = "" }
        }
        .sheet(isPresented: Binding(get: { remote.needsToken && !mac.isEmpty }, set: { if !$0 { mac = "" } })) {
            tokenSheet
        }
    }

    private var filter: ActivityLog.Filter { .init(level: level, category: category, search: search) }

    private var shownEntries: [ActivityLog.Entry] { mac.isEmpty ? feed.entries : remote.entries }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Mac", selection: $mac) {
                Text("This Mac").tag("")
                ForEach(model.otherThuners, id: \.self) { host in
                    Text(AppModel.shown(host)).tag(host)
                }
            }
            .fixedSize()
            .help("Whose activity to show: this Mac's, or another ThUNER's over its API")
            Picker("Level", selection: $level) {
                Text("Activity").tag(ActivityLog.Level.activity)
                Text("Everything").tag(ActivityLog.Level.detail)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Activity: what the panel says, plus errors. Everything: every line ThUNER logs")
            Picker("Category", selection: $category) {
                Text("All").tag(String?.none)
                ForEach(categories, id: \.self) { id in
                    Text(ActivityLog.name(ofCategory: id)).tag(Optional(id))
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 240)
            Spacer()
            Button(copied ? "Copied" : "Copy") { copy() }
                .help("Copy the lines shown, for a bug report")
        }
        .controlSize(.small)
    }

    /// The categories with something to show, in the window's order, so the picker only offers real choices.
    private var categories: [String] {
        let present = Set(shownEntries.map(\.category))
        let known = ActivityLog.categoryNames.map(\.id).filter(present.contains)
        return known + present.subtracting(known).sorted()
    }

    private func copy() {
        let lines = shownEntries.filter(filter.matches)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ActivityLog.text(lines), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    // MARK: Another Mac

    private var remoteStrip: some View {
        HStack(spacing: 8) {
            if let problem = remote.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Try Again") { Task { await remote.follow(host: mac, address: model.addressOfThuner(mac)) } }
                    .controlSize(.small)
                Button("Change Token…") { remote.forgetToken(for: mac) }.controlSize(.small)
            } else if remote.connected {
                Label("\(AppModel.shown(mac))'s activity, live, from \(remote.address)", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change Token…") { remote.forgetToken(for: mac) }.controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Connecting to \(AppModel.shown(mac))…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
    }

    private var tokenSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(AppModel.shown(mac))'s Control API token").font(.headline)
            Text("Its activity log names tracks, accounts and addresses, so ThUNER only hands it over with the token from that Mac's Settings → Controls → Control API. It's kept in this Mac's Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // The token also controls that Mac, and it goes to whatever address Bonjour gave for the name, over
            // plain HTTP on the LAN: say which, so a wrong one can be spotted.
            Text("It will be sent to \(AppModel.shown(mac)) at \(model.addressOfThuner(mac) ?? "an address not found yet") over the local network.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Token", text: $tokenDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { useToken() }
            if let problem = remote.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { mac = "" }.keyboardShortcut(.cancelAction)
                Button("Connect") { useToken() }.keyboardShortcut(.defaultAction).disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func useToken() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        tokenDraft = ""
        remote.setToken(token, for: mac)
        Task { await remote.follow(host: mac, address: model.addressOfThuner(mac)) }
    }
}

// MARK: - The log

/// The lines, oldest first, following the newest until scrolled away. A hosting view of its own would not help
/// here: the list is what changes.
private struct ActivityList: View {
    let entries: [ActivityLog.Entry]
    let filter: ActivityLog.Filter

    var body: some View {
        let shown = entries.filter(filter.matches)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if shown.isEmpty {
                        Text(entries.isEmpty ? "Nothing yet." : "Nothing matches.")
                            .foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        if index == 0 || !Calendar.current.isDate(entry.date, inSameDayAs: shown[index - 1].date) {
                            Text(entry.date, format: .dateTime.weekday(.wide).month().day().year())
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 10).padding(.bottom, 2)
                        }
                        row(entry)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } label: {
                    Label("Newest", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
                .padding(10)
                .help("Jump to the newest line (the list follows it until you scroll up)")
            }
        }
    }

    private func row(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary).monospacedDigit().frame(width: 64, alignment: .leading)
            Text(ActivityLog.name(ofCategory: entry.category))
                .foregroundStyle(.secondary).frame(width: 84, alignment: .leading).lineLimit(1)
            Text(entry.message)
                .foregroundStyle(entry.isError ? .red : entry.level == .activity ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
    }
}

// MARK: - What's happening now

/// The strip at the top: state, input and meter, what ThUNER is waiting for, whom it defers to.
private struct ActivityStrip: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(stateLabel).fontWeight(.semibold)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(stateColor.opacity(0.14), in: Capsule())
                if let track = model.shownTrack {
                    Text(track.displayName).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(inputLabel).foregroundStyle(.secondary).lineLimit(1)
                LiveLevelMeter(model: model).frame(width: 140)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(waiting).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 12))
    }

    private var stateLabel: String {
        if model.peerHasControl, let host = model.remote?.host { return "Playing on \(AppModel.shown(host))" }
        if let player = model.activePlayer, player.isPlaying { return "Following \(player.name)" }
        switch model.machine.state {
        case .idle: return model.micOffReason == nil ? "Idle" : "Mic off"
        case .identifying: return "Identifying"
        case .playing: return "Playing"
        }
    }

    private var stateColor: Color {
        if model.peerHasControl || (model.activePlayer?.isPlaying ?? false) { return .blue }
        switch model.machine.state {
        case .idle: return .secondary
        case .identifying: return .orange
        case .playing: return .green
        }
    }

    private var inputLabel: String {
        guard let device = model.selectedDevice else { return "System default input" }
        if device.uid == SystemAudioTap.uid { return model.systemAudioLabel }
        let label = model.deviceLabel(device)
        guard device.inputChannels > 2, let pair = device.channelPairs.first(where: { $0.first == model.firstChannel }) else { return label }
        return "\(label) \(model.pairLabel(device, pair))"
    }

    /// What it's waiting for, in one line.
    private var waiting: String {
        var parts: [String] = []
        if let reason = model.micOffReason {
            switch reason {
            case .disabled: parts.append("Mic listening is off in Settings")
            case .player(let name): parts.append("Mic off while \(name) tells ThUNER what's playing")
            case .paused: parts.append("Mic muted")
            case .autoPaused(let minutes): parts.append("Paused after \(minutes) minutes without music")
            case .peer(let host): parts.append("\(AppModel.shown(host)) is playing; standing by")
            case .afterPlayer(let name): parts.append("\(name) stopped; the mic stays off until you turn it on")
            }
        } else if let candidate = model.machine.candidate {
            parts.append("Heard \(candidate.displayName), confirming")
        } else if model.machine.state != .idle, let next = model.machine.nextQueryAt {
            let seconds = max(Int(next.timeIntervalSinceNow.rounded()), 0)
            let when = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) m \(seconds % 60) s"
            if model.machine.state == .playing {
                parts.append("Next check in \(when)")
            } else {
                let misses = model.machine.identifyMisses
                parts.append("Next try in \(when)" + (misses > 0 ? " (\(misses) \(misses == 1 ? "miss" : "misses") in a row)" : ""))
            }
        } else if model.machine.state == .idle {
            parts.append(model.gateOpen ? "Hearing something" : "Quiet: below the silence level")
        }
        if let target = model.deferral.target {
            parts.append("Deferring to \(AppModel.shown(target))\(model.deferral.viaStream ? " (playing its stream)" : "")")
        }
        if !model.streamSource.isEmpty {
            parts.append("Listening to \(model.streamSource == AppModel.streamThisMac ? "this Mac" : AppModel.shown(model.streamSource))'s stream")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Another Mac's log

/// Another ThUNER's activity log over its HTTP API: the recent lines, then new ones as they happen (its event
/// stream with `?activity=1`). Needs that Mac's Control API token, kept in the Keychain per Mac.
@MainActor @Observable
final class RemoteActivity {
    private(set) var entries: [ActivityLog.Entry] = []
    private(set) var connected = false
    private(set) var problem: String?
    private(set) var needsToken = false
    /// Where the log is being fetched from, shown so a wrong address can be spotted.
    private(set) var address = ""
    private var host = ""

    private static func account(_ host: String) -> String { "activity-token-\(host.lowercased())" }

    func setToken(_ token: String, for host: String) {
        Keychain.write(token, account: Self.account(host))
        needsToken = false
        problem = nil
    }

    func forgetToken(for host: String) {
        Keychain.delete(account: Self.account(host))
        problem = nil
        needsToken = true
    }

    /// Follows `host`'s log until the task is cancelled (the window closes or another Mac is picked).
    func follow(host: String, address: String?) async {
        self.host = host
        entries = []
        connected = false
        problem = nil
        guard let token = Keychain.read(String.self, account: Self.account(host)) else {
            needsToken = true
            return
        }
        guard let address else {
            problem = "\(AppModel.shown(host)) hasn't been found on the network yet."
            return
        }
        self.address = address
        let base = "http://\(address):\(WebDisplayServer.defaultPort)"
        while !Task.isCancelled {
            do {
                try await load(base: base, token: token)
                connected = true
                try await stream(base: base, token: token)
                connected = false
                problem = "Lost \(AppModel.shown(host))'s event stream; trying again."
            } catch is CancellationError {
                return
            } catch RemoteError.unauthorized {
                connected = false
                problem = "\(AppModel.shown(host)) didn't accept the token."
                needsToken = true
                return
            } catch {
                connected = false
                problem = Self.describe(error, host: host)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private enum RemoteError: Error { case unauthorized, http(Int) }

    /// The other Mac's lines are its own to make up: keep each to a sane length.
    private static func bounded(_ entry: ActivityLog.Entry) -> ActivityLog.Entry {
        guard entry.message.count > 2000 || entry.category.count > 40 else { return entry }
        var cut = entry
        cut.message = String(entry.message.prefix(2000)) + "…"
        cut.category = String(entry.category.prefix(40))
        return cut
    }

    private static func describe(_ error: Error, host: String) -> String {
        if case RemoteError.http(let code) = error { return "\(AppModel.shown(host)) answered HTTP \(code)." }
        let text = error.localizedDescription
        return "Couldn't reach \(AppModel.shown(host))'s API: \(text). Its web display and API may be set to \"This Mac only\"."
    }

    private func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func load(base: String, token: String) async throws {
        let url = URL(string: "\(base)/api/activity?level=everything&limit=5000")!
        let (data, response) = try await URLSession.shared.data(for: request(url, token: token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw RemoteError.unauthorized }
        guard status == 200 else { throw RemoteError.http(status) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = json?["entries"] as? [[String: Any]] ?? []
        entries = items.prefix(5000).compactMap(WebDisplayServer.entry(from:)).map(Self.bounded)
    }

    private func stream(base: String, token: String) async throws {
        let url = URL(string: "\(base)/api/events?activity=1")!
        var request = request(url, token: token)
        request.timeoutInterval = 3600 * 24
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw RemoteError.unauthorized }
        guard status == 200 else { throw RemoteError.http(status) }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any]
            guard json?["type"] as? String == "activity", let item = json?["entry"] as? [String: Any],
                  let entry = WebDisplayServer.entry(from: item) else { continue }
            if let last = entries.last, entry.id <= last.id { continue }
            entries.append(Self.bounded(entry))
            if entries.count > 20_000 { entries.removeFirst(entries.count - 20_000) }
        }
    }
}
