import Testing
@testable import ThunerCore

struct SplittingArtistTests {
    /// KCRW over AirPlay: the show as the title, "Song - Artist" as the artist.
    @Test func readsSongAndArtistFromTheArtistField() {
        let reported = Track(title: "On Air - Morning Becomes Eclectic", artist: "Policy of Truth - Depeche Mode", album: "Violator")
        let readings = reported.splittingArtist()
        #expect(readings.map(\.title) == ["Policy of Truth", "Depeche Mode"])
        #expect(readings.map(\.artist) == ["Depeche Mode", "Policy of Truth"])
        #expect(readings.allSatisfy { $0.album == "Violator" })
    }

    @Test func leavesAPlainArtistAlone() {
        #expect(Track(title: "Kerosene", artist: "King Buffalo").splittingArtist().isEmpty)
        #expect(Track(title: "x", artist: "Jay-Z").splittingArtist().isEmpty)
        #expect(Track(title: "x", artist: "Name - ").splittingArtist().isEmpty)
    }
}
