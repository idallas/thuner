import Darwin
import Foundation
import ThunerCore
import os

/// Tiny LAN coordination channel between the ThUNER instances: JSON over UDP.
///
/// Each instance advertises itself over Bonjour (`_thuner._udp`) and sends its messages directly to every
/// other instance it has found. UDP broadcast goes out too, as a fallback, but macOS silently drops an app's
/// broadcasts in some setups (seen on a Mac mini: sendto succeeded, nothing arrived) while unicast gets through.
final class PeerLink: NSObject, @unchecked Sendable {
    struct Message: Codable {
        enum Event: String, Codable {
            /// Just pushed cover art.
            case push
            /// Heartbeat: hearing audio (identifying) or playing something.
            case active
            /// Went quiet: the other Mac can take over right away.
            case idle
        }

        var v = 1
        /// Unique per message, so a copy that arrives twice (unicast and broadcast) is handled once.
        var id: String? = UUID().uuidString
        var instance: String
        var host: String
        var role: String
        var event: Event
        /// "Artist – Title", for logs.
        var track: String?
        /// What's playing there, with artwork, so the other Mac can show it.
        var nowPlaying: Track?
    }

    static let port: UInt16 = 47_474

    /// Called on the main queue for messages from other instances.
    var onMessage: ((Message) -> Void)?
    /// Called on the main queue when other ThUNERs appear or disappear, with their host names.
    var onPeersChanged: (([String]) -> Void)?
    private var peerHosts: [String: String] = [:]

    private let instance = UUID().uuidString
    private let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let log = Logger(subsystem: "com.idallas.thuner", category: "peers")

    // Bonjour: our own advertisement, the browser, and the IPv4 addresses of the other instances by service name.
    private var advertisement: NetService?
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var peers: [String: [sockaddr_in]] = [:]
    /// Ids of recently handled messages.
    private var recentMessageIDs: [String] = []

    func start() {
        guard fd < 0 else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log.error("socket() failed: \(errno)")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            log.error("bind() failed: \(errno)")
            close(fd)
            fd = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
        self.source = source
        log.notice("Listening for other ThUNERs on UDP \(Self.port)")

        let advertisement = NetService(domain: "local.", type: "_thuner._udp.", name: instance, port: Int32(Self.port))
        advertisement.publish()
        self.advertisement = advertisement
        browser.delegate = self
        browser.searchForServices(ofType: "_thuner._udp.", inDomain: "local.")
    }

    func send(_ event: Message.Event, role: String, nowPlaying: Track?) {
        guard fd >= 0 else { return }
        let message = Message(instance: instance, host: host, role: role, event: event,
                              track: nowPlaying?.displayName, nowPlaying: nowPlaying)
        guard let data = try? JSONEncoder().encode(message) else { return }
        var broadcast = sockaddr_in()
        broadcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_port = Self.port.bigEndian
        broadcast.sin_addr.s_addr = INADDR_BROADCAST

        // One address per peer is enough; a Mac with Wi-Fi and Ethernet on the same network has two.
        let targets = peers.values.compactMap(\.first) + [broadcast]
        var delivered = 0
        for var addr in targets {
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent >= 0 { delivered += 1 }
        }
        log.notice("Sent \(event.rawValue, privacy: .public) to \(self.peers.count) ThUNER(s) plus broadcast (\(nowPlaying?.displayName ?? "", privacy: .public))")
        if delivered == 0 { log.error("Couldn't send to other ThUNERs: errno \(errno)") }
    }

    fileprivate func found(_ service: NetService) {
        guard service.name != instance else { return }
        resolving.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    fileprivate func resolved(_ service: NetService) {
        resolving.removeAll { $0 === service }
        let addresses: [sockaddr_in] = (service.addresses ?? []).compactMap { data in
            data.withUnsafeBytes { raw -> sockaddr_in? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                      raw.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET) else { return nil }
                var addr = raw.load(as: sockaddr_in.self)
                addr.sin_port = Self.port.bigEndian
                return addr
            }
        }
        guard !addresses.isEmpty else { return }
        if peers[service.name] == nil {
            log.notice("Found another ThUNER at \(service.hostName ?? "?", privacy: .public)")
        }
        peers[service.name] = addresses
        peerHosts[service.name] = (service.hostName ?? service.name).replacingOccurrences(of: ".local.", with: "")
        onPeersChanged?(Array(peerHosts.values).sorted())
    }

    fileprivate func removed(_ service: NetService) {
        resolving.removeAll { $0 === service }
        peers[service.name] = nil
        peerHosts[service.name] = nil
        onPeersChanged?(Array(peerHosts.values).sorted())
    }

    /// Messages are only taken from ThUNERs found over Bonjour: anything on the network can send a datagram to
    /// this port, and a made-up "the turntable Mac is playing" would silence this Mac's mic and put whatever
    /// it liked on the display. (Bonjour can be spoofed too, but it takes more than one packet.)
    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var sender = sockaddr_in()
        var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength) }
        }
        guard n > 0 else { return }
        guard sender.sin_family == sa_family_t(AF_INET), isKnownPeer(sender.sin_addr) else {
            log.notice("Ignoring a message from \(Self.string(sender.sin_addr), privacy: .public): not a ThUNER found over Bonjour")
            return
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(buffer[0..<n])),
              message.instance != instance else { return }
        if let id = message.id {
            guard !recentMessageIDs.contains(id) else { return }
            recentMessageIDs.append(id)
            if recentMessageIDs.count > 64 { recentMessageIDs.removeFirst(recentMessageIDs.count - 64) }
        }
        log.notice("Heard \(message.event.rawValue, privacy: .public) from \(message.host, privacy: .public) (\(message.role, privacy: .public))")
        onMessage?(message)
    }
}

extension PeerLink {
    private func isKnownPeer(_ address: in_addr) -> Bool {
        peers.values.contains { $0.contains { $0.sin_addr.s_addr == address.s_addr } }
    }

    private static func string(_ address: in_addr) -> String {
        var addr = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) } ?? "?"
    }
}

extension PeerLink: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        found(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        removed(service)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolved(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
