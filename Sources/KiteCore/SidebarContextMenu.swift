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
        let ids = tabsToArchive(which, relativeTo: id)
        guard !ids.isEmpty, let s = location(of: id)?.space else { return [] }
        let archived = archiveToday(ids, inSpace: s)
        if let selected = spaces[s].selectedTabID, ids.contains(selected) {
            spaces[s].selectedTabID = id
        }
        return archived
    }

    // MARK: Folder menu

    /// Whether the folder menu offers Duplicate: not for a Claude (ephemeral) folder or a live one.
    public func canDuplicateFolder(_ id: UUID) -> Bool {
        guard let folder = spaces.lazy.compactMap({ $0.pinnedItems.folder(id) }).first else { return false }
        return folder.ephemeral != true && folder.live == nil
    }

    /// Arc's folder Duplicate: a copy of the folder, its nested folders and tabs (new ids, not
    /// loaded) right after it in the same place. Live folders inside are left out: their tabs come
    /// from their source, which a space has one folder for. Returns the copy's id.
    @discardableResult
    public mutating func duplicateFolder(_ id: UUID, now: Date = Date()) -> UUID? {
        guard canDuplicateFolder(id),
              let s = spaces.indices.first(where: { spaces[$0].pinnedItems.folder(id) != nil }),
              let folder = spaces[s].pinnedItems.folder(id) else { return nil }
        func copy(_ item: PinnedItem) -> PinnedItem? {
            switch item {
            case .tab(let tab):
                var new = BrowserTab(url: tab.url, title: tab.title, faviconURL: tab.faviconURL, lastActiveAt: now,
                                     pinnedURL: tab.pinnedURL)
                new.customTitle = tab.customTitle
                return .tab(new)
            case .folder(let folder):
                guard folder.live == nil else { return nil }
                return .folder(TabFolder(name: folder.name, isExpanded: folder.isExpanded, items: folder.items.compactMap(copy),
                                         ephemeral: folder.ephemeral))
            }
        }
        guard let duplicate = copy(.folder(folder)), spaces[s].pinnedItems.insertItem(duplicate, after: id) else { return nil }
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

    /// Whether Turn "<folder>" into Space is offered and enabled: a plain folder with tabs in it. Never a
    /// Claude folder, one with Claude or live folders inside, or one named Claude: Kite never makes a
    /// Claude space (`claudeMayCreateSpace`).
    public func canTurnFolderIntoSpace(_ id: UUID) -> Bool {
        guard let folder = spaces.lazy.compactMap({ $0.pinnedItems.folder(id) }).first,
              Self.claudeMayCreateSpace(named: folder.name), !folder.items.tabs.isEmpty else { return false }
        func plain(_ folder: TabFolder) -> Bool {
            folder.ephemeral != true && folder.live == nil && folder.items.allSatisfy {
                if case .folder(let inner) = $0 { plain(inner) } else { true }
            }
        }
        return plain(folder)
    }

    /// Arc's Turn "<folder>" into Space: a new space right after the folder's, named after it, with
    /// the folder's items as its pinned tabs. It keeps the old space's theme and profile, has no icon
    /// (a dot, as Arc shows an icon-less space), and Kite switches to it, as for a new space. Splits
    /// made only of the folder's tabs go along.
    @discardableResult
    public mutating func turnFolderIntoSpace(_ id: UUID) -> UUID? {
        guard canTurnFolderIntoSpace(id),
              let s = spaces.indices.first(where: { spaces[$0].pinnedItems.folder(id) != nil }),
              let folder = spaces[s].pinnedItems.removeFolder(id) else { return nil }
        let moved = Set(folder.items.tabs.map(\.id))
        let source = spaces[s]
        let spaceID = insertSpace(name: folder.name, icon: "", theme: source.theme, profile: source.profile, at: s + 1)
        let n = s + 1
        spaces[n].pinnedItems = folder.items
        spaces[n].splits = source.splits.filter { $0.tabIDs.allSatisfy(moved.contains) }
        spaces[n].selectedTabID = source.selectedTabID.flatMap { moved.contains($0) ? $0 : nil } ?? folder.items.tabs.first?.id
        if let selected = source.selectedTabID, moved.contains(selected) {
            spaces[s].selectedTabID = spaces[s].allTabs.first?.id
        }
        normalizeSplits()
        return spaceID
    }
}

extension LinkFormat {
    /// A tab as `[title](url)` with the title its row shows (a Rename… name wins), as every Copy … as
    /// Markdown uses. Nil without a URL.
    public static func markdown(_ tab: BrowserTab) -> String? {
        tab.url.map { markdown(title: tab.displayTitle, url: $0) }
    }

    /// Copy All Links as Markdown: one `[title](url)` per line, the folder's tabs in sidebar order.
    public static func markdownList(_ tabs: [BrowserTab]) -> String {
        tabs.compactMap(markdown).joined(separator: "\n")
    }
}
