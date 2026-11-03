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

struct WithoutBracketsTests {
    @Test func dropsTagsAndCredits() {
        #expect(Track.withoutBrackets("Lean (feat. Saya Gray) [CLEAN]") == "Lean")
        #expect(Track.withoutBrackets("Flower In A Hurricane (feat. Tame Impala, SZA) (Radio Edit)") == "Flower In A Hurricane")
        #expect(Track.withoutBrackets("Kerosene") == "Kerosene")
        #expect(Track.withoutBrackets("Don't Stop (Color on the Walls)") == "Don't Stop")
    }
}
