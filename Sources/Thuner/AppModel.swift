import AVFoundation
import AppKit
import Foundation
import Observation
import ServiceManagement
import ThunerCore
import os

/// Ties capture, the level gate, the state machine, matching, peer coordination and the display together.
/// Everything here runs on the main actor; audio arrives from the tap thread and is hopped over.
@MainActor @Observable
final class AppModel {
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
    private(set) var otherThuners: [String] = []
    /// Microphone permission granted (refreshed after asking).
    private(set) var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @ObservationIgnored private var networkStarted = false

    /// Offer ThUNER's controls to Twist Commando over App Link.
    var twistCommandoEnabled: Bool {
        didSet {
            save(twistCommandoEnabled, "twistCommandoEnabled")
            twistCommandoEnabled ? appLink.start() : appLink.stop()
        }
    }
    /// Twist Commando's version while App Link is connected.
    private(set) var twistCommandoVersion: String?
    /// The Tuneshine's brightness (1–100), when known.
    private(set) var tuneshineBrightness: Int?
    @ObservationIgnored private var brightnessWrite: DispatchWorkItem?
    @ObservationIgnored private lazy var appLink = makeAppLink()

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
        if peerHasControl { return .elsewhere(playing: remote?.track != nil) }
        if pausedManually || autoPaused { return .idle }
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
    var floatingCoverOnlyWhilePlaying: Bool {
        didSet { save(floatingCoverOnlyWhilePlaying, "floatingCoverOnlyWhilePlaying"); applyFloatingCover() }
    }

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
    /// Listening paused by hand, from the menu.
    var pausedManually = false {
        didSet {
            guard pausedManually != oldValue else { return }
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
        var recent = recentAudioApps
        for pid in AudioDevices.processesPlayingAudio() {
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
                let playing = AudioDevices.processesPlayingAudio()
                alreadyPlaying.formIntersection(playing)  // stopped, so starting again would count
                startedPlaying = startedPlaying.filter { playing.contains($0.key) }
                for pid in playing.subtracting(alreadyPlaying) where startedPlaying[pid] == nil { startedPlaying[pid] = now }
                if let (pid, _) = startedPlaying.first(where: { now.timeIntervalSince($0.value) >= 5 }) {
                    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
                    wake("\(name) started playing")
                }
            }
            return
        }
        guard autoPauseMinutes > 0, micOffReason == nil,
              now.timeIntervalSince(lastActivity) >= autoPauseMinutes * 60 else { return }
        autoPaused = true
        alreadyPlaying = AudioDevices.processesPlayingAudio()
        startedPlaying = [:]
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
        floatingCoverOnlyWhilePlaying = d.object(forKey: "floatingCoverOnlyWhilePlaying") as? Bool ?? true
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
        peers.onPeersChanged = { [weak self] hosts in
            MainActor.assumeIsolated { self?.otherThuners = hosts }
        }

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
        if twistCommandoEnabled { appLink.start() }
        peers.start()
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
                                         systemAudioApps: Set(systemAudioApps.map(\.bundleID)))
        do {
            try capture.start(config)
            captureError = nil
            captureNotice = nil
            note("Listening to \(usingSystemAudio ? systemAudioLabel : capture.activeDeviceName ?? "default input")")
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
        perform(machine.audioStopped(at: Date()))
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
        switch gate.feed(levelDB: db, at: now) {
        case .opened:
            note("Audio detected")
            if role == .primary {
                lastHeartbeat = now
                peers.send(.active, role: role.rawValue, nowPlaying: nil)
            }
            perform(machine.audioStarted(at: now))
        case .closed:
            note("Silence")
            if role == .primary, activePlayer == nil { peers.send(.idle, role: role.rawValue, nowPlaying: nil) }
            deferredPush = nil
            perform(machine.audioStopped(at: now))
        case nil:
            break
        }
    }

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
        updateCapture()
        updater.installPendingUpdateIfQuiet(isQuiet: activePlayer == nil && machine.state == .idle)
        if showFloatingCover, floatingCoverOnlyWhilePlaying, (floatingCover?.isVisible ?? false) != musicIsPlaying {
            applyFloatingCover()
        }
        stepIconLevel(at: now)
        if webDisplayEnabled { webDisplay.update(webNowPlaying) }
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
        return now
    }

    // MARK: Controls (App Link, HTTP API)

    /// ThUNER's controls, shared by every adapter (Twist Commando's App Link, the HTTP API).
    @ObservationIgnored private(set) lazy var controls = ControlSurface(model: self)

    private func makeAppLink() -> AppLinkClient {
        let link = AppLinkClient(controls: controls.definitions.map { definition in
            let kind: AppLinkClient.Kind = switch definition.kind {
            case .level: .level
            case .toggle: .toggle
            case .button: .button
            }
            return AppLinkClient.Control(id: definition.id, name: definition.name, kind: kind, group: definition.group)
        })
        link.onTurn = { [weak self] id, value, _ in
            if let value { self?.controls.turn(id, to: value) }
        }
        link.onPress = { [weak self] id, down in
            if down { self?.controls.press(id) }
        }
        link.onConnectionChange = { [weak self] version in
            self?.twistCommandoVersion = version
            if version != nil { self?.note("Connected to Twist Commando") }
        }
        controls.refresh()
        for (id, state) in controls.states { link.set(id, value: state.value, text: state.text, on: state.on) }
        controls.observers.append { [weak link] id, state in
            link?.set(id, value: state.value, text: state.text, on: state.on)
        }
        return link
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

    private func applyFloatingCover() {
        if showFloatingCover, !floatingCoverOnlyWhilePlaying || musicIsPlaying {
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
