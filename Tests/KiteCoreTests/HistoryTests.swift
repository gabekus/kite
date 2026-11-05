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

    /// Accents match whether a page wrote them precomposed or as combining marks, and either case.
    @Test func searchMatchesAccentsAndCase() {
        var history = History()
        history.recordVisit(URL(string: "https://example.com/menu")!, title: "Cafe\u{301} Menu", at: now)
        history.recordVisit(URL(string: "https://example.com/uber")!, title: "ÜBER uns", at: now)
        #expect(history.search("café", now: now).first?.url.path() == "/menu")
        #expect(history.search("über", now: now).first?.url.path() == "/uber")
        #expect(history.search("cafe", now: now).isEmpty)
    }

    /// The search keeps only the best `limit` as it goes; that must pick what sorting every match did.
    @Test func searchPicksWhatSortingEveryMatchPicked() {
        var history = History()
        var generator = SeededGenerator(seed: 7)
        let hosts = ["github.com", "www.google.com", "docs.swift.org", "en.wikipedia.org", "x.com"]
        let words = ["Swift", "Kite", "browser", "Pull", "request", "Café", "release", "notes", "Git", "go"]
        for i in 0..<600 {
            let host = hosts[Int(generator.next() % UInt64(hosts.count))]
            let title = (0..<3).map { _ in words[Int(generator.next() % UInt64(words.count))] }.joined(separator: " ")
            let url = URL(string: "https://\(host)/\(i)")!
            for _ in 0..<Int(generator.next() % 4) + 1 {
                history.recordVisit(url, title: title, at: now.addingTimeInterval(-Double(generator.next() % 8_000_000)))
            }
        }
        for query in ["g", "gi", "git", "go", "sw", "café", "re", "x", "1", "notes k", "zzz"] {
            for limit in [1, 4, 6] {
                let reference = Self.referenceSearch(history, query, limit: limit, now: now)
                #expect(history.search(query, limit: limit, now: now).map(\.url) == reference.map(\.url), "\(query) \(limit)")
            }
        }
    }

    /// Main's search before HistorySearchItem: every entry scored on lowercased copies, then sorted.
    private static func referenceSearch(_ history: History, _ query: String, limit: Int, now: Date) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ entry: HistoryEntry) -> Int? {
            let title = entry.title.lowercased()
            let host = (entry.url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
            let url = entry.url.absoluteString.lowercased()
            if host.hasPrefix(q) { return 100 }
            if title.hasPrefix(q) { return 90 }
            if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 75 }
            if title.contains(q) { return 55 }
            if url.contains(q) { return 40 }
            return nil
        }
        return history.entries.values.compactMap { entry -> (HistoryEntry, Double)? in
            guard let match = score(entry) else { return nil }
            let days = max(0, now.timeIntervalSince(entry.lastVisit)) / 86_400
            return (entry, Double(match) + log2(Double(entry.visitCount) + 1) * 8 - min(days, 90) / 3)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastVisit > $1.0.lastVisit }
        .prefix(limit).map(\.0)
    }

    @Test func roundTripsThroughJSON() throws {
        var history = History()
        history.recordVisit(URL(string: "https://example.com/")!, title: "Example", at: now)
        let decoded = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }

    // MARK: History page

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func pageGroupsByDayNewestFirstAndSearches() {
        var history = History()
        // 1_800_000_000 is 2027-01-15 08:00 UTC.
        history.recordVisit(URL(string: "https://a.com/")!, title: "Alpha", at: now)
        history.recordVisit(URL(string: "https://b.com/")!, title: "Beta", at: now.addingTimeInterval(3600))
        history.recordVisit(URL(string: "https://c.com/x")!, title: "Gamma", at: now.addingTimeInterval(-86_400))
        let days = history.days(calendar: utc)
        #expect(days.map { $0.entries.map(\.title) } == [["Beta", "Alpha"], ["Gamma"]])
        #expect(days[1].start == utc.startOfDay(for: now.addingTimeInterval(-86_400)))
        // Title or URL, any case.
        #expect(history.days(matching: "GAM", calendar: utc).flatMap(\.entries).map(\.title) == ["Gamma"])
        #expect(history.days(matching: "c.com/x", calendar: utc).count == 1)
        #expect(history.days(matching: "zzz", calendar: utc).isEmpty)
    }

    @Test func pageRemovesEntries() {
        var history = History()
        history.recordVisit(URL(string: "https://a.com/")!, title: "A", at: now)
        history.recordVisit(URL(string: "https://b.com/")!, title: "B", at: now)
        history.remove([URL(string: "https://a.com/")!])
        #expect(history.entries.keys.sorted() == ["https://b.com/"])
    }

    @Test func dayHeadingsMatchChromium() {
        let locale = Locale(identifier: "en_US")
        let today = HistoryDay(start: utc.startOfDay(for: now), entries: [])
        let yesterday = HistoryDay(start: utc.startOfDay(for: now.addingTimeInterval(-86_400)), entries: [])
        let older = HistoryDay(start: utc.startOfDay(for: now.addingTimeInterval(-3 * 86_400)), entries: [])
        #expect(today.heading(now: now, calendar: utc, locale: locale) == "Today - Friday, January 15, 2027")
        #expect(yesterday.heading(now: now, calendar: utc, locale: locale) == "Yesterday - Thursday, January 14, 2027")
        #expect(older.heading(now: now, calendar: utc, locale: locale) == "Tuesday, January 12, 2027")
    }

    @Test func internalPageURLs() {
        #expect(InternalPage(URL(string: "kite://history")) == .history)
        #expect(InternalPage(URL(string: "KITE://History")) == .history)
        #expect(InternalPage(URL(string: "kite://nope")) == nil)
        #expect(InternalPage(URL(string: "https://history")) == nil)
        #expect(InternalPage.history.url.absoluteString == "kite://history")
        #expect(!History.records(InternalPage.history.url))
    }
}

/// A repeatable generator for tests that want varied data (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
