import Foundation
import Testing
@testable import ThunerCore

@Suite struct ScrobbleSourcesTests {
    @Test func everySourceScrobblesUntilSwitchedOff() {
        var sources = ScrobbleSources()
        #expect(sources.allows("KCRW (AirPlay)"))
        sources.set("KCRW (AirPlay)", on: false)
        #expect(!sources.allows("KCRW (AirPlay)"))
        #expect(sources.allows("Apple Music"))
        sources.set("KCRW (AirPlay)", on: true)
        #expect(sources.off.isEmpty)
    }

    @Test func theButtonIsAboutTheSourcePlaying() {
        let sources = ScrobbleSources()
        // Playing Apple Music, scrobbling: a press stops scrobbling Apple Music, and only that.
        var r = ScrobbleSources.press(source: "Apple Music", paused: false, sources: sources)
        #expect(!r.paused && !r.sources.allows("Apple Music") && r.sources.allows("Spotify"))
        // Pressed again: Apple Music scrobbles again.
        r = ScrobbleSources.press(source: "Apple Music", paused: false, sources: r.sources)
        #expect(!r.paused && r.sources.allows("Apple Music"))
        // Paused everything, KCRW switched off, press while KCRW plays: resume, and KCRW is on (that's what was asked).
        r = ScrobbleSources.press(source: "KCRW (AirPlay)", paused: true, sources: ScrobbleSources(off: ["KCRW (AirPlay)", "Spotify"]))
        #expect(!r.paused && r.sources.allows("KCRW (AirPlay)") && !r.sources.allows("Spotify"))
        // Paused, source on: just resume.
        r = ScrobbleSources.press(source: "Apple Music", paused: true, sources: sources)
        #expect(!r.paused && r.sources == sources)
    }

    @Test func withNothingPlayingTheButtonPausesEverything() {
        let off = ScrobbleSources(off: ["Spotify"])
        var r = ScrobbleSources.press(source: nil, paused: false, sources: off)
        #expect(r.paused && r.sources == off)
        r = ScrobbleSources.press(source: nil, paused: true, sources: off)
        #expect(!r.paused && r.sources == off)
    }
}
