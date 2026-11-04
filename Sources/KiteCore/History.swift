import Foundation

/// One visited page in browsing history.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visitCount: Int

    public init(url: URL, title: String, lastVisit: Date, visitCount: Int = 1) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visitCount = visitCount
    }

    public var displayTitle: String { title.isEmpty ? (url.host() ?? url.absoluteString) : title }
}

/// One day of the history page, newest entry first.
public struct HistoryDay: Hashable, Sendable {
    public var start: Date
    public var entries: [HistoryEntry]

    public init(start: Date, entries: [HistoryEntry]) {
        self.start = start
        self.entries = entries
    }

    /// Chromium's history page headings: "Today - Saturday, October 31, 2026",
    /// "Yesterday - Friday, October 30, 2026", then the date alone.
    public func heading(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let date = formatter.string(from: start)
        let today = calendar.startOfDay(for: now)
        if start == today { return "Today - " + date }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), start == yesterday {
            return "Yesterday - " + date
        }
        return date
    }
}

/// Browsing history, one entry per URL, for the command bar's history results.
/// Only web pages are kept; incognito windows never record.
public struct History: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Oldest entries beyond this are dropped.
    public static let maxEntries = 20_000

    public private(set) var entries: [String: HistoryEntry] = [:]

    public init() {}

    public static func records(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    public mutating func recordVisit(_ url: URL, title: String, at date: Date = Date()) {
        guard Self.records(url) else { return }
        let key = url.absoluteString
        if var entry = entries[key] {
            entry.visitCount += 1
            entry.lastVisit = date
            if !title.isEmpty { entry.title = title }
            entries[key] = entry
        } else {
            entries[key] = HistoryEntry(url: url, title: title, lastVisit: date)
            if entries.count > Self.maxEntries { prune(to: Self.maxEntries * 9 / 10) }
        }
    }

    /// A page's title usually arrives after its URL.
    public mutating func updateTitle(_ url: URL, _ title: String) {
        guard !title.isEmpty else { return }
        entries[url.absoluteString]?.title = title
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// Adds history from another browser (Import from Arc). A page already here keeps the
    /// later visit and the higher count, so importing twice doesn't double anything.
    /// Returns how many pages were new.
    @discardableResult
    public mutating func merge(_ imported: [HistoryEntry]) -> Int {
        var added = 0
        for entry in imported where Self.records(entry.url) {
            let key = entry.url.absoluteString
            guard var existing = entries[key] else {
                entries[key] = entry
                added += 1
                continue
            }
            existing.visitCount = max(existing.visitCount, entry.visitCount)
            if entry.lastVisit > existing.lastVisit {
                existing.lastVisit = entry.lastVisit
                if !entry.title.isEmpty { existing.title = entry.title }
            }
            if existing.title.isEmpty { existing.title = entry.title }
            entries[key] = existing
        }
        if entries.count > Self.maxEntries { prune(to: Self.maxEntries) }
        return added
    }

    /// Chromium's history timestamps: microseconds since 1601-01-01 UTC.
    public static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    /// The history page's Remove from History.
    public mutating func remove(_ urls: some Sequence<URL>) {
        for url in urls { entries[url.absoluteString] = nil }
    }

    /// The history page's list: newest first, grouped by the day of the last visit, keeping
    /// entries whose title or URL contains `query` (case-insensitive), as Chromium's history
    /// search does.
    public func days(matching query: String = "", calendar: Calendar = .current) -> [HistoryDay] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = entries.values.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
        var days: [HistoryDay] = []
        for entry in matching.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            let start = calendar.startOfDay(for: entry.lastVisit)
            if days.last?.start == start {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(HistoryDay(start: start, entries: [entry]))
            }
        }
        return days
    }

    private mutating func prune(to count: Int) {
        let keep = entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(count)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.url.absoluteString, $0) })
    }

    /// Best matches first: how well the title, host or URL matches, then how
    /// often and how recently the page was visited.
    public func search(_ query: String, limit: Int = 4, now: Date = Date()) -> [HistoryEntry] {
        Self.search(query, in: entries.values.lazy.map(HistorySearchItem.init), limit: limit, now: now)
    }

    /// `search` over entries made ready beforehand (HistoryStore keeps them between keystrokes).
    public static func search(_ query: String, in items: some Sequence<HistorySearchItem>, limit: Int = 4,
                              now: Date = Date()) -> [HistoryEntry] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, limit > 0 else { return [] }
        let q = HistorySearchItem.Needle(lowered)
        // The best `limit`, best first, kept as they come: a short query matches most of history.
        var best: [(entry: HistoryEntry, score: Double)] = []
        func ranks(_ a: (entry: HistoryEntry, score: Double), above b: (entry: HistoryEntry, score: Double)) -> Bool {
            a.score != b.score ? a.score > b.score : a.entry.lastVisit > b.entry.lastVisit
        }
        for item in items {
            guard let match = item.score(q) else { continue }
            let entry = item.entry
            let days = max(0, now.timeIntervalSince(entry.lastVisit)) / 86_400
            let frecency = log2(Double(entry.visitCount) + 1) * 8 - min(days, 90) / 3
            let scored = (entry: entry, score: Double(match) + frecency)
            if best.count == limit {
                guard ranks(scored, above: best[limit - 1]) else { continue }
                best.removeLast()
            }
            best.insert(scored, at: best.firstIndex { ranks(scored, above: $0) } ?? best.endIndex)
        }
        return best.map(\.entry)
    }

    static func score(_ q: String, _ entry: HistoryEntry) -> Int? {
        HistorySearchItem(entry).score(HistorySearchItem.Needle(q))
    }
}

/// A history entry as `History.search` compares it: lowercased once, in NFC, as UTF-8, so that each
/// keystroke compares bytes rather than lowercasing every title and URL in history again (with 20,000
/// entries that was over 150 ms a keystroke on the main thread).
public struct HistorySearchItem: Sendable {
    public let entry: HistoryEntry
    private let title: [UInt8]
    private let host: [UInt8]
    private let url: [UInt8]
    /// For the word starts, which go by Character.
    private let lowercasedTitle: String

    public init(_ entry: HistoryEntry) {
        self.entry = entry
        lowercasedTitle = entry.title.lowercased()
        title = Self.bytes(lowercasedTitle)
        host = Self.bytes((entry.url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: ""))
        url = Self.bytes(entry.url.absoluteString.lowercased())
    }

    /// A lowercased query, ready to compare.
    struct Needle {
        let string: String
        let bytes: [UInt8]
        init(_ lowercased: String) {
            string = lowercased
            bytes = HistorySearchItem.bytes(lowercased)
        }
    }

    /// NFC on both sides makes canonically equivalent text (a precomposed or a combining accent) the same bytes.
    private static func bytes(_ string: String) -> [UInt8] {
        Array(string.precomposedStringWithCanonicalMapping.utf8)
    }

    /// The host (without www.) starting with the query, then the title, a word in the title, the title
    /// containing it, the URL containing it; nil for no match. Each of these needs the query somewhere in
    /// the title or the URL (the host is part of it), which is checked first.
    func score(_ q: Needle) -> Int? {
        let inTitle = Self.contains(title, q.bytes)
        guard inTitle || Self.contains(url, q.bytes) else { return nil }
        if host.starts(with: q.bytes) { return 100 }
        guard inTitle else { return 40 }
        if title.starts(with: q.bytes) { return 90 }
        if lowercasedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q.string) }) {
            return 75
        }
        return 55
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        #if canImport(Darwin)
        return haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
        #else
        let first = needle[0], last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == first, haystack[i..<i + needle.count].elementsEqual(needle) { return true }
            i += 1
        }
        return false
        #endif
    }
}
