import Foundation
import Testing
@testable import ThunerCore

/// Shaped like what Web Scrobbler 3.23's Webhook sends: its Song object serialized whole.
private func payload(event: String = "nowplaying", processedArtist: String? = nil, album: String? = "Black Holes and Revelations",
                     trackArt: String? = "https://i.ytimg.com/vi/abc/hqdefault.jpg") -> Data {
    let body: [String: Any] = [
        "eventName": event,
        "time": 1_761_660_000_000,
        "data": [
            "song": [
                "parsed": [
                    "track": "Starlight ",
                    "artist": "Muse - Topic",
                    "album": album as Any,
                    "albumArtist": NSNull(),
                    "duration": 240,
                    "trackArt": trackArt as Any,
                    "uniqueID": "abc",
                    "originUrl": "https://music.youtube.com/watch?v=abc",
                    "isPodcast": false,
                    "isPlaying": true,
                    "currentTime": 12.5,
                ],
                "processed": [
                    "track": NSNull(),
                    "artist": processedArtist as Any,
                    "album": NSNull(),
                    "albumArtist": NSNull(),
                    "duration": NSNull(),
                ],
                "noRegex": [:],
                "flags": ["isScrobbled": false, "isValid": true],
                "metadata": ["label": "YouTube Music", "startTimestamp": 1_761_659_990, "userloved": false],
                "connector": ["label": "YouTube Music", "id": "youtube-music", "js": "youtube-music.js", "matches": []],
            ] as [String: Any],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: body)
}

@Suite struct WebScrobblerEventTests {
    @Test func readsANowPlayingEvent() throws {
        let event = try #require(WebScrobblerEvent.parse(payload(processedArtist: "Muse")))
        #expect(event.kind == .nowPlaying)
        #expect(event.track.title == "Starlight")
        #expect(event.track.artist == "Muse")  // Web Scrobbler's correction wins over the site's "Muse - Topic"
        #expect(WebScrobblerEvent.parse(payload(processedArtist: "Banner Pilot - Topic"))?.track.artist == "Banner Pilot")
        #expect(WebScrobblerEvent.withoutTopic("Topic") == "Topic")
        #expect(event.track.album == "Black Holes and Revelations")
        #expect(event.track.duration == 240)
        #expect(event.site == "YouTube Music")
        #expect(event.siteArtwork?.host == "i.ytimg.com")
        #expect(event.pageURL?.absoluteString == "https://music.youtube.com/watch?v=abc")
        #expect(event.position == 12.5)
        #expect(event.startedAt == Date(timeIntervalSince1970: 1_761_659_990))
        #expect(!event.isPodcast)
    }

    @Test func fallsBackToWhatTheSiteShowed() throws {
        let event = try #require(WebScrobblerEvent.parse(payload(album: nil, trackArt: nil)))
        #expect(event.track.artist == "Muse")  // without YouTube's " - Topic"
        #expect(event.track.album == nil)
        #expect(event.siteArtwork == nil)
    }

    @Test func knowsEveryEvent() {
        for (name, kind) in [("paused", WebScrobblerEvent.Kind.paused), ("resumedplaying", .resumed), ("scrobble", .scrobble)] {
            #expect(WebScrobblerEvent.parse(payload(event: name))?.kind == kind)
        }
        #expect(WebScrobblerEvent.parse(payload(event: "somethingNew")) == nil)
    }

    @Test func knowsTheBrowser() {
        let firefox = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
        let chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        let edge = chrome + " Edg/141.0.0.0"
        let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        #expect(WebScrobblerEvent.Browser(userAgent: firefox)?.name == "Firefox")
        #expect(WebScrobblerEvent.Browser(userAgent: chrome)?.bundleIDs.contains("com.brave.Browser") == true)
        #expect(WebScrobblerEvent.Browser(userAgent: edge)?.name == "Edge")
        #expect(WebScrobblerEvent.Browser(userAgent: safari)?.name == "Safari")
        #expect(WebScrobblerEvent.Browser(userAgent: "curl/8.7.1") == nil)
    }

    @Test func ignoresAnythingElse() {
        #expect(WebScrobblerEvent.parse(Data("not json".utf8)) == nil)
        #expect(WebScrobblerEvent.parse(Data(#"{"eventName":"nowplaying","data":{"song":{"parsed":{"track":"x"}}}}"#.utf8)) == nil)
        #expect(WebScrobblerEvent.parse(payload(trackArt: "javascript:alert(1)"))?.siteArtwork == nil)
    }
}
