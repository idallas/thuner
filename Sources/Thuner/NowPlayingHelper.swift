import AppKit
import Foundation
import os

/// What macOS shows as playing (Control Center's Now Playing): any app or website that reports it, through the
/// helper in Helpers/NowPlaying. macOS only lets Apple-signed processes read it, so the helper runs inside Apple's
/// /usr/bin/perl, which loads it as a library; it reports each change as a line of JSON and takes play/pause/skip
/// commands. If macOS ever closes that route too, the helper just reports nothing and ThUNER carries on without it.
@MainActor
final class NowPlayingHelper {
    struct Report: Decodable, Equatable {
        var playing: Bool
        var pid: Int32?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var position: Double?
        /// Base64 cover, sent once per track.
        var artwork: String?
    }

    /// Each change of what's playing. Main queue.
    var onReport: ((Report) -> Void)?
    /// Whether the helper is up and answering (so commands can go through it).
    private(set) var isRunning = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var wanted = false
    private var failures = 0
    private let log = Logger(subsystem: "com.idallas.thuner", category: "players")

    /// The helper library, inside the app (not there for `swift run`: Scripts/build-app.sh builds it).
    private var libraryURL: URL? {
        let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libThunerNowPlaying.dylib")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    func start() {
        wanted = true
        launch()
    }

    func stop() {
        wanted = false
        input?.closeFile()  // the helper exits when its input closes
        process?.terminate()
        process = nil
        input = nil
        isRunning = false
    }

    /// Play/pause or skip in whatever macOS says is playing. False if the helper isn't running.
    func send(_ command: PlayerControl.Command) -> Bool {
        guard isRunning, let input else { return false }
        let word = switch command {
        case .playPause: "playpause"
        case .next: "next"
        case .previous: "previous"
        }
        input.write(Data((word + "\n").utf8))
        return true
    }

    private func launch() {
        guard wanted, process == nil else { return }
        guard let library = libraryURL else {
            log.notice("Now Playing helper isn't in this build")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use DynaLoader;
            my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
            my $main = DynaLoader::dl_find_symbol($lib, "ThunerNowPlayingMain") or die "no entry point";
            DynaLoader::dl_install_xsub("main::run", $main);
            run();
            """, library.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }  // the helper ended
            DispatchQueue.main.async { self?.received(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.ended(finished, status: status) }
        }
        do {
            try process.run()
        } catch {
            log.error("Couldn't start the Now Playing helper: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer = Data()
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["ready"] != nil {
                isRunning = true
                failures = 0
                log.notice("Now Playing helper running")
            } else if let error = object["error"] as? String {
                log.error("Now Playing helper: \(error, privacy: .public)")
            } else if let command = object["command"] as? String {
                if object["ok"] as? Bool != true { log.notice("Now Playing: \(command, privacy: .public) wasn't taken") }
            } else {
                do {
                    onReport?(try JSONDecoder().decode(Report.self, from: Data(line)))
                } catch {
                    log.error("Now Playing helper sent something unreadable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func ended(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        input = nil
        isRunning = false
        guard wanted else { return }
        failures += 1
        // Exit 2: MediaRemote refused (a future macOS closing the route); don't keep trying.
        guard status != 2, failures <= 5 else {
            log.error("Now Playing helper stopped (status \(status)); not restarting")
            return
        }
        log.notice("Now Playing helper stopped (status \(status)); restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures * 5)) { [weak self] in self?.launch() }
    }
}
