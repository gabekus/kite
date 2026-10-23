import Foundation

/// Arc's tab and space commands that aren't plain selection: recent-tab switching,
/// Clear Today, duplicate, rename.
extension BrowserState {
    /// ⌃Tab: the most recently used other tab in this space (favorites included).
    public mutating func selectRecentTab(now: Date = Date()) {
        let current = selectedSpace.selectedTabID
        guard let recent = sidebarTabs(in: selectedSpaceIndex)
            .filter({ $0.id != current })
            .max(by: { $0.lastActiveAt < $1.lastActiveAt })
        else { return }
        select(tab: recent.id, now: now)
    }

    /// ⇧⌘K: archives every unpinned tab in the current space, like Arc's Clear Today.
    /// A pinned or favorite selection stays; otherwise the first pinned tab is selected.
    @discardableResult
    public mutating func clearToday() -> [BrowserTab] {
        let s = selectedSpaceIndex
        let cleared = spaces[s].tabs
        guard !cleared.isEmpty else { return [] }
        appendToArchive(cleared.enumerated().map { ClosedTab(tab: $1, spaceID: spaces[s].id, index: $0) })
        spaces[s].tabs = []
        if let selected = spaces[s].selectedTabID, cleared.contains(where: { $0.id == selected }) {
            spaces[s].selectedTabID = spaces[s].pinned.first?.id
        }
        return cleared
    }

    /// Opens a copy of the tab just below it in the unpinned list and selects it.
    @discardableResult
    public mutating func duplicate(tab id: UUID, now: Date = Date()) -> UUID? {
        guard let location = location(of: id) else { return nil }
        let s = location.space ?? selectedSpaceIndex
        let original = self[location]
        let copy = BrowserTab(url: original.url, title: original.title, faviconURL: original.faviconURL, lastActiveAt: now)
        let index = location.section == .unpinned ? location.index + 1 : 0
        spaces[s].tabs.insert(copy, at: min(index, spaces[s].tabs.count))
        spaces[s].selectedTabID = copy.id
        selectedSpaceID = spaces[s].id
        return copy.id
    }

    public mutating func renameSpace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = spaceIndex(id), !name.isEmpty else { return }
        spaces[s].name = name
    }
}
