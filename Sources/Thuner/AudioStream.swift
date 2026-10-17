import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Synchronization
import ThunerCore
import os

/// Sharing this Mac's input with other ThUNERs, as a stream of uncompressed packets over UDP.
///
/// Nothing is sent until another ThUNER subscribes (and keeps subscribing, once a second). Like `PeerLink`, only
/// ThUNERs found over Bonjour (or this Mac itself) may subscribe, so nothing else on the network can ask for the
/// audio. The capture thread hands packets over through the packetizer's queue; a dedicated thread sends them.
final class AudioStreamSender: StreamSink, @unchecked Sendable {
    struct Listener {
        var address: sockaddr_in
        var host: String
        var method: StreamMethod
        var lastSeen: Date
        /// Packets it may still ask to have resent this second.
        var resendBudget = Self.resendsPerSecond
        var budgetSince = Date()
        static let resendsPerSecond = 200
    }
    /// At most this many Macs listening at once (each is a full stream: ~2.4 Mbit/s).
    static let maxListeners = 4

    /// Whether to share at all; when off, subscribers are told so and get nothing. Main thread.
    var sharing = false {
        didSet { if !sharing { listeners.removeAll(); listenersChanged() } }
    }
    /// The input has been silent a while: stop sending audio until it isn't (listeners close their outputs).
    /// Main thread.
    var idle = false {
        didSet {
            guard idle != oldValue else { return }
            shared.withLock { $0.idle = idle }
            log.notice("\(self.idle ? "Input silent; pausing the stream" : "Input back; resuming the stream", privacy: .public)")
        }
    }
    /// Decides whether an address belongs to another ThUNER (found over Bonjour). Main thread.
    var isKnownPeer: ((in_addr) -> Bool)?
    /// Called on the main queue with the host names of the Macs listening.
    var onListenersChanged: (([String]) -> Void)?

    private struct Shared {
        var packetizer: Packetizer?
        var source: String?
        var latencyFrames = 0
        var idle = false
        var targets: [sockaddr_in] = []
        /// Packets listeners asked for again, for the sending thread.
        var resends: [(address: sockaddr_in, sequences: [UInt32])] = []
    }
    /// What was sent lately, for resending. Only the sending thread touches it.
    private let history = PacketHistory()
    let levels = PeakLevels()
    private var lastLevels = 0.0
    private let shared = Mutex(Shared())
    private let ready = DispatchSemaphore(value: 0)
    private var listeners: [String: Listener] = [:]
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var expiry: Timer?
    private var lastLog = Date.distantPast
    private var lastIgnoredLog = Date.distantPast

    /// Another Mac's name, as it gave it: shown and logged, so kept short and printable.
    private static func displayable(_ host: String) -> String {
        String(String.UnicodeScalarView(host.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(63)))
    }
    private let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let log = Logger(subsystem: "com.idallas.thuner", category: "stream")

    func start() {
        guard fd < 0 else { return }
        fd = UDP.socket(port: StreamWire.port)
        guard fd >= 0 else {
            log.error("Couldn't open the stream port \(StreamWire.port)")
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.receiveControl() } }
        source.resume()
        self.source = source
        expiry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireListeners() }
        }
        let thread = Thread { [weak self] in self?.sendLoop() }
        thread.name = "ThUNER stream sender"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: StreamSink (capture threads)

    func attach(_ packetizer: Packetizer?, source: String?, latencyFrames: Int) {
        shared.withLock {
            $0.packetizer = packetizer
            $0.source = source
            $0.latencyFrames = latencyFrames
        }
        ready.signal()
    }

    func packetsReady() { ready.signal() }

    private func sendLoop() {
        let fd = self.fd
        while true {
            ready.wait()
            let (packetizer, targets, idle, resends) = shared.withLock { state in
                defer { state.resends.removeAll(keepingCapacity: true) }
                return (state.packetizer, state.targets, state.idle, state.resends)
            }
            guard let packetizer else { continue }
            // Always drain, even with nobody listening (or nothing to hear), so sending resumes with fresh audio.
            while packetizer.packets.pop({ bytes in
                guard !idle else { return }
                history.store(bytes)
                for target in targets { Self.send(fd, bytes, to: target) }
            }) {}
            for request in resends {
                for sequence in request.sequences {
                    history.resend(sequence) { Self.send(fd, $0, to: request.address) }
                }
            }
            // The input's levels for meters on the other side, idle or not (the capture keeps waking this thread).
            let now = HostClock.now()
            if now - lastLevels >= 0.05, !targets.isEmpty {
                lastLevels = now
                let peak = levels.take()
                let message = StreamWire.control(.levels, StreamWire.Levels(left: peak.left.rounded(), right: peak.right.rounded()))
                message.withUnsafeBytes { bytes in for target in targets { Self.send(fd, bytes, to: target) } }
            }
        }
    }

    private static func send(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, to address: sockaddr_in) {
        var address = address
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: Control (main thread)

    @MainActor private func receiveControl() {
        guard let (data, sender) = UDP.receive(fd) else { return }
        data.withUnsafeBytes { bytes in
            guard let kind = StreamWire.kind(of: bytes) else { return }
            // One listener per Mac: keyed by address alone, so one Mac can't open a stream per port.
            let key = UDP.string(sender.sin_addr)
            // Everything here is only for ThUNERs found over Bonjour (or this Mac).
            guard UDP.isLoopback(sender.sin_addr) || isKnownPeer?(sender.sin_addr) == true else {
                if Date().timeIntervalSince(lastIgnoredLog) > 10 {
                    lastIgnoredLog = Date()
                    log.notice("Ignoring stream messages from \(key, privacy: .public): not a ThUNER found over Bonjour")
                }
                return
            }
            switch kind {
            case .subscribe:
                guard var request = StreamWire.controlBody(StreamWire.Subscribe.self, from: bytes) else { return }
                request.host = Self.displayable(request.host)
                let (packetizer, input, latency) = shared.withLock { ($0.packetizer, $0.source, $0.latencyFrames) }
                let live = sharing && packetizer != nil
                if live, listeners[key] != nil || listeners.count < Self.maxListeners {
                    if var listener = listeners[key] {
                        // The same Mac (its port changes if its ThUNER restarted).
                        let moved = UDP.string(listener.address) != UDP.string(sender)
                        listener.address = sender
                        listener.host = request.host
                        listener.method = request.method
                        listener.lastSeen = Date()
                        listeners[key] = listener
                        if moved { listenersChanged() }
                    } else {
                        log.notice("\(request.host, privacy: .public) (\(key, privacy: .public)) started listening (\(request.method.rawValue, privacy: .public))")
                        listeners[key] = Listener(address: sender, host: request.host, method: request.method, lastSeen: Date())
                        listenersChanged()
                    }
                }
                let status = StreamWire.Status(host: host, sharing: live, source: live ? input : nil,
                                               sampleRate: packetizer.map { Double($0.sampleRate) },
                                               framesPerPacket: packetizer?.framesPerPacket,
                                               captureLatencyFrames: live ? latency : nil, echo: request.sentAt,
                                               idle: live ? idle : nil)
                UDP.send(fd, StreamWire.control(.status, status), to: sender)
            case .unsubscribe:
                if let gone = listeners.removeValue(forKey: key) {
                    log.notice("\(gone.host, privacy: .public) stopped listening")
                    listenersChanged()
                }
            case .resend:
                // Only for someone already listening, each packet once, and no more than a lossy network needs.
                guard var listener = listeners[key], let request = StreamWire.controlBody(StreamWire.Resend.self, from: bytes) else { return }
                if Date().timeIntervalSince(listener.budgetSince) >= 1 {
                    listener.resendBudget = Listener.resendsPerSecond
                    listener.budgetSince = Date()
                }
                var seen = Set<UInt32>()
                let sequences = Array(request.sequences.prefix(64).filter { seen.insert($0).inserted }.prefix(listener.resendBudget))
                listener.resendBudget -= sequences.count
                listeners[key] = listener
                guard !sequences.isEmpty else { return }
                shared.withLock { $0.resends.append((listener.address, sequences)) }
                ready.signal()
            case .audio, .resentAudio, .status, .levels:
                break
            }
        }
    }

    @MainActor private func expireListeners() {
        if let packetizer = shared.withLock({ $0.packetizer }), !listeners.isEmpty,
           Date().timeIntervalSince(lastLog) >= 10 {
            lastLog = Date()
            log.notice("Sending: largest capture buffer \(packetizer.takeLargestAppend()) frames, \(packetizer.overflows) packets dropped, \(packetizer.discontinuities) input skips")
        }
        let stale = listeners.filter { Date().timeIntervalSince($0.value.lastSeen) > 4 }
        guard !stale.isEmpty else { return }
        for (key, listener) in stale {
            log.notice("Lost \(listener.host, privacy: .public)")
            listeners[key] = nil
        }
        listenersChanged()
    }

    private func listenersChanged() {
        let targets = Array(listeners.values.map(\.address))
        shared.withLock { $0.targets = targets }
        onListenersChanged?(listeners.values.map(\.host).sorted())
    }
}

/// Listening to another ThUNER's stream: subscribes once a second, takes packets in on a network thread, and plays
/// them into a pair of an output device's channels with one of the playout methods.
final class AudioStreamReceiver: @unchecked Sendable {
    struct Settings: Equatable {
        var method: StreamMethod
        /// Raw: extra buffer beyond one output buffer. Resilient: the least extra buffer to keep.
        var marginMs: Double
        /// Nil for the system's default output.
        var outputUID: String?
        /// Zero-based first channel of the output pair.
        var outputChannel = 0
        /// Testing: throw away this share of first-time audio packets, as if the network lost them
        /// (`defaults write com.idallas.thuner streamDebugLossPercent 2`).
        var debugLoss = UserDefaults.standard.double(forKey: "streamDebugLossPercent") / 100
        var ioBufferFrames = 128
    }

    let settings: Settings
    let sourceHost: String
    /// What the sender said about itself. Main thread.
    private(set) var status: StreamWire.Status?
    /// Called on the main queue when `status` changes or playback fails.
    var onChange: (() -> Void)?
    private(set) var error: String?

    private let sourceAddress: sockaddr_in
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var subscribeTimer: Timer?
    private let packets = SPSCRing(slotSize: 8 + StreamWire.maxDatagram, capacity: 512)
    /// Created at the first packet (it needs the sample rate); then only touched on the render thread.
    private var playout: Playout?
    /// The stream rate the output was started for (0: no output), read on the network thread to spot a change
    /// or audio coming back after the output was released.
    private let engineRate = Atomic<UInt32>(0)
    /// When the last datagram from the sender arrived (a Double's bits).
    private let lastAudio = Atomic<UInt64>(0)
    /// Peak levels for meters: the sender's input as it measured it (the loudest since last read, and when it last
    /// said), and what this Mac played.
    private let sourceLevels = Mutex<(levels: (left: Double, right: Double), at: Double, fresh: Bool)?>(nil)
    private let received = PeakLevels()

    struct Levels {
        /// The sender's input since the last call; nil if it hasn't said anything new.
        var source: (left: Double, right: Double)?
        /// Whether the sender has said anything lately (it's gone, or an older ThUNER, if not).
        var sourceAlive: Bool
        /// What played here since the last call; nil if nothing did (the output's closed, or between buffers).
        var received: (left: Double, right: Double)?
    }

    /// Peaks since the last call, in dBFS.
    func takeLevels() -> Levels {
        let (source, alive) = sourceLevels.withLock { current -> ((left: Double, right: Double)?, Bool) in
            guard let latest = current else { return (nil, false) }
            let alive = HostClock.now() - latest.at < 1
            guard latest.fresh else { return (nil, alive) }
            current?.fresh = false
            return (latest.levels, alive)
        }
        return Levels(source: source, sourceAlive: alive, received: received.takeIfFresh())
    }

    /// Network thread only: which packets belong to the stream being played.
    private var gate = StreamGate()
    /// Resilient only: asking for lost packets again. Network thread only.
    private var resendTracker = ResendTracker()
    private let resendCounts = Mutex((requested: 0, recovered: 0, abandoned: 0))
    /// Lost packets asked for again, how many came back, and how many were given up on.
    var resendStats: (requested: Int, recovered: Int, abandoned: Int) { resendCounts.withLock { $0 } }

    /// Nothing has come for a couple of seconds (the sender's input went silent, or it stopped): close the output
    /// device rather than hold it open playing silence. The next packet opens it again.
    @MainActor private func releaseOutputIfQuiet() {
        guard output != nil, HostClock.now() - Double(bitPattern: lastAudio.load(ordering: .relaxed)) > 2 else { return }
        stopOutput()
        playout = nil
        engineRate.store(0, ordering: .relaxed)
        log.notice("Stream quiet; released the output")
        logAudioActivity()
        onChange?()
    }

    /// When opening the output last failed (unplugged, or it kept changing).
    private var outputFailedAt: Date?

    /// The output couldn't be opened but audio is coming: try again every few seconds (the interface may be back).
    @MainActor private func retryOutputIfFailed() {
        guard output == nil, let failed = outputFailedAt, Date().timeIntervalSince(failed) >= 5,
              HostClock.now() - Double(bitPattern: lastAudio.load(ordering: .relaxed)) < 2 else { return }
        outputFailedAt = nil
        log.notice("Trying the stream output again")
        startOutput(sampleRate: streamRate)
    }

    /// Subscribed and the sender is sharing, but nothing's playing, so the output is closed. Main thread.
    @MainActor var isQuiet: Bool { fd >= 0 && output == nil && error == nil && status?.sharing == true }
    private let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let network = DispatchQueue(label: "com.idallas.thuner.stream-receive", qos: .userInteractive)
    private let log = Logger(subsystem: "com.idallas.thuner", category: "stream")

    init(source: sockaddr_in, host: String, settings: Settings) {
        sourceAddress = source
        sourceHost = host
        self.settings = settings
    }

    var stats: PlayoutStats? { playout?.stats }

    @MainActor func start() {
        fd = UDP.socket(port: 0)
        guard fd >= 0 else {
            error = "Couldn't open a network socket"
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: network)
        let socket = fd
        source.setEventHandler { [weak self] in self?.receive(socket) }
        source.setCancelHandler { close(socket) }
        source.resume()
        self.source = source
        subscribe()
        subscribeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.subscribe() }
        }
        log.notice("Listening to \(self.sourceHost, privacy: .public) (\(self.settings.method.rawValue, privacy: .public))")
    }

    @MainActor func stop() {
        subscribeTimer?.invalidate()
        subscribeTimer = nil
        if fd >= 0 { UDP.send(fd, StreamWire.control(.unsubscribe, StreamWire.Subscribe(host: host, method: settings.method)), to: sourceAddress) }
        source?.cancel()  // closes the socket once no handler is running
        source = nil
        stopOutput()
        fd = -1
    }

    @MainActor private func subscribe() {
        releaseOutputIfQuiet()
        retryOutputIfFailed()
        UDP.send(fd, StreamWire.control(.subscribe, StreamWire.Subscribe(host: host, method: settings.method, sentAt: HostClock.now())),
                 to: sourceAddress)
    }

    /// Recent round trips to the sender, in seconds (subscribe → status). Main thread.
    private var roundTrips: [Double] = []

    /// End-to-end latency, roughly, in ms: the sender's input, the network, the buffer, this Mac's output.
    struct Latency: Equatable {
        var captureMs: Double
        var networkMs: Double
        var bufferMs: Double
        var outputMs: Double
        /// The part of the playout's buffer level that's this Mac's output buffer (counted in `outputMs`).
        var outputBufferMs: Double
        var totalMs: Double { captureMs + networkMs + bufferMs + outputMs }
    }

    @MainActor var latency: Latency? {
        guard let stats = playout?.stats, stats.playing, let output, let status else { return nil }
        let streamRate = stats.sampleRate > 0 ? stats.sampleRate : 48_000
        let outputBufferMs = Double(output.ioBufferFrames) / output.sampleRate * 1000
        return Latency(
            captureMs: Double(status.captureLatencyFrames ?? 0) / streamRate * 1000,
            // Half the quickest recent round trip (the slower ones include the sender's main thread being busy).
            networkMs: (roundTrips.min() ?? 0) / 2 * 1000,
            // The buffer level counts the output buffer being filled; Output counts that already.
            bufferMs: max(stats.bufferedMs - outputBufferMs, 0),
            outputMs: Double(output.latencyFrames) / output.sampleRate * 1000,
            outputBufferMs: outputBufferMs)
    }

    // MARK: Network thread

    private func receive(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        while true {
            let n = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &length) }
            }
            // Nothing of ours is bigger than one Ethernet frame's worth; the queue's slots aren't either.
            guard n > 0 else { return }
            guard n <= StreamWire.maxDatagram else { continue }
            let arrival = HostClock.now()
            // Only the Mac we subscribed to.
            guard sender.sin_addr.s_addr == sourceAddress.sin_addr.s_addr, sender.sin_port == sourceAddress.sin_port else { continue }
            buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                switch StreamWire.kind(of: bytes) {
                case .audio, .resentAudio:
                    // Only packets that belong to the stream being played (see StreamGate).
                    guard let header = StreamWire.audioHeader(bytes), gate.admit(header) else { return }
                    if settings.debugLoss > 0, !header.resent, Double.random(in: 0..<1) < settings.debugLoss { return }
                    lastAudio.store(arrival.bitPattern, ordering: .relaxed)
                    if settings.method == .resilient { trackLosses(header, at: arrival, socket: fd) }
                    if header.sampleRate != engineRate.load(ordering: .relaxed) {
                        engineRate.store(header.sampleRate, ordering: .relaxed)
                        let rate = Double(header.sampleRate)
                        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.startOutput(sampleRate: rate) } }
                    }
                    packets.push { slot in
                        slot.storeBytes(of: arrival, as: Double.self)
                        (slot + 8).copyMemory(from: bytes.baseAddress!, byteCount: n)
                        return 8 + n
                    }
                case .levels:
                    guard var levels = StreamWire.controlBody(StreamWire.Levels.self, from: bytes) else { return }
                    levels.left = levels.left.isFinite ? min(max(levels.left, -160), 20) : -160
                    levels.right = levels.right.isFinite ? min(max(levels.right, -160), 20) : -160
                    sourceLevels.withLock { current in
                        // Unread peaks still count: keep the loudest.
                        let previous = current?.fresh == true ? current?.levels : nil
                        current = ((max(levels.left, previous?.left ?? -160), max(levels.right, previous?.right ?? -160)), arrival, true)
                    }
                case .status:
                    var status = StreamWire.controlBody(StreamWire.Status.self, from: bytes)
                    let echo = status?.echo
                    status?.echo = nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if let echo, arrival - echo >= 0, arrival - echo < 1 {
                            self.roundTrips.append(arrival - echo)
                            if self.roundTrips.count > 10 { self.roundTrips.removeFirst() }
                            self.shareRoundTrip()
                        }
                        guard status != self.status else { return }
                        self.status = status
                        self.onChange?()
                    }
                default:
                    break
                }
            }
        }
    }

    /// Resilient keeps room for resends to arrive in time, which takes the round trip.
    @MainActor private func shareRoundTrip() {
        guard let resilient = playout as? ResilientPlayout, let quickest = roundTrips.min() else { return }
        resilient.setResendRoundTrip(quickest)
    }

    /// Asks the sender again for packets that went missing (and, a few ms later, again if they still haven't come).
    private func trackLosses(_ header: AudioPacketHeader, at now: Double, socket: Int32) {
        let missing = resendTracker.received(header.sequence, resent: header.resent, at: now) + resendTracker.due(at: now)
        if !missing.isEmpty {
            UDP.send(socket, StreamWire.control(.resend, StreamWire.Resend(sequences: missing)), to: sourceAddress)
        }
        let t = resendTracker
        resendCounts.withLock { $0 = (t.requested, t.recovered, t.abandoned) }
    }

    // MARK: Output

    /// (Re)starts playback into the chosen output for a stream at `sampleRate`.
    @MainActor private func startOutput(sampleRate: Double) {
        stopOutput()
        guard fd >= 0 else { return }
        // No output is running, so nothing else is reading the queue: drop what piled up while there wasn't one.
        while packets.pop({ _ in }) {}
        streamRate = sampleRate
        let deviceID: AudioDeviceID?
        if let uid = settings.outputUID {
            deviceID = AudioDevices.outputDevice(uid: uid)?.id
            if deviceID == nil { error = "The output isn't connected" }
        } else {
            deviceID = AudioDevices.defaultOutputDevice()
        }
        guard let deviceID, let outputRate = AudioDevices.nominalSampleRate(deviceID) else {
            if error == nil { error = "No output device" }
            outputFailedAt = Date()
            onChange?()
            return
        }

        let marginFrames = Int(settings.marginMs / 1000 * sampleRate)
        let rate = outputRate == sampleRate ? 0 : outputRate
        let playout: Playout = switch settings.method {
        case .raw: RawPlayout(targetFrames: marginFrames, outputRate: rate)
        case .resilient: ResilientPlayout(minimumFrames: marginFrames, outputRate: rate)
        }
        let scratch = Scratch()
        let packets = self.packets
        let received = self.received
        do {
            let tap = try DeviceOutputTap(device: deviceID, firstChannel: settings.outputChannel,
                                          ioBufferFrames: settings.ioBufferFrames) { left, right, frames in
                let now = HostClock.now()
                while packets.pop({ slot in
                    let arrival = slot.loadUnaligned(as: Double.self)
                    let bytes = UnsafeRawBufferPointer(rebasing: slot[8...])
                    guard let header = StreamWire.audioHeader(bytes) else { return }
                    StreamWire.readSamples(bytes, header: header, into: scratch.samples)
                    playout.receive(header, samples: scratch.samples, arrival: arrival)
                }) {}
                playout.render(left: left, right: right, frames: frames, now: now)
                received.record(left: left, right: right, frames: frames)
            }
            try tap.start()
            output = tap
            self.playout = playout
            outputFailedAt = nil
            shareRoundTrip()
            error = nil
            watch(deviceID)
            logAudioActivity()
            log.notice("Stream output started: \(sampleRate) Hz stream to \(outputRate) Hz output, channel \(self.settings.outputChannel + 1), \(self.settings.method.rawValue, privacy: .public), margin \(self.settings.marginMs) ms, I/O buffer \(tap.ioBufferFrames) frames")
        } catch {
            self.error = "Couldn't start the output: \(error.localizedDescription)"
            outputFailedAt = Date()
            log.error("Couldn't start the stream output: \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
    }

    /// Restarts the output when it changes under us: its sample rate, it going away, or (when following the
    /// system's choice) a different default output.
    @MainActor private func watch(_ device: AudioDeviceID) {
        let restart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.output != nil else { return }
                self.recentRestarts = self.recentRestarts.filter { Date().timeIntervalSince($0) < 60 }
                guard self.recentRestarts.count < 10 else {
                    // Too many in a row: let it settle, then the retry in subscribe() picks it up.
                    self.stopOutput()
                    self.playout = nil
                    self.error = "The output keeps changing; trying again shortly"
                    self.outputFailedAt = Date()
                    self.onChange?()
                    return
                }
                self.recentRestarts.append(Date())
                self.log.notice("Stream output changed; restarting")
                self.startOutput(sampleRate: self.streamRate)
            }
        }
        var watched = [
            (device, kAudioDevicePropertyNominalSampleRate),
            (device, kAudioDevicePropertyDeviceIsAlive),
        ]
        if settings.outputUID == nil { watched.append((AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)) }
        for (object, selector) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, restart) == noErr {
                listeners.append((object, address, restart))
            }
        }
    }

    /// What macOS thinks ThUNER is doing with audio (recording drives the orange indicator), once it's caught up.
    @MainActor private func logAudioActivity() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [log] in
            guard let activity = AudioDevices.ownAudioActivity() else { return }
            log.notice("Core Audio says ThUNER is recording: \(activity.input), playing: \(activity.output)")
        }
    }

    @MainActor private func stopOutput() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
        output = nil
    }

    private var output: DeviceOutputTap?
    private var streamRate = 48_000.0
    private var recentRestarts: [Date] = []
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Decoding space for the render thread, freed with the last output that uses it.
    private final class Scratch: @unchecked Sendable {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: StreamWire.maxFramesPerPacket * StreamWire.channels)
        deinit { samples.deallocate() }
    }
}

/// The host clock (mach absolute time) in seconds: what Core Audio timestamps use.
enum HostClock {
    private static let factor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(_ hostTime: UInt64) -> Double { Double(hostTime) * factor }
    static func now() -> Double { seconds(mach_absolute_time()) }
}

/// Bare UDP sockets, as `PeerLink` uses: IPv4 only (the other Macs are found over Bonjour as IPv4 addresses).
enum UDP {
    /// A UDP socket bound to `port` (0 for any), or -1.
    static func socket(port: UInt16) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // Room for bursts: a few hundred packets.
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        // Mark it as voice traffic, which Wi-Fi gives priority to.
        var tos: Int32 = 0xB8
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        var service: Int32 = NET_SERVICE_TYPE_VO
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data, to address: sockaddr_in) {
        guard fd >= 0 else { return }
        var address = address
        data.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func receive(_ fd: Int32) -> (Data, sockaddr_in)? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard n > 0, sender.sin_family == sa_family_t(AF_INET) else { return nil }
        return (Data(buffer[0..<n]), sender)
    }

    static func address(_ ip: in_addr, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = ip
        return addr
    }

    static var loopback: sockaddr_in { address(in_addr(s_addr: INADDR_LOOPBACK.bigEndian), port: StreamWire.port) }

    static func isLoopback(_ ip: in_addr) -> Bool { UInt32(bigEndian: ip.s_addr) >> 24 == 127 }

    static func string(_ ip: in_addr) -> String {
        var ip = ip
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) } ?? "?"
    }

    static func string(_ address: sockaddr_in) -> String {
        var ip = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let text = inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) } ?? "?"
        return "\(text):\(UInt16(bigEndian: address.sin_port))"
    }
}
