import AVFoundation
import os

/// For working out why Shazam misses: `open Thuner.app --args -matchFile /path/a.m4a[,/path/b.wav]` runs ThUNER's
/// matcher over each file in 10-second windows, 5 s apart, and logs every result (category "diagnostic"). A file of
/// 10 s or less (a clip saved with `saveMissedClips`) is also tried as if recorded at other rates, which is how
/// System Audio turned out to be 9% fast.
enum MatchFileDiagnostic {
    static func runIfAsked() {
        guard let list = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["matchFile"] as? String else { return }
        let log = ThunerLogger("diagnostic")
        Task.detached {
            let matcher = Matcher()
            for path in list.split(separator: ",").map(String.init) {
                guard let samples = mono48k(path) else { log.error("matchFile: couldn't read \(path)"); continue }
                let name = (path as NSString).lastPathComponent
                // As if the capture got the speed wrong: play it back as if it had been recorded at another rate.
                for factor in [44_100.0 / 48_000, 48_000.0 / 44_100, 0.5, 2.0, 88_200.0 / 48_000, 48_000.0 / 88_200] where samples.count <= 480_000 {
                    guard let respun = resample(samples, from: 48_000 * factor) else { continue }
                    let window = Array(respun.prefix(480_000))
                    let outcome = await matcher.match(samples: window, sampleRate: 48_000)
                    let result = switch outcome {
                    case .match(let m): "match \(m.track.displayName) at \(Int(m.offset)) s"
                    case .noMatch: "no match"
                    case .error(let e): "error \(e)"
                    }
                    log.notice("matchFile \(name) as \(Int(48_000 * factor)) Hz: \(result)")
                }
                for start in stride(from: 0, through: max(samples.count - 480_000, 0), by: 240_000) {
                    let window = Array(samples[start..<min(start + 480_000, samples.count)])
                    let outcome = await matcher.match(samples: window, sampleRate: 48_000)
                    let result = switch outcome {
                    case .match(let m): "match \(m.track.displayName) at \(Int(m.offset)) s"
                    case .noMatch: "no match"
                    case .error(let e): "error \(e)"
                    }
                    log.notice("matchFile \(name) \(start / 48_000) s: \(result)")
                }
            }
        }
    }

    /// Mono samples taken to be at `rate`, converted to 48 kHz.
    private static func resample(_ samples: [Float], from rate: Double) -> [Float]? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * 48_000 / rate) + 4096) else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))) : nil
    }

    /// The file as mono at 48 kHz (what the match ring holds).
    private static func mono48k(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        // Downmix like the capture does: average the channels.
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 48_000 / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
