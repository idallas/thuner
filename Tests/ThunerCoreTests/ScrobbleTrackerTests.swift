import Foundation
import Testing
@testable import ThunerCore

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private func obs(_ track: Track, offset: TimeInterval, at s: TimeInterval) -> MatchObservation {
    MatchObservation(track: track, offset: offset, observedAt: at(s))
}

private let short = Track(title: "Turncoat", artist: "Anti-Flag", shazamID: "1", duration: 130)
private let long = Track(title: "Epic", artist: "Band", shazamID: "2", duration: 600)
private let jingle = Track(title: "Ident", artist: "Station", shazamID: "3", duration: 20)

@Suite struct ScrobbleTrackerTests {
    @Test func thresholds() {
        #expect(ScrobbleTracker.threshold(for: short) == 65)
        #expect(ScrobbleTracker.threshold(for: long) == 240)
        #expect(ScrobbleTracker.threshold(for: jingle) == nil)
        #expect(ScrobbleTracker.threshold(for: Track(title: "x", artist: "y")) == 240)
    }

    @Test func nowPlayingThenScrobbleAtHalfway() {
        var s = ScrobbleTracker()
        // Confirmed 40s in at t=100, so it started at t=60 and qualifies at t=125.
        #expect(s.update(confirmed: obs(short, offset: 40, at: 100), audible: true, at: at(100)) == [.nowPlaying(short)])
        #expect(s.update(confirmed: obs(short, offset: 40, at: 100), audible: true, at: at(120)) == [])
        #expect(s.update(confirmed: obs(short, offset: 40, at: 100), audible: true, at: at(125)) == [.scrobble(short, startedAt: at(60))])
        #expect(s.update(confirmed: obs(short, offset: 40, at: 100), audible: true, at: at(200)) == [])
    }

    @Test func lateConfirmationScrobblesImmediately() {
        var s = ScrobbleTracker()
        let actions = s.update(confirmed: obs(short, offset: 90, at: 100), audible: true, at: at(100))
        #expect(actions == [.nowPlaying(short), .scrobble(short, startedAt: at(10))])
    }

    @Test func silenceBeforeThresholdMeansNoScrobble() {
        var s = ScrobbleTracker()
        _ = s.update(confirmed: obs(long, offset: 10, at: 20), audible: true, at: at(20))
        #expect(s.update(confirmed: nil, audible: false, at: at(100)) == [])
        #expect(s.update(confirmed: nil, audible: false, at: at(1000)) == [])
    }

    @Test func keepsCountingWhileIdentifyingTheNextTrack() {
        var s = ScrobbleTracker()
        _ = s.update(confirmed: obs(short, offset: 0, at: 0), audible: true, at: at(0))
        // Machine went to Identifying (confirmed nil) but audio is still playing.
        #expect(s.update(confirmed: nil, audible: true, at: at(70)) == [.scrobble(short, startedAt: at(0))])
    }

    @Test func resumingSameSongDoesNotDoubleScrobble() {
        var s = ScrobbleTracker()
        _ = s.update(confirmed: obs(short, offset: 70, at: 70), audible: true, at: at(70))
        _ = s.update(confirmed: nil, audible: false, at: at(80))
        let actions = s.update(confirmed: obs(short, offset: 100, at: 101), audible: true, at: at(101))
        #expect(actions == [.nowPlaying(short)])
    }

    @Test func playingTheSongAgainLaterScrobblesAgain() {
        var s = ScrobbleTracker()
        _ = s.update(confirmed: obs(short, offset: 70, at: 70), audible: true, at: at(70))
        _ = s.update(confirmed: nil, audible: false, at: at(140))
        let actions = s.update(confirmed: obs(short, offset: 70, at: 1000), audible: true, at: at(1000))
        #expect(actions == [.nowPlaying(short), .scrobble(short, startedAt: at(930))])
    }

    @Test func newTrackStartsNewPlay() {
        var s = ScrobbleTracker()
        _ = s.update(confirmed: obs(short, offset: 0, at: 0), audible: true, at: at(0))
        #expect(s.update(confirmed: obs(long, offset: 5, at: 30), audible: true, at: at(30)) == [.nowPlaying(long)])
        #expect(s.play?.track == long)
    }
}
