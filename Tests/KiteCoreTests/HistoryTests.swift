import Foundation
import Testing
@testable import KiteCore

@Suite struct HistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsWebPagesOnly() {
        var history = History()
        history.recordVisit(URL(string: "https://example.com/a")!, title: "A", at: now)
        history.recordVisit(URL(string: "about:blank")!, title: "", at: now)
        history.recordVisit(URL(string: "view-source:https://example.com")!, title: "", at: now)
        #expect(history.entries.count == 1)
    }

    @Test func repeatVisitsCountAndKeepTheTitle() {
        var history = History()
        let url = URL(string: "https://example.com/")!
        history.recordVisit(url, title: "", at: now)
        history.updateTitle(url, "Example Domain")
        history.recordVisit(url, title: "", at: now.addingTimeInterval(60))
        let entry = history.entries[url.absoluteString]
        #expect(entry?.visitCount == 2)
        #expect(entry?.title == "Example Domain")
        #expect(entry?.lastVisit == now.addingTimeInterval(60))
    }

    @Test func searchRanksHostThenTitleThenFrecency() {
        var history = History()
        history.recordVisit(URL(string: "https://github.com/gabekus/kite")!, title: "gabekus/kite", at: now)
        history.recordVisit(URL(string: "https://news.ycombinator.com/")!, title: "Hacker News", at: now)
        history.recordVisit(URL(string: "https://example.com/git")!, title: "Learn Git", at: now)
        let results = history.search("git", now: now)
        #expect(results.map(\.url.host) == ["github.com", "example.com"])
        #expect(history.search("hack", now: now).first?.title == "Hacker News")
        #expect(history.search("zzz", now: now).isEmpty)
        #expect(history.search("  ", now: now).isEmpty)
    }

    @Test func frequentAndRecentPagesWinTies() {
        var history = History()
        let old = URL(string: "https://docs.swift.org/old")!
        let often = URL(string: "https://docs.swift.org/often")!
        history.recordVisit(old, title: "Swift docs", at: now.addingTimeInterval(-60 * 86_400))
        for i in 0..<5 { history.recordVisit(often, title: "Swift docs", at: now.addingTimeInterval(Double(-i))) }
        #expect(history.search("swift", now: now).first?.url == often)
    }

    @Test func roundTripsThroughJSON() throws {
        var history = History()
        history.recordVisit(URL(string: "https://example.com/")!, title: "Example", at: now)
        let decoded = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}
