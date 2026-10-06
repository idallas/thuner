import Foundation
import Testing
@testable import ThunerCore

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private let songA = Track(title: "Pool Tunes", artist: "Artist A", shazamID: "1", duration: 200)
private let songB = Track(title: "Another One", artist: "Artist B", shazamID: "2")

private func match(_ track: Track, offset: TimeInterval = 30, at s: TimeInterval) -> MatchOutcome {
    .match(MatchObservation(track: track, offset: offset, observedAt: at(s)))
}

@Suite struct NowPlayingMachineTests {
    @Test func staysQuietWhileIdle() {
        var m = NowPlayingMachine()
        #expect(m.tick(at: at(100)) == [])
        #expect(m.state == .idle)
    }

    @Test func firstQueryWaitsForASampleOfAudio() {
        var m = NowPlayingMachine()
        _ = m.audioStarted(at: at(0))
        #expect(m.tick(at: at(5)) == [])
        #expect(m.tick(at: at(10)) == [.query])
        // No second query while one is in flight.
        #expect(m.tick(at: at(30)) == [])
    }

    @Test func needsTwoAgreeingResultsToPush() {
        var m = NowPlayingMachine()
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        #expect(m.handle(match(songA, at: 11), at: at(11)) == [])
        #expect(m.state == .identifying)
        #expect(m.tick(at: at(23)) == [.query])
        #expect(m.handle(match(songA, offset: 42, at: 24), at: at(24)) == [.push(songA)])
        #expect(m.state == .playing)
    }

    @Test func disagreeingResultsDontPush() {
        var m = NowPlayingMachine()
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        _ = m.handle(match(songA, at: 11), at: at(11))
        _ = m.tick(at: at(23))
        #expect(m.handle(match(songB, at: 24), at: at(24)) == [])
        #expect(m.candidate == songB)
        _ = m.tick(at: at(36))
        #expect(m.handle(match(songB, at: 37), at: at(37)) == [.push(songB)])
    }

    @Test func noMatchBreaksTheStreak() {
        var m = NowPlayingMachine()
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        _ = m.handle(match(songA, at: 11), at: at(11))
        _ = m.tick(at: at(23))
        _ = m.handle(.noMatch, at: at(24))
        _ = m.tick(at: at(36))
        #expect(m.handle(match(songA, at: 37), at: at(37)) == [])
        #expect(m.state == .identifying)
    }

    @Test func playingChecksNearPredictedEnd() {
        var m = NowPlayingMachine()
        confirm(&m, songA, offsetAtConfirm: 50, confirmAt: 24)
        // 200s track, 50s in at t=24 -> ends at t=174, check at 179.
        #expect(m.nextQueryAt == at(179))
    }

    @Test func playingSpotChecksWhenLengthUnknown() {
        var m = NowPlayingMachine()
        confirm(&m, songB, offsetAtConfirm: 50, confirmAt: 24)
        #expect(m.nextQueryAt == at(24 + 75))
    }

    @Test func differentResultWhilePlayingNeedsConfirmation() {
        var m = NowPlayingMachine()
        confirm(&m, songA, offsetAtConfirm: 50, confirmAt: 24)
        _ = m.tick(at: at(179))
        #expect(m.handle(match(songB, at: 180), at: at(180)) == [])
        #expect(m.state == .identifying)
        #expect(m.displayed == songA)
        _ = m.tick(at: at(192))
        #expect(m.handle(match(songB, at: 193), at: at(193)) == [.push(songB)])
    }

    @Test func shortGapKeepsCoverAndResumesWithOneMatch() {
        var m = NowPlayingMachine()
        confirm(&m, songA, offsetAtConfirm: 50, confirmAt: 24)
        _ = m.audioStopped(at: at(60))
        #expect(m.state == .idle)
        #expect(m.displayed == songA)
        _ = m.audioStarted(at: at(70))
        _ = m.tick(at: at(80))
        // Same song as what's on screen: confirm without a second query, and don't re-push.
        #expect(m.handle(match(songA, at: 81), at: at(81)) == [])
        #expect(m.state == .playing)
    }

    @Test func longSilenceShowsIdleImageOnce() {
        var m = NowPlayingMachine()
        confirm(&m, songA, offsetAtConfirm: 50, confirmAt: 24)
        _ = m.audioStopped(at: at(60))
        #expect(m.tick(at: at(300)) == [])
        #expect(m.tick(at: at(360)) == [.showIdleImage])
        #expect(m.tick(at: at(400)) == [])
        #expect(m.displayed == nil)
    }

    @Test func idleImageCanBeDisabled() {
        var timing = NowPlayingMachine.Timing()
        timing.idleImageDelay = nil
        var m = NowPlayingMachine(timing: timing)
        confirm(&m, songA, offsetAtConfirm: 50, confirmAt: 24)
        _ = m.audioStopped(at: at(60))
        #expect(m.tick(at: at(10_000)) == [])
        #expect(m.displayed == songA)
    }

    @Test func staleResultAfterSilenceIsIgnored() {
        var m = NowPlayingMachine()
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        _ = m.audioStopped(at: at(11))
        #expect(m.handle(match(songA, at: 12), at: at(12)) == [])
        #expect(m.state == .idle)
        #expect(!m.queryInFlight)
    }

    private func confirm(_ m: inout NowPlayingMachine, _ track: Track, offsetAtConfirm: TimeInterval, confirmAt: TimeInterval) {
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        _ = m.handle(match(track, at: 11), at: at(11))
        _ = m.tick(at: at(confirmAt - 1))
        _ = m.handle(match(track, offset: offsetAtConfirm, at: confirmAt), at: at(confirmAt))
        #expect(m.state == .playing)
    }
}

@Suite struct LevelGateTests {
    @Test func opensAfterAttackAndClosesAfterRelease() {
        var g = LevelGate(thresholdDB: -45, hysteresisDB: 3, attack: 1, release: 8)
        #expect(g.feed(levelDB: -30, at: at(0)) == nil)
        #expect(g.feed(levelDB: -30, at: at(1)) == .opened)
        // Inside the hysteresis band doesn't count as silence.
        #expect(g.feed(levelDB: -46, at: at(2)) == nil)
        #expect(g.feed(levelDB: -46, at: at(20)) == nil)
        #expect(g.feed(levelDB: -60, at: at(21)) == nil)
        #expect(g.feed(levelDB: -60, at: at(28)) == nil)
        #expect(g.feed(levelDB: -60, at: at(29)) == .closed)
    }

    @Test func briefDipDoesNotClose() {
        var g = LevelGate(thresholdDB: -45, attack: 0, release: 8)
        _ = g.feed(levelDB: -20, at: at(0))
        #expect(g.isOpen)
        _ = g.feed(levelDB: -70, at: at(1))
        _ = g.feed(levelDB: -70, at: at(5))
        _ = g.feed(levelDB: -20, at: at(6))
        #expect(g.feed(levelDB: -70, at: at(10)) == nil)
        #expect(g.isOpen)
    }
}

@Suite struct TrackTests {
    @Test func sameSongAcrossCatalogEntries() {
        let a = Track(title: "Heroes (2017 Remaster)", artist: "David Bowie", shazamID: "1")
        let b = Track(title: "\"Heroes\"", artist: "David Bowie", shazamID: "2")
        #expect(a.isSameSong(as: b))
        #expect(!a.isSameSong(as: Track(title: "Fame", artist: "David Bowie")))
    }
}

@Suite struct PushArbiterTests {
    @Test func secondaryDefersToRecentPrimary() {
        var a = PushArbiter(role: .secondary, quietWindow: 300)
        #expect(a.mayPush(at: at(0)))
        a.primaryWasActive(at: at(10))
        #expect(!a.mayPush(at: at(200)))
        #expect(a.mayPush(at: at(310)))
    }

    @Test func primaryAlwaysPushes() {
        var a = PushArbiter(role: .primary)
        a.primaryWasActive(at: at(0))
        #expect(a.mayPush(at: at(1)))
    }
}

@Suite struct ExternalDisplayTests {
    private let a = Track(title: "Pool Tunes", artist: "Artist A", shazamID: "1")
    private let b = Track(title: "Another One", artist: "Artist B", shazamID: "2")

    @Test func shazamOfSameSongAsPlayerDoesNotRepush() {
        var m = NowPlayingMachine()
        m.displayedExternally(a)
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        #expect(m.handle(.match(MatchObservation(track: a, offset: 30, observedAt: at(11))), at: at(11)) == [])
        #expect(m.state == .playing)
    }

    @Test func differentSongAfterPlayerStillNeedsConfirmation() {
        var m = NowPlayingMachine()
        m.displayedExternally(a)
        _ = m.audioStarted(at: at(0))
        _ = m.tick(at: at(10))
        #expect(m.handle(.match(MatchObservation(track: b, offset: 30, observedAt: at(11))), at: at(11)) == [])
        _ = m.tick(at: at(23))
        #expect(m.handle(.match(MatchObservation(track: b, offset: 42, observedAt: at(24))), at: at(24)) == [.push(b)])
    }
}
