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
    }

    /// Whether to share at all; when off, subscribers are told so and get nothing. Main thread.
    var sharing = false {
        didSet { if !sharing { listeners.removeAll(); listenersChanged() } }
    }
    /// Decides whether an address belongs to another ThUNER (found over Bonjour). Main thread.
    var isKnownPeer: ((in_addr) -> Bool)?
    /// Called on the main queue with the host names of the Macs listening.
    var onListenersChanged: (([String]) -> Void)?

    private struct Shared {
        var packetizer: Packetizer?
        var source: String?
        var targets: [sockaddr_in] = []
    }
    private let shared = Mutex(Shared())
    private let ready = DispatchSemaphore(value: 0)
    private var listeners: [String: Listener] = [:]
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var expiry: Timer?
    private var lastLog = Date.distantPast
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

    func attach(_ packetizer: Packetizer?, source: String?) {
        shared.withLock {
            $0.packetizer = packetizer
            $0.source = source
        }
        ready.signal()
    }

    func packetsReady() { ready.signal() }

    private func sendLoop() {
        let fd = self.fd
        while true {
            ready.wait()
            let (packetizer, targets) = shared.withLock { ($0.packetizer, $0.targets) }
            guard let packetizer else { continue }
            // Always drain, even with nobody listening, so a new listener starts with fresh audio.
            while packetizer.packets.pop({ bytes in
                for var target in targets {
                    _ = withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }) {}
        }
    }

    // MARK: Control (main thread)

    @MainActor private func receiveControl() {
        guard let (data, sender) = UDP.receive(fd) else { return }
        data.withUnsafeBytes { bytes in
            guard let kind = StreamWire.kind(of: bytes) else { return }
            let key = UDP.string(sender)
            switch kind {
            case .subscribe:
                guard let request = StreamWire.controlBody(StreamWire.Subscribe.self, from: bytes) else { return }
                guard UDP.isLoopback(sender.sin_addr) || isKnownPeer?(sender.sin_addr) == true else {
                    log.notice("Ignoring a stream request from \(key, privacy: .public): not a ThUNER found over Bonjour")
                    return
                }
                let (packetizer, input) = shared.withLock { ($0.packetizer, $0.source) }
                let live = sharing && packetizer != nil
                if live {
                    if listeners[key] == nil { log.notice("\(request.host, privacy: .public) started listening (\(request.method.rawValue, privacy: .public))") }
                    let isNew = listeners[key] == nil
                    listeners[key] = Listener(address: sender, host: request.host, method: request.method, lastSeen: Date())
                    if isNew { listenersChanged() }
                }
                let status = StreamWire.Status(host: host, sharing: live, source: live ? input : nil,
                                               sampleRate: packetizer.map { Double($0.sampleRate) },
                                               framesPerPacket: packetizer?.framesPerPacket)
                UDP.send(fd, StreamWire.control(.status, status), to: sender)
            case .unsubscribe:
                if let gone = listeners.removeValue(forKey: key) {
                    log.notice("\(gone.host, privacy: .public) stopped listening")
                    listenersChanged()
                }
            case .audio, .status:
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
/// them through an output device with one of the playout methods.
final class AudioStreamReceiver: @unchecked Sendable {
    struct Settings: Equatable {
        var method: StreamMethod
        /// Raw: extra buffer beyond one output buffer. Resilient: the least extra buffer to keep.
        var marginMs: Double
        /// Nil for the system's default output.
        var outputUID: String?
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
    private var configObserver: NSObjectProtocol?
    private let packets = SPSCRing(slotSize: 8 + StreamWire.maxDatagram, capacity: 512)
    /// Created at the first packet (it needs the sample rate); then only touched on the render thread.
    private var playout: Playout?
    private var engine: AVAudioEngine?
    /// The rate the output engine was built for, read on the network thread to spot a change.
    private let engineRate = Atomic<UInt32>(0)
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
        stopEngine()
        fd = -1
    }

    @MainActor private func subscribe() {
        UDP.send(fd, StreamWire.control(.subscribe, StreamWire.Subscribe(host: host, method: settings.method)), to: sourceAddress)
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
            guard n > 0 else { return }
            let arrival = HostClock.now()
            // Only the Mac we subscribed to.
            guard sender.sin_addr.s_addr == sourceAddress.sin_addr.s_addr, sender.sin_port == sourceAddress.sin_port else { continue }
            buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                switch StreamWire.kind(of: bytes) {
                case .audio:
                    guard let header = StreamWire.audioHeader(bytes) else { return }
                    if header.sampleRate != engineRate.load(ordering: .relaxed) {
                        engineRate.store(header.sampleRate, ordering: .relaxed)
                        let rate = Double(header.sampleRate)
                        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.startEngine(sampleRate: rate) } }
                    }
                    packets.push { slot in
                        slot.storeBytes(of: arrival, as: Double.self)
                        (slot + 8).copyMemory(from: bytes.baseAddress!, byteCount: n)
                        return 8 + n
                    }
                case .status:
                    let status = StreamWire.controlBody(StreamWire.Status.self, from: bytes)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, status != self.status else { return }
                        self.status = status
                        self.onChange?()
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: Output

    @MainActor private func startEngine(sampleRate: Double) {
        stopEngine()
        guard fd >= 0 else { return }
        let marginFrames = Int(settings.marginMs / 1000 * sampleRate)
        let playout: Playout = switch settings.method {
        case .raw: RawPlayout(targetFrames: marginFrames)
        case .resilient: ResilientPlayout(minimumFrames: marginFrames)
        }
        self.playout = playout

        let engine = AVAudioEngine()
        let output = engine.outputNode
        var outputDevice = AudioDevices.defaultOutputDevice()
        if let uid = settings.outputUID, let device = AudioDevices.outputDevice(uid: uid), let unit = output.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                outputDevice = device.id
            } else {
                log.error("Couldn't select output \(device.name, privacy: .public) (OSStatus \(status))")
            }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: StreamWire.maxFramesPerPacket * StreamWire.channels)
        let packets = self.packets
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, list in
            // Not the timestamp's host time: for an output that's when this buffer will be heard, a few ms ahead,
            // and the playout needs now on the same clock as the arrival times.
            let now = HostClock.now()
            while packets.pop({ slot in
                let arrival = slot.loadUnaligned(as: Double.self)
                let bytes = UnsafeRawBufferPointer(rebasing: slot[8...])
                guard let header = StreamWire.audioHeader(bytes) else { return }
                StreamWire.readSamples(bytes, header: header, into: scratch)
                playout.receive(header, samples: scratch, arrival: arrival)
            }) {}
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData else { return noErr }
            playout.render(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self),
                           frames: Int(frameCount), now: now)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged(engine, sampleRate: sampleRate) }
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            error = nil
            // Only after starting: the engine sets its own I/O buffer size as it starts.
            let ioFrames = outputDevice.map { AudioCapture.setIOBufferFrames(settings.ioBufferFrames, device: $0) } ?? 0
            log.notice("Stream output started @ \(sampleRate) Hz, \(self.settings.method.rawValue, privacy: .public), margin \(self.settings.marginMs) ms, I/O buffer \(ioFrames) frames")
        } catch {
            self.error = "Couldn't start the output: \(error.localizedDescription)"
            log.error("Couldn't start the stream output: \(error.localizedDescription, privacy: .public)")
        }
        // The node's block owns the scratch buffer for as long as the engine lives.
        scratchBuffers.append(scratch)
        onChange?()
    }

    private var scratchBuffers: [UnsafeMutablePointer<Float>] = []
    private var recentRebuilds: [Date] = []

    /// Starting the engine (and asking for a small I/O buffer) posts a configuration change of its own, and
    /// rebuilding would just post another; so resume this engine, and only rebuild if it won't start (the output
    /// device went away), at most a few times a minute.
    @MainActor private func configurationChanged(_ engine: AVAudioEngine, sampleRate: Double) {
        guard engine === self.engine, !engine.isRunning else { return }
        do {
            try engine.start()
            log.notice("Stream output configuration changed; resumed")
        } catch {
            recentRebuilds = recentRebuilds.filter { Date().timeIntervalSince($0) < 60 }
            guard recentRebuilds.count < 5 else {
                self.error = "The output keeps failing: \(error.localizedDescription)"
                onChange?()
                return
            }
            recentRebuilds.append(Date())
            log.notice("Stream output stopped (\(error.localizedDescription, privacy: .public)); rebuilding")
            startEngine(sampleRate: sampleRate)
        }
    }

    @MainActor private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
    }

    deinit {
        for buffer in scratchBuffers { buffer.deallocate() }
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

    static func string(_ address: sockaddr_in) -> String {
        var ip = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let text = inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) } ?? "?"
        return "\(text):\(UInt16(bigEndian: address.sin_port))"
    }
}
