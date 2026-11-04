import Foundation

/// The tab context menu's Archive Other Tabs / Archive Tabs Below / Archive Tabs Above (Arc's
/// `SidebarMenu+TabContextMenu`, comments "Deletes all unselected unpinned tabs from the sidebar." and
/// "Deletes all tabs from the sidebar that are below / _above_ the selected one.").
public enum ArchiveTabsRelative: Equatable, Sendable {
    case others, below, above
}

/// What the sidebar's tab and folder context menus do that isn't a plain command.
extension BrowserState {
    // MARK: Tab menu

    /// The Today tabs that Archive Other Tabs / Below / Above would archive for the row of tab `id`.
    /// The row is the tab and, when it's in a split, the split's other panes. Empty when the tab isn't
    /// in Today or there's nothing on that side (Arc shows Archive Tabs Above disabled on the top row).
    public func tabsToArchive(_ which: ArchiveTabsRelative, relativeTo id: UUID) -> [UUID] {
        guard let location = location(of: id), location.section == .unpinned, let s = location.space else { return [] }
        let tabs = spaces[s].tabs
        let row = Set(spaces[s].splits.first { $0.tabIDs.contains(id) }?.tabIDs ?? [id])
        let rowIndices = tabs.indices.filter { row.contains(tabs[$0].id) }
        guard let first = rowIndices.first, let last = rowIndices.last else { return [] }
        return tabs.indices.filter { i in
            switch which {
            case .others: !row.contains(tabs[i].id)
            case .above: i < first
            case .below: i > last
            }
        }.map { tabs[$0].id }
    }

    /// Archives the tabs `tabsToArchive` lists. When the selected tab goes, the row the menu was
    /// opened on is selected instead.
    @discardableResult
    public mutating func archiveTabs(_ which: ArchiveTabsRelative, relativeTo id: UUID) -> [BrowserTab] {
        let ids = Set(tabsToArchive(which, relativeTo: id))
        guard !ids.isEmpty, let s = location(of: id)?.space else { return [] }
        let archived = spaces[s].tabs.enumerated().filter { ids.contains($1.id) }
        appendToArchive(archived.map { ClosedTab(tab: $1, spaceID: spaces[s].id, index: $0) })
        spaces[s].tabs.removeAll { ids.contains($0.id) }
        normalizeSplits()
        if let selected = spaces[s].selectedTabID, ids.contains(selected) {
            spaces[s].selectedTabID = id
        }
        return archived.map(\.element)
    }

    // MARK: Folder menu

    /// Arc's folder Duplicate: a copy of the folder, its nested folders and tabs (new ids, not
    /// loaded) right after it in the same place. Returns the copy's id.
    @discardableResult
    public mutating func duplicateFolder(_ id: UUID, now: Date = Date()) -> UUID? {
        guard let s = spaces.indices.first(where: { spaces[$0].pinnedItems.folder(id) != nil }),
              let folder = spaces[s].pinnedItems.folder(id) else { return nil }
        func copy(_ item: PinnedItem) -> PinnedItem {
            switch item {
            case .tab(let tab):
                var new = BrowserTab(url: tab.url, title: tab.title, faviconURL: tab.faviconURL, lastActiveAt: now,
                                     pinnedURL: tab.pinnedURL)
                new.customTitle = tab.customTitle
                return .tab(new)
            case .folder(let folder):
                return .folder(TabFolder(name: folder.name, isExpanded: folder.isExpanded, items: folder.items.map(copy)))
            }
        }
        let duplicate = copy(.folder(folder))
        guard spaces[s].pinnedItems.insertItem(duplicate, after: id) else { return nil }
        return duplicate.id
    }

    /// Arc's New Nested Folder…: an empty folder at the end of folder `id`, which opens to show it.
    @discardableResult
    public mutating func createNestedFolder(in id: UUID, name: String = "New Folder") -> UUID? {
        let nested = TabFolder(name: name)
        for s in spaces.indices where spaces[s].pinnedItems.updateFolder(id, {
            $0.items.append(.folder(nested))
            $0.isExpanded = true
        }) {
            return nested.id
        }
        return nil
    }

    /// Arc's Turn "<folder>" into Space: a new space right after the folder's, named after it, with
    /// the folder's items as its pinned tabs. It keeps the old space's theme and profile, and Kite
    /// switches to it, as it does for a new space. Splits made only of the folder's tabs go along.
    @discardableResult
    public mutating func turnFolderIntoSpace(_ id: UUID) -> UUID? {
        guard let s = spaces.indices.first(where: { spaces[$0].pinnedItems.folder(id) != nil }),
              spaces[s].pinnedItems.folder(id)?.live == nil,
              let folder = spaces[s].pinnedItems.removeFolder(id) else { return nil }
        let moved = Set(folder.items.tabs.map(\.id))
        var space = Space(name: folder.name, icon: "", theme: spaces[s].theme, pinnedItems: folder.items)
        space.profile = spaces[s].profile
        space.splits = spaces[s].splits.filter { $0.tabIDs.allSatisfy(moved.contains) }
        space.selectedTabID = spaces[s].selectedTabID.flatMap { moved.contains($0) ? $0 : nil } ?? folder.items.tabs.first?.id
        if let selected = spaces[s].selectedTabID, moved.contains(selected) {
            spaces[s].selectedTabID = spaces[s].allTabs.first?.id
        }
        spaces.insert(space, at: s + 1)
        selectedSpaceID = space.id
        normalizeSplits()
        return space.id
    }
}

extension LinkFormat {
    /// Copy All Links as Markdown: one `[title](url)` per line, the folder's tabs in sidebar order.
    public static func markdownList(_ tabs: [BrowserTab]) -> String {
        tabs.compactMap { tab in tab.url.map { markdown(title: tab.displayTitle, url: $0) } }.joined(separator: "\n")
    }
}

extension [PinnedItem] {
    /// Inserts `item` just after the item `neighbor` (a tab or folder), at whatever depth it is.
    mutating func insertItem(_ item: PinnedItem, after neighbor: UUID) -> Bool {
        for i in indices {
            if self[i].id == neighbor {
                insert(item, at: i + 1)
                return true
            }
            guard case .folder(var folder) = self[i], folder.items.insertItem(item, after: neighbor) else { continue }
            self[i] = .folder(folder)
            return true
        }
        return false
    }
}
