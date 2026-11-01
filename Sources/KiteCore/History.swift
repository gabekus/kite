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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let scored = entries.values.compactMap { entry -> (HistoryEntry, Double)? in
            guard let match = Self.score(q, entry) else { return nil }
            let days = max(0, now.timeIntervalSince(entry.lastVisit)) / 86_400
            let frecency = log2(Double(entry.visitCount) + 1) * 8 - min(days, 90) / 3
            return (entry, Double(match) + frecency)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastVisit > $1.0.lastVisit }
            .prefix(limit)
            .map(\.0)
    }

    static func score(_ q: String, _ entry: HistoryEntry) -> Int? {
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
}
