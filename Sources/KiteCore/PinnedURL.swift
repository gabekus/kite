import Foundation

/// Arc's pinned-URL behaviour: a pinned tab (or favorite) remembers the page it was pinned
/// at, offers "Back to Pinned URL" once it has wandered off, and Tabs › "Reset all tabs in
/// this Space" sends every pinned tab in the space home. Arc's names: `savedURL`,
/// `canResetTab`, `resetTab` ("Reset tab to original URL."), `resetSpace` ("Resets all your
/// pinned tabs in the current Space."), `revealTabInSidebar` ("Reveals the current tab in
/// your Sidebar."). See docs/arc-visual-spec.md, "Pinned URL reset and Reveal Tab".
extension BrowserTab {
    /// Whether the tab has left its pinned page (Arc's `TabNavigatedAwayFromSavedURLHeuristic`).
    /// Arc's exact rules aren't known; this ignores the fragment, a trailing slash, `www.` and
    /// http/https, so a pinned page's own redirects and in-page anchors don't count as leaving.
    public var hasLeftPinnedURL: Bool {
        guard let pinnedURL, let url else { return false }
        return !Self.samePage(url, pinnedURL)
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        pageKey(a) == pageKey(b)
    }

    private static func pageKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil else {
            return url.absoluteString
        }
        parts.fragment = nil
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        parts.scheme = parts.scheme?.lowercased()
        if var host = parts.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            parts.host = host
        }
        while parts.path.count > 1 && parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? url.absoluteString
    }
}

extension BrowserState {
    /// Gives every pinned tab and favorite a pinned URL (its current page, the first time it's
    /// seen pinned) and takes it off unpinned tabs, so unpinning and pinning again pins the page
    /// you're on. Shells call it after every change; it only writes what differs.
    public mutating func syncPinnedURLs() {
        func adopt(_ tab: inout BrowserTab) {
            if tab.pinnedURL == nil, let url = tab.url, InternalPage(url) == nil { tab.pinnedURL = url }
        }
        for i in favorites.indices where favorites[i].pinnedURL == nil && favorites[i].url != nil {
            adopt(&favorites[i])
        }
        for s in spaces.indices {
            for tab in spaces[s].pinned where tab.pinnedURL == nil && tab.url != nil {
                spaces[s].pinnedItems.updateTab(tab.id, adopt)
            }
            for i in spaces[s].tabs.indices where spaces[s].tabs[i].pinnedURL != nil {
                spaces[s].tabs[i].pinnedURL = nil
            }
        }
    }

    /// A pinned tab or favorite that has left its pinned page.
    public func canReset(tab id: UUID) -> Bool {
        guard let location = location(of: id), location.section != .unpinned else { return false }
        return self[location].hasLeftPinnedURL
    }

    /// "Back to Pinned URL": puts the tab back on its pinned page. Returns the URL for the
    /// shell to load, or nil when there's nothing to reset.
    @discardableResult
    public mutating func resetTab(_ id: UUID) -> URL? {
        guard canReset(tab: id), let location = location(of: id), let home = self[location].pinnedURL else { return nil }
        self[location].url = home
        return home
    }

    /// Tabs › "Reset all tabs in this Space": every pinned tab in the current space (folders
    /// included) goes back to its pinned page. Returns what changed, for the shell to load.
    @discardableResult
    public mutating func resetPinnedTabs() -> [(id: UUID, url: URL)] {
        var reset: [(id: UUID, url: URL)] = []
        for tab in selectedSpace.pinned {
            if let url = resetTab(tab.id) { reset.append((tab.id, url)) }
        }
        return reset
    }

    /// "Separate From Pinned Tab": the page the pinned tab wandered to opens as a new unpinned
    /// tab (selected), and the pinned tab goes back to its pinned page. Returns the new tab's ID.
    @discardableResult
    public mutating func separateFromPinnedTab(_ id: UUID, now: Date = Date()) -> UUID? {
        guard canReset(tab: id), let location = location(of: id), let away = self[location].url else { return nil }
        let space = location.space.map { spaces[$0].id }
        resetTab(id)
        return openTab(url: away, in: space, now: now)
    }

    /// Tabs › "Reveal Tab in Sidebar": opens the folders the tab sits in. Returns the ID of
    /// the sidebar row that holds it (a top-level pinned item, a split, or the tab), for the
    /// shell to scroll to; nil for favorites, which are always in view, and unknown tabs.
    @discardableResult
    public mutating func revealTab(_ id: UUID) -> UUID? {
        guard let location = location(of: id), let s = location.space else { return nil }
        if location.section == .pinned {
            spaces[s].pinnedItems.expandFolders(containing: id)
        }
        return sidebarRowID(of: id)
    }

    /// The sidebar row (a `SidebarGroup` of the space's top level) that holds the tab.
    public func sidebarRowID(of id: UUID) -> UUID? {
        guard let location = location(of: id), let s = location.space else { return nil }
        let space = spaces[s]
        let topLevel: [UUID] = location.section == .pinned ? space.pinnedItems.map(\.id) : space.tabs.map(\.id)
        let item = location.section == .pinned
            ? space.pinnedItems.first { $0.contains(tab: id) }?.id
            : id
        guard let item else { return nil }
        return SidebarGroup.group(topLevel, splits: space.splits).first { group in
            group.indices.contains { topLevel[$0] == item }
        }?.id
    }
}

extension PinnedItem {
    func contains(tab id: UUID) -> Bool {
        switch self {
        case .tab(let tab): tab.id == id
        case .folder(let folder): folder.items.contains { $0.contains(tab: id) }
        }
    }
}

extension [PinnedItem] {
    /// Expands every folder on the way down to the tab. Returns whether the tab was found.
    @discardableResult
    mutating func expandFolders(containing id: UUID) -> Bool {
        for i in indices {
            switch self[i] {
            case .tab(let tab) where tab.id == id:
                return true
            case .folder(var folder) where folder.items.contains(where: { $0.contains(tab: id) }):
                folder.isExpanded = true
                folder.items.expandFolders(containing: id)
                self[i] = .folder(folder)
                return true
            default:
                continue
            }
        }
        return false
    }
}
