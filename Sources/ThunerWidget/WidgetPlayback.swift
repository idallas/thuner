import AppIntents
import Foundation

/// The widget's playback buttons. The widget is sandboxed and can't script Apple Music or Spotify itself, so it
/// asks ThUNER (its HTTP API, which takes commands from this Mac without a token) to press the control.
struct WidgetPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "ThUNER Playback"
    static let isDiscoverable = false

    @Parameter(title: "Control") var control: String

    init() {}
    init(_ control: String) { self.control = control }

    func perform() async throws -> some IntentResult {
        guard ["playPause", "nextTrack", "previousTrack"].contains(control),
              let url = URL(string: "http://127.0.0.1:47480/api/controls/\(control)") else { return .result() }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"press": true}"#.utf8)
        _ = try? await URLSession(configuration: .ephemeral).data(for: request)
        return .result()
    }
}
