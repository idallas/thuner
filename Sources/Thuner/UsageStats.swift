import Foundation

/// Anonymous update-check events for the website's Umami stats. Sparkle fetches the appcast directly, so the
/// website's tracking script never sees those requests; the app reports them itself through Umami's
/// event API. Umami counts each Mac as its own visitor, so this shows active installs and their versions.
///
/// Only release builds know where to send them (Scripts/build-app.sh adds `ThunerStatsEndpoint` and
/// `ThunerStatsWebsiteID` to Info.plist); development builds and builds from source send nothing.
enum UsageStats {
    private struct Config {
        var endpoint: URL
        var websiteID: String
        /// The appcast, reported as the page that was "visited".
        var feed: URL
    }

    private static let config: Config? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let endpoint = (info["ThunerStatsEndpoint"] as? String).flatMap(URL.init(string:)),
              let websiteID = info["ThunerStatsWebsiteID"] as? String, !websiteID.isEmpty,
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Config(endpoint: endpoint, websiteID: websiteID, feed: feed)
    }()

    /// Whether this build sends stats at all (Settings only offers the switch when it does).
    static var isAvailable: Bool { config != nil }

    static func updateCheck() async {
        guard let config else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        let body: [String: Any] = [
            "type": "event",
            "payload": [
                "website": config.websiteID,
                "hostname": config.feed.host() ?? "",
                "language": Locale.preferredLanguages.first ?? "en-US",
                "url": config.feed.path(),
                "title": "ThUNER update check",
                "name": "update-check",
                "data": ["version": version, "build": info["CFBundleVersion"] as? String ?? "?", "macos": macOS, "arch": arch],
            ],
        ]
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Umami drops requests whose user agent looks like a bot or an HTTP library.
        request.setValue("ThUNER/\(version) (Macintosh; Mac OS X \(macOS); \(arch))", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
