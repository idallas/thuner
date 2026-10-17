import Foundation

/// How the listening Mac turns the stream back into sound. The receiver picks; the sender sends the same packets
/// either way.
public enum StreamMethod: String, Codable, CaseIterable, Sendable {
    /// Uncompressed audio straight into a small fixed buffer; clock drift fixed by dropping or repeating a sample
    /// under a short crossfade. Lowest latency, but a late packet is a dropout: for wired networks.
    case raw
    /// SonoBus-style: packets placed by their timestamp (so reordering is harmless), a buffer that grows and shrinks
    /// with the measured network jitter, smooth resampling to follow the sender's clock, and lost audio faded over.
    case resilient

    public var name: String {
        switch self {
        case .raw: "Raw (lowest latency)"
        case .resilient: "Resilient (adaptive buffer)"
        }
    }
}

/// The header of one audio packet.
public struct AudioPacketHeader: Equatable, Sendable {
    /// Random per sender start: a new value means a new stream, so the receiver starts over.
    public var streamID: UInt16
    public var sequence: UInt32
    /// The sender's frame count at the packet's first frame.
    public var sampleTime: UInt64
    public var sampleRate: UInt32
    public var frames: Int
    public var channels: Int
    /// Sent again because the receiver asked: its timing says nothing about the network's jitter.
    public var resent = false

    public init(streamID: UInt16, sequence: UInt32, sampleTime: UInt64, sampleRate: UInt32, frames: Int, channels: Int = StreamWire.channels) {
        self.streamID = streamID
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.frames = frames
        self.channels = channels
    }
}

/// The stream's datagrams: 24-bit interleaved stereo audio packets, plus small JSON control messages.
///
/// Every datagram starts with the magic and version, then a kind. Audio:
///
///     magic u32 · version u8 · kind u8 · channels u8 · bits u8 · sequence u32 · sampleTime u64 ·
///     sampleRate u32 · frames u16 · streamID u16 · samples (frames × channels × 3 bytes)
///
/// All little-endian. Control messages are the same first six bytes, then JSON.
public enum StreamWire {
    public static let port: UInt16 = 47_476
    public static let magic: UInt32 = 0x5448_5341  // "THSA"
    public static let version: UInt8 = 1
    public static let headerSize = 28
    public static let channels = 2
    public static let bytesPerSample = 3
    /// Keeps a packet inside one Ethernet frame (1472 bytes of UDP payload).
    public static let maxFramesPerPacket = 240
    public static let maxDatagram = 1472

    public enum Kind: UInt8, Sendable {
        case audio = 1
        /// Receiver → sender, about once a second: keep sending to me.
        case subscribe = 2
        /// Sender → receiver, in answer to a subscribe: what's being shared (or that nothing is).
        case status = 3
        /// Receiver → sender: stop sending to me.
        case unsubscribe = 4
        /// Receiver → sender: send these packets again (`Resend`).
        case resend = 5
        /// An audio packet sent again on request; laid out exactly like `audio`.
        case resentAudio = 6
    }

    public struct Resend: Codable, Sendable, Equatable {
        public var sequences: [UInt32]
        public init(sequences: [UInt32]) { self.sequences = sequences }
    }

    public struct Subscribe: Codable, Sendable, Equatable {
        public var host: String
        public var method: StreamMethod
        /// The receiver's clock when it sent this; the status reply echoes it back, timing the round trip.
        public var sentAt: Double?
        public init(host: String, method: StreamMethod, sentAt: Double? = nil) {
            self.host = host
            self.method = method
            self.sentAt = sentAt
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var host: String
        /// False when the sender has sharing turned off (or isn't capturing anything).
        public var sharing: Bool
        /// The input being shared, for display.
        public var source: String?
        public var sampleRate: Double?
        public var framesPerPacket: Int?
        /// How long audio takes from the input's jacks to a sent packet: the device's latency and I/O buffer, plus
        /// waiting for a packet to fill.
        public var captureLatencyFrames: Int?
        /// The subscribe's `sentAt`, sent straight back.
        public var echo: Double?
        /// Sharing, but the input has been silent a while, so no audio is being sent until it isn't.
        public var idle: Bool?
        public init(host: String, sharing: Bool, source: String? = nil, sampleRate: Double? = nil, framesPerPacket: Int? = nil,
                    captureLatencyFrames: Int? = nil, echo: Double? = nil, idle: Bool? = nil) {
            self.host = host
            self.sharing = sharing
            self.source = source
            self.sampleRate = sampleRate
            self.framesPerPacket = framesPerPacket
            self.captureLatencyFrames = captureLatencyFrames
            self.echo = echo
            self.idle = idle
        }
    }

    // MARK: Audio packets (no allocation: safe for the audio and network threads)

    /// Writes an audio packet for `header.frames` interleaved stereo frames; returns its size in bytes.
    /// `out` needs room for `headerSize + frames × channels × 3` bytes.
    public static func writeAudio(_ header: AudioPacketHeader, samples: UnsafePointer<Float>, to out: UnsafeMutableRawPointer) -> Int {
        out.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt32.self)
        out.storeBytes(of: version, toByteOffset: 4, as: UInt8.self)
        out.storeBytes(of: Kind.audio.rawValue, toByteOffset: 5, as: UInt8.self)
        out.storeBytes(of: UInt8(header.channels), toByteOffset: 6, as: UInt8.self)
        out.storeBytes(of: UInt8(bytesPerSample * 8), toByteOffset: 7, as: UInt8.self)
        out.storeBytes(of: header.sequence.littleEndian, toByteOffset: 8, as: UInt32.self)
        out.storeBytes(of: header.sampleTime.littleEndian, toByteOffset: 12, as: UInt64.self)
        out.storeBytes(of: header.sampleRate.littleEndian, toByteOffset: 20, as: UInt32.self)
        out.storeBytes(of: UInt16(header.frames).littleEndian, toByteOffset: 24, as: UInt16.self)
        out.storeBytes(of: header.streamID.littleEndian, toByteOffset: 26, as: UInt16.self)
        let count = header.frames * header.channels
        var p = out + headerSize
        for i in 0..<count {
            let clamped = max(-1, min(samples[i], 1))
            let v = Int32((clamped * 8_388_607).rounded())
            p.storeBytes(of: UInt8(truncatingIfNeeded: v), as: UInt8.self)
            (p + 1).storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), as: UInt8.self)
            (p + 2).storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), as: UInt8.self)
            p += 3
        }
        return headerSize + count * bytesPerSample
    }

    /// The kind of a datagram, if it's one of ours.
    public static func kind(of bytes: UnsafeRawBufferPointer) -> Kind? {
        guard bytes.count >= 6,
              UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == magic,
              bytes[4] == version else { return nil }
        return Kind(rawValue: bytes[5])
    }

    /// The header of an audio packet, if it's a well-formed one.
    public static func audioHeader(_ bytes: UnsafeRawBufferPointer) -> AudioPacketHeader? {
        let kind = kind(of: bytes)
        guard kind == .audio || kind == .resentAudio, bytes.count >= headerSize else { return nil }
        let channels = Int(bytes[6])
        guard channels == Self.channels, Int(bytes[7]) == bytesPerSample * 8 else { return nil }
        let frames = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 24, as: UInt16.self)))
        guard frames > 0, frames <= maxFramesPerPacket, bytes.count >= headerSize + frames * channels * bytesPerSample else { return nil }
        let rate = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
        guard rate >= 8_000, rate <= 384_000 else { return nil }
        var header = AudioPacketHeader(
            streamID: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 26, as: UInt16.self)),
            sequence: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
            sampleTime: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt64.self)),
            sampleRate: rate, frames: frames, channels: channels)
        header.resent = kind == .resentAudio
        return header
    }

    /// Decodes an audio packet's samples (interleaved) into `out`, which needs room for frames × channels floats.
    public static func readSamples(_ bytes: UnsafeRawBufferPointer, header: AudioPacketHeader, into out: UnsafeMutablePointer<Float>) {
        let count = header.frames * header.channels
        var offset = headerSize
        let scale: Float = 1 / 8_388_608
        for i in 0..<count {
            let v = Int32(bytes[offset]) | Int32(bytes[offset + 1]) << 8 | Int32(bytes[offset + 2]) << 16
            out[i] = Float((v << 8) >> 8) * scale  // sign-extend 24 → 32 bits
            offset += 3
        }
    }

    // MARK: Control messages

    public static func control<T: Encodable>(_ kind: Kind, _ body: T) -> Data {
        var data = Data(capacity: 128)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(version)
        data.append(kind.rawValue)
        data.append((try? JSONEncoder().encode(body)) ?? Data())
        return data
    }

    public static func controlBody<T: Decodable>(_ type: T.Type, from bytes: UnsafeRawBufferPointer) -> T? {
        guard bytes.count > 6 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(bytes[6...]))
    }
}
