import Foundation

/// Where a sidebar drag lands, after Arc's `SidebarDropTarget` (tab list or favorites tray) and
/// `SidebarDropType` (`before` / `after` an item, or `on` it). Gaps are named by the item they
/// sit before (nil: the end of the list), so they stay right while other rows come and go.
public enum SidebarDropTarget: Hashable, Sendable {
    /// Between favorites.
    case favorites(before: UUID?)
    /// Between a space's pinned items, at the top level or inside a folder.
    case pinned(space: UUID, folder: UUID?, before: UUID?)
    /// Between a space's Today tabs.
    case unpinned(space: UUID, before: UUID?)
    /// On a folder's row: into the folder, at its end.
    case folder(UUID)
    /// On a tab's left or right half (Arc's `SidebarDropTargetRegion`): the two become a split.
    case split(with: UUID, side: SplitDropSide)
    /// On a space's icon in the strip: to the top of its Today tabs.
    case space(UUID)
}

public enum SplitDropSide: String, Hashable, Sendable {
    case left
    case right
}

/// What a drop did, for Arc's `MoveItemsToastType` toasts.
public enum SidebarDropOutcome: Equatable, Sendable {
    case moved
    /// Today tabs that became pinned (`itemsPinned`).
    case pinned(count: Int)
    /// Pinned tabs that went back to Today (`itemsUnpinned`).
    case unpinned(count: Int)
    /// The items left the space on screen (`navigateToMovedTab`): the toast offers to follow them.
    case movedToSpace(UUID, tabID: UUID)
}

extension BrowserState {
    /// A drag's unit for an item: a split's members move together, so a tab in a split stands
    /// for the split (its ID). Folders and lone tabs stand for themselves.
    public func sidebarDragID(for id: UUID) -> UUID {
        split(containing: id)?.split.id ?? id
    }

    /// Whether `ids` (tabs, folders or splits) can be dropped on `target`.
    public func canDrop(_ ids: [UUID], on target: SidebarDropTarget) -> Bool {
        let units = ids.compactMap(dragUnit)
        guard !units.isEmpty, units.count == ids.count else { return false }
        let hasFolder = units.contains { if case .folder = $0 { true } else { false } }
        let hasSplit = units.contains { if case .split = $0 { true } else { false } }
        switch target {
        case .favorites:
            // Favorites hold tabs and split views (Arc's tray items can be a split's panes), not folders.
            return !hasFolder
        case .unpinned, .space:
            // Folders live in the pinned section only.
            return !hasFolder
        case .pinned(let space, let folder, _):
            guard spaceIndex(space) != nil else { return false }
            if let folder, !folderExists(folder, inSpace: space) { return false }
            // Not into a folder being dragged, or one inside it.
            if let folder, units.contains(where: { $0.contains(folder) }) { return false }
            return true
        case .folder(let folder):
            guard spaceContaining(folder: folder) != nil else { return false }
            return !units.contains { $0.contains(folder) }
        case .split(let anchor, _):
            guard !hasFolder, location(of: anchor) != nil, location(of: anchor)?.section != .favorite,
                  !units.contains(where: { $0.contains(anchor) }) else { return false }
            let incoming = units.reduce(0) { $0 + $1.tabCount }
            let existing = split(containing: anchor)?.split.tabIDs.count ?? 1
            return incoming + existing <= SplitView.maxPanes
        }
    }

    /// Moves `ids` (tabs, folders or splits, in sidebar order) to `target`, keeping each split's
    /// panes together. Nil when the drop isn't allowed.
    @discardableResult
    public mutating func dropSidebarItems(_ ids: [UUID], on target: SidebarDropTarget) -> SidebarDropOutcome? {
        guard canDrop(ids, on: target) else { return nil }
        let units = ids.compactMap(dragUnit)
        let movedTabIDs = units.flatMap(\.tabIDs)
        let fromSections = Set(movedTabIDs.compactMap { location(of: $0)?.section })
        let sourceSpace = selectedSpaceIndex

        // The gap's anchor, made safe before anything moves: a dragged item can't mark its own gap.
        var target = target
        switch target {
        case .favorites(let before):
            target = .favorites(before: firstStaying(from: before.map(rowAnchor), in: favorites.map(\.id), moving: Set(movedTabIDs)))
        case .unpinned(let space, let before):
            let list = spaceIndex(space).map { spaces[$0].tabs.map(\.id) } ?? []
            target = .unpinned(space: space, before: firstStaying(from: before.map(rowAnchor), in: list, moving: Set(movedTabIDs)))
        case .pinned(let space, let folder, let before):
            let list = spaceIndex(space).map { pinnedLevel(spaces[$0].pinnedItems, folder: folder).map(\.id) } ?? []
            let moving = Set(units.map(\.firstID))
            target = .pinned(space: space, folder: folder, before: firstStaying(from: before.map(rowAnchor), in: list, moving: moving))
        default:
            break
        }

        var extracted: [(unit: DragUnit, tabs: [PinnedItem], split: SplitView?)] = []
        for unit in units {
            let split = unit.splitID.flatMap { id in (spaces.flatMap(\.splits) + favoriteSplits).first { $0.id == id } }
            extracted.append((unit, remove(unit), split))
        }
        for s in spaces.indices {
            let gone = Set(extracted.compactMap(\.split?.id))
            spaces[s].splits.removeAll { gone.contains($0.id) }
        }
        favoriteSplits.removeAll { split in extracted.contains { $0.split?.id == split.id } }

        let destinationSpace: Int
        switch target {
        case .favorites(let before):
            let tabs = extracted.flatMap(\.tabs).compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
            favorites.insert(contentsOf: tabs, at: before.flatMap { id in favorites.firstIndex { $0.id == id } } ?? favorites.count)
            favoriteSplits += extracted.compactMap(\.split)
            destinationSpace = selectedSpaceIndex
        case .unpinned(let space, let before):
            let s = spaceIndex(space)!
            let tabs = extracted.flatMap(\.tabs).compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
            spaces[s].tabs.insert(contentsOf: tabs, at: before.flatMap { id in spaces[s].tabs.firstIndex { $0.id == id } } ?? spaces[s].tabs.count)
            spaces[s].splits += extracted.compactMap(\.split)
            destinationSpace = s
        case .space(let space):
            let s = spaceIndex(space)!
            let tabs = extracted.flatMap(\.tabs).compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
            spaces[s].tabs.insert(contentsOf: tabs, at: 0)
            spaces[s].splits += extracted.compactMap(\.split)
            destinationSpace = s
        case .pinned(let space, let folder, let before):
            let s = spaceIndex(space)!
            spaces[s].pinnedItems.insert(extracted.flatMap(\.tabs), inFolder: folder, before: before)
            spaces[s].splits += extracted.compactMap(\.split)
            destinationSpace = s
        case .folder(let folder):
            let s = spaceContaining(folder: folder)!
            spaces[s].pinnedItems.insert(extracted.flatMap(\.tabs), inFolder: folder, before: nil)
            spaces[s].splits += extracted.compactMap(\.split)
            destinationSpace = s
        case .split(let anchor, let side):
            let s = location(of: anchor)!.space!
            destinationSpace = s
            join(extracted.flatMap(\.tabs), to: anchor, side: side, inSpace: s)
        }

        // A space whose selected tab left it selects its first tab instead. Favorites show in every space.
        for s in spaces.indices {
            guard let selected = spaces[s].selectedTabID, movedTabIDs.contains(selected) else { continue }
            let now = location(of: selected)
            if now?.section != .favorite && now?.space != s { spaces[s].selectedTabID = spaces[s].allTabs.first?.id }
        }
        // A new split shows itself when it's made in the space on screen.
        if case .split = target, destinationSpace == sourceSpace, let first = movedTabIDs.first {
            spaces[destinationSpace].selectedTabID = first
        }

        normalizeSplits()
        pruneTabGroups()
        syncPinnedURLs()

        let toSection: TabSection? = switch target {
        case .favorites: .favorite
        case .unpinned, .space: .unpinned
        case .pinned, .folder: .pinned
        case .split(let anchor, _): location(of: anchor)?.section
        }
        if destinationSpace != sourceSpace, !isFavoriteTarget(target), let first = movedTabIDs.first {
            return .movedToSpace(spaces[destinationSpace].id, tabID: first)
        }
        if toSection == .pinned, fromSections == [.unpinned] { return .pinned(count: units.count) }
        if toSection == .unpinned, fromSections == [.pinned] { return .unpinned(count: units.count) }
        return .moved
    }

    // MARK: Helpers

    private func isFavoriteTarget(_ target: SidebarDropTarget) -> Bool {
        if case .favorites = target { true } else { false }
    }

    /// A row's first item: a split's row is anchored at its first pane.
    private func rowAnchor(_ id: UUID) -> UUID {
        if let split = (spaces.flatMap(\.splits) + favoriteSplits).first(where: { $0.id == id }) { return split.tabIDs.first ?? id }
        return id
    }

    private func firstStaying(from anchor: UUID?, in list: [UUID], moving: Set<UUID>) -> UUID? {
        guard let anchor, let i = list.firstIndex(of: anchor) else { return nil }
        return list[i...].first { !moving.contains($0) }
    }

    private func pinnedLevel(_ items: [PinnedItem], folder: UUID?) -> [PinnedItem] {
        guard let folder else { return items }
        for item in items {
            guard case .folder(let f) = item else { continue }
            if f.id == folder { return f.items }
            let inner = pinnedLevel(f.items, folder: folder)
            if !inner.isEmpty || f.items.containsFolder(folder) { return inner }
        }
        return []
    }

    private func folderExists(_ id: UUID, inSpace space: UUID) -> Bool {
        spaceIndex(space).map { spaces[$0].pinnedItems.containsFolder(id) } ?? false
    }

    private func spaceContaining(folder id: UUID) -> Int? {
        spaces.indices.first { spaces[$0].pinnedItems.containsFolder(id) }
    }

    private func dragUnit(_ id: UUID) -> DragUnit? {
        for space in spaces {
            if let split = space.splits.first(where: { $0.id == id }) { return .split(split.id, split.tabIDs) }
            if let folder = space.pinnedItems.folder(id) { return .folder(folder) }
        }
        if let split = favoriteSplits.first(where: { $0.id == id }) ?? split(containing: id)?.split {
            return .split(split.id, split.tabIDs)
        }
        return location(of: id) != nil ? .tab(id) : nil
    }

    /// Takes a unit out of wherever it is, as pinned items (tabs, or the folder).
    private mutating func remove(_ unit: DragUnit) -> [PinnedItem] {
        switch unit {
        case .folder(let folder):
            for s in spaces.indices { if let removed = spaces[s].pinnedItems.removeFolder(folder.id) { return [.folder(removed)] } }
            return []
        case .tab(let id):
            return removeTabAnywhere(id).map { [.tab($0)] } ?? []
        case .split(_, let ids):
            var tabs: [PinnedItem] = []
            for id in ids { if let tab = removeTabAnywhere(id) { tabs.append(.tab(tab)) } }
            return tabs
        }
    }

    private mutating func removeTabAnywhere(_ id: UUID) -> BrowserTab? {
        guard let location = location(of: id) else { return nil }
        switch location.section {
        case .favorite: return favorites.remove(at: location.index)
        case .unpinned: return spaces[location.space!].tabs.remove(at: location.index)
        case .pinned: return spaces[location.space!].pinnedItems.removeTab(id)
        }
    }

    /// Arc's drag to combine tabs into a split: the dragged tabs go beside `anchor` and join its
    /// split, or make a new one with it. Panes sit next to each other in the list, in pane order.
    private mutating func join(_ items: [PinnedItem], to anchor: UUID, side: SplitDropSide, inSpace s: Int) {
        let tabs = items.compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
        guard let section = location(of: anchor)?.section else { return }
        var split = spaces[s].splits.first { $0.tabIDs.contains(anchor) } ?? SplitView(tabIDs: [anchor])
        spaces[s].splits.removeAll { $0.id == split.id }
        let members = split.tabIDs
        let at = members.firstIndex(of: anchor)! + (side == .right ? 1 : 0)
        split.tabIDs.insert(contentsOf: tabs.map(\.id), at: at)
        // Arc gives a split's panes equal widths when one joins.
        split.widthFactors = SplitView.equalFactors(split.tabIDs.count)
        split.expandedTabID = nil
        switch section {
        case .unpinned:
            let old = spaces[s].tabs.filter { members.contains($0.id) }
            let first = spaces[s].tabs.firstIndex { members.contains($0.id) } ?? 0
            spaces[s].tabs.removeAll { members.contains($0.id) }
            let byID = Dictionary(uniqueKeysWithValues: (old + tabs).map { ($0.id, $0) })
            spaces[s].tabs.insert(contentsOf: split.tabIDs.compactMap { byID[$0] }, at: min(first, spaces[s].tabs.count))
        case .pinned:
            var previous: UUID?
            for id in split.tabIDs {
                if let tab = tabs.first(where: { $0.id == id }) {
                    if let previous {
                        _ = spaces[s].pinnedItems.insertTab(tab, after: previous)
                    } else {
                        _ = spaces[s].pinnedItems.insertTab(tab, before: members[0])
                    }
                }
                previous = id
            }
        case .favorite:
            return
        }
        spaces[s].splits.append(split)
    }
}

private enum DragUnit {
    case tab(UUID)
    case folder(TabFolder)
    case split(UUID, [UUID])

    var firstID: UUID {
        switch self {
        case .tab(let id): id
        case .folder(let folder): folder.id
        case .split(_, let ids): ids.first!
        }
    }

    var splitID: UUID? {
        if case .split(let id, _) = self { id } else { nil }
    }

    var tabIDs: [UUID] {
        switch self {
        case .tab(let id): [id]
        case .folder(let folder): folder.items.tabs.map(\.id)
        case .split(_, let ids): ids
        }
    }

    var tabCount: Int { tabIDs.count }

    /// Whether this unit is `id` or holds it.
    func contains(_ id: UUID) -> Bool {
        switch self {
        case .tab(let tab): tab == id
        case .folder(let folder): folder.id == id || folder.items.containsFolder(id) || folder.items.tabs.contains { $0.id == id }
        case .split(let split, let ids): split == id || ids.contains(id)
        }
    }
}

extension [PinnedItem] {
    func containsFolder(_ id: UUID) -> Bool {
        folder(id) != nil
    }

    public func folder(_ id: UUID) -> TabFolder? {
        for item in self {
            guard case .folder(let folder) = item else { continue }
            if folder.id == id { return folder }
            if let inner = folder.items.folder(id) { return inner }
        }
        return nil
    }

    /// Inserts items into a folder (nil: the top level), before `before` (nil: at the end).
    mutating func insert(_ items: [PinnedItem], inFolder folder: UUID?, before: UUID?) {
        guard let folder else {
            insert(contentsOf: items, at: before.flatMap { id in firstIndex { $0.id == id } } ?? count)
            return
        }
        updateFolder(folder) { $0.items.insert(items, inFolder: nil, before: before) }
    }

    /// Inserts `tab` just before the tab `neighbor`, at whatever depth it is.
    mutating func insertTab(_ tab: BrowserTab, before neighbor: UUID) -> Bool {
        for i in indices {
            switch self[i] {
            case .tab(let existing) where existing.id == neighbor:
                insert(.tab(tab), at: i)
                return true
            case .folder(var folder):
                if folder.items.insertTab(tab, before: neighbor) {
                    self[i] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}
