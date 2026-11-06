import Foundation
import Testing
@testable import ThunerCore

@Suite struct SourceSwitchesTests {
    @Test func everySourceIsOnUntilSwitchedOff() {
        var sources = SourceSwitches()
        #expect(sources.allows("KCRW (AirPlay)"))
        sources.set("KCRW (AirPlay)", on: false)
        #expect(!sources.allows("KCRW (AirPlay)"))
        #expect(sources.allows("Apple Music"))
        sources.set("KCRW (AirPlay)", on: true)
        #expect(sources.off.isEmpty && sources.on.isEmpty)
    }

    @Test func sendersFollowTheAirPlayGroup() {
        var s = SourceSwitches()
        s.set("AirPlay", on: false)
        // A sender never seen before, and one seen, both follow the group.
        #expect(!s.allows("KCRW (AirPlay)"))
        #expect(!s.allows("Music (AirPlay)"))
        #expect(!s.overrides("KCRW (AirPlay)"))
        // Plain "AirPlay" plays (from before senders were named) are the group itself.
        #expect(!s.allows("AirPlay"))
        #expect(s.allows("VOX"))
    }

    @Test func aSenderCanOverrideItsGroup() {
        var s = SourceSwitches()
        s.set("AirPlay", on: false)
        s.set("Music (AirPlay)", on: true)
        #expect(s.allows("Music (AirPlay)") && !s.allows("KCRW (AirPlay)"))
        #expect(s.overrides("Music (AirPlay)"))
        #expect(s.on == ["Music (AirPlay)"])
        // Set back to what the group says: no override is kept.
        s.set("Music (AirPlay)", on: false)
        #expect(!s.overrides("Music (AirPlay)"))
        #expect(s.on.isEmpty)

        // Group on, one sender off.
        var t = SourceSwitches()
        t.set("KCRW (AirPlay)", on: false)
        #expect(!t.allows("KCRW (AirPlay)") && t.allows("Music (AirPlay)") && t.allows("AirPlay"))
        #expect(t.overrides("KCRW (AirPlay)"))
    }

    @Test func flippingTheGroupResetsItsSenders() {
        var s = SourceSwitches()
        s.set("KCRW (AirPlay)", on: false)
        s.set("VOX", on: false)
        s.set("AirPlay", on: false)
        #expect(!s.overrides("KCRW (AirPlay)"))
        #expect(!s.allows("VOX"))  // not AirPlay's business
        s.set("AirPlay", on: true)
        #expect(s.allows("KCRW (AirPlay)"))
        #expect(s.off == ["VOX"] && s.on.isEmpty)
    }

    @Test func existingSettingsStillHold() {
        // Dallas's own before the group: AirPlay and KCRW both switched off by hand.
        let s = SourceSwitches(off: ["AirPlay", "KCRW (AirPlay)", "VOX"])
        #expect(!s.allows("AirPlay") && !s.allows("KCRW (AirPlay)") && !s.allows("Music (AirPlay)") && !s.allows("VOX"))
        #expect(s.allows("Spotify"))
    }

    @Test func notificationsStartWithApplePlayersOff() {
        let s = SourceSwitches.forNotifications()
        #expect(!s.allows("Apple Music") && !s.allows("Spotify"))
        #expect(s.allows("Shazam") && s.allows("echo") && s.allows("KCRW (AirPlay)"))
    }

    @Test func rowsPutSendersUnderTheGroup() {
        let rows = SourceSwitches.rows(for: ["VOX", "KCRW (AirPlay)", "Apple Music", "Music (AirPlay)", "echo"])
        #expect(rows.map(\.name) == ["AirPlay", "KCRW (AirPlay)", "Music (AirPlay)", "Apple Music", "echo", "VOX"])
        #expect(rows[0].isGroup && rows[0].group == nil)
        #expect(rows[1].group == "AirPlay" && !rows[1].isGroup)
        #expect(rows[3].group == nil)
        // The group alone (old plays named "AirPlay") is a group row too; no group row without a reason.
        #expect(SourceSwitches.rows(for: ["AirPlay"]) == [.init(name: "AirPlay", group: nil, isGroup: true)])
        #expect(SourceSwitches.rows(for: ["VOX"]).map(\.name) == ["VOX"])
    }

    @Test func theButtonIsAboutTheSourcePlaying() {
        let sources = SourceSwitches()
        // Playing Apple Music, scrobbling: a press stops scrobbling Apple Music, and only that.
        var r = SourceSwitches.press(source: "Apple Music", paused: false, sources: sources)
        #expect(!r.paused && !r.sources.allows("Apple Music") && r.sources.allows("Spotify"))
        // Pressed again: Apple Music scrobbles again.
        r = SourceSwitches.press(source: "Apple Music", paused: false, sources: r.sources)
        #expect(!r.paused && r.sources.allows("Apple Music"))
        // Paused everything, KCRW switched off, press while KCRW plays: resume, and KCRW is on (that's what was asked).
        r = SourceSwitches.press(source: "KCRW (AirPlay)", paused: true, sources: SourceSwitches(off: ["KCRW (AirPlay)", "Spotify"]))
        #expect(!r.paused && r.sources.allows("KCRW (AirPlay)") && !r.sources.allows("Spotify"))
        // Paused, source on: just resume.
        r = SourceSwitches.press(source: "Apple Music", paused: true, sources: sources)
        #expect(!r.paused && r.sources == sources)
        // KCRW plays with all AirPlay off: the press switches KCRW on as an override, not the whole group.
        r = SourceSwitches.press(source: "KCRW (AirPlay)", paused: false, sources: SourceSwitches(off: ["AirPlay"]))
        #expect(r.sources.allows("KCRW (AirPlay)") && !r.sources.allows("Music (AirPlay)"))
    }

    @Test func withNothingPlayingTheButtonPausesEverything() {
        let off = SourceSwitches(off: ["Spotify"])
        var r = SourceSwitches.press(source: nil, paused: false, sources: off)
        #expect(r.paused && r.sources == off)
        r = SourceSwitches.press(source: nil, paused: true, sources: off)
        #expect(!r.paused && r.sources == off)
    }
}
