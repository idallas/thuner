import AVFoundation
import AppKit
import Foundation
import Observation
import ServiceManagement
import WidgetKit
import Applug
import ThunerCore
import os

/// Ties capture, the level gate, the state machine, matching, peer coordination and the display together.
/// Everything here runs on the main actor; audio arrives from the tap thread and is hopped over.
@MainActor @Observable
final class AppModel {
    /// The app's one model, for Shortcuts actions (which arrive with no other way to reach it).
    static weak var current: AppModel?
    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    // MARK: Settings (persisted to UserDefaults, so `defaults write com.idallas.thuner …` works over SSH)

    var inputDeviceUID: String? {
        didSet {
            save(inputDeviceUID, "inputDeviceUID")
            // A channel pair picked for one interface means nothing on another.
            if firstChannel != 0, oldValue != inputDeviceUID { firstChannel = 0 } else { restartCapture() }
        }
    }
    var firstChannel: Int { didSet { save(firstChannel, "firstChannel"); restartCapture() } }
    var thresholdDB: Double { didSet { save(thresholdDB, "thresholdDB"); gate.thresholdDB = thresholdDB } }
    var role: PushArbiter.Role { didSet { save(role.rawValue, "role"); arbiter.role = role } }
    /// 0 keeps the last cover up indefinitely.
    var idleImageMinutes: Double { didSet { save(idleImageMinutes, "idleImageMinutes"); applyTiming() } }
    /// The Tuneshine to use; empty means automatic (the first one found on the network).
    var tuneshineHost: String {
        didSet {
            save(tuneshineHost, "tuneshineHost")
            Task { await checkTuneshine() }
        }
    }

    /// Tuneshines found on the network over Bonjour.
    private(set) var discoveredTuneshines: [TuneshineBrowser.Device] = []

    /// What ThUNER actually connects to: the chosen address, or the first Tuneshine found.
    var effectiveTuneshineHost: String? {
        tuneshineHost.isEmpty ? discoveredTuneshines.first?.host : tuneshineHost
    }
    /// Off by default: on the main Mac, the mic also hears Spotify/Apple Music that Silicio already scrobbles.
    var scrobblingEnabled: Bool {
        didSet {
            save(scrobblingEnabled, "scrobblingEnabled")
            if scrobblingEnabled { catchUpScrobbling() }
        }
    }
    /// Radio mode: keep listening and showing covers, but don't send anything to scrobbling services.
    var radioMode: Bool {
        didSet {
            guard radioMode != oldValue else { return }
            save(radioMode, "radioMode")
            missedScrobble = nil  // nothing heard in radio mode gets scrobbled after the fact
            note(radioMode ? "Radio mode on: not scrobbling" : "Radio mode off: scrobbling again")
        }
    }
    /// The welcome tour has been done (or skipped). Until then, nothing asks for permissions on its own: the
    /// tour asks for each one at the step that needs it.
    var onboardingComplete: Bool { didSet { save(onboardingComplete, "onboardingComplete") } }
    /// Other ThUNERs found on the network, by host name.
    private(set) var otherThuners: [String] = [] {
        didSet { if streamReceiver == nil, !streamSource.isEmpty { applyStreamReceiver() } }
    }

    // MARK: Streaming (sharing this Mac's input with another ThUNER, or listening to one)

    /// Send this Mac's input to any ThUNER that asks for it.
    var streamSharing: Bool {
        didSet {
            save(streamSharing, "streamSharing")
            streamSender.sharing = streamSharing
            restartCapture()
        }
    }
    /// The ThUNER to listen to, by host name; `AppModel.streamThisMac` for this Mac's own input (a test); empty
    /// for off.
    var streamSource: String { didSet { save(streamSource, "streamSource"); applyStreamReceiver() } }
    var streamMethod: StreamMethod { didSet { save(streamMethod.rawValue, "streamMethod"); applyStreamReceiver() } }
    /// Extra buffer: for raw, the margin beyond one output buffer; for resilient, the least it keeps.
    var streamMarginMs: Double { didSet { save(streamMarginMs, "streamMarginMs"); applyStreamReceiver() } }
    /// Nil for the system's default output.
    var streamOutputUID: String? {
        didSet {
            save(streamOutputUID, "streamOutputUID")
            // A channel pair picked for one interface means nothing on another.
            if streamOutputChannel != 0, oldValue != streamOutputUID { streamOutputChannel = 0 } else { applyStreamReceiver() }
        }
    }
    /// Zero-based first channel of the output pair, for interfaces with more than two outputs.
    var streamOutputChannel: Int { didSet { save(streamOutputChannel, "streamOutputChannel"); applyStreamReceiver() } }
    var selectedStreamOutput: AudioInputDevice? {
        outputDevices.first { $0.uid == streamOutputUID }
    }
    nonisolated static let streamThisMac = "This Mac"
    /// The stream password (both Macs need the same one): seals and encrypts everything between them. Kept in the
    /// Keychain; empty for none.
    var streamPassword: String {
        didSet {
            guard streamPassword != oldValue else { return }
            if streamPassword.isEmpty { Keychain.delete(account: "stream-password") } else { Keychain.write(streamPassword, account: "stream-password") }
            applyStreamPassword()
        }
    }
    @ObservationIgnored private var streamCipher: StreamCipher?
    /// Watches for `defaults write com.idallas.thuner streamPassword …` (a Mac without a screen) while running.
    @ObservationIgnored private var passwordWatcher: NSKeyValueObservation?

    /// A password written to the preferences goes into the Keychain (and out of the readable preferences) and
    /// takes effect at once; an empty one clears it.
    private func adoptTypedPassword() {
        guard let typed = defaults.string(forKey: "streamPassword") else { return }
        defaults.removeObject(forKey: "streamPassword")
        note(typed.isEmpty ? "Stream password cleared" : "Stream password set")
        streamPassword = typed
    }

    private func applyStreamPassword() {
        streamCipher = StreamCipher(password: streamPassword)
        streamSender.cipher = streamCipher
        applyStreamReceiver()
    }
    /// Who's listening to this Mac.
    private(set) var streamListeners: [String] = []
    /// While listening: the playout's numbers, what the other Mac says it's sending, and any problem.
    private(set) var streamStats: PlayoutStats?
    private(set) var streamSenderStatus: StreamWire.Status?
    private(set) var streamProblem: String?
    private(set) var outputDevices: [AudioInputDevice] = []
    @ObservationIgnored private let streamSender = AudioStreamSender()
    @ObservationIgnored private var streamReceiver: AudioStreamReceiver?
    @ObservationIgnored private var lastStreamLog = Date.distantPast

    /// The listening session in progress (totals that survive quiet gaps, a minute-by-minute history), and past
    /// sessions, saved to Application Support/Thuner/stream-log.json.
    private(set) var streamSession: StreamSession?
    private(set) var streamLog = StreamLog()
    @ObservationIgnored private var streamRecorder: StreamSessionRecorder?
    @ObservationIgnored private var lastStreamRecord = Date.distantPast
    @ObservationIgnored private var lastStreamLogSave = Date.distantPast
    @ObservationIgnored private var lastStreamSessionShown = Date.distantPast

    /// Peak levels on both sides of the stream while listening (dBFS, with meter falloff), for the meters and
    /// Twist Commando. `source` is the other Mac's input as it measured it; nil if it hasn't said lately.
    struct Stereo: Equatable {
        var left: Double
        var right: Double
        static let silent = Stereo(left: -160, right: -160)
    }
    private(set) var streamSourceLevels: Stereo?
    private(set) var streamPlayedLevels = Stereo.silent
    @ObservationIgnored private var streamLevelTimer: Timer?

    /// Levels are read 20 times a second while something shows them: this Mac's stream meters (while listening to
    /// a stream), or a meter another app (Twist Commando, Action Hero) is watching.
    private func updateLevelPolling() {
        let wanted = streamReceiver != nil || (twistCommandoEnabled && !applug.watchedMeters.isEmpty)
        if wanted, streamLevelTimer == nil {
            streamLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollLevels() }
            }
        } else if !wanted, streamLevelTimer != nil {
            streamLevelTimer?.invalidate()
            streamLevelTimer = nil
        }
        if streamReceiver == nil, streamSourceLevels != nil || streamPlayedLevels != .silent {
            streamSourceLevels = nil
            streamPlayedLevels = .silent
            controls.refreshStreamLevels()
        }
    }

    private func pollLevels() {
        // Peaks since the last read go to the watching apps as they are (they do their own falloff).
        let input = capture.peaks.takeIfFresh()
        let stream = streamReceiver?.takeLevels()
        if twistCommandoEnabled, !applug.watchedMeters.isEmpty {
            if let input { applug.sendMeter("inputLevel", levels: [input.left, input.right]) }
            if let source = stream?.source { applug.sendMeter("streamSourceLevel", levels: [source.left, source.right]) }
            if let played = stream?.received { applug.sendMeter("streamLevel", levels: [played.left, played.right]) }
        }
        guard let stream else { return }
        // On screen they jump up and fall back 15 dB a second, like a hardware meter.
        func fall(_ old: Double, _ new: Double?) -> Double { max(new ?? -160, old - 0.75, -160) }
        if stream.sourceAlive {
            let old = streamSourceLevels ?? .silent
            let source = Stereo(left: fall(old.left, stream.source?.left), right: fall(old.right, stream.source?.right))
            if source != streamSourceLevels { streamSourceLevels = source }
        } else if streamSourceLevels != nil {
            streamSourceLevels = nil
        }
        let played = Stereo(left: fall(streamPlayedLevels.left, stream.received?.left),
                            right: fall(streamPlayedLevels.right, stream.received?.right))
        if played != streamPlayedLevels { streamPlayedLevels = played }
        controls.refreshStreamLevels()
    }
    /// Since when the input has been silent (the gate closed), for pausing a shared stream.
    @ObservationIgnored private var silentSince: Date? = Date()
    /// How long the input stays silent before a shared stream pauses (listeners then close their outputs).
    static let streamIdleAfter: TimeInterval = 60
    /// Listening to a stream, but nothing's playing there, so this Mac's output is closed.
    private(set) var streamQuiet = false
    /// Microphone permission granted (refreshed after asking).
    private(set) var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @ObservationIgnored private var networkStarted = false

    /// Offer ThUNER's controls to other apps on this Mac over Applug (Action Hero, Twist Commando; older Twist
    /// Commandos over App Link). Kept under its old name so the setting carries over.
    var twistCommandoEnabled: Bool {
        didSet {
            save(twistCommandoEnabled, "twistCommandoEnabled")
            twistCommandoEnabled ? applug.start() : applug.stop()
        }
    }
    /// Twist Commando's version while it's connected.
    private(set) var twistCommandoVersion: String?
    /// The apps using ThUNER's controls now ("Twist Commando 0.14.0", "Action Hero").
    private(set) var controlConsumers: [String] = []
    /// The Tuneshine's brightness (1–100), when known.
    private(set) var tuneshineBrightness: Int?
    @ObservationIgnored private var brightnessWrite: DispatchWorkItem?
    @ObservationIgnored private lazy var applug = makeApplug()

    /// Serve the web display (a pretend Tuneshine or large cover for any screen on the network).
    var webDisplayEnabled: Bool {
        didSet {
            save(webDisplayEnabled, "webDisplayEnabled")
            if !webDisplayEnabled { webDisplay.stop() } else if networkStarted { startWebDisplay() }
        }
    }
    /// Only this Mac can reach the web display and API (for a laptop on other people's networks, say).
    var webDisplayLocalOnly: Bool {
        didSet {
            save(webDisplayLocalOnly, "webDisplayLocalOnly")
            if webDisplayEnabled, networkStarted { startWebDisplay() }
        }
    }
    @ObservationIgnored let webDisplay = WebDisplayServer()

    private func startWebDisplay() {
        webDisplay.start(port: WebDisplayServer.defaultPort, localOnly: webDisplayLocalOnly)
    }

    /// Token for changing things through the HTTP API from other devices (this Mac doesn't need it).
    private(set) var apiToken: String

    func regenerateAPIToken() {
        apiToken = Self.makeToken()
        save(apiToken, "apiToken")
        webDisplay.setToken(apiToken)
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }

    /// Addresses for the web display: this Mac's .local name (for other devices) and localhost.
    var webDisplayURL: URL {
        if webDisplayLocalOnly { return URL(string: "http://localhost:\(WebDisplayServer.defaultPort)/")! }
        let host = ProcessInfo.processInfo.hostName
        let name = host.hasSuffix(".local") ? host : (host.contains(".") ? host : host + ".local")
        return URL(string: "http://\(name):\(WebDisplayServer.defaultPort)/")!
    }

    func openWebDisplay(mode: String = "tuneshine") {
        if let url = URL(string: "http://localhost:\(WebDisplayServer.defaultPort)/?mode=\(mode)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Use the Music / Spotify apps' own now-playing info instead of Shazam while they're playing.
    var useAppleMusic: Bool { didSet { save(useAppleMusic, "useAppleMusic"); playerChanged() } }
    var useSpotify: Bool { didSet { save(useSpotify, "useSpotify"); playerChanged() } }
    /// Check Last.fm for the same play (Silicio, Spotify's own scrobbling, another Mac) before scrobbling.
    var skipDuplicateScrobbles: Bool { didSet { save(skipDuplicateScrobbles, "skipDuplicateScrobbles") } }
    /// Input devices left out of the menu's picker (by UID).
    var hiddenInputUIDs: Set<String> { didSet { save(Array(hiddenInputUIDs), "hiddenInputUIDs") } }
    /// Animate the menu bar icon as a slow, stepped level meter while something's playing.
    var animateMenuBarIcon: Bool { didSet { save(animateMenuBarIcon, "animateMenuBarIcon") } }
    /// The menu bar panel is pinned open as its own floating window (restored at launch).
    var panelPinned: Bool { didSet { save(panelPinned, "panelPinned") } }
    /// What the menu bar icon shows.
    var menuBarIconKind: MenuBarIcon.Kind {
        // A pause comes first: the point is to see at a glance whether this Mac's mic is listening.
        if micEnabled, pausedManually { return .paused(auto: false) }
        if micEnabled, autoPaused { return .paused(auto: true) }
        if peerHasControl { return .elsewhere(playing: remote?.track != nil) }
        if let level = iconLevel { return .level(level) }
        if activePlayer != nil { return .playing }
        return switch machine.state {
        case .idle: .idle
        case .identifying: .identifying
        case .playing: .playing
        }
    }
    var showFloatingCover: Bool { didSet { save(showFloatingCover, "showFloatingCover"); applyFloatingCover() } }
    /// Only show the floating cover while something's playing (hide it once the audio goes quiet).
    /// The floating cover never hides by itself (a paused player's play button has to stay reachable); after a
    /// while with nothing playing it dims, on the last cover shown, unless this is off.
    var floatingCoverDims: Bool { didSet { save(floatingCoverDims, "floatingCoverDims") } }
    /// The floating cover is dimmed now: nothing has played, and no player is paused, for `coverDimAfter`.
    private(set) var floatingCoverDimmed = false
    /// The last track shown, kept for the floating cover after the display clears (and across relaunches).
    private(set) var lastShownTrack: Track? {
        didSet {
            if let lastShownTrack, let data = try? JSONEncoder().encode(lastShownTrack) {
                defaults.set(data, forKey: "floatingCoverTrack")
            }
        }
    }
    @ObservationIgnored private var coverQuietSince: Date?
    static let coverDimAfter: TimeInterval = 300

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                note("Launch at login: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Live state for the UI

    let updater = Updater()

    private(set) var devices: [AudioInputDevice] = []
    private(set) var levelDB: Double = -160
    /// Menu bar meter position, 0..<MenuBarIcon.levels; nil when the icon isn't animating.
    private(set) var iconLevel: Int?
    @ObservationIgnored private var smoothedLevelDB: Double = -160
    private(set) var machine = NowPlayingMachine()
    private(set) var captureError: String?
    private(set) var micDenied = false
    private(set) var log: [LogEntry] = []
    private(set) var lastPrimaryPeer: String?
    /// A confirmed track this Mac didn't push because the turntable Mac had the display.
    private(set) var deferredPush: Track?

    /// The Music or Spotify app playing right now, when it's being used instead of Shazam.
    private(set) var activePlayer: PlayerMonitor.Snapshot?

    // MARK: Playback controls

    /// What the playback controls act on: the most recently active of Apple Music and Spotify that's still open.
    /// A paused one counts only while ThUNER isn't showing something else (the turntable Mac's record, say).
    private(set) var controllablePlayer: PlayerMonitor.Snapshot?
    /// Shown for a while when a control couldn't be used (ThUNER not allowed to control the app, say).
    private(set) var playbackProblem: String?
    @ObservationIgnored private var playbackProblemTask: Task<Void, Never>?

    private func updateControllablePlayer() {
        var player = players.latest.values.filter { PlayerControl.isRunning($0.source) }.max { $0.receivedAt < $1.receivedAt }
        if let p = player, !p.isPlaying {
            if peerHasControl || shownTrack.map({ !$0.isSameSong(as: p.track) }) == true { player = nil }
        }
        if player != controllablePlayer { controllablePlayer = player }
    }

    /// Play/pause or skip in the player the controls act on. The first time for each app, macOS asks whether
    /// ThUNER may control it.
    func playback(_ command: PlayerControl.Command) {
        Task { _ = await playbackResult(command) }
    }

    /// Does it, and says what happened (for Shortcuts): "Playing", or what got in the way.
    func playbackResult(_ command: PlayerControl.Command) async -> String {
        guard let player = controllablePlayer else {
            let text = "Nothing to control: playback controls work with Apple Music and Spotify"
            showPlaybackProblem(text)
            return text
        }
        let name = player.source.rawValue
        switch await PlayerControl.send(command, to: player.source) {
        case .done:
            playbackProblem = nil
            switch command {
            case .playPause: return player.isPlaying ? "\(name) paused" : "\(name) playing"
            case .next: return "\(name): next track"
            case .previous: return "\(name): previous track"
            }
        case .notRunning:
            let text = "\(name) isn't open"
            showPlaybackProblem(text)
            return text
        case .notAllowed:
            let text = "Allow ThUNER to control \(name): System Settings → Privacy & Security → Automation"
            showPlaybackProblem(text)
            return text
        case .failed(let message):
            let text = "\(name) didn't respond (\(message))"
            showPlaybackProblem(text)
            return text
        }
    }

    private func showPlaybackProblem(_ text: String) {
        note(text)
        playbackProblem = text
        playbackProblemTask?.cancel()
        playbackProblemTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.playbackProblem = nil }
        }
    }
    /// The mic is off (a player is reporting the track, listening is paused, or the turntable Mac has it).
    private(set) var micSuspended = false

    // MARK: Pause and the turntable Mac

    /// What the turntable Mac is doing, from its messages.
    struct RemoteNowPlaying: Equatable {
        var host: String
        /// nil while it's still identifying.
        var track: Track?
        var updatedAt: Date

        /// Heartbeats come every 30s while it has audio; a minute and a half of silence means it's gone.
        func isCurrent(at now: Date) -> Bool { now.timeIntervalSince(updatedAt) < 90 }
    }

    private(set) var remote: RemoteNowPlaying?
    /// Listening paused by hand (menu, Listening control or API). Saved, so it lasts through relaunches and
    /// updates: only resuming by hand ends it; the auto-pause wake signals never do.
    var pausedManually = false {
        didSet {
            guard pausedManually != oldValue else { return }
            save(pausedManually, "pausedManually")
            note(pausedManually ? "Listening paused" : "Listening resumed")
            updateCapture()
        }
    }
    /// Listen and update the display here even though the turntable Mac is playing. Lasts until it goes quiet.
    private(set) var overridingPeer = false

    /// The turntable Mac is playing, so this (secondary) Mac stays out of the way: mic off, no pushes.
    var peerHasControl: Bool {
        guard role == .secondary, !overridingPeer, let remote else { return false }
        return remote.isCurrent(at: Date())
    }

    enum MicOffReason: Equatable {
        /// Microphone listening is switched off altogether.
        case disabled
        case player(String)
        case paused
        /// Paused itself after this many minutes of silence; wakes when something plays.
        case autoPaused(Int)
        case peer(String)
    }

    var micOffReason: MicOffReason? {
        if !micEnabled { return .disabled }
        if pausedManually { return .paused }
        if autoPaused { return .autoPaused(Int(autoPauseMinutes)) }
        if peerHasControl, let remote { return .peer(remote.host) }
        if let player = activePlayer { return .player(player.source.rawValue) }
        return nil
    }

    /// What the panel and floating cover show: the turntable Mac's track while it has control.
    var shownTrack: Track? {
        if peerHasControl, let track = remote?.track { return track }
        return machine.displayed
    }

    /// Pause or resume. Resuming from an auto-pause just wakes it (it isn't a pause you chose).
    func togglePause() {
        if autoPaused {
            wake("Resumed")
        } else {
            pausedManually.toggle()
        }
    }

    // MARK: Auto-pause

    // MARK: System Audio apps

    /// With System Audio as the input: everything, only the chosen apps, or everything except them.
    var systemAudioMode: SystemAudioTap.Mode {
        didSet { save(systemAudioMode.rawValue, "systemAudioMode"); restartIfSystemAudio() }
    }
    /// The chosen apps for System Audio.
    var systemAudioApps: [AudioDevices.AudioApp] {
        didSet {
            if let data = try? JSONEncoder().encode(systemAudioApps) { defaults.set(data, forKey: "systemAudioApps") }
            restartIfSystemAudio()
        }
    }
    /// Apps that have played sound lately, newest first: suggestions for the System Audio app list.
    private(set) var recentAudioApps: [AudioDevices.AudioApp] = []
    @ObservationIgnored private var lastRecentAppsCheck = Date.distantPast
    /// Shown instead of an error while a filtered System Audio capture waits for its apps to play.
    private(set) var captureNotice: String?

    var usingSystemAudio: Bool { inputDeviceUID == SystemAudioTap.uid }

    /// "System Audio", "System Audio · Firefox", "System Audio · 2 apps", "System Audio · all but Zoom".
    var systemAudioLabel: String {
        let names = systemAudioApps.map(\.name)
        switch systemAudioMode {
        case .all: return SystemAudioTap.name
        case .only:
            if names.isEmpty { return "\(SystemAudioTap.name) · no apps chosen" }
            return "\(SystemAudioTap.name) · " + (names.count == 1 ? names[0] : "\(names.count) apps")
        case .except:
            if names.isEmpty { return SystemAudioTap.name }
            return "\(SystemAudioTap.name) · all but " + (names.count == 1 ? names[0] : "\(names.count) apps")
        }
    }

    func toggleSystemAudioApp(_ app: AudioDevices.AudioApp) {
        if let i = systemAudioApps.firstIndex(of: app) { systemAudioApps.remove(at: i) } else { systemAudioApps.append(app) }
    }

    private func restartIfSystemAudio() {
        if usingSystemAudio { restartCapture() }
    }

    /// Notes which apps are playing sound (cheap: asks Core Audio, listens to nothing), for suggestions.
    private func noteRecentAudioApps(at now: Date) {
        guard now.timeIntervalSince(lastRecentAppsCheck) >= 3 else { return }
        lastRecentAppsCheck = now
        queryPlayingProcesses { [weak self] pids in
            guard let self else { return }
            var recent = recentAudioApps
            for pid in pids {
                guard let app = AudioDevices.owningApp(of: pid) else { continue }
                recent.removeAll { $0.bundleID == app.bundleID }
                recent.insert(app, at: 0)
            }
            recent = Array(recent.prefix(12))
            if recent != recentAudioApps {
                recentAudioApps = recent
                if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: "recentAudioApps") }
            }
        }
    }

    /// Asking Core Audio which processes are playing can take most of a second while audio is running (it waits on
    /// coreaudiod), so it's asked on a queue of its own: on the main thread it froze the meters every few seconds.
    /// A query already under way makes the next one wait its turn, unless `always` is set.
    nonisolated private static let audioProcessQueue = DispatchQueue(label: "com.idallas.thuner.audio-processes", qos: .utility)
    @ObservationIgnored private var audioProcessQueryRunning = false

    private func queryPlayingProcesses(always: Bool = false, _ done: @escaping @MainActor (Set<pid_t>) -> Void) {
        guard always || !audioProcessQueryRunning else { return }
        audioProcessQueryRunning = true
        Self.audioProcessQueue.async { [weak self] in
            let pids = AudioDevices.processesPlayingAudio()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.audioProcessQueryRunning = false
                    done(pids)
                }
            }
        }
    }

    /// Listen with a microphone or input at all. Off means Shazam is never used and the mic is never touched
    /// (or asked for): ThUNER follows Apple Music and Spotify (and the turntable Mac) only.
    var micEnabled: Bool {
        didSet {
            guard micEnabled != oldValue else { return }
            save(micEnabled, "micEnabled")
            note(micEnabled ? "Microphone listening on" : "Microphone listening off: following Apple Music and Spotify only")
            if micEnabled, onboardingComplete { listeningStarted = false; startListening() }
            updateCapture()
        }
    }

    /// Pause listening after this many minutes with nothing heard and nothing playing (0 = never).
    var autoPauseMinutes: Double {
        didSet {
            save(autoPauseMinutes, "autoPauseMinutes")
            lastActivity = Date()
            if autoPauseMinutes == 0, autoPaused { wake("Auto-pause turned off") }
        }
    }
    /// Paused itself after a stretch of silence. Not saved: a relaunch starts listening again.
    private(set) var autoPaused = false
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var lastOutputCheck = Date.distantPast
    /// Apps already sending audio when ThUNER paused (SoundSource, SonoBus, a calls helper...): they don't
    /// count as "started playing" unless they stop and start again.
    @ObservationIgnored private var alreadyPlaying = Set<pid_t>()
    /// Apps that started sending audio during the pause, and when.
    @ObservationIgnored private var startedPlaying: [pid_t: Date] = [:]

    /// Ends an auto-pause, if there is one. Called by the wake signals: a player starting, any app playing
    /// sound, the panel opening, the Listening control. Nothing that just means "you're at the Mac".
    func wake(_ reason: String) {
        lastActivity = Date()
        guard autoPaused else { return }
        autoPaused = false
        note("\(reason): listening again")
        updateCapture()
    }

    private func checkAutoPause(at now: Date) {
        // Activity means music actually identified (or a player, or the turntable Mac playing). Noise over the
        // threshold that never matches doesn't count, or a loud room would keep the mic on, and Shazam busy,
        // all night.
        if machine.state == .playing || activePlayer != nil || peerHasControl || pausedManually {
            lastActivity = now
        }
        if autoPaused {
            // Some app started playing sound (checked every couple of seconds; nothing is listened to).
            // An app started playing sound and kept it up for 5 seconds (alert sounds are too short to count).
            if now.timeIntervalSince(lastOutputCheck) >= 1 {
                lastOutputCheck = now
                queryPlayingProcesses { [weak self] playing in
                    guard let self, autoPaused else { return }
                    let now = Date()
                    alreadyPlaying.formIntersection(playing)  // stopped, so starting again would count
                    startedPlaying = startedPlaying.filter { playing.contains($0.key) }
                    for pid in playing.subtracting(alreadyPlaying) where startedPlaying[pid] == nil { startedPlaying[pid] = now }
                    if let (pid, _) = startedPlaying.first(where: { now.timeIntervalSince($0.value) >= 5 }) {
                        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
                        wake("\(name) started playing")
                    }
                }
            }
            return
        }
        guard autoPauseMinutes > 0, micOffReason == nil,
              now.timeIntervalSince(lastActivity) >= autoPauseMinutes * 60 else { return }
        autoPaused = true
        alreadyPlaying = []
        startedPlaying = [:]
        queryPlayingProcesses(always: true) { [weak self] playing in
            guard let self else { return }
            alreadyPlaying = playing
            // A check that answered first may have taken these for apps that just started.
            startedPlaying = startedPlaying.filter { !playing.contains($0.key) }
        }
        note("Nothing identified for \(Int(autoPauseMinutes)) minutes; pausing until something plays")
        updateCapture()
    }

    func listenHereAnyway() {
        overridingPeer = true
        note("Listening here even though \(remote?.host ?? "the turntable Mac") is playing")
        updateCapture()
    }

    private func canPush(at now: Date) -> Bool {
        overridingPeer || arbiter.mayPush(at: now)
    }

    /// Turns the mic on or off to match `micOffReason`.
    private func updateCapture() {
        let shouldBeOff = micOffReason != nil
        if shouldBeOff, !micSuspended {
            micSuspended = true
            // Whatever the mic confirmed before it went off isn't playing here any more.
            if activePlayer == nil { deferredPush = nil }
            capture.stop()
            gate.reset()
            levelDB = -160
            perform(machine.audioStopped(at: Date()))
        } else if !shouldBeOff, micSuspended {
            micSuspended = false
            restartCapture()
        }
    }

    enum ShazamStatus { case unknown, ok, serviceNotEnabled }

    private(set) var tuneshineHealth: TuneshineDisplay.Health?
    private(set) var checkingTuneshine = false
    private(set) var shazamStatus = ShazamStatus.unknown
    var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    /// Something in the Status section needs attention.
    var hasPermissionProblem: Bool {
        (micEnabled && micDenied) || tuneshineHealth == .localNetworkDenied || shazamStatus == .serviceNotEnabled
    }

    /// Every play from every source, newest last. Persisted to Application Support/Thuner/history.json.
    private(set) var history = PlayHistory()

    /// ListenBrainz-style services (ListenBrainz, Maloja, Koito, multi-scrobbler), persisted in UserDefaults;
    /// their tokens are in the Keychain.
    private(set) var listenBrainzConfigs: [ListenBrainzService.Config] = []
    @ObservationIgnored private var listenBrainzServices: [UUID: ListenBrainzService] = [:]
    /// Plays waiting to be sent, per service id.
    private(set) var pendingScrobbles: [String: Int] = [:]
    /// Whether any service is connected and switched on, so there's somewhere to scrobble to.
    private(set) var hasScrobbleService = false

    private(set) var lastFMUser: String?
    private(set) var lastFMHasCredentials = false
    private(set) var lastFMAwaitingApproval = false
    private(set) var lastFMPending = 0
    private(set) var lastFMError: String?

    var gateOpen: Bool { gate.isOpen }
    var arbiterAllowsPush: Bool { canPush(at: Date()) }
    /// Devices for the menu's picker: everything not hidden, plus the selected one even if it is.
    var menuDevices: [AudioInputDevice] {
        devices.filter { !hiddenInputUIDs.contains($0.uid) || $0.uid == inputDeviceUID }
    }

    func setInput(_ device: AudioInputDevice, visible: Bool) {
        if visible { hiddenInputUIDs.remove(device.uid) } else { hiddenInputUIDs.insert(device.uid) }
    }

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.uid == inputDeviceUID }
    }

    // MARK: Input names

    /// Names given to inputs ("Turntable" for an interface's 3–4), by `deviceUID#firstChannel` (0 for a mono or
    /// stereo device). Over SSH: `defaults write com.idallas.thuner inputNames -dict-add '<uid>#2' Turntable`.
    var inputNames: [String: String] {
        didSet {
            save(inputNames, "inputNames")
            // Other Macs see the name as the stream's source.
            if streamSharing { restartCapture() }
        }
    }

    private static func inputKey(_ device: AudioInputDevice, first: Int) -> String {
        "\(device.uid)#\(device.inputChannels <= 2 ? 0 : first)"
    }

    func inputName(_ device: AudioInputDevice, first: Int) -> String? {
        inputNames[Self.inputKey(device, first: first)].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setInputName(_ name: String, for device: AudioInputDevice, first: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        inputNames[Self.inputKey(device, first: first)] = trimmed.isEmpty ? nil : trimmed
    }

    /// The selected input's name, if it has one.
    var selectedInputName: String? {
        selectedDevice.flatMap { inputName($0, first: firstChannel) }
    }

    /// How another Mac's name is shown. `open Thuner.app --args -peerDisplayName "Mac mini"` shows every other
    /// Mac under that name instead, for screenshots that shouldn't carry real machine names. Display only:
    /// settings and connections use the real names.
    nonisolated static func shown(_ host: String) -> String {
        guard host != streamThisMac,
              let alias = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["peerDisplayName"] as? String,
              !alias.isEmpty else { return host }
        return alias
    }

    /// A channel pair for pickers: its name with the channels ("Turntable (3–4)"), or the plain label.
    func pairLabel(_ device: AudioInputDevice, _ pair: (first: Int, label: String)) -> String {
        guard let name = inputName(device, first: pair.first) else { return pair.label }
        let numbers = pair.first + 1 < device.inputChannels ? "\(pair.first + 1)–\(pair.first + 2)" : "\(pair.first + 1)"
        return "\(name) (\(numbers))"
    }

    /// A device for the input picker: a mono or stereo device's own name, or its given one with it.
    func deviceLabel(_ device: AudioInputDevice) -> String {
        guard device.inputChannels <= 2, let name = inputName(device, first: 0) else { return device.name }
        return "\(name) (\(device.name))"
    }

    // MARK: Internals

    private var gate: LevelGate
    private var arbiter: PushArbiter
    private let capture = AudioCapture()
    private let matcher = Matcher()
    private let peers = PeerLink()
    private var display: CoverDisplay { TuneshineDisplay(host: effectiveTuneshineHost ?? "") }
    private let tuneshineBrowser = TuneshineBrowser()
    private var ticker: Timer?
    @ObservationIgnored private var floatingCover: FloatingCoverController?
    private let players = PlayerMonitor()
    /// Set when something outside the Shazam state machine left a cover up (a player stopped, or the cover
    /// restored at launch): clear it after the same silence delay as Shazam unless something takes over.
    private var clearAfterQuietSince: Date?
    /// A push that failed, to try again shortly.
    private var pushRetry: (track: Track, attempt: Int, at: Date)?
    /// A clear that failed, to try again shortly.
    private var clearRetry: (attempt: Int, at: Date)?
    private let lastFM = LastFM()
    private var scrobbles = ScrobbleTracker()
    private var lastFlushAttempt = Date.distantPast
    /// The current play's scrobble, if it came due while scrobbling was off or not connected yet.
    private var missedScrobble: ScrobbleTracker.Action?
    private var lastHeartbeat = Date.distantPast
    private var lastUILevelUpdate = Date.distantPast
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.idallas.thuner", category: "app")

    init() {
        let d = UserDefaults.standard
        let threshold = d.object(forKey: "thresholdDB") as? Double ?? -45
        let role = PushArbiter.Role(rawValue: d.string(forKey: "role") ?? "") ?? .secondary
        inputDeviceUID = d.string(forKey: "inputDeviceUID")
        firstChannel = d.integer(forKey: "firstChannel")
        thresholdDB = threshold
        self.role = role
        idleImageMinutes = d.object(forKey: "idleImageMinutes") as? Double ?? 5
        tuneshineHost = d.string(forKey: "tuneshineHost") ?? ""
        scrobblingEnabled = d.bool(forKey: "scrobblingEnabled")
        radioMode = d.bool(forKey: "radioMode")
        // Copies set up before the tour existed have settings already; don't greet them.
        onboardingComplete = d.bool(forKey: "onboardingComplete")
            || ["role", "inputDeviceUID", "lastDisplayed", "scrobblingEnabled"].contains { d.object(forKey: $0) != nil }
        webDisplayEnabled = d.object(forKey: "webDisplayEnabled") as? Bool ?? true
        webDisplayLocalOnly = d.bool(forKey: "webDisplayLocalOnly")
        twistCommandoEnabled = d.object(forKey: "twistCommandoEnabled") as? Bool ?? true
        micEnabled = d.object(forKey: "micEnabled") as? Bool ?? true
        let paused = d.bool(forKey: "pausedManually")
        pausedManually = paused
        // Paused when it quit: start with the mic off rather than turn it on for a moment at launch.
        micSuspended = paused
        systemAudioMode = SystemAudioTap.Mode(rawValue: d.string(forKey: "systemAudioMode") ?? "") ?? .all
        systemAudioApps = d.data(forKey: "systemAudioApps").flatMap { try? JSONDecoder().decode([AudioDevices.AudioApp].self, from: $0) } ?? []
        recentAudioApps = d.data(forKey: "recentAudioApps").flatMap { try? JSONDecoder().decode([AudioDevices.AudioApp].self, from: $0) } ?? []
        // On by default for a room mic; off for the turntable Mac, whose line-in isn't a privacy concern and
        // which (headless) would rarely see a wake signal.
        autoPauseMinutes = d.object(forKey: "autoPauseMinutes") as? Double ?? (role == .primary ? 0 : 30)
        let savedToken = d.string(forKey: "apiToken") ?? ""
        let token = savedToken.isEmpty ? Self.makeToken() : savedToken
        if savedToken.isEmpty { d.set(token, forKey: "apiToken") }
        apiToken = token
        if let data = d.data(forKey: "listenBrainzServices"),
           let configs = try? JSONDecoder().decode([ListenBrainzService.Config].self, from: data) {
            listenBrainzConfigs = configs
            for config in configs { listenBrainzServices[config.id] = ListenBrainzService(config: config) }
        }
        showFloatingCover = d.bool(forKey: "showFloatingCover")
        panelPinned = d.bool(forKey: "panelPinned")
        floatingCoverDims = d.object(forKey: "floatingCoverDims") as? Bool ?? true
        lastShownTrack = d.data(forKey: "floatingCoverTrack").flatMap { try? JSONDecoder().decode(Track.self, from: $0) }
        animateMenuBarIcon = d.object(forKey: "animateMenuBarIcon") as? Bool ?? true
        hiddenInputUIDs = Set(d.stringArray(forKey: "hiddenInputUIDs") ?? [])
        skipDuplicateScrobbles = d.object(forKey: "skipDuplicateScrobbles") as? Bool ?? true
        if let data = try? Data(contentsOf: Self.historyURL) {
            if let saved = try? JSONDecoder().decode(PlayHistory.self, from: data) {
                history = saved
            } else {
                // Don't let the next save overwrite a history we couldn't read; keep it to recover by hand.
                let aside = Self.historyURL.deletingLastPathComponent()
                    .appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: Self.historyURL, to: aside)
            }
        }
        if let data = try? Data(contentsOf: Self.streamLogURL) {
            do {
                streamLog = try JSONDecoder().decode(StreamLog.self, from: data)
            } catch {
                // As with History: keep a log we couldn't read rather than let the next save replace it.
                logger.error("Couldn't read the stream log: \(error, privacy: .public)")
                let aside = Self.streamLogURL.deletingLastPathComponent()
                    .appendingPathComponent("stream-log-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: Self.streamLogURL, to: aside)
            }
        }
        streamSharing = d.bool(forKey: "streamSharing")
        streamSource = d.string(forKey: "streamSource") ?? ""
        streamMethod = StreamMethod(rawValue: d.string(forKey: "streamMethod") ?? "") ?? .resilient
        streamMarginMs = d.object(forKey: "streamMarginMs") as? Double ?? 2
        streamOutputUID = d.string(forKey: "streamOutputUID")
        streamOutputChannel = d.integer(forKey: "streamOutputChannel")
        inputNames = d.dictionary(forKey: "inputNames") as? [String: String] ?? [:]
        // Set over SSH on a headless Mac (`defaults write com.idallas.thuner streamPassword …`): move it into the
        // Keychain and out of the readable preferences.
        if let typed = d.string(forKey: "streamPassword") {
            if typed.isEmpty { Keychain.delete(account: "stream-password") } else { Keychain.write(typed, account: "stream-password") }
            d.removeObject(forKey: "streamPassword")
        }
        streamPassword = Keychain.read(String.self, account: "stream-password") ?? ""
        useAppleMusic = d.object(forKey: "useAppleMusic") as? Bool ?? true
        useSpotify = d.object(forKey: "useSpotify") as? Bool ?? true
        gate = LevelGate(thresholdDB: threshold)
        arbiter = PushArbiter(role: role)
        applyTiming()

        // The Tuneshine keeps showing Thuner's last image across a relaunch, so show it here too (no re-push).
        if let data = d.data(forKey: "lastDisplayed"), let track = try? JSONDecoder().decode(Track.self, from: data) {
            machine.displayedExternally(track)
            logger.notice("Restored last cover: \(track.displayName, privacy: .public)")
            clearAfterQuietSince = Date()
        }

        devices = AudioDevices.inputDevices()
        AudioDevices.observeDeviceListChanges { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }

        capture.onLevel = { [weak self] db in
            DispatchQueue.main.async { self?.ingest(levelDB: db) }
        }
        capture.onInterrupted = { [weak self] in
            MainActor.assumeIsolated {
                self?.note("Audio input changed; restarting capture")
                self?.restartCapture()
            }
        }

        peers.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.received(message) }
        }
        peers.onAddressesChanged = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let receiver = self.streamReceiver, self.streamSource != Self.streamThisMac else { return }
                receiver.setSourceAddresses(self.peers.addresses(ofHost: self.streamSource))
            }
        }
        peers.onPeersChanged = { [weak self] hosts in
            MainActor.assumeIsolated { self?.otherThuners = hosts }
        }

        passwordWatcher = d.observe(\.streamPassword, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.adoptTypedPassword() } }
        }

        capture.streamSink = streamSender
        streamSender.sharing = streamSharing
        streamCipher = StreamCipher(password: streamPassword)
        streamSender.cipher = streamCipher
        streamSender.isKnownPeer = { [weak self] address in
            MainActor.assumeIsolated { self?.peers.isKnownPeer(address) ?? false }
        }
        streamSender.onListenersChanged = { [weak self] hosts in
            MainActor.assumeIsolated {
                guard let self, hosts != self.streamListeners else { return }
                for host in Set(hosts).subtracting(self.streamListeners) { self.note("\(host) is listening to this Mac") }
                self.streamListeners = hosts
            }
        }
        outputDevices = AudioDevices.outputDevices()

        players.onChange = { [weak self] _ in self?.playerChanged() }
        players.start()

        tuneshineBrowser.onChange = { [weak self] in
            guard let self else { return }
            let wasAutomaticAndMissing = tuneshineHost.isEmpty && discoveredTuneshines.isEmpty
            discoveredTuneshines = tuneshineBrowser.devices
            if wasAutomaticAndMissing, !discoveredTuneshines.isEmpty {
                Task { await self.checkTuneshine() }
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        applyFloatingCover()
        Task { await refreshLastFMStatus() }
        if onboardingComplete {
            startListening()
            startNetwork()
        }
    }

    /// Asks for the microphone if needed and starts listening. The tour calls this from its Listening step.
    func startListening() {
        guard micEnabled, !listeningStarted else { return }
        listeningStarted = true
        requestMicAndStart()
    }
    @ObservationIgnored private var listeningStarted = false

    /// Starts everything that touches the local network (and so triggers macOS's Local Network prompt):
    /// finding the Tuneshine and other ThUNERs, and the web display. The tour calls this from its Display step.
    func startNetwork() {
        guard !networkStarted else { return }
        networkStarted = true
        connectAPI()
        if twistCommandoEnabled { applug.start() }
        peers.start()
        streamSender.start()
        applyStreamReceiver()
        tuneshineBrowser.start()
        if webDisplayEnabled { startWebDisplay() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await checkTuneshine()
        }
    }

    /// The tour is done (or skipped): make sure everything's running.
    func finishOnboarding() {
        onboardingComplete = true
        startListening()
        startNetwork()
    }

    // MARK: User actions

    func identifyNow() {
        perform(machine.requestQuery(at: Date()))
    }

    /// Remove whatever Thuner put on the Tuneshine (for when it's stuck), like the "Clear Tuneshine" shortcut.
    func clearDisplay(attempt: Int = 1) {
        clearRetry = nil
        machine.displayCleared()
        let display = display
        Task {
            do {
                try await display.showIdle()
                saveConfirmedDisplay(nil)
                note("Cleared the Tuneshine")
            } catch {
                // Retry unless something new has gone up since.
                if attempt < 3, machine.displayed == nil {
                    note("Tuneshine clear failed (\(error.localizedDescription)); retrying in 20s")
                    clearRetry = (attempt + 1, Date().addingTimeInterval(20))
                } else {
                    note("Tuneshine clear failed: \(error.localizedDescription)")
                }
                await checkTuneshine()
            }
        }
    }

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    // MARK: Capture

    private func requestMicAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            restartCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.micDenied = !granted
                    self?.micAuthorized = granted
                    if granted { self?.restartCapture() }
                }
            }
        default:
            micDenied = true
            note("Microphone access denied. Allow ThUNER in System Settings → Privacy & Security → Microphone.")
        }
    }

    @ObservationIgnored private var recentRestarts: [Date] = []
    @ObservationIgnored private var restartScheduled = false

    private func restartCapture() {
        guard !micDenied, !micSuspended else { return }
        // Never spin: if restarts pile up (more than 5 in 10 seconds), wait a few seconds before the next one.
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 10 }
        if recentRestarts.count >= 5 {
            guard !restartScheduled else { return }
            restartScheduled = true
            note("Audio input keeps changing; waiting 5s before restarting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                restartScheduled = false
                recentRestarts.removeAll()
                restartCapture()
            }
            return
        }
        recentRestarts.append(now)
        let config = AudioCapture.Config(deviceUID: inputDeviceUID, firstChannel: firstChannel, channelCount: 2,
                                         systemAudioMode: systemAudioMode,
                                         systemAudioApps: Set(systemAudioApps.map(\.bundleID)),
                                         streamFrames: streamSharing ? 128 : nil,
                                         sourceName: selectedInputName)
        do {
            try capture.start(config)
            captureError = nil
            captureNotice = nil
            let name = selectedInputName.map { "\($0) (\(capture.activeDeviceName ?? "input"))" }
            note("Listening to \(usingSystemAudio ? systemAudioLabel : name ?? capture.activeDeviceName ?? "default input")")
        } catch AudioCapture.CaptureError.waitingForApps {
            captureError = nil
            captureNotice = "Waiting for \(systemAudioApps.map(\.name).joined(separator: " or ")) to play"
            note(captureNotice!)
        } catch {
            captureError = error.localizedDescription
            captureNotice = nil
            note("Capture failed: \(error.localizedDescription)")
        }
        gate.reset()
        silentSince = Date()
        perform(machine.audioStopped(at: Date()))
    }

    // MARK: Streaming

    /// Starts (or restarts, with the current settings) listening to `streamSource`, or stops.
    private func applyStreamReceiver() {
        endStreamSession()
        streamReceiver?.stop()
        streamReceiver = nil
        updateLevelPolling()
        streamStats = nil
        streamSenderStatus = nil
        streamProblem = nil
        guard networkStarted, !streamSource.isEmpty else { return }
        let address: sockaddr_in
        if streamSource == Self.streamThisMac {
            address = UDP.loopback
        } else if let ip = peers.address(ofHost: streamSource) {
            address = UDP.address(ip, port: StreamWire.port)
        } else {
            // Not found yet; `otherThuners` changing tries again.
            streamProblem = "Looking for \(streamSource)…"
            return
        }
        let settings = AudioStreamReceiver.Settings(method: streamMethod, marginMs: streamMarginMs, outputUID: streamOutputUID,
                                                    outputChannel: streamOutputUID == nil ? 0 : streamOutputChannel)
        let receiver = AudioStreamReceiver(source: address, host: streamSource, settings: settings, cipher: streamCipher)
        receiver.onChange = { [weak self, weak receiver] in
            MainActor.assumeIsolated {
                guard let self, let receiver, receiver === self.streamReceiver else { return }
                self.streamSenderStatus = receiver.status
                let other = Self.shown(receiver.status?.host ?? self.streamSource)
                self.streamProblem = receiver.error ?? {
                    switch receiver.status?.password {
                    case .needed: return "\(other) has a stream password, and this Mac's is missing or different"
                    case .notSet: return "\(other) has no stream password; clear this Mac's to listen"
                    case nil: return receiver.status?.sharing == false ? "\(other) isn't sharing its input" : nil
                    }
                }()
            }
        }
        streamReceiver = receiver
        if streamSource != Self.streamThisMac { receiver.setSourceAddresses(peers.addresses(ofHost: streamSource)) }
        receiver.start()
        beginStreamSession()
        updateLevelPolling()
        streamProblem = receiver.error
        note("Listening to \(streamSource)'s stream (\(streamMethod.rawValue))")
    }

    // MARK: Stream sessions

    private func beginStreamSession() {
        let now = Date()
        if let earlier = streamLog.resumable(source: streamSource, method: streamMethod, at: now) {
            streamRecorder = StreamSessionRecorder(continuing: earlier)
        } else {
            streamRecorder = StreamSessionRecorder(session: StreamSession(source: streamSource, method: streamMethod, started: now))
        }
        streamSession = streamRecorder?.snapshot
    }

    private func endStreamSession() {
        guard let recorder = streamRecorder else { return }
        streamRecorder = nil
        streamSession = nil
        streamLog.save(recorder.snapshot)
        saveStreamLog()
    }

    /// Ends the session in progress and starts a fresh one (the Stream window's New Session).
    func startNewStreamSession() {
        guard let recorder = streamRecorder else { return }
        streamLog.save(recorder.snapshot)
        saveStreamLog()
        streamRecorder = StreamSessionRecorder(session: StreamSession(source: streamSource, method: streamMethod, started: Date()))
        streamSession = streamRecorder?.snapshot
    }

    func clearStreamLog() {
        streamLog.sessions.removeAll { $0.id != streamSession?.id }
        saveStreamLog()
    }

    /// Once a second while listening.
    private func recordStreamSession(at now: Date) {
        guard var recorder = streamRecorder, let receiver = streamReceiver,
              now.timeIntervalSince(lastStreamRecord) >= 1 else { return }
        lastStreamRecord = now
        let resends = receiver.resendStats
        let latency = receiver.latency
        recorder.record(StreamSample(stats: receiver.stats, latencyMs: latency?.totalMs,
                                     resendsRequested: resends.requested, resendsRecovered: resends.recovered,
                                     outputBufferMs: latency?.outputBufferMs ?? 0), at: now)
        streamRecorder = recorder
        let snapshot = recorder.snapshot
        // Shown every few seconds, not every second: each change re-lays out the Stream window, graph and all.
        if streamSession?.id != snapshot.id || now.timeIntervalSince(lastStreamSessionShown) >= 5 {
            lastStreamSessionShown = now
            streamSession = snapshot
        }
        if now.timeIntervalSince(lastStreamLogSave) >= 60, snapshot.playingSeconds > 0 {
            lastStreamLogSave = now
            streamLog.save(snapshot)
            saveStreamLog()
        }
    }

    /// Writes the session in progress straight away (quitting).
    func saveStreamSessionNow() {
        if let recorder = streamRecorder { streamLog.save(recorder.snapshot) }
        guard let data = try? JSONEncoder().encode(streamLog) else { return }
        Self.historyQueue.sync {
            try? FileManager.default.createDirectory(at: Self.streamLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.streamLogURL, options: .atomic)
        }
    }

    nonisolated private static var streamLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thuner/stream-log.json")
    }

    private func saveStreamLog() {
        let snapshot = streamLog
        Self.historyQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: Self.streamLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.streamLogURL, options: .atomic)
        }
    }

    /// Lost packets asked for again, how many came back in time, and how many were given up on (resilient only).
    var streamResends: (requested: Int, recovered: Int, abandoned: Int)? {
        guard streamMethod == .resilient else { return nil }
        return streamReceiver?.resendStats
    }

    /// The stream's live numbers, for the meters (read often; not observed).
    func streamReading() -> (stats: PlayoutStats, latency: AudioStreamReceiver.Latency?)? {
        guard let receiver = streamReceiver, let stats = receiver.stats else { return nil }
        return (stats, receiver.latency)
    }

    func refreshOutputDevices() {
        outputDevices = AudioDevices.outputDevices()
    }

    private func devicesChanged() {
        let wasMissing = captureError != nil
        refreshDevices()
        // The chosen device came back (USB interface replugged, etc.).
        if wasMissing, let uid = inputDeviceUID, devices.contains(where: { $0.uid == uid }) {
            restartCapture()
        }
    }

    private func ingest(levelDB db: Double) {
        let now = Date()
        smoothedLevelDB = smoothedLevelDB * 0.85 + db * 0.15
        if now.timeIntervalSince(lastUILevelUpdate) > 0.1 {
            levelDB = db
            lastUILevelUpdate = now
            controls.refreshInputLevel()
        }
        // Sound again after the stream paused for silence: resume at once, not after the gate's attack time, or
        // the start of the record goes missing on the other Mac.
        if streamSender.idle, db >= thresholdDB {
            streamSender.idle = false
            // Count silence again from now: a lone pop that never opens the gate mustn't keep the stream awake.
            silentSince = Date()
        }
        // A brief dip below the threshold while the gate stays open: likely the gap between two tracks.
        if gate.isOpen, micOffReason == nil {
            if db < thresholdDB {
                if quietSince == nil { quietSince = now }
            } else if let since = quietSince {
                quietSince = nil
                if now.timeIntervalSince(since) >= Self.trackGap { perform(machine.gapEnded(at: now)) }
            }
        } else {
            quietSince = nil
        }
        switch gate.feed(levelDB: db, at: now) {
        case .opened:
            silentSince = nil
            note("Audio detected")
            if role == .primary {
                lastHeartbeat = now
                peers.send(.active, role: role.rawValue, nowPlaying: nil)
            }
            perform(machine.audioStarted(at: now))
        case .closed:
            silentSince = now
            note("Silence")
            if role == .primary, activePlayer == nil { peers.send(.idle, role: role.rawValue, nowPlaying: nil) }
            deferredPush = nil
            perform(machine.audioStopped(at: now))
        case nil:
            break
        }
    }

    /// Near-silence this long, short of the gate closing, counts as a gap between tracks.
    private static let trackGap: TimeInterval = 0.8
    @ObservationIgnored private var quietSince: Date?

    // MARK: State machine plumbing

    private func tick() {
        let now = Date()
        // Only write the machine back when the tick changed it: every write redraws whatever shows it.
        var ticked = machine
        let actions = ticked.tick(at: now)
        if ticked != machine { machine = ticked }
        perform(actions)
        if let r = remote, !r.isCurrent(at: now) {
            remote = nil
            overridingPeer = false
            note("Lost touch with \(r.host); listening here again")
        }
        checkAutoPause(at: now)
        noteRecentAudioApps(at: now)
        updateControllablePlayer()
        if streamSharing, !streamSender.idle, let since = silentSince, now.timeIntervalSince(since) > Self.streamIdleAfter {
            streamSender.idle = true
        }
        let quiet = streamReceiver?.isQuiet ?? false
        if quiet != streamQuiet { streamQuiet = quiet }
        recordStreamSession(at: now)
        if let receiver = streamReceiver {
            let stats = receiver.stats
            if stats != streamStats { streamStats = stats }
            if let stats, now.timeIntervalSince(lastStreamLog) >= 10 {
                lastStreamLog = now
                logger.notice("Stream \(stats.method.rawValue, privacy: .public): \(stats.playing ? "playing" : "waiting", privacy: .public), buffer \(String(format: "%.2f", stats.bufferedMs), privacy: .public)/\(String(format: "%.2f", stats.targetMs), privacy: .public) ms, jitter \(String(format: "%.2f", stats.jitterMs), privacy: .public) ms, drift \(String(format: "%+.1f", stats.driftPPM), privacy: .public) ppm, \(stats.received) received, \(stats.lost) lost, \(stats.late) late, \(stats.underruns) dropouts, \(stats.adjustments) corrections")
            }
        }
        updateCapture()
        updater.installPendingUpdateIfQuiet(isQuiet: activePlayer == nil && machine.state == .idle)
        updateFloatingCoverDimming(at: now)
        stepIconLevel(at: now)
        let shown = webNowPlaying
        if webDisplayEnabled { webDisplay.update(shown) }
        // The widget reads /now.json; tell it to when what's shown changes.
        if shown != lastWidgetState {
            lastWidgetState = shown
            WidgetCenter.shared.reloadAllTimelines()
        }
        controls.refresh(at: now)

        if let track = deferredPush, canPush(at: now) {
            deferredPush = nil
            // Only if it's still what's playing here; otherwise it's stale (the player stopped, the record changed).
            if isPlayingHere(track) {
                note("Turntable Mac has gone quiet; taking over the display")
                push(track)
            }
        }

        // The turntable Mac speaks up as soon as it hears audio, not just once a track is confirmed, so the
        // other Mac doesn't race it to the display while it's still identifying.
        if role == .primary, machine.state != .idle || activePlayer != nil, now.timeIntervalSince(lastHeartbeat) > 30 {
            lastHeartbeat = now
            peers.send(.active, role: role.rawValue, nowPlaying: activePlayer?.track ?? machine.current?.track)
        }

        if let stopped = clearAfterQuietSince, activePlayer == nil {
            if machine.state == .playing {
                clearAfterQuietSince = nil  // Shazam confirmed something; its own silence timer takes over.
            } else if machine.state == .identifying {
                clearAfterQuietSince = now  // There's audio; count the delay from when it goes quiet.
            } else if let delay = machine.timing.idleImageDelay, now.timeIntervalSince(stopped) >= delay {
                clearAfterQuietSince = nil
                if machine.displayed != nil, canPush(at: now) {
                    note("Nothing playing for a while; clearing the Tuneshine")
                    clearDisplay()
                }
            }
        }

        if let retry = clearRetry, now >= retry.at {
            clearRetry = nil
            if machine.displayed == nil { clearDisplay(attempt: retry.attempt) }
        }

        if let retry = pushRetry, now >= retry.at {
            pushRetry = nil
            if let shown = machine.displayed, shown.isSameSong(as: retry.track), canPush(at: now) {
                push(retry.track, attempt: retry.attempt)
            }
        }

        let confirmed: MatchObservation?
        if let player = activePlayer {
            // Spotify reports its position; for Music, count the track as starting when the notification came.
            confirmed = MatchObservation(track: player.track, offset: player.position ?? 0, observedAt: player.receivedAt)
        } else {
            confirmed = machine.state == .playing ? machine.current : nil
        }
        let scrobbleActions = scrobbles.update(
            confirmed: confirmed,
            audible: activePlayer != nil || machine.state != .idle, at: now)
        for action in scrobbleActions {
            if case .nowPlaying(let track) = action, let play = scrobbles.play {
                let source: PlayHistory.Source = switch activePlayer?.source {
                case .appleMusic: .appleMusic
                case .spotify: .spotify
                case nil: .shazam
                }
                history.record(track, startedAt: play.startedAt, source: source)
                saveHistory()
            }
            handleScrobble(action, at: now)
        }
        if pendingScrobbles.values.contains(where: { $0 > 0 }), now.timeIntervalSince(lastFlushAttempt) > 300 {
            lastFlushAttempt = now
            Task { await flushScrobbles() }
        }
    }

    private func isPlayingHere(_ track: Track) -> Bool {
        if let player = activePlayer { return player.track.isSameSong(as: track) }
        return machine.state == .playing && machine.current?.track.isSameSong(as: track) == true
    }

    /// What the web display shows: the same track as the panel, including the turntable Mac's.
    @ObservationIgnored private var lastWidgetState: WebDisplayServer.NowPlaying?

    private var webNowPlaying: WebDisplayServer.NowPlaying {
        var now = WebDisplayServer.NowPlaying()
        let track = shownTrack
        now.title = track?.title
        now.artist = track?.artist
        now.album = track?.album
        now.artwork = track?.artworkURL?.absoluteString
        if peerHasControl {
            now.state = remote?.track == nil ? "identifying" : "playing"
            now.source = remote.map { "On \($0.host)" }
        } else if let player = activePlayer {
            now.state = "playing"
            now.source = player.source.rawValue
        } else {
            now.state = switch machine.state {
            case .idle: "idle"
            case .identifying: "identifying"
            case .playing: "playing"
            }
            now.source = machine.state == .playing ? "Identified by Shazam" : nil
        }
        if let player = controllablePlayer {
            now.player = player.source.rawValue
            now.paused = !player.isPlaying
        }
        return now
    }

    // MARK: Controls (App Link, HTTP API)

    /// ThUNER's controls, shared by every adapter (Twist Commando's App Link, the HTTP API).
    @ObservationIgnored private(set) lazy var controls = ControlSurface(model: self)

    /// ThUNER's controls for other apps on this Mac (Applug), with Twist Commando's App Link port too for versions
    /// that don't speak Applug yet (only while Twist Commando is running).
    private func makeApplug() -> ApplugProvider {
        controls.refresh()
        let states = controls.states
        let provider = ApplugProvider(name: "ThUNER", controls: controls.definitions.map { definition in
            let state = states[definition.id]
            let kind: Control.Kind = if definition.meterChannels != nil { .meter } else {
                switch definition.kind {
                case .level: .level
                case .toggle: .toggle
                case .button: .button
                }
            }
            return Control(id: definition.id, name: definition.name, kind: kind,
                           value: kind == .meter ? nil : state?.value, text: state?.text, on: state?.on,
                           group: definition.group, channels: definition.meterChannels, readOnly: definition.readOnly)
        })
        provider.appLinkCompatibility = AppLinkCompatibility()
        provider.onWatchedMetersChange = { [weak self] meters in
            self?.logger.notice("Meters wanted: \(meters.sorted().joined(separator: ", "), privacy: .public)")
            self?.updateLevelPolling()
        }
        provider.onTurn = { [weak self] turn in
            if let value = turn.value { self?.controls.turn(turn.id, to: value) }
        }
        provider.onPress = { [weak self] press in
            if press.down { self?.controls.press(press.id) }
        }
        provider.onConsumersChange = { [weak self] consumers in
            guard let self else { return }
            let twist = consumers.first { $0.app.hasPrefix("com.twistcommando.") }
            let wasTwist = twistCommandoVersion != nil
            twistCommandoVersion = twist.map { $0.version ?? "" }
            if twist != nil, !wasTwist { note("Connected to Twist Commando") }
            let names = consumers.map { [$0.name, $0.version].compactMap { $0 }.joined(separator: " ") }
            for name in Set(names).subtracting(controlConsumers) where !name.hasPrefix("Twist Commando") {
                note("\(name) is using ThUNER's controls")
            }
            controlConsumers = names
        }
        controls.observers.append { [weak provider] id, state in
            guard let provider else { return }
            if provider.controls.first(where: { $0.id == id })?.kind == .meter { return }
            provider.set(id, value: state.value, text: state.text, on: state.on)
            if state.text == nil { provider.clearText(id) }
        }
        return provider
    }

    /// Hooks the HTTP API up to the controls: their definitions and live state, the token, and actions.
    private func connectAPI() {
        controls.refresh()
        webDisplay.setToken(apiToken)
        webDisplay.setControls(controls.definitions.map {
            WebDisplayServer.ControlInfo(definition: $0, state: controls.states[$0.id] ?? .init())
        })
        let server = webDisplay
        controls.observers.append { id, state in server.controlChanged(id, state) }
        webDisplay.onAction = { [weak self] id, action in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch action {
                case .turn(let value): self.controls.turn(id, to: value)
                case .press: self.controls.press(id)
                case .set(let on): self.controls.set(id, on: on)
                }
            }
        }
    }

    /// Sets the Tuneshine's brightness, coalescing a fast knob turn into one request every so often.
    func setTuneshineBrightness(_ percent: Int) {
        tuneshineBrightness = percent
        brightnessWrite?.cancel()
        let display = TuneshineDisplay(host: effectiveTuneshineHost ?? "")
        let work = DispatchWorkItem { Task { try? await display.setBrightness(percent) } }
        brightnessWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// How far through the current track (0–1), when its start and length are known.
    func nowPlayingProgress(at now: Date) -> Double? {
        guard let track = shownTrack, let play = scrobbles.play, play.track.isSameSong(as: track),
              let duration = track.duration, duration > 0 else { return nil }
        return max(now.timeIntervalSince(play.startedAt) / duration, 0)
    }

    // MARK: Menu bar meter

    /// Moves the menu bar meter at most one tick per clock tick (every 0.5s), so it pulses like neon rather
    /// than twitching like a real meter.
    private func stepIconLevel(at now: Date) {
        let playing = activePlayer != nil || machine.state == .playing
        guard animateMenuBarIcon, playing else {
            if iconLevel != nil { iconLevel = nil }
            return
        }
        let top = Double(MenuBarIcon.levels - 1)
        let target: Int
        if micSuspended {
            // Mic is off (a player reports the track): a slow made-up rhythm instead.
            let t = now.timeIntervalSince1970
            let v = 0.55 + 0.22 * sin(t * 0.7) + 0.14 * sin(t * 1.9 + 1) + 0.09 * sin(t * 4.3 + 2)
            target = Int((min(max(v, 0), 1) * top).rounded())
        } else {
            // From just above the silence threshold to 30 dB over it.
            let v = (smoothedLevelDB - thresholdDB) / 30
            target = Int((min(max(v, 0), 1) * top).rounded())
        }
        let current = iconLevel ?? Int(top / 2)
        iconLevel = current + (target > current ? 1 : target < current ? -1 : 0)
    }

    // MARK: Spotify / Apple Music

    private func playerChanged() {
        defer { updateControllablePlayer() }
        let enabled = players.latest.values.filter {
            $0.isPlaying && ($0.source == .appleMusic ? useAppleMusic : useSpotify)
        }
        let playing = enabled.max { $0.receivedAt < $1.receivedAt }
        let wasActive = activePlayer != nil
        activePlayer = playing

        guard let playing else {
            if wasActive {
                clearAfterQuietSince = Date()
                note("Player stopped; mic back on for Shazam")
            }
            updateCapture()
            return
        }
        clearAfterQuietSince = nil
        if autoPaused { wake("\(playing.source.rawValue) started playing") }
        if !wasActive { note("Using \(playing.source.rawValue) instead of Shazam; mic off") }
        updateCapture()
        if let shown = machine.displayed, shown.isSameSong(as: playing.track) { return }

        machine.displayedExternally(playing.track)
        guard playing.track.artworkURL != nil else {
            note("\(playing.source.rawValue): \(playing.track.displayName) (no artwork found, display unchanged)")
            return
        }
        if canPush(at: Date()) {
            push(playing.track)
        } else {
            deferredPush = playing.track
            note("\(playing.track.displayName) on \(playing.source.rawValue), but the turntable Mac has the display")
        }
    }

    // MARK: Status checks

    func checkTuneshine() async {
        guard let host = effectiveTuneshineHost else {
            tuneshineHealth = .unreachable("No Tuneshine found on the network yet")
            return
        }
        checkingTuneshine = true
        let health = await TuneshineDisplay(host: host).health()
        checkingTuneshine = false
        if health != tuneshineHealth {
            switch health {
            case .ok(let name, let firmware): note("Tuneshine \(name) reachable (firmware \(firmware))")
            case .localNetworkDenied: note("macOS is blocking ThUNER from the local network (Privacy & Security → Local Network)")
            case .unreachable(let reason): note("Tuneshine unreachable: \(reason)")
            }
        }
        tuneshineHealth = health
        if case .ok = health { tuneshineBrightness = await TuneshineDisplay(host: host).brightness() }
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Last.fm

    func setLastFMCredentials(apiKey: String, secret: String) {
        let credentials = LastFM.Credentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            await lastFM.setCredentials(credentials)
            await refreshLastFMStatus()
        }
    }

    /// Opens Last.fm in the browser to approve Thuner; then call `finishLastFMConnect()`.
    func beginLastFMConnect() {
        Task {
            do {
                let url = try await lastFM.beginAuth()
                lastFMAwaitingApproval = true
                lastFMError = nil
                NSWorkspace.shared.open(url)
            } catch {
                lastFMError = error.localizedDescription
            }
        }
    }

    func finishLastFMConnect() {
        Task {
            do {
                let session = try await lastFM.finishAuth()
                lastFMAwaitingApproval = false
                lastFMError = nil
                note("Connected to Last.fm as \(session.username)")
            } catch {
                lastFMError = "\(error.localizedDescription). Approve ThUNER on the Last.fm page first."
            }
            await refreshLastFMStatus()
            catchUpScrobbling()
        }
    }

    func disconnectLastFM() {
        Task {
            await lastFM.disconnect()
            await refreshLastFMStatus()
        }
    }

    private func refreshLastFMStatus() async {
        lastFMUser = await lastFM.session?.username
        lastFMHasCredentials = await lastFM.credentials != nil
        lastFMPending = await lastFM.pendingCount
        await refreshScrobbleStatus()
    }

    // MARK: Scrobbling (all services)

    /// Every service that's connected and switched on.
    private func activeScrobbleServices() async -> [any ScrobbleService] {
        var services: [any ScrobbleService] = []
        if await lastFM.isConnected { services.append(lastFM) }
        for config in listenBrainzConfigs where config.enabled {
            if let service = listenBrainzServices[config.id], await service.isConnected { services.append(service) }
        }
        return services
    }

    private func refreshScrobbleStatus() async {
        var pending: [String: Int] = [:]
        pending[lastFM.id] = await lastFM.pendingCount
        for (id, service) in listenBrainzServices { pending[id.uuidString] = await service.pendingCount }
        pendingScrobbles = pending
        hasScrobbleService = !(await activeScrobbleServices()).isEmpty
    }

    /// Scrobbling was just turned on or a service connected: send "now playing" for the current track, plus
    /// its scrobble if that already came due.
    private func catchUpScrobbling() {
        let now = Date()
        guard let play = scrobbles.play else { return }
        let missed = missedScrobble
        handleScrobble(.nowPlaying(play.track), at: now)
        if let missed, case .scrobble(let track, _) = missed, track.isSameSong(as: play.track) {
            handleScrobble(missed, at: now)
        } else if play.scrobbled {
            // Already scrobbled to the services that were connected then; send it to any that weren't. Services
            // that have it are skipped by the per-service history check.
            handleScrobble(.scrobble(play.track, startedAt: play.startedAt), at: now)
        }
    }

    private func handleScrobble(_ action: ScrobbleTracker.Action, at now: Date) {
        if case .nowPlaying = action { missedScrobble = nil }
        // Radio mode: plays still go in the history, but nothing goes to the services, not even now playing.
        guard !radioMode else { return }
        guard scrobblingEnabled, hasScrobbleService else {
            if case .scrobble = action { missedScrobble = action }
            return
        }
        // The secondary Mac's mic can hear the turntable, so it stays quiet while the turntable Mac is active.
        // Plays reported by Spotify/Music on this Mac are real regardless.
        guard activePlayer != nil || canPush(at: now) else { return }
        switch action {
        case .nowPlaying(let track):
            Task {
                // Services can't take "now playing" back once it's set (it lingers for about the track's
                // length), so only send it once the track has kept playing for a bit. A quick play/pause blip,
                // or a track skipped straight past, never shows up.
                try? await Task.sleep(for: .seconds(10))
                guard let play = scrobbles.play, play.track.isSameSong(as: track),
                      activePlayer != nil || machine.state == .playing else { return }
                for service in await activeScrobbleServices() {
                    do {
                        try await service.updateNowPlaying(track)
                    } catch {
                        note("\(await service.displayName) now playing failed: \(error.localizedDescription)")
                    }
                }
                await refreshLastFMStatus()
            }
        case .scrobble(let track, let startedAt):
            let entryID = history.entry(for: track, startedAt: startedAt)?.id
            Task {
                var sentTo: [String] = []
                for service in await activeScrobbleServices() {
                    let name = await service.displayName
                    if history.alreadyScrobbled(track, startedAt: startedAt, service: service.id) {
                        note("Not scrobbling \(track.displayName) to \(name): already sent this play")
                        continue
                    }
                    if skipDuplicateScrobbles,
                       let recent = try? await service.recentScrobbles(from: startedAt.addingTimeInterval(-1800), to: Date().addingTimeInterval(60)),
                       let duplicate = RemoteScrobble.duplicate(of: track, startedAt: startedAt, in: recent) {
                        let time = duplicate.date.formatted(date: .omitted, time: .shortened)
                        note("Not scrobbling \(track.displayName) to \(name): already there at \(time)")
                        setScrobble(.skippedDuplicate("Already on \(name) at \(time)"), service: service.id, entryID)
                        continue
                    }
                    do {
                        try await service.scrobble(track, startedAt: startedAt)
                        setScrobble(.scrobbled, service: service.id, entryID)
                        sentTo.append(name)
                    } catch {
                        setScrobble(.queued, service: service.id, entryID)
                        note("\(name): scrobble queued for later (\(error.localizedDescription))")
                    }
                }
                if !sentTo.isEmpty { note("Scrobbled \(track.displayName) to \(sentTo.joined(separator: ", "))") }
                await refreshLastFMStatus()
            }
        }
    }

    private func setScrobble(_ status: PlayHistory.ScrobbleStatus, service: String, _ id: UUID?) {
        guard let id else { return }
        history.setScrobble(status, service: service, for: id)
        saveHistory()
    }

    // MARK: ListenBrainz-style services

    /// Detects the server type (if not given), checks the token, and saves the service.
    func addListenBrainzService(name: String, kind: ListenBrainzService.Config.Kind?, serverURL: String, token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var detected = kind
        if detected == nil { detected = await ListenBrainzService.detectKind(serverURL: serverURL) }
        var config = ListenBrainzService.Config(
            name: name.isEmpty ? (detected ?? .other).rawValue : name,
            kind: detected ?? .other,
            serverURL: serverURL)
        config.username = try await ListenBrainzService.validate(config, token: token)
        Keychain.write(token, account: ListenBrainzService.tokenAccount(config.id))
        listenBrainzConfigs.append(config)
        listenBrainzServices[config.id] = ListenBrainzService(config: config)
        saveListenBrainzConfigs()
        note("Connected to \(config.name)\(config.username.map { " as \($0)" } ?? "")")
        await refreshScrobbleStatus()
        catchUpScrobbling()
    }

    func removeListenBrainzService(_ id: UUID) {
        listenBrainzConfigs.removeAll { $0.id == id }
        listenBrainzServices[id] = nil
        Keychain.delete(account: ListenBrainzService.tokenAccount(id))
        saveListenBrainzConfigs()
        Task { await refreshScrobbleStatus() }
    }

    func setListenBrainzService(_ id: UUID, enabled: Bool) {
        guard let i = listenBrainzConfigs.firstIndex(where: { $0.id == id }) else { return }
        listenBrainzConfigs[i].enabled = enabled
        let config = listenBrainzConfigs[i]
        saveListenBrainzConfigs()
        Task {
            await listenBrainzServices[id]?.update(config)
            await refreshScrobbleStatus()
            if enabled { catchUpScrobbling() }
        }
    }

    /// "Last.fm", or a ListenBrainz-style service's name, for a history entry's service id.
    func scrobbleServiceName(_ id: String) -> String {
        if id == lastFM.id { return "Last.fm" }
        return listenBrainzConfigs.first { $0.id.uuidString == id }?.name ?? "Removed service"
    }

    private func saveListenBrainzConfigs() {
        if let data = try? JSONEncoder().encode(listenBrainzConfigs) { defaults.set(data, forKey: "listenBrainzServices") }
    }

    // MARK: History

    nonisolated private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thuner/history.json")
    }

    /// Serial, so saves land in the order they were made and an older snapshot never overwrites a newer one.
    nonisolated private static let historyQueue = DispatchQueue(label: "com.idallas.thuner.history", qos: .utility)

    private func saveHistory() {
        let snapshot = history
        Self.historyQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    private func flushScrobbles() async {
        for service in await activeScrobbleServices() where await service.pendingCount > 0 {
            do {
                try await service.flush()
            } catch {
                let name = await service.displayName
                logger.notice("\(name, privacy: .public) flush failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await refreshLastFMStatus()
    }

    private func perform(_ actions: [NowPlayingMachine.Action]) {
        for action in actions {
            switch action {
            case .query:
                runQuery()
            case .push(let track):
                if activePlayer != nil { break }
                if canPush(at: Date()) {
                    push(track)
                } else {
                    deferredPush = track
                    note("Confirmed \(track.displayName), but the turntable Mac has the display")
                }
            case .showIdleImage:
                guard activePlayer == nil, canPush(at: Date()) else { break }
                note("Long silence; clearing the Tuneshine")
                clearDisplay()
            }
        }
    }

    private func runQuery() {
        guard let samples = capture.ring.latest(seconds: machine.timing.sampleDuration) else {
            // Not enough audio buffered yet (capture just restarted); treat as a miss and try again shortly.
            perform(machine.handle(.noMatch, at: Date()))
            return
        }
        Task {
            let outcome = await matcher.match(samples: samples, sampleRate: capture.ring.sampleRate)
            switch outcome {
            case .match(let m):
                shazamStatus = .ok
                let length = m.track.duration.map { " of \(Self.format($0))" } ?? ""
                note("Match: \(m.track.displayName) at \(Self.format(m.offset))\(length)")
            case .noMatch:
                shazamStatus = .ok
                note("No match")
            case .error(let message):
                // ShazamCore error 102: the ShazamKit App Service isn't enabled for this bundle ID.
                if message.contains("error 102") { shazamStatus = .serviceNotEnabled }
                note("Match error: \(message)")
            }
            perform(machine.handle(outcome, at: Date()))
        }
    }

    /// Remembers what the Tuneshine has confirmed it's showing, so it can be shown again after a relaunch.
    private func saveConfirmedDisplay(_ track: Track?) {
        if let track, let data = try? JSONEncoder().encode(track) {
            defaults.set(data, forKey: "lastDisplayed")
        } else {
            defaults.removeObject(forKey: "lastDisplayed")
        }
    }

    private func push(_ track: Track, attempt: Int = 1) {
        pushRetry = nil
        clearRetry = nil
        note("Showing \(track.displayName)")
        if role == .primary {
            lastHeartbeat = Date()
            peers.send(.push, role: role.rawValue, nowPlaying: track)
        }
        let display = display
        Task {
            do {
                try await display.show(track)
                saveConfirmedDisplay(track)
            } catch {
                // Only retry if this is still what should be showing (a newer push supersedes it).
                if attempt < 3, let shown = machine.displayed, shown.isSameSong(as: track) {
                    note("Tuneshine push failed (\(error.localizedDescription)); retrying in 20s")
                    pushRetry = (track, attempt + 1, Date().addingTimeInterval(20))
                } else {
                    note("Tuneshine push failed: \(error.localizedDescription)")
                }
                await checkTuneshine()
            }
        }
    }

    private func received(_ message: PeerLink.Message) {
        guard message.role == PushArbiter.Role.primary.rawValue else { return }
        lastPrimaryPeer = message.host
        let hadControl = peerHasControl
        switch message.event {
        case .idle:
            arbiter.primaryWentIdle()
            remote = nil
            overridingPeer = false
            if hadControl { note("\(message.host) went quiet; listening here again") }
        case .active, .push:
            arbiter.primaryWasActive(at: Date())
            remote = RemoteNowPlaying(host: message.host, track: message.nowPlaying, updatedAt: Date())
            // The turntable Mac's plays go in this Mac's history too (it scrobbles them itself, if it does).
            // Repeats of the same play (every heartbeat carries it) just update its row.
            if let track = message.nowPlaying {
                let before = history
                history.record(track, startedAt: Date(), source: .anotherMac, host: message.host)
                if history != before { saveHistory() }
            }
            if !hadControl, peerHasControl { note("\(message.host) is playing; pausing here") }
            if message.event == .push { note("\(message.host) is showing \(message.track ?? "a track")") }
        }
        updateCapture()
    }

    // MARK: Helpers

    /// Whether music is playing right now, for the floating cover: a player is playing, or the mic hears
    /// audio and there's a cover up for it.
    private var musicIsPlaying: Bool {
        activePlayer != nil || (machine.state != .idle && machine.displayed != nil)
            || (peerHasControl && remote?.track != nil)
    }

    private func updateFloatingCoverDimming(at now: Date) {
        if let track = shownTrack, track != lastShownTrack { lastShownTrack = track }
        // A paused player counts as something to come back to: its play button stays at full strength.
        let active = musicIsPlaying || controllablePlayer != nil
        if active { coverQuietSince = nil } else if coverQuietSince == nil { coverQuietSince = now }
        let dimmed = floatingCoverDims && coverQuietSince.map { now.timeIntervalSince($0) >= Self.coverDimAfter } == true
        if dimmed != floatingCoverDimmed { floatingCoverDimmed = dimmed }
    }

    private func applyFloatingCover() {
        if showFloatingCover {
            if floatingCover == nil { floatingCover = FloatingCoverController(model: self) }
            floatingCover?.show()
        } else {
            floatingCover?.hide()
        }
    }

    private func applyTiming() {
        machine.timing.idleImageDelay = idleImageMinutes > 0 ? idleImageMinutes * 60 : nil
    }

    private func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        log.insert(LogEntry(date: Date(), text: text), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension UserDefaults {
    /// For watching the key: `defaults write` from another process shows up here too.
    @objc dynamic var streamPassword: String? { string(forKey: "streamPassword") }
}
