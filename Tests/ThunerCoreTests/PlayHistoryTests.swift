import Foundation
import Testing
@testable import ThunerCore

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let song = Track(title: "Sons of Thunder", artist: "High On Fire", duration: 300)

@Suite struct PlayHistoryTests {
    @Test func samePlayIsOneEntry() {
        var h = PlayHistory()
        let a = h.record(song, startedAt: at(0), source: .shazam)
        var withAlbum = song
        withAlbum.album = "Blessed Black Wings"
        let b = h.record(withAlbum, startedAt: at(20), source: .appleMusic)
        #expect(a == b)
        #expect(h.entries.count == 1)
        #expect(h.entries[0].track.album == "Blessed Black Wings")
        #expect(h.entries[0].source == .appleMusic)
    }

    @Test func playingItAgainLaterIsANewEntry() {
        var h = PlayHistory()
        h.record(song, startedAt: at(0), source: .shazam)
        h.record(song, startedAt: at(1000), source: .shazam)
        #expect(h.entries.count == 2)
    }

    @Test func knowsWhatItAlreadyScrobbled() {
        var h = PlayHistory()
        let id = h.record(song, startedAt: at(0), source: .shazam)
        #expect(!h.alreadyScrobbled(song, startedAt: at(10), service: "lastfm"))
        h.setScrobble(.scrobbled, service: "lastfm", for: id)
        // Relaunched mid-track and re-identified it: start time worked out slightly differently.
        #expect(h.alreadyScrobbled(song, startedAt: at(10), service: "lastfm"))
        #expect(!h.alreadyScrobbled(song, startedAt: at(1000), service: "lastfm"))
        // Each service is tracked on its own.
        #expect(!h.alreadyScrobbled(song, startedAt: at(10), service: "maloja"))
    }

    @Test func skippedDuplicateDoesNotCountAsScrobbled() {
        var h = PlayHistory()
        let id = h.record(song, startedAt: at(0), source: .spotify)
        h.setScrobble(.skippedDuplicate("Already on Last.fm"), service: "lastfm", for: id)
        #expect(!h.alreadyScrobbled(song, startedAt: at(0), service: "lastfm"))
        #expect(h.entries[0].scrobble == .skippedDuplicate("Already on Last.fm"))
    }

    @Test func summaryPrefersScrobbled() {
        var h = PlayHistory()
        let id = h.record(song, startedAt: at(0), source: .shazam)
        h.setScrobble(.skippedDuplicate("Already on Last.fm"), service: "lastfm", for: id)
        h.setScrobble(.scrobbled, service: "maloja", for: id)
        #expect(h.entries[0].scrobble == .scrobbled)
    }

    @Test func readsHistoryFromBeforeMultipleServices() throws {
        let old = """
        [{"id":"7E1D4C3A-0000-4000-8000-000000000001","track":{"title":"Sweet Leaf","artist":"Black Sabbath"},
          "startedAt":0,"source":"Apple Music","scrobble":{"scrobbled":{}}}]
        """
        let entries = try JSONDecoder().decode([PlayHistory.Entry].self, from: Data(old.utf8))
        #expect(entries[0].scrobbles == ["lastfm": .scrobbled])
    }

    @Test func remoteDuplicateMatchesCollaborationsSplitDifferently() {
        let track = Track(title: "Gaa Chuye Bolo", artist: "Tanjib Sarowar feat. Abanti Sithi", duration: 240)
        let recent = [RemoteScrobble(artist: "Abanti Sithi, Tanjib Sarowar", title: "Gaa Chuye Bolo", date: at(10))]
        #expect(RemoteScrobble.duplicate(of: track, startedAt: at(0), in: recent) != nil)
        // A different song by one of the same artists isn't a duplicate.
        let other = [RemoteScrobble(artist: "Tanjib Sarowar", title: "Another Song", date: at(10))]
        #expect(RemoteScrobble.duplicate(of: track, startedAt: at(0), in: other) == nil)
    }

    @Test func findsRemoteDuplicate() {
        let recent = [
            RemoteScrobble(artist: "Black Sabbath", title: "Sweet Leaf", date: at(-400)),
            RemoteScrobble(artist: "High On Fire", title: "Sons of Thunder", date: at(5)),
        ]
        #expect(RemoteScrobble.duplicate(of: song, startedAt: at(0), in: recent)?.title == "Sons of Thunder")
        #expect(RemoteScrobble.duplicate(of: song, startedAt: at(2000), in: recent) == nil)
    }
}
