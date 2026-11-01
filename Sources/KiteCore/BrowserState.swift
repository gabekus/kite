import Foundation

/// How long an unpinned tab can sit unused before it's archived: Arc 1.169's
/// "Archive tabs after" choices, with Arc's internal names as raw values.
public enum ArchiveInterval: String, Hashable, Codable, CaseIterable, Sendable {
    case never, oneHour, sixHours, twelveHours, twentyFourHours, sevenDays, thirtyDays

    /// nil for `never`.
    public var seconds: TimeInterval? {
        switch self {
        case .never: nil
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .twentyFourHours: 24 * 3600
        case .sevenDays: 7 * 24 * 3600
        case .thirtyDays: 30 * 24 * 3600
        }
    }

    /// Arc's wording.
    public var title: String {
        switch self {
        case .never: "Never"
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Names from the first version of this setting, before matching Arc's.
        let renamed = ["day": "twentyFourHours", "week": "sevenDays", "month": "thirtyDays"]
        self = Self(rawValue: renamed[raw] ?? raw) ?? .twelveHours
    }
}

public enum DarkPagesMode: String, Hashable, Codable, CaseIterable, Sendable {
    case off
    /// Darken sites that have no dark theme of their own whenever the OS is in dark mode.
    case matchSystem
    case always
}

/// Everything that survives a relaunch. Pure value type: shells mutate it and
/// render it, which keeps the behavior identical across platforms and testable.
public struct BrowserState: Hashable, Codable, Sendable {
    public var spaces: [Space]
    /// Arc's favorites grid: shared by every space, shown above the pinned tabs.
    public var favorites: [BrowserTab]
    public var selectedSpaceID: UUID
    public var recentlyClosed: [ClosedTab]
    public var archived: [ClosedTab]
    public var searchEngine: SearchEngine
    public var darkPages: DarkPagesMode
    /// Sites flipped from the mode's default (darkened when the default is light, and vice versa).
    public var darkPageHosts: Set<String>
    /// The built-in ad and tracker blocker, on by default.
    public var blocksAds: Bool
    /// Sites the blocker leaves alone (the shield's per-site off switch).
    public var adblockAllowedHosts: Set<String>
    /// Site Search shortcuts for the command bar (type the shortcut, then Tab).
    public var siteSearches: [SiteSearch]
    /// Which version of Arc's default Site Searches has been added, so a deleted default stays deleted.
    var siteSearchDefaultsSeeded: Int
    /// When unpinned tabs archive themselves; Arc's default is 12 hours.
    public var archiveAfter: ArchiveInterval
    /// View → Show Toolbar: back/forward/reload and the URL in a bar over the page
    /// instead of in the sidebar. Off by default, as in Arc.
    public var showsToolbar: Bool
    /// Ask "Quit Kite?" on ⌘Q, as Arc's "Warn before quitting" does. On by default.
    public var warnsBeforeQuitting: Bool

    public static let recentlyClosedLimit = 25
    public static let archiveLimit = 500

    public init(spaces: [Space], selectedSpaceID: UUID? = nil, searchEngine: SearchEngine = .google) {
        precondition(!spaces.isEmpty, "A browser needs at least one space")
        self.spaces = spaces
        self.favorites = []
        self.selectedSpaceID = selectedSpaceID.flatMap { id in spaces.first { $0.id == id }?.id } ?? spaces[0].id
        self.recentlyClosed = []
        self.archived = []
        self.searchEngine = searchEngine
        self.darkPages = .matchSystem
        self.darkPageHosts = []
        self.blocksAds = true
        self.adblockAllowedHosts = []
        self.siteSearches = []
        self.siteSearchDefaultsSeeded = 0
        self.archiveAfter = .twelveHours
        self.showsToolbar = false
        self.warnsBeforeQuitting = true
        seedDefaultSiteSearches()
    }

    // Decode field by field so sessions saved by older versions still load.
    private enum CodingKeys: String, CodingKey {
        case spaces, favorites, selectedSpaceID, recentlyClosed, archived, searchEngine, darkPages, darkPageHosts
        case blocksAds, adblockAllowedHosts, siteSearches, siteSearchDefaultsSeeded, archiveAfter, showsToolbar
        case warnsBeforeQuitting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            spaces: try c.decode([Space].self, forKey: .spaces),
            selectedSpaceID: try c.decodeIfPresent(UUID.self, forKey: .selectedSpaceID),
            searchEngine: try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .google
        )
        favorites = try c.decodeIfPresent([BrowserTab].self, forKey: .favorites) ?? []
        recentlyClosed = try c.decodeIfPresent([ClosedTab].self, forKey: .recentlyClosed) ?? []
        archived = try c.decodeIfPresent([ClosedTab].self, forKey: .archived) ?? []
        darkPages = try c.decodeIfPresent(DarkPagesMode.self, forKey: .darkPages) ?? .matchSystem
        darkPageHosts = try c.decodeIfPresent(Set<String>.self, forKey: .darkPageHosts) ?? []
        blocksAds = try c.decodeIfPresent(Bool.self, forKey: .blocksAds) ?? true
        adblockAllowedHosts = try c.decodeIfPresent(Set<String>.self, forKey: .adblockAllowedHosts) ?? []
        siteSearches = try c.decodeIfPresent([SiteSearch].self, forKey: .siteSearches) ?? []
        siteSearchDefaultsSeeded = try c.decodeIfPresent(Int.self, forKey: .siteSearchDefaultsSeeded) ?? 0
        // Sessions saved before Kite had Arc's defaults get them now.
        seedDefaultSiteSearches()
        archiveAfter = try c.decodeIfPresent(ArchiveInterval.self, forKey: .archiveAfter) ?? .twelveHours
        showsToolbar = try c.decodeIfPresent(Bool.self, forKey: .showsToolbar) ?? false
        warnsBeforeQuitting = try c.decodeIfPresent(Bool.self, forKey: .warnsBeforeQuitting) ?? true
    }

    // MARK: Dark pages

    public func wantsDarkPage(for url: URL?, systemIsDark: Bool) -> Bool {
        let byDefault = switch darkPages {
        case .off: false
        case .matchSystem: systemIsDark
        case .always: true
        }
        let flipped = url?.host().map { darkPageHosts.contains($0.lowercased()) } ?? false
        return byDefault != flipped
    }

    /// Flips dark pages for the site, relative to the current mode's default.
    public mutating func toggleDarkPage(for url: URL?) {
        guard let host = url?.host()?.lowercased() else { return }
        if darkPageHosts.contains(host) {
            darkPageHosts.remove(host)
        } else {
            darkPageHosts.insert(host)
        }
    }

    // MARK: Ad blocking

    /// Whether ads and trackers are blocked on this page. Pages without a host
    /// (about:blank, files) report false so the shield stays hidden.
    public func blocksAds(on url: URL?) -> Bool {
        guard blocksAds, let host = url?.host()?.lowercased() else { return false }
        return !adblockAllowedHosts.contains(host)
    }

    /// The shield's per-site switch. Turning a site back on while blocking is off
    /// globally turns blocking on, so the click always does what it shows.
    public mutating func toggleAdblock(for url: URL?) {
        guard let host = url?.host()?.lowercased() else { return }
        if !blocksAds {
            blocksAds = true
            adblockAllowedHosts.remove(host)
        } else if adblockAllowedHosts.contains(host) {
            adblockAllowedHosts.remove(host)
        } else {
            adblockAllowedHosts.insert(host)
        }
    }

    public static func makeDefault(seedURL: URL? = URL(string: "https://www.wikipedia.org")) -> BrowserState {
        var personal = Space(name: "Personal", icon: "🏠", theme: Theme.presets[0])
        if let seedURL {
            let tab = BrowserTab(url: seedURL)
            personal.tabs = [tab]
            personal.selectedTabID = tab.id
        }
        let work = Space(name: "Work", icon: "💼", theme: Theme.presets[1])
        return BrowserState(spaces: [personal, work])
    }

    // MARK: Lookup

    public var selectedSpaceIndex: Int {
        spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
    }

    public var selectedSpace: Space { spaces[selectedSpaceIndex] }

    public var selectedTab: BrowserTab? {
        guard let id = selectedSpace.selectedTabID else { return nil }
        return sidebarTabs(in: selectedSpaceIndex).first { $0.id == id }
    }

    public var allTabIDs: Set<UUID> {
        Set(favorites.map(\.id) + spaces.flatMap { $0.allTabs.map(\.id) })
    }

    /// Favorites, then the space's pinned and unpinned tabs: the order ⌘1…⌘9 and ⌃Tab follow.
    public func sidebarTabs(in space: Int) -> [BrowserTab] {
        favorites + spaces[space].allTabs
    }

    public func spaceIndex(_ id: UUID) -> Int? {
        spaces.firstIndex { $0.id == id }
    }

    public func location(of id: UUID) -> TabLocation? {
        if let i = favorites.firstIndex(where: { $0.id == id }) {
            return TabLocation(space: nil, section: .favorite, index: i)
        }
        for (s, space) in spaces.enumerated() {
            if let i = space.pinned.firstIndex(where: { $0.id == id }) {
                return TabLocation(space: s, section: .pinned, index: i)
            }
            if let i = space.tabs.firstIndex(where: { $0.id == id }) {
                return TabLocation(space: s, section: .unpinned, index: i)
            }
        }
        return nil
    }

    public func tab(_ id: UUID) -> BrowserTab? {
        location(of: id).map { self[$0] }
    }

    subscript(location: TabLocation) -> BrowserTab {
        get {
            switch location.section {
            case .favorite: favorites[location.index]
            case .pinned: spaces[location.space!].pinned[location.index]
            case .unpinned: spaces[location.space!].tabs[location.index]
            }
        }
        set {
            switch location.section {
            case .favorite: favorites[location.index] = newValue
            case .pinned: spaces[location.space!].pinnedItems.updateTab(newValue.id) { $0 = newValue }
            case .unpinned: spaces[location.space!].tabs[location.index] = newValue
            }
        }
    }

    // MARK: Tabs

    /// New tabs go to the top of the unpinned list.
    @discardableResult
    public mutating func openTab(
        id: UUID = UUID(),
        url: URL?,
        in spaceID: UUID? = nil,
        select: Bool = true,
        now: Date = Date()
    ) -> UUID {
        let s = spaceID.flatMap(spaceIndex) ?? selectedSpaceIndex
        spaces[s].tabs.insert(BrowserTab(id: id, url: url, lastActiveAt: now), at: 0)
        if select {
            spaces[s].selectedTabID = id
            selectedSpaceID = spaces[s].id
        }
        return id
    }

    /// Favorites open in the current space; other tabs switch to their own space.
    public mutating func select(tab id: UUID, now: Date = Date()) {
        guard let location = location(of: id) else { return }
        let s = location.space ?? selectedSpaceIndex
        spaces[s].selectedTabID = id
        selectedSpaceID = spaces[s].id
        self[location].lastActiveAt = now
    }

    public mutating func update(tab id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let location = location(of: id) else { return }
        body(&self[location])
    }

    @discardableResult
    public mutating func close(tab id: UUID) -> CloseOutcome {
        guard let location = location(of: id) else { return .notFound }
        let s = location.space ?? selectedSpaceIndex
        let ordered = sidebarTabs(in: s)
        let wasSelected = spaces[s].selectedTabID == id
        // Closing a pane keeps the rest of its split on screen.
        let splitNeighbor = split(containing: id).flatMap { found -> UUID? in
            let split = found.split
            guard let i = split.tabIDs.firstIndex(of: id) else { return nil }
            // The pane before it, or the one after when it was first.
            let rest = split.tabIDs.filter { $0 != id }
            return rest.isEmpty ? nil : rest[max(i - 1, 0)]
        }
        defer { normalizeSplits() }

        let outcome: CloseOutcome
        if location.section != .unpinned {
            outcome = .unloaded
        } else {
            let tab = spaces[s].tabs.remove(at: location.index)
            let closed = ClosedTab(tab: tab, spaceID: spaces[s].id, index: location.index)
            recentlyClosed.append(closed)
            if recentlyClosed.count > Self.recentlyClosedLimit {
                recentlyClosed.removeFirst(recentlyClosed.count - Self.recentlyClosedLimit)
            }
            // In Arc, closing an unpinned tab archives it: it stays findable in the archive.
            appendToArchive([closed])
            outcome = .removed
        }

        if location.section != .unpinned, let i = spaces[s].splits.firstIndex(where: { $0.tabIDs.contains(id) }) {
            // An unloaded pinned pane leaves its split too, or it would come back blank.
            spaces[s].splits[i].remove(id)
        }

        if wasSelected, let splitNeighbor {
            spaces[s].selectedTabID = splitNeighbor
        } else if wasSelected {
            // Prefer the tab that slides into this one's place, then the one above it.
            let position = ordered.firstIndex { $0.id == id } ?? 0
            let remaining = ordered.filter { $0.id != id }
            spaces[s].selectedTabID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
        }
        return outcome
    }

    @discardableResult
    public mutating func reopenLastClosed(now: Date = Date()) -> UUID? {
        guard let closed = recentlyClosed.last else { return nil }
        return reopenClosed(tab: closed.tab.id, now: now)
    }

    /// Edit › Undo Archive Tab: puts one archived tab back where it was, selected. Nil when it
    /// isn't among the recently closed (reopened since, or pushed out).
    @discardableResult
    public mutating func reopenClosed(tab id: UUID, now: Date = Date()) -> UUID? {
        guard let i = recentlyClosed.lastIndex(where: { $0.tab.id == id }) else { return nil }
        let closed = recentlyClosed.remove(at: i)
        let s = spaceIndex(closed.spaceID) ?? selectedSpaceIndex
        var tab = closed.tab
        tab.lastActiveAt = now
        // It's open again, so it's no longer in the archive.
        archived.removeAll { $0.tab.id == tab.id }
        spaces[s].tabs.insert(tab, at: min(closed.index, spaces[s].tabs.count))
        spaces[s].selectedTabID = tab.id
        selectedSpaceID = spaces[s].id
        return tab.id
    }

    public mutating func togglePin(tab id: UUID) {
        guard let location = location(of: id), let s = location.space else { return }
        // A split pins and unpins as one item, keeping its panes together and in order.
        if let split = split(containing: id)?.split {
            let members = split.tabIDs.compactMap { member -> BrowserTab? in
                if let i = spaces[s].tabs.firstIndex(where: { $0.id == member }) { return spaces[s].tabs.remove(at: i) }
                return spaces[s].pinnedItems.removeTab(member)
            }
            if location.section == .pinned {
                spaces[s].tabs.insert(contentsOf: members, at: 0)
            } else {
                spaces[s].pinnedItems.append(contentsOf: members.map(PinnedItem.tab))
            }
            return
        }
        togglePinOne(id, in: s)
    }

    private mutating func togglePinOne(_ id: UUID, in s: Int) {
        guard let location = location(of: id) else { return }
        if location.section == .pinned {
            if let tab = spaces[s].pinnedItems.removeTab(id) {
                spaces[s].tabs.insert(tab, at: 0)
            }
        } else {
            let tab = spaces[s].tabs.remove(at: location.index)
            spaces[s].pinnedItems.append(.tab(tab))
        }
    }

    /// Moves a tab into the favorites, or a favorite back to the current space's unpinned tabs.
    public mutating func toggleFavorite(tab id: UUID) {
        guard let location = location(of: id) else { return }
        defer { normalizeSplits() }
        switch location.section {
        case .favorite:
            let tab = favorites.remove(at: location.index)
            spaces[selectedSpaceIndex].tabs.insert(tab, at: 0)
        case .pinned:
            if let tab = spaces[location.space!].pinnedItems.removeTab(id) { favorites.append(tab) }
        case .unpinned:
            favorites.append(spaces[location.space!].tabs.remove(at: location.index))
        }
    }

    public mutating func setFolderExpanded(_ folderID: UUID, _ expanded: Bool) {
        for s in spaces.indices where spaces[s].pinnedItems.updateFolder(folderID, { $0.isExpanded = expanded }) {
            return
        }
    }

    /// Same contract as SwiftUI's `onMove`. For pinned, offsets are top-level items (tabs or folders).
    public mutating func moveTabs(inSpace spaceID: UUID, pinned: Bool, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let s = spaceIndex(spaceID) else { return }
        func move<T>(_ items: inout [T]) {
            let moving = source.map { items[$0] }
            let shift = source.filter { $0 < destination }.count
            for i in source.reversed() { items.remove(at: i) }
            items.insert(contentsOf: moving, at: destination - shift)
        }
        if pinned {
            move(&spaces[s].pinnedItems)
        } else {
            move(&spaces[s].tabs)
        }
    }

    /// ⌘1…⌘8 pick the nth tab in sidebar order, ⌘9 the last one.
    public mutating func selectTab(number: Int, now: Date = Date()) {
        let stops = sidebarStops(in: selectedSpaceIndex)
        guard !stops.isEmpty, number >= 1 else { return }
        let index = number >= 9 ? stops.count - 1 : number - 1
        guard stops.indices.contains(index) else { return }
        select(tab: stops[index], now: now)
    }

    public mutating func selectAdjacentTab(offset: Int, now: Date = Date()) {
        let stops = sidebarStops(in: selectedSpaceIndex)
        guard !stops.isEmpty else { return }
        let current = stops.firstIndex { $0 == selectedSpace.selectedTabID } ?? 0
        let next = ((current + offset) % stops.count + stops.count) % stops.count
        select(tab: stops[next], now: now)
    }

    /// Unpinned tabs untouched for `interval` move to the archive, like Arc's auto-archive.
    @discardableResult
    public mutating func archiveStaleTabs(olderThan interval: TimeInterval, now: Date = Date()) -> [BrowserTab] {
        var removed: [BrowserTab] = []
        let cutoff = now.addingTimeInterval(-interval)
        for s in spaces.indices {
            let selected = spaces[s].selectedTabID
            var kept: [BrowserTab] = []
            for (index, tab) in spaces[s].tabs.enumerated() {
                if tab.id != selected && tab.lastActiveAt < cutoff {
                    removed.append(tab)
                    appendToArchive([ClosedTab(tab: tab, spaceID: spaces[s].id, index: index)], reason: .auto, now: now)
                } else {
                    kept.append(tab)
                }
            }
            spaces[s].tabs = kept
        }
        normalizeSplits()
        return removed
    }

    /// Adds tabs to the archive, stamped with when and why, dropping the oldest past `archiveLimit`.
    mutating func appendToArchive(_ tabs: [ClosedTab], reason: ArchiveReason = .manual, now: Date = Date()) {
        archived.append(contentsOf: tabs.map { closed in
            var closed = closed
            closed.archivedAt = closed.archivedAt ?? now
            closed.reason = closed.reason ?? reason
            return closed
        })
        if archived.count > Self.archiveLimit {
            archived.removeFirst(archived.count - Self.archiveLimit)
        }
    }

    // MARK: Spaces

    public mutating func selectSpace(_ id: UUID) {
        guard spaceIndex(id) != nil else { return }
        selectedSpaceID = id
    }

    public mutating func selectSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        selectedSpaceID = spaces[index].id
    }

    public mutating func selectAdjacentSpace(offset: Int) {
        let next = ((selectedSpaceIndex + offset) % spaces.count + spaces.count) % spaces.count
        selectedSpaceID = spaces[next].id
    }

    @discardableResult
    public mutating func setTheme(_ theme: Theme, forSpace id: UUID) {
        guard let index = spaceIndex(id) else { return }
        spaces[index].theme = theme
    }

    public mutating func addSpace(name: String, icon: String, theme: Theme) -> UUID {
        let space = Space(name: name, icon: icon, theme: theme)
        spaces.append(space)
        selectedSpaceID = space.id
        return space.id
    }
}
