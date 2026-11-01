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
        normalizeSplits()
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

    public mutating func setSpaceIcon(_ id: UUID, to icon: String) {
        let icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = spaceIndex(id), let first = icon.first else { return }
        spaces[s].icon = String(first)
    }

    /// Removes a space with its pinned and unpinned tabs. The last space stays: a window always has one.
    /// Deleting the selected space selects the one before it.
    public mutating func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let s = spaceIndex(id) else { return }
        let wasSelected = selectedSpaceID == id
        spaces.remove(at: s)
        if wasSelected { selectedSpaceID = spaces[max(s - 1, 0)].id }
    }

    /// Moves a space to a new place in the strip (Manage Spaces' drag).
    public mutating func moveSpace(_ id: UUID, to index: Int) {
        guard let s = spaceIndex(id) else { return }
        let space = spaces.remove(at: s)
        spaces.insert(space, at: min(max(index, 0), spaces.count))
    }
}
