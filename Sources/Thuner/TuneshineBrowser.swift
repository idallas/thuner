import Foundation
import os

/// Finds Tuneshines on the local network. Each one advertises `_tuneshine._tcp` over Bonjour, with its
/// display name in the TXT record (`deviceName`) and a stable `tuneshine-xxxx.local` hostname.
@MainActor
final class TuneshineBrowser: NSObject {
    struct Device: Identifiable, Equatable {
        /// The Tuneshine's own device id, from the TXT record (falls back to the service name).
        var id: String
        /// The name set in the Tuneshine app, e.g. "Tuneshiner".
        var name: String
        /// e.g. "tuneshine-1a2b.local", what ThUNER connects to.
        var host: String
    }

    private(set) var devices: [Device] = []
    var onChange: (() -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let log = Logger(subsystem: "com.idallas.thuner", category: "tuneshine")

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_tuneshine._tcp.", inDomain: "local.")
    }

    fileprivate func found(_ service: NetService) {
        resolving.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    fileprivate func resolved(_ service: NetService) {
        resolving.removeAll { $0 === service }
        guard let rawHost = service.hostName else { return }
        let host = (rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost).lowercased()
        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func value(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        let device = Device(id: value("deviceId") ?? service.name, name: value("deviceName") ?? service.name, host: host)
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            guard devices[i] != device else { return }
            devices[i] = device
        } else {
            devices.append(device)
            log.notice("Found Tuneshine \(device.name, privacy: .public) at \(device.host, privacy: .public)")
        }
        onChange?()
    }

    fileprivate func removed(_ service: NetService) {
        resolving.removeAll { $0 === service }
        // Services are keyed by name until resolved; drop any device whose service went away.
        let before = devices.count
        devices.removeAll { $0.id == service.name || $0.host.hasPrefix(service.name.lowercased().replacingOccurrences(of: " ", with: "-")) }
        if devices.count != before { onChange?() }
    }
}

extension TuneshineBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { found(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { removed(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { resolved(sender) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.removeAll { $0 === sender } }
    }
}
