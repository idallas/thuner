import CommonCrypto
import CryptoKit
import Foundation

/// The optional stream password: every datagram between the two Macs is sealed with AES-GCM under a key derived
/// from it, so only Macs that know it can listen (or be talked to), and the audio isn't readable on the network.
///
/// A sealed datagram keeps the six-byte header in the clear (with the kind's top bit set, and the header as the
/// authenticated data), then a 12-byte nonce, the sealed rest, and a 16-byte tag.
public struct StreamCipher: Sendable {
    private let key: SymmetricKey
    public static let overhead = 12 + 16
    static let sealedFlag: UInt8 = 0x80

    /// Nil for an empty password. Deriving the key takes a few tens of milliseconds (PBKDF2, 200,000 rounds), so
    /// a captured stream can't be tried against a password list quickly; make one and keep it.
    public init?(password: String) {
        guard !password.isEmpty else { return nil }
        let salt = Array("ThUNER stream v1".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &derived, derived.count)
        guard status == kCCSuccess else { return nil }
        key = SymmetricKey(data: derived)
    }

    /// A plain datagram (header and all), sealed.
    public func seal(_ datagram: UnsafeRawBufferPointer) -> Data? {
        guard datagram.count >= 6 else { return nil }
        var header = Data(datagram[0..<6])
        header[5] |= Self.sealedFlag
        guard let box = try? AES.GCM.seal(Data(datagram[6...]), using: key, authenticating: header) else { return nil }
        return header + box.nonce + box.ciphertext + box.tag
    }

    /// The plain datagram, or nil if it isn't sealed with this password (or was changed on the way).
    public func open(_ bytes: UnsafeRawBufferPointer) -> Data? {
        guard bytes.count >= 6 + Self.overhead, bytes[5] & Self.sealedFlag != 0 else { return nil }
        let header = Data(bytes[0..<6])
        guard let nonce = try? AES.GCM.Nonce(data: Data(bytes[6..<18])),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(bytes[18..<(bytes.count - 16)]),
                                               tag: Data(bytes[(bytes.count - 16)...])),
              let body = try? AES.GCM.open(box, using: key, authenticating: header) else { return nil }
        var plain = header
        plain[5] &= ~Self.sealedFlag
        return plain + body
    }

    /// Whether a datagram is sealed (with some password).
    public static func isSealed(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.count >= 6 && bytes[5] & sealedFlag != 0
    }
}
