import Foundation

/// Arc's tab and space commands that aren't plain selection: Clear Today, duplicate, rename.
/// (Recent-tab switching, ⌃Tab, is RecentTabSwitcher.)
extension BrowserState {
    /// ⇧⌘K: archives every unpinned tab in the current space, like Arc's Clear Today.
    /// A pinned or favorite selection stays; otherwise the first pinned tab is selected.
    @discardableResult
    public mutating func clearToday() -> [BrowserTab] {
        clearToday(inSpace: selectedSpace.id)
    }

    /// Clear Today for one space: the ⇧⌘K command and the Today divider's Clear button.
    @discardableResult
    public mutating func clearToday(inSpace spaceID: UUID) -> [BrowserTab] {
        guard let s = spaceIndex(spaceID) else { return [] }
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

    /// What the Today divider's Clear button does for a space (Arc's UnpinnedSectionDividerState
    /// `clearTabAction`): `clearOthers` ("Clear unselected Today tabs", no arrow) when the
    /// space's selected tab is one of two or more Today tabs, else `clearAll`.
    public func todayClearAction(inSpace spaceID: UUID) -> TodayClearAction {
        guard let s = spaceIndex(spaceID), let selected = spaces[s].selectedTabID,
              spaces[s].tabs.count != 1, spaces[s].tabs.contains(where: { $0.id == selected })
        else { return .clearAll }
        return .clearOthers
    }

    /// The divider's Clear in `clearOthers` mode: archives the space's Today tabs except the
    /// selected one, which stays selected. Falls back to Clear Today otherwise.
    @discardableResult
    public mutating func clearUnselectedToday(inSpace spaceID: UUID) -> [BrowserTab] {
        guard todayClearAction(inSpace: spaceID) == .clearOthers, let s = spaceIndex(spaceID),
              let selected = spaces[s].selectedTabID
        else { return clearToday(inSpace: spaceID) }
        let cleared = spaces[s].tabs.enumerated().filter { $1.id != selected }
        appendToArchive(cleared.map { ClosedTab(tab: $1, spaceID: spaces[s].id, index: $0) })
        spaces[s].tabs.removeAll { $0.id != selected }
        normalizeSplits()
        return cleared.map(\.element)
    }

    /// Opens a copy of the tab just below it in the unpinned list and selects it.
    @discardableResult
    public mutating func duplicate(tab id: UUID, now: Date = Date()) -> UUID? {
        guard let location = location(of: id) else { return nil }
        let s = location.space ?? selectedSpaceIndex
        let original = self[location]
        var copy = BrowserTab(url: original.url, title: original.title, faviconURL: original.faviconURL, lastActiveAt: now)
        copy.customTitle = original.customTitle
        let index = location.section == .unpinned ? location.index + 1 : 0
        spaces[s].tabs.insert(copy, at: min(index, spaces[s].tabs.count))
        spaces[s].selectedTabID = copy.id
        selectedSpaceID = spaces[s].id
        return copy.id
    }

    /// Arc's Rename for a tab (pinned, unpinned or favorite). The name stays when the page's title
    /// changes; an empty name goes back to showing the page's title.
    public mutating func renameTab(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(tab: id) { $0.customTitle = name.isEmpty ? nil : name }
    }

    // MARK: Collapse Pinned Tabs

    public func isPinnedSectionCollapsed(_ spaceID: UUID) -> Bool {
        spacesWithCollapsedPinnedSections.contains(spaceID)
    }

    /// View → Collapse / Expand Pinned Tabs, and the chevron in the space's header.
    public mutating func togglePinnedSection(_ spaceID: UUID) {
        guard spaceIndex(spaceID) != nil else { return }
        if spacesWithCollapsedPinnedSections.contains(spaceID) {
            spacesWithCollapsedPinnedSections.remove(spaceID)
        } else {
            spacesWithCollapsedPinnedSections.insert(spaceID)
        }
    }

    /// The pinned items the sidebar lists for a space. Collapsed, only the selected pinned tab
    /// stays (lifted out of its folder), the way a collapsed folder keeps its selected tab.
    public func shownPinnedItems(in space: Space) -> [PinnedItem] {
        guard isPinnedSectionCollapsed(space.id) else { return space.pinnedItems }
        return space.pinnedItems.tabs.filter { $0.id == space.selectedTabID }.map(PinnedItem.tab)
    }

    public mutating func renameSpace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = spaceIndex(id), !name.isEmpty else { return }
        spaces[s].name = name
    }

    /// Arc puts a new space right after the one you're in, and switches to it.
    @discardableResult
    public mutating func insertSpace(name: String, icon: String, theme: Theme, profile: String? = nil) -> UUID {
        var space = Space(name: name, icon: icon, theme: theme)
        space.profile = profile
        spaces.insert(space, at: selectedSpaceIndex + 1)
        selectedSpaceID = space.id
        return space.id
    }

    /// A space's icon: an emoji, a `symbol:` SF Symbol name, or empty for none (Arc shows a dot).
    public mutating func setSpaceIcon(_ id: UUID, to icon: String) {
        guard let s = spaceIndex(id) else { return }
        let icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if icon.hasPrefix(Space.symbolPrefix) {
            spaces[s].icon = icon
        } else {
            spaces[s].icon = icon.first.map(String.init) ?? ""
        }
    }

    /// Removes a space with its pinned and unpinned tabs. The last space stays: a window always has one.
    /// Deleting the selected space selects the one before it.
    public mutating func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let s = spaceIndex(id) else { return }
        let wasSelected = selectedSpaceID == id
        spaces.remove(at: s)
        if wasSelected { selectedSpaceID = spaces[max(s - 1, 0)].id }
    }

    /// Arc's folder Delete: the folder goes, and the tabs in it (nested folders' too) are
    /// archived, like Arc's "Deleting this folder will archive the tabs inside it."
    @discardableResult
    public mutating func deleteFolder(_ id: UUID) -> [BrowserTab] {
        for s in spaces.indices {
            guard let folder = spaces[s].pinnedItems.removeFolder(id) else { continue }
            let tabs = folder.items.tabs
            appendToArchive(tabs.enumerated().map { ClosedTab(tab: $1, spaceID: spaces[s].id, index: $0) })
            if let selected = spaces[s].selectedTabID, tabs.contains(where: { $0.id == selected }) {
                spaces[s].selectedTabID = spaces[s].allTabs.first?.id
            }
            normalizeSplits()
            return tabs
        }
        return []
    }

    /// Arc's folder Rename…. A blank name keeps the old one.
    public mutating func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for s in spaces.indices where spaces[s].pinnedItems.updateFolder(id, { $0.name = name }) {
            return
        }
    }

    /// Moves a space to a new place in the strip (Manage Spaces' drag).
    public mutating func moveSpace(_ id: UUID, to index: Int) {
        guard let s = spaceIndex(id) else { return }
        let space = spaces.remove(at: s)
        spaces.insert(space, at: min(max(index, 0), spaces.count))
    }
}

/// Arc's ClearTabAction for the Today divider's Clear button.
public enum TodayClearAction: Equatable, Sendable {
    /// "↓ Clear", tooltip "Clear Today tabs": archives every Today tab.
    case clearAll
    /// "Clear" without the arrow, tooltip "Clear unselected Today tabs": keeps the selected tab.
    case clearOthers
}
