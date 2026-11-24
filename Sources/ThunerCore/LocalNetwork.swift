/// Whether an address that connects to ThUNER is on one of this Mac's own local networks: the subnet of an
/// Ethernet or Wi-Fi interface, or this Mac itself. Anything that arrives through a VPN or tunnel (Tailscale, a
/// work VPN: point-to-point `utun` interfaces) or is routed from further away isn't.
public enum LocalNetwork {
    public struct Interface: Sendable, Equatable {
        public var name: String
        /// 4 bytes (IPv4) or 16 (IPv6).
        public var address: [UInt8]
        public var netmask: [UInt8]
        public var isPointToPoint: Bool

        public init(name: String, address: [UInt8], netmask: [UInt8], isPointToPoint: Bool = false) {
            self.name = name
            self.address = address
            self.netmask = netmask
            self.isPointToPoint = isPointToPoint
        }

        /// VPNs and tunnels: Tailscale, WireGuard and most work VPNs are `utun`; older ones `ipsec`, `ppp`, `tun`.
        public var isTunnel: Bool {
            isPointToPoint || ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].contains { name.hasPrefix($0) }
        }
    }

    /// - Parameters:
    ///   - address: 4 bytes or 16 (an IPv4-mapped IPv6 address counts as its IPv4 one).
    ///   - scope: for an IPv6 link-local address, the interface it arrived on.
    public static func contains(_ address: [UInt8], scope: String? = nil, interfaces: [Interface]) -> Bool {
        let address = unmapped(address)
        if isLoopback(address) { return true }
        // fe80::/10 is the same prefix on every interface, tunnels included, so go by the one it came in on.
        if address.count == 16, address[0] == 0xFE, address[1] & 0xC0 == 0x80 {
            guard let scope else { return false }
            return interfaces.contains { $0.name == scope && !$0.isTunnel }
        }
        return interfaces.contains { interface in
            guard !interface.isTunnel, interface.address.count == address.count,
                  interface.netmask.count == address.count, interface.netmask.contains(where: { $0 != 0 }) else { return false }
            return zip(zip(address, interface.address), interface.netmask).allSatisfy { pair, mask in
                pair.0 & mask == pair.1 & mask
            }
        }
    }

    static func isLoopback(_ address: [UInt8]) -> Bool {
        if address.count == 4 { return address[0] == 127 }
        return address.count == 16 && address.dropLast().allSatisfy { $0 == 0 } && address[15] == 1
    }

    /// ::ffff:a.b.c.d → a.b.c.d (a dual-stack listener reports IPv4 clients this way).
    static func unmapped(_ address: [UInt8]) -> [UInt8] {
        guard address.count == 16, address[0..<10].allSatisfy({ $0 == 0 }), address[10] == 0xFF, address[11] == 0xFF
        else { return address }
        return Array(address[12...])
    }
}
