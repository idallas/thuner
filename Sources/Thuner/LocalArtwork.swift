import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Covers ThUNER got from the Music app itself (when Apple's catalogue search can't find the track: explicit
/// songs, other countries' stores, your own library). They're saved as JPEGs, named by their content, and served
/// by ThUNER's web server at `/artwork/<name>`, so the panel, the floating cover, the widget, the web display, the
/// Tuneshine and other Macs can all load them by address like any other cover.
enum LocalArtwork {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thuner/artwork")
    }

    /// Keeps this many covers; older ones go.
    private static let keep = 40

    /// Saves cover image data (any format ImageIO reads) as a JPEG of at most 600 px, and returns its file name.
    static func save(_ data: Data) -> String? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = String(digest.prefix(16)) + ".jpg"
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
              ] as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        prune()
        return name
    }

    /// A served cover's file, if `name` is one of ours (nothing else in the folder, or outside it, is served).
    static func file(named name: String) -> URL? {
        guard name.range(of: #"^[0-9a-f]{16}\.jpg$"#, options: .regularExpression) != nil else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A smaller copy (for the Tuneshine, which is 64×64 and doesn't show a large JPEG), made once and kept beside
    /// the cover.
    static func file(named name: String, size: Int) -> URL? {
        guard let original = file(named: name), (16...600).contains(size) else { return nil }
        let small = folder.appendingPathComponent("\(name.dropLast(4))-\(size).jpg")
        if FileManager.default.fileExists(atPath: small.path) { return small }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(small as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? small : nil
    }

    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > keep * 2 else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep * 2) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// This Mac's IPv4 address on the local network (Ethernet first, then Wi-Fi), for addresses the Tuneshine can
    /// reach: it doesn't resolve .local names reliably.
    static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Skip self-assigned addresses (no DHCP).
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        return found.sorted { $0.name < $1.name }.first?.address
    }
}
