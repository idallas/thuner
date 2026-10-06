import AVFoundation
import ShazamKit
import ThunerCore
import os

/// Matches a chunk of our own captured audio with a plain SHSession (not SHManagedSession, which only listens
/// to the default input).
final class Matcher: @unchecked Sendable {
    private let session = SHSession()
    private let lookup = TrackInfoLookup()
    private let log = Logger(subsystem: "com.idallas.thuner", category: "match")

    func match(samples: [Float], sampleRate: Double) async -> MatchOutcome {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return .error("Couldn't allocate audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let signature: SHSignature
        do {
            let generator = SHSignatureGenerator()
            try generator.append(buffer, at: nil)
            signature = generator.signature()
        } catch {
            return .error("Signature: \(error.localizedDescription)")
        }

        switch await session.result(from: signature) {
        case .match(let match):
            guard let item = match.mediaItems.first else { return .noMatch }
            let observedAt = Date()
            var track = Track(
                title: item.title ?? "Unknown title",
                artist: item.artist ?? "Unknown artist",
                artworkURL: item.artworkURL,
                shazamID: item.shazamID,
                isrc: item.isrc,
                appleMusicID: item.appleMusicID)
            if let id = item.appleMusicID, let info = await lookup.info(appleMusicID: id) {
                track.duration = info.duration
                track.album = info.album
            }
            return .match(MatchObservation(track: track, offset: item.predictedCurrentMatchOffset, observedAt: observedAt))
        case .noMatch:
            return .noMatch
        case .error(let error, _):
            log.error("ShazamKit error: \(String(describing: error), privacy: .public)")
            return .error(error.localizedDescription)
        }
    }
}

/// ShazamKit doesn't report track length, which we need to predict the end of a track. The public iTunes
/// lookup API does, keyed by the Apple Music ID ShazamKit returns.
actor TrackInfoLookup {
    struct Info {
        var duration: TimeInterval?
        var album: String?
    }

    private var cache: [String: Info] = [:]

    func info(appleMusicID: String) async -> Info? {
        if let hit = cache[appleMusicID] { return hit }
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appleMusicID)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Response: Decodable {
                struct Item: Decodable {
                    var trackTimeMillis: Double?
                    var collectionName: String?
                }
                var results: [Item]
            }
            guard let item = try JSONDecoder().decode(Response.self, from: data).results.first else { return nil }
            let info = Info(duration: item.trackTimeMillis.map { $0 / 1000 }, album: item.collectionName)
            cache[appleMusicID] = info
            return info
        } catch {
            return nil
        }
    }
}
