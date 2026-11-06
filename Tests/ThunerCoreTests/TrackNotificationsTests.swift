import Foundation
import Testing
@testable import ThunerCore

private let song = Track(title: "Sons of Thunder", artist: "High On Fire", duration: 300)
private let other = Track(title: "Devilution", artist: "High On Fire", duration: 300)

@Suite struct TrackNotificationsTests {
    @Test func onlyANewSongIsDue() {
        #expect(TrackNotifications.isNewSong(from: nil, to: song))
        #expect(TrackNotifications.isNewSong(from: song, to: other))
        #expect(!TrackNotifications.isNewSong(from: song, to: nil))
        #expect(!TrackNotifications.isNewSong(from: song, to: song))
        // The same play with its album filled in isn't a new song.
        var filled = song
        filled.album = "Blessed Black Wings"
        filled.artworkURL = URL(string: "https://example.com/a.jpg")
        #expect(!TrackNotifications.isNewSong(from: song, to: filled))
    }

    @Test func contentSaysWhereItPlays() {
        var withAlbum = song
        withAlbum.album = "Blessed Black Wings"
        let c = TrackNotifications.content(for: withAlbum, source: .shazam, sourceName: "Shazam")
        #expect(c.title == "Sons of Thunder")
        #expect(c.subtitle == "High On Fire — Blessed Black Wings")
        #expect(c.body == "Identified with Shazam")

        #expect(TrackNotifications.content(for: song, source: .shazam, sourceName: "Shazam").subtitle == "High On Fire")
        #expect(TrackNotifications.content(for: song, source: .anotherMac, sourceName: "echo").body == "Playing on echo")
        #expect(TrackNotifications.content(for: song, source: .browser, sourceName: "YouTube Music").body == "Playing in YouTube Music")
        #expect(TrackNotifications.content(for: song, source: .nowPlaying, sourceName: "AirPlay").body == "Playing over AirPlay")
        #expect(TrackNotifications.content(for: song, source: .nowPlaying, sourceName: "KCRW (AirPlay)").body
            == "Playing from KCRW over AirPlay")
    }

    @Test func singleAlbumNotRepeated() {
        var single = song
        single.album = song.title
        #expect(TrackNotifications.content(for: single, source: .appleMusic, sourceName: "Apple Music").subtitle == "High On Fire")
    }
}
