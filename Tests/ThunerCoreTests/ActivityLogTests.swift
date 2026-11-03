import Foundation
import Testing
@testable import ThunerCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func entry(_ id: Int, _ message: String, level: ActivityLog.Level = .activity, category: String = "app",
                   date: Date = now, error: Bool = false) -> ActivityLog.Entry {
    ActivityLog.Entry(id: id, date: date, level: level, category: category, message: message, isError: error)
}

@Suite struct ActivityLogTests {
    @Test func fileLinesRoundTrip() {
        let entries = [
            entry(1, "Found a Tuneshine", category: "tuneshine"),
            entry(2, "Sent push to 1 ThUNER(s)", level: .detail, category: "peers"),
            entry(3, "Couldn't start the web server", level: .detail, category: "web", error: true),
            entry(4, "Quotes \"and\" a newline\nin the message"),
        ]
        let text = entries.map(ActivityLog.line(for:)).joined(separator: "\n") + "\n"
        let back = ActivityLog.entries(in: text, firstID: 1)
        #expect(back.count == 4)
        for (a, b) in zip(entries, back) {
            #expect(a.level == b.level)
            #expect(a.category == b.category)
            #expect(a.message == b.message)
            #expect(a.isError == b.isError)
            #expect(abs(a.date.timeIntervalSince(b.date)) < 0.001)
        }
        #expect(back.map(\.id) == [1, 2, 3, 4])
    }

    @Test func badLinesAreSkipped() {
        let text = ActivityLog.line(for: entry(1, "fine")) + "\nnot json\n{\"t\":1}\n" + ActivityLog.line(for: entry(2, "also fine"))
        let back = ActivityLog.entries(in: text, firstID: 10)
        #expect(back.map(\.message) == ["fine", "also fine"])
        #expect(back.map(\.id) == [10, 11])
    }

    @Test func trimsByAge() {
        let entries = [
            entry(1, "old activity", date: ago(31)),
            entry(2, "kept activity", date: ago(29)),
            entry(3, "old detail", level: .detail, date: ago(3)),
            entry(4, "kept detail", level: .detail, date: ago(1)),
            entry(5, "now"),
        ]
        #expect(ActivityLog.trimmed(entries, now: now).map(\.id) == [2, 4, 5])
    }

    @Test func trimsOldestWhenOverBudget() {
        let entries = (1...100).map { entry($0, String(repeating: "x", count: 100), date: ago(Double(100 - $0) / 1000)) }
        let kept = ActivityLog.trimmed(entries, now: now, maxBytes: 3000)
        #expect(kept.count < 100)
        #expect(kept.count > 10)
        #expect(kept.last?.id == 100)
        #expect(kept.first!.id == 101 - kept.count)
    }

    @Test func filterLevelsCategoriesAndSearch() {
        let plain = entry(1, "Playing: Policy of Truth", category: "app")
        let detail = entry(2, "Heard push from echo", level: .detail, category: "peers")
        let error = entry(3, "bind() failed", level: .detail, category: "peers", error: true)

        var filter = ActivityLog.Filter(level: .activity)
        #expect(filter.matches(plain))
        #expect(!filter.matches(detail))
        #expect(filter.matches(error), "errors show at the Activity level")

        filter.level = .detail
        #expect(filter.matches(detail))
        filter.category = "peers"
        #expect(!filter.matches(plain))
        #expect(filter.matches(detail))
        filter.category = nil
        filter.search = "POLICY"
        #expect(filter.matches(plain))
        #expect(!filter.matches(detail))
        filter.search = "peers"
        #expect(filter.matches(detail), "the category counts as text too")
    }

    @Test func copyText() {
        let text = ActivityLog.text([
            entry(1, "Hello", category: "app", date: Date(timeIntervalSince1970: 0)),
            entry(2, "Oops", category: "web", date: Date(timeIntervalSince1970: 61), error: true),
        ], timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == "1970-01-01 00:00:00  [app] Hello\n1970-01-01 00:01:01  ERROR [web] Oops")
    }

    @Test func categoryNames() {
        #expect(ActivityLog.name(ofCategory: "peers") == "Other Macs")
        #expect(ActivityLog.name(ofCategory: "whatever") == "Whatever")
    }
}
