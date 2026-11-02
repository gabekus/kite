import Foundation

/// Edit › Undo and Redo for the sidebar, like Arc's: closing and archiving tabs, moving and
/// reordering them, pinning, favorites, renaming tabs and folders, making and deleting folders,
/// moving tabs between spaces, adding tabs, and making, deleting, moving and renaming spaces.
///
/// Each step keeps the sidebar as it was before and after the change (`SidebarSnapshot`).
/// Undoing puts the "before" layout back over the live state, and Redo the "after" one, without
/// touching what changed since for other reasons: pages keep the URL and title they have now,
/// folders stay open or closed, and tabs that came along later (a new tab, Claude's tabs, a live
/// folder's refresh) stay where they are. This is plain value work, kept free of AppKit.
public struct SidebarSnapshot: Hashable, Sendable {
    struct SpaceContent: Hashable, Sendable {
        var pinnedItems: [PinnedItem]
        var tabs: [BrowserTab]
        var splits: [SplitView]
        var tabGroups: [TodayTabGroup]
        var selectedTabID: UUID?
    }

    var spaces: [UUID: SpaceContent]
    /// The spaces in order, whole, so a deleted one comes back with its theme, icon and profile.
    var spaceList: [Space]
    var favoritesByProfile: [String: [BrowserTab]]
    var favoriteSplitsByProfile: [String: [SplitView]]
    var recentlyClosed: [ClosedTab]
    var archived: [ClosedTab]
    var selectedSpaceID: UUID

    public init(_ state: BrowserState) {
        spaces = Dictionary(uniqueKeysWithValues: state.spaces.map {
            ($0.id, SpaceContent(pinnedItems: $0.pinnedItems, tabs: $0.tabs, splits: $0.splits,
                                 tabGroups: $0.tabGroups, selectedTabID: $0.selectedTabID))
        })
        spaceList = state.spaces
        favoritesByProfile = state.favoritesByProfile
        favoriteSplitsByProfile = state.favoriteSplitsByProfile
        recentlyClosed = state.recentlyClosed
        archived = state.archived
        selectedSpaceID = state.selectedSpaceID
    }

    /// Every tab the sidebar shows, by id.
    var tabsByID: [UUID: BrowserTab] {
        var all: [UUID: BrowserTab] = [:]
        for tabs in favoritesByProfile.values { for tab in tabs { all[tab.id] = tab } }
        for space in spaces.values {
            for tab in space.pinnedItems.tabs + space.tabs { all[tab.id] = tab }
        }
        return all
    }
}

/// What an undo step is called in the Edit menu ("Undo Archive Tab"). The names are
/// Arc's own (its undo titles, read from Arc's binary: see the PR).
public enum SidebarUndo {
    /// How many steps each window keeps.
    public static let levels = 100

    /// The part of the state an undo step covers, with everything that changes on its own
    /// stripped out (page URLs and titles, favicons, last-active times, folders opening and
    /// closing, split divider positions, selection). Two states with the same layout compare equal.
    public struct Layout: Hashable, Sendable {
        var spaces: [UUID: SpaceLayout]
        var spaceOrder: [UUID]
        var spaceNames: [UUID: String]
        var favorites: [String: [TabLayout]]
        var favoriteSplits: [String: [SplitLayout]]

        struct TabLayout: Hashable, Sendable {
            var id: UUID
            var customTitle: String?
        }
        indirect enum ItemLayout: Hashable, Sendable {
            case tab(TabLayout)
            case folder(id: UUID, name: String, items: [ItemLayout])
        }
        struct SplitLayout: Hashable, Sendable {
            var tabIDs: [UUID]
            var orientation: SplitOrientation
        }
        struct SpaceLayout: Hashable, Sendable {
            var pinned: [ItemLayout]
            var tabs: [TabLayout]
            var splits: [SplitLayout]
            var groups: [TodayTabGroup]
        }

        public init(_ state: BrowserState) {
            func tab(_ tab: BrowserTab) -> TabLayout {
                TabLayout(id: tab.id, customTitle: tab.customTitle.flatMap { $0.isEmpty ? nil : $0 })
            }
            func layout(_ list: [PinnedItem]) -> [ItemLayout] {
                list.map { item -> ItemLayout in
                    switch item {
                    case .tab(let t): .tab(tab(t))
                    case .folder(let f): .folder(id: f.id, name: f.name, items: Self.isLive(f) ? [] : layout(f.items))
                    }
                }
            }
            func splits(_ splits: [SplitView]) -> [SplitLayout] {
                splits.map { SplitLayout(tabIDs: $0.tabIDs, orientation: $0.orientation) }
            }
            spaces = Dictionary(uniqueKeysWithValues: state.spaces.map {
                ($0.id, SpaceLayout(pinned: layout($0.pinnedItems), tabs: $0.tabs.map(tab), splits: splits($0.splits), groups: $0.tabGroups))
            })
            spaceOrder = state.spaces.map(\.id)
            spaceNames = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id, $0.name) })
            favorites = state.favoritesByProfile.mapValues { $0.map(tab) }
            favoriteSplits = state.favoriteSplitsByProfile.mapValues(splits)
        }

        /// A live folder's tabs come from its source and refresh on their own, so they aren't a
        /// user change.
        private static func isLive(_ folder: TabFolder) -> Bool { folder.live != nil }
    }

    /// Whether going from `before` to `after` is a change the user can undo.
    public static func isUndoable(from before: BrowserState, to after: BrowserState) -> Bool {
        Layout(before) != Layout(after)
    }

    /// Arc's name for the change from `before` to `after`, as the Edit menu shows it after
    /// "Undo " and "Redo ".
    public static func actionName(from before: BrowserState, to after: BrowserState) -> String {
        // Spaces first: deleting one takes its tabs with it, and that's still "Delete Space".
        let oldSpaces = before.spaces.map(\.id), newSpaces = after.spaces.map(\.id)
        if oldSpaces.contains(where: { !newSpaces.contains($0) }) { return "Delete Space" }
        if newSpaces.contains(where: { !oldSpaces.contains($0) }) { return "New Space" }
        if oldSpaces != newSpaces { return "Move Space" }
        if before.spaces.contains(where: { space in after.spaces.first { $0.id == space.id }?.name != space.name }) {
            return "Customize Space"
        }

        let old = Placement.all(in: before), new = Placement.all(in: after)
        let removed = old.keys.filter { new[$0] == nil }
        let added = new.keys.filter { old[$0] == nil }
        let oldFolders = folders(in: before), newFolders = folders(in: after)
        let removedFolders = oldFolders.keys.filter { newFolders[$0] == nil }
        let addedFolders = newFolders.keys.filter { oldFolders[$0] == nil }

        if !removedFolders.isEmpty { return removedFolders.count == 1 ? "Delete Folder" : "Delete Folders" }
        if !removed.isEmpty {
            // Arc names a close by what went: pinned tabs are "Remove Pin", favorites "Remove Favorite",
            // and Today's tabs are archived ("Undo Archive Tab"), or just closed when they never had a page.
            let one = removed.count == 1
            if removed.allSatisfy({ old[$0]?.section == .favorite }) { return one ? "Remove Favorite" : "Remove Favorites" }
            if removed.allSatisfy({ old[$0]?.section == .pinned }) { return one ? "Remove Pin" : "Remove Pins" }
            let archivedIDs = Set(after.archived.map(\.tab.id)).union(after.recentlyClosed.map(\.tab.id))
            if removed.allSatisfy({ !archivedIDs.contains($0) }) { return one ? "Close Tab" : "Close Tabs" }
            return one ? "Archive Tab" : "Archive Tabs"
        }
        if !addedFolders.isEmpty { return "New Folder" }
        if !added.isEmpty { return added.count == 1 ? "New Tab" : "New Tabs" }

        // Renames: Arc calls renaming a tab or a folder "Rename Item".
        let renamedFolder = newFolders.contains { id, name in oldFolders[id].map { $0 != name } ?? false }
        let renamedTab = new.contains { id, placement in old[id].map { $0.customTitle != placement.customTitle } ?? false }
        if renamedFolder || renamedTab { return "Rename Item" }

        // Every move is "Move Item" in Arc: reordering, pinning and unpinning, into or out of a folder
        // or Favorites, and to another space.
        let moved = new.filter { id, placement in old[id].map { $0.where != placement.where } ?? false }.count
        let count = moved + reorderedCount(old, new)
        if count > 0 { return count == 1 ? "Move Item" : "Move Items" }

        // Splits and Tidy Tabs' groups.
        let oldLayout = Layout(before), newLayout = Layout(after)
        let splitsChanged = oldLayout.favoriteSplits != newLayout.favoriteSplits
            || oldLayout.spaces.contains { id, space in newLayout.spaces[id].map { $0.splits != space.splits } ?? false }
        if splitsChanged { return "Split View" }
        let groupsChanged = oldLayout.spaces.contains { id, space in newLayout.spaces[id].map { $0.groups != space.groups } ?? false }
        if groupsChanged { return "Tidy Tabs" }
        // Folders moved among the pinned tabs.
        return "Move Item"
    }

    /// Where a tab sits in the sidebar, for naming a change.
    struct Placement: Hashable {
        enum Section: Hashable { case favorite, pinned, unpinned }
        var id: UUID
        var space: UUID?
        var section: Section
        /// The folder it's in, or nil at the top of its section.
        var container: UUID?
        var index: Int
        var customTitle: String?

        /// Section, space and folder, without the position in it.
        var `where`: [AnyHashable] { [AnyHashable(section), AnyHashable(space), AnyHashable(container)] }

        static func all(in state: BrowserState) -> [UUID: Placement] {
            var all: [UUID: Placement] = [:]
            for (_, tabs) in state.favoritesByProfile {
                for (i, tab) in tabs.enumerated() {
                    all[tab.id] = Placement(id: tab.id, space: nil, section: .favorite, container: nil, index: i, customTitle: tab.customTitle)
                }
            }
            for space in state.spaces {
                func walk(_ items: [PinnedItem], in folder: UUID?) {
                    for (i, item) in items.enumerated() {
                        switch item {
                        case .tab(let tab):
                            all[tab.id] = Placement(id: tab.id, space: space.id, section: .pinned, container: folder ?? space.id,
                                                    index: i, customTitle: tab.customTitle)
                        case .folder(let f):
                            // A live folder's tabs aren't the user's.
                            if f.live == nil { walk(f.items, in: f.id) }
                        }
                    }
                }
                walk(space.pinnedItems, in: nil)
                for (i, tab) in space.tabs.enumerated() {
                    all[tab.id] = Placement(id: tab.id, space: space.id, section: .unpinned, container: nil, index: i, customTitle: tab.customTitle)
                }
            }
            return all
        }
    }

    /// How many tabs moved within their own list: its length less the longest run that kept its order.
    static func reorderedCount(_ old: [UUID: Placement], _ new: [UUID: Placement]) -> Int {
        var lists: [[AnyHashable]: [(old: Int, new: Int)]] = [:]
        for (id, was) in old {
            guard let now = new[id], now.where == was.where else { continue }
            lists[was.where, default: []].append((was.index, now.index))
        }
        return lists.values.reduce(0) { total, list in
            // Longest increasing run of new positions, in old order (patience sorting).
            var tails: [Int] = []
            for position in list.sorted(by: { $0.old < $1.old }).map(\.new) {
                if let i = tails.firstIndex(where: { $0 >= position }) { tails[i] = position } else { tails.append(position) }
            }
            return total + list.count - tails.count
        }
    }

    /// Every folder, with its name.
    static func folders(in state: BrowserState) -> [UUID: String] {
        var all: [UUID: String] = [:]
        func walk(_ items: [PinnedItem]) {
            for case .folder(let f) in items {
                all[f.id] = f.name
                walk(f.items)
            }
        }
        for space in state.spaces { walk(space.pinnedItems) }
        return all
    }
}

extension BrowserState {
    /// Undo (or Redo) one sidebar step: puts the layout `target` back, where `other` is the layout
    /// on the step's other side. Tabs keep their live page (URL, title, favicon), folders keep
    /// whether they're open, and tabs that the step didn't touch and that came along since stay.
    /// Returns the tabs it brought back, so the shell can show them.
    @discardableResult
    public mutating func restoreSidebar(_ target: SidebarSnapshot, other: SidebarSnapshot) -> [UUID] {
        let current = SidebarSnapshot(self)
        let live = current.tabsByID
        let stepTabs = Set(target.tabsByID.keys).union(other.tabsByID.keys)
        let liveFolders = Self.folderStates(in: spaces.flatMap(\.pinnedItems))
        restoreSpaces(target, other: other)

        // The step's layout, space by space (spaces made or deleted since are left alone).
        for s in spaces.indices {
            guard let content = target.spaces[spaces[s].id] else { continue }
            spaces[s].pinnedItems = content.pinnedItems
            spaces[s].tabs = content.tabs
            spaces[s].splits = content.splits
            spaces[s].tabGroups = content.tabGroups
        }
        // Favorites of profiles deleted since stay gone.
        for profile in Set(target.favoritesByProfile.keys).union(favoritesByProfile.keys) where isKnownProfile(profile) {
            favoritesByProfile[profile] = target.favoritesByProfile[profile]
        }
        favoriteSplitsByProfile = target.favoriteSplitsByProfile

        // Live page state and folder open/closed come from now; a live folder keeps its current tabs.
        for s in spaces.indices {
            spaces[s].tabs = spaces[s].tabs.map { Self.refreshed($0, from: live) }
            spaces[s].pinnedItems = Self.refreshed(spaces[s].pinnedItems, from: live, folders: liveFolders)
        }
        for profile in favoritesByProfile.keys {
            favoritesByProfile[profile] = favoritesByProfile[profile]?.map { Self.refreshed($0, from: live) }
        }

        // A tab can only be in one place: drop copies left in spaces the step doesn't know.
        var seen = Set<UUID>()
        for s in spaces.indices where target.spaces[spaces[s].id] != nil {
            seen.formUnion(spaces[s].allTabs.map(\.id))
        }
        for tabs in favoritesByProfile.values { seen.formUnion(tabs.map(\.id)) }
        for s in spaces.indices where target.spaces[spaces[s].id] == nil {
            spaces[s].tabs.removeAll { seen.contains($0.id) }
            for id in spaces[s].pinnedItems.tabs.map(\.id) where seen.contains(id) { _ = spaces[s].pinnedItems.removeTab(id) }
            seen.formUnion(spaces[s].allTabs.map(\.id))
        }

        // Tabs that came along since the step, outside it, stay where they were.
        for (id, tab) in live where !seen.contains(id) && !stepTabs.contains(id) {
            keepNewcomer(tab, from: current)
            seen.insert(id)
        }

        // The archive: tabs back in the sidebar leave it, and tabs the step takes away go back in.
        let shown = allTabIDs
        let removedByStep = Set(other.tabsByID.keys).subtracting(target.tabsByID.keys).filter { live[$0] != nil && !shown.contains($0) }
        recentlyClosed.removeAll { shown.contains($0.tab.id) }
        archived.removeAll { shown.contains($0.tab.id) }
        for closed in target.recentlyClosed where removedByStep.contains(closed.tab.id) {
            var closed = closed
            if let tab = live[closed.tab.id] { closed.tab = Self.refreshed(closed.tab, from: [tab.id: tab]) }
            recentlyClosed.append(closed)
        }
        if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst(recentlyClosed.count - Self.recentlyClosedLimit) }
        for closed in target.archived where removedByStep.contains(closed.tab.id) {
            var closed = closed
            if let tab = live[closed.tab.id] { closed.tab = Self.refreshed(closed.tab, from: [tab.id: tab]) }
            archived.append(closed)
        }
        if archived.count > Self.archiveLimit { archived.removeFirst(archived.count - Self.archiveLimit) }

        // Selection: a tab brought back that was the one shown comes forward, as Arc's Undo Archive
        // Tab does; a selection the step took away falls back to the step's.
        let broughtBack = shown.filter { live[$0] == nil }
        for s in spaces.indices {
            guard let content = target.spaces[spaces[s].id] else { continue }
            let ids = Set(spaces[s].allTabs.map(\.id)).union(favorites.map(\.id))
            if let wanted = content.selectedTabID, broughtBack.contains(wanted), ids.contains(wanted) {
                spaces[s].selectedTabID = wanted
                if target.selectedSpaceID == spaces[s].id { selectedSpaceID = spaces[s].id }
            } else if let selected = spaces[s].selectedTabID, !ids.contains(selected) {
                spaces[s].selectedTabID = content.selectedTabID.flatMap { ids.contains($0) ? $0 : nil } ?? spaces[s].allTabs.first?.id
            }
        }
        normalizeSplits()
        return Array(broughtBack)
    }

    /// The step's spaces: ones it made go, ones it deleted come back whole where they were, and
    /// they take the step's order and names. Spaces made since, outside the step, stay.
    private mutating func restoreSpaces(_ target: SidebarSnapshot, other: SidebarSnapshot) {
        let wanted = target.spaceList.map(\.id)
        let made = Set(other.spaceList.map(\.id)).subtracting(wanted)
        if spaces.contains(where: { !made.contains($0.id) }) { spaces.removeAll { made.contains($0.id) } }
        let present = Set(spaces.map(\.id))
        var cameBack: [UUID] = []
        for (i, space) in target.spaceList.enumerated() where !present.contains(space.id) {
            spaces.insert(space, at: min(i, spaces.count))
            cameBack.append(space.id)
        }
        // The step's spaces take its order in the slots they fill; others keep their places.
        let rank = Dictionary(uniqueKeysWithValues: wanted.enumerated().map { ($1, $0) })
        let slots = spaces.indices.filter { rank[spaces[$0].id] != nil }
        let ordered = slots.map { spaces[$0] }.sorted { rank[$0.id]! < rank[$1.id]! }
        for (slot, space) in zip(slots, ordered) { spaces[slot] = space }
        for s in spaces.indices {
            if let name = target.spaceList.first(where: { $0.id == spaces[s].id })?.name { spaces[s].name = name }
        }
        if let back = cameBack.first(where: { $0 == target.selectedSpaceID }) ?? cameBack.first {
            selectedSpaceID = back
        } else if spaceIndex(selectedSpaceID) == nil {
            selectedSpaceID = spaceIndex(target.selectedSpaceID).map { spaces[$0].id } ?? spaces[0].id
        }
    }

    private func isKnownProfile(_ profile: String) -> Bool {
        profile == Profile.defaultDirectory || profiles.contains { $0.directory == profile }
    }

    /// A tab from the step with today's page on it.
    private static func refreshed(_ tab: BrowserTab, from live: [UUID: BrowserTab]) -> BrowserTab {
        guard let now = live[tab.id] else { return tab }
        var tab = tab
        tab.url = now.url
        tab.title = now.title
        tab.faviconURL = now.faviconURL
        tab.lastActiveAt = now.lastActiveAt
        return tab
    }

    private static func refreshed(_ items: [PinnedItem], from live: [UUID: BrowserTab], folders: [UUID: TabFolder]) -> [PinnedItem] {
        items.map { item in
            switch item {
            case .tab(let tab):
                return .tab(refreshed(tab, from: live))
            case .folder(var folder):
                if let now = folders[folder.id] {
                    folder.isExpanded = now.isExpanded
                    // A live folder's tabs are its source's, not the step's.
                    if folder.live != nil {
                        folder.items = now.items
                        folder.live = now.live
                        return .folder(folder)
                    }
                }
                folder.items = refreshed(folder.items, from: live, folders: folders)
                return .folder(folder)
            }
        }
    }

    private static func folderStates(in items: [PinnedItem]) -> [UUID: TabFolder] {
        var all: [UUID: TabFolder] = [:]
        for case .folder(let folder) in items {
            all[folder.id] = folder
            all.merge(folderStates(in: folder.items)) { a, _ in a }
        }
        return all
    }

    /// Puts back a tab the step never saw (opened since, by the user, Claude or a live folder),
    /// near where it was: the same place in its space's Today, or its folder, or the top of
    /// its space's pinned tabs.
    private mutating func keepNewcomer(_ tab: BrowserTab, from current: SidebarSnapshot) {
        for (profile, tabs) in current.favoritesByProfile {
            if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
                var list = favoritesByProfile[profile] ?? []
                list.insert(tab, at: min(i, list.count))
                favoritesByProfile[profile] = list
                return
            }
        }
        for (spaceID, content) in current.spaces {
            guard let s = spaceIndex(spaceID) else { continue }
            if let i = content.tabs.firstIndex(where: { $0.id == tab.id }) {
                spaces[s].tabs.insert(tab, at: min(i, spaces[s].tabs.count))
                return
            }
            if content.pinnedItems.tabs.contains(where: { $0.id == tab.id }) {
                if case .some(.some(let folder)) = Self.parentFolder(of: tab.id, in: content.pinnedItems),
                   spaces[s].pinnedItems.updateFolder(folder, { $0.items.append(.tab(tab)) }) {
                    return
                }
                spaces[s].pinnedItems.append(.tab(tab))
                return
            }
        }
    }

    /// The folder holding tab `id`: `.some(nil)` at the top level, nil when it isn't there at all.
    private static func parentFolder(of id: UUID, in items: [PinnedItem], parent: UUID? = nil) -> UUID?? {
        for item in items {
            switch item {
            case .tab(let tab) where tab.id == id: return .some(parent)
            case .folder(let folder):
                if let found = parentFolder(of: id, in: folder.items, parent: folder.id) { return found }
            default: continue
            }
        }
        return nil
    }
}
