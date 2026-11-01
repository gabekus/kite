import Foundation

/// Why a tab went into the archive. Arc 1.171 keeps an `ArchiveReason` per archived item and its
/// archive page filters on it: "How was the tab closed?" › "Auto-Closed" / "Manually Closed".
public enum ArchiveReason: String, Hashable, Codable, CaseIterable, Sendable {
    /// Archived by the user: ⌘W, Clear Today, deleting a folder.
    case manual
    /// Archived by "Archive tabs after".
    case auto

    /// Arc's filter wording.
    public var title: String {
        switch self {
        case .manual: "Manually Closed"
        case .auto: "Auto-Closed"
        }
    }
}

/// The archive page's filters: Arc's "Where was the tab?" (a space) and "How was the tab closed?",
/// plus the search field.
public struct ArchiveFilter: Hashable, Sendable {
    public var spaceID: UUID?
    public var reason: ArchiveReason?
    public var query: String

    public init(spaceID: UUID? = nil, reason: ArchiveReason? = nil, query: String = "") {
        self.spaceID = spaceID
        self.reason = reason
        self.query = query
    }

    public func matches(_ item: ClosedTab) -> Bool {
        if let spaceID, item.spaceID != spaceID { return false }
        if let reason, (item.reason ?? .manual) != reason { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = item.tab.title + " " + (item.tab.url?.absoluteString ?? "")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A run of archived tabs under one heading. Arc's Library sections are "Today", "Yesterday" and
/// "Earlier This Week"; older items are grouped by month here (Arc's older headings aren't in its strings).
public struct ArchiveSection: Hashable, Sendable {
    public enum Bucket: Hashable, Sendable {
        case today, yesterday, earlierThisWeek
        /// The first day of the month.
        case month(Date)
    }

    public var bucket: Bucket
    public var items: [ClosedTab]

    public func title(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch bucket {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier This Week"
        case .month(let start):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: start)
        }
    }
}

extension ClosedTab {
    /// When it was archived; entries from before Kite kept the date fall back to the tab's last use.
    public var archiveDate: Date { archivedAt ?? tab.lastActiveAt }
}

extension BrowserState {
    /// The archive, newest first, filtered and split into Arc's time sections.
    public func archiveSections(_ filter: ArchiveFilter = ArchiveFilter(), now: Date = Date(),
                                calendar: Calendar = .current) -> [ArchiveSection] {
        var seen = Set<UUID>()
        let items = archived.reversed().filter { item in
            seen.insert(item.tab.id).inserted && filter.matches(item)
        }.sorted { $0.archiveDate > $1.archiveDate }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        func bucket(_ date: Date) -> ArchiveSection.Bucket {
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= week { return .earlierThisWeek }
            return .month(calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date))
        }

        var sections: [ArchiveSection] = []
        for item in items {
            let b = bucket(item.archiveDate)
            if sections.last?.bucket == b {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(ArchiveSection(bucket: b, items: [item]))
            }
        }
        return sections
    }

    /// Arc's archive Restore: the tab goes back to the space it was archived from (the current space
    /// if that one is gone), where it was, without switching to it. Returns the space it went to.
    @discardableResult
    public mutating func restoreArchived(_ tabID: UUID, now: Date = Date()) -> UUID? {
        guard let i = archived.lastIndex(where: { $0.tab.id == tabID }) else { return nil }
        let item = archived[i]
        archived.removeAll { $0.tab.id == tabID }
        // It's open again, so ⇧⌘T mustn't bring back a second copy.
        recentlyClosed.removeAll { $0.tab.id == tabID }
        guard location(of: tabID) == nil else { return nil }
        let s = spaceIndex(item.spaceID) ?? selectedSpaceIndex
        var tab = item.tab
        // Fresh, so auto-archive doesn't take it straight back.
        tab.lastActiveAt = now
        spaces[s].tabs.insert(tab, at: min(max(item.index, 0), spaces[s].tabs.count))
        return spaces[s].id
    }

    /// Arc's archive Delete: gone for good.
    public mutating func deleteArchived(_ tabIDs: Set<UUID>) {
        archived.removeAll { tabIDs.contains($0.tab.id) }
    }

    /// Archive › Clear Archive ("Clears all tabs in the Archive."). Returns how many went.
    @discardableResult
    public mutating func clearArchive() -> Int {
        let count = archived.count
        archived = []
        return count
    }
}
