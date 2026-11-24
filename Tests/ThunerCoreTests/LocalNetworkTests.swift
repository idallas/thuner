import Testing
@testable import ThunerCore

struct LocalNetworkTests {
    static let linkLocal: [UInt8] = [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    static let prefix64: [UInt8] = [255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]
    let interfaces: [LocalNetwork.Interface] = [
        LocalNetwork.Interface(name: "en0", address: [192, 168, 1, 20], netmask: [255, 255, 255, 0]),
        LocalNetwork.Interface(name: "en0", address: linkLocal, netmask: prefix64),
        LocalNetwork.Interface(name: "utun4", address: [100, 79, 18, 90], netmask: [255, 255, 255, 255], isPointToPoint: true),
        LocalNetwork.Interface(name: "utun7", address: [10, 8, 0, 5], netmask: [255, 255, 0, 0]),
    ]

    @Test func sameSubnetIsLocal() {
        #expect(LocalNetwork.contains([192, 168, 1, 77], interfaces: interfaces))
        #expect(!LocalNetwork.contains([192, 168, 2, 77], interfaces: interfaces))
    }

    @Test func loopbackIsLocal() {
        #expect(LocalNetwork.contains([127, 0, 0, 1], interfaces: []))
        let ipv6Loopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        #expect(LocalNetwork.contains(ipv6Loopback, interfaces: []))
    }

    @Test func vpnsAreNot() {
        // Tailscale's 100.64/10 and a work VPN's subnet, both on tunnels.
        #expect(!LocalNetwork.contains([100, 79, 18, 91], interfaces: interfaces))
        #expect(!LocalNetwork.contains([10, 8, 3, 3], interfaces: interfaces))
        #expect(!LocalNetwork.contains([8, 8, 8, 8], interfaces: interfaces))
    }

    @Test func mappedIPv4() {
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        #expect(LocalNetwork.contains(mapped + [192, 168, 1, 77], interfaces: interfaces))
        #expect(!LocalNetwork.contains(mapped + [10, 8, 3, 3], interfaces: interfaces))
    }

    @Test func linkLocalGoesByInterface() {
        var peer = Self.linkLocal
        peer[15] = 9
        #expect(LocalNetwork.contains(peer, scope: "en0", interfaces: interfaces))
        #expect(!LocalNetwork.contains(peer, scope: "utun4", interfaces: interfaces))
        #expect(!LocalNetwork.contains(peer, interfaces: interfaces))
    }
}
