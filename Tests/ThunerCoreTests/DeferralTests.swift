import Testing
@testable import ThunerCore

@Suite struct DeferralTests {
    @Test func defersToNoOneByDefault() {
        #expect(Deferral.resolve(chosen: nil, streamingFrom: nil, me: ["trithena"], peersDeferTo: [:]) == .none)
    }

    @Test func defersToTheChosenMac() {
        let d = Deferral.resolve(chosen: "echo", streamingFrom: nil, me: ["trithena"], peersDeferTo: ["echo": "nobody"])
        #expect(d.target == "echo")
        #expect(!d.viaStream)
        #expect(!d.mutual)
    }

    @Test func aStreamWinsOverTheSetting() {
        let d = Deferral.resolve(chosen: "echo", streamingFrom: "studio", me: ["trithena"], peersDeferTo: [:])
        #expect(d.target == "studio")
        #expect(d.viaStream)
        // Playing a stream defers even with no one chosen.
        #expect(Deferral.resolve(chosen: nil, streamingFrom: "echo", me: ["trithena"], peersDeferTo: [:]).target == "echo")
    }

    @Test func twoMacsDeferringToEachOtherAgreeWhichOneStops() {
        // echo sorts first, so echo stops deferring and trithena keeps deferring to it.
        let onEcho = Deferral.resolve(chosen: "trithena", streamingFrom: nil, me: ["echo"], peersDeferTo: ["trithena": "echo"])
        let onTrithena = Deferral.resolve(chosen: "echo", streamingFrom: nil, me: ["trithena"], peersDeferTo: ["echo": "trithena"])
        #expect(onEcho.target == nil)
        #expect(onEcho.mutual && onEcho.mutualWith == "trithena")
        #expect(onTrithena.target == "echo")
        #expect(onTrithena.mutual)
    }

    @Test func namesMatchAcrossComputerAndHostNames() {
        #expect(Deferral.sameMac("Dallas's Mac mini", "Dallass-Mac-mini.local"))
        #expect(Deferral.sameMac("echo", "ECHO.local."))
        #expect(!Deferral.sameMac("echo", "echo2"))
        // The other Mac names this one by its host name; this Mac knows its computer name first.
        let d = Deferral.resolve(chosen: "echo", streamingFrom: nil, me: ["Dallas's MacBook Pro", "Dallass-MacBook-Pro.local"],
                                 peersDeferTo: ["echo": "Dallass-MacBook-Pro"])
        #expect(d.mutual)
    }
}
