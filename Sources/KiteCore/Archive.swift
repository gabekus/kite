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

/// The archive page's filters: Arc's "Where was the tab?" (a space, or Little Arc: its filter cases are
/// `space`, `littleArc`, `autoArchived`, `manuallyArchived`) and "How was the tab closed?", plus the
/// search field.
public struct ArchiveFilter: Hashable, Sendable {
    /// Where the tab was: one space, or Little Kite (Arc's "Little Arc" filter). nil shows all.
    public enum Source: Hashable, Sendable {
        case space(UUID)
        case littleKite
    }

    public var source: Source?
    public var reason: ArchiveReason?
    public var query: String

    public init(source: Source? = nil, reason: ArchiveReason? = nil, query: String = "") {
        self.source = source
        self.reason = reason
        self.query = query
    }

    public init(spaceID: UUID?, reason: ArchiveReason? = nil, query: String = "") {
        self.init(source: spaceID.map(Source.space), reason: reason, query: query)
    }

    public var spaceID: UUID? {
        if case .space(let id) = source { return id }
        return nil
    }

    public func matches(_ item: ClosedTab) -> Bool {
        switch source {
        case .space(let id): if item.isLittleKite || item.spaceID != id { return false }
        case .littleKite: if !item.isLittleKite { return false }
        case nil: break
        }
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

    /// Arc's archive Restore (`unarchiveAndPutBackItem(_:desiredSpaceID:…)`): the tab goes back to the
    /// space it was archived from (the current space if that one is gone), where it was, without
    /// switching to it. A Little Kite page has no space of its own and goes to the top of the current
    /// space's Today. Returns the space it went to.
    @discardableResult
    public mutating func restoreArchived(_ tabID: UUID, now: Date = Date()) -> UUID? {
        guard let i = archived.lastIndex(where: { $0.tab.id == tabID }) else { return nil }
        let item = archived[i]
        archived.removeAll { $0.tab.id == tabID }
        // It's open again, so ⇧⌘T mustn't bring back a second copy.
        recentlyClosed.removeAll { $0.tab.id == tabID }
        guard location(of: tabID) == nil else { return nil }
        let s = item.isLittleKite ? selectedSpaceIndex : (spaceIndex(item.spaceID) ?? selectedSpaceIndex)
        var tab = item.tab
        // Fresh, so auto-archive doesn't take it straight back.
        tab.lastActiveAt = now
        spaces[s].tabs.insert(tab, at: min(max(item.index, 0), spaces[s].tabs.count))
        return spaces[s].id
    }

    /// A Little Kite window closed with a page in it: Arc archives Little Arcs (`autoArchiveLittleArcTimeThreshold`,
    /// archive `tabSource` `littleArc`), so the page lands in the archive under the Little Kite filter.
    /// Nothing for a window that never had a page. Returns the archived item's id.
    @discardableResult
    public mutating func archiveLittleKite(url: URL?, title: String, faviconURL: URL? = nil, reason: ArchiveReason,
                                           now: Date = Date()) -> UUID? {
        guard let url else { return nil }
        let tab = BrowserTab(url: url, title: title, faviconURL: faviconURL, lastActiveAt: now)
        appendToArchive([ClosedTab(tab: tab, spaceID: selectedSpace.id, index: 0, littleKite: true)],
                        reason: reason, now: now)
        return tab.id
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
