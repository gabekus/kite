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
