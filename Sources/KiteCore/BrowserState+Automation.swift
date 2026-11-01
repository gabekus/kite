import Foundation

// Additions for Claude's Kite tools (spaces, folders). Nothing here changes how
// existing mutations behave; these only ever add.

extension BrowserState {
    /// The name of the space Claude's tabs can open into.
    public static let claudeSpaceName = "Claude"
    /// Orange, like Claude (✳️ renders green).
    public static let claudeSpaceIcon = "✴️"

    /// A space by id, or by name (case-insensitive).
    public func space(matching idOrName: String) -> Int? {
        let key = idOrName.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: key), let index = spaceIndex(id) { return index }
        return spaces.firstIndex { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }
    }

    /// Adds a space without switching to it (unlike `addSpace`, which is for the user's own clicks).
    @discardableResult
    public mutating func addBackgroundSpace(name: String, icon: String, theme: Theme) -> UUID {
        let space = Space(name: name, icon: icon, theme: theme)
        spaces.append(space)
        return space.id
    }

    /// The Claude space, made (in the background) the first time it's needed.
    public mutating func claudeSpace(theme: Theme = .claude) -> UUID {
        if let index = space(matching: Self.claudeSpaceName) {
            // Claude spaces made before it was orange: the green ✳️ and the last preset theme.
            if spaces[index].icon == "✳️" {
                spaces[index].icon = Self.claudeSpaceIcon
                if spaces[index].theme == Theme.presets.last { spaces[index].theme = theme }
            }
            return spaces[index].id
        }
        return addBackgroundSpace(name: Self.claudeSpaceName, icon: Self.claudeSpaceIcon, theme: theme)
    }

    /// Every folder in a space's pinned section, depth first.
    public func folders(inSpace index: Int) -> [TabFolder] {
        func collect(_ items: [PinnedItem]) -> [TabFolder] {
            items.flatMap { item -> [TabFolder] in
                guard case .folder(let folder) = item else { return [] }
                return [folder] + collect(folder.items)
            }
        }
        return collect(spaces[index].pinnedItems)
    }

    /// A folder by id, or by name (searching the selected space first).
    public func folder(matching idOrName: String) -> (space: Int, folder: TabFolder)? {
        let key = idOrName.trimmingCharacters(in: .whitespaces)
        let order = [selectedSpaceIndex] + spaces.indices.filter { $0 != selectedSpaceIndex }
        for s in order {
            if let folder = folders(inSpace: s).first(where: {
                $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame
            }) {
                return (s, folder)
            }
        }
        return nil
    }

    /// Adds an empty folder at the end of a space's pinned section.
    @discardableResult
    /// The space's Claude folder, where Claude's tabs go when asked from that space: made on
    /// first use, and gone again once its tabs have all archived (`TabFolder.ephemeral`).
    public mutating func claudeFolder(inSpace id: UUID) -> UUID? {
        guard let index = spaceIndex(id) else { return nil }
        if let folder = spaces[index].pinnedItems.compactMap({ item -> TabFolder? in
            if case .folder(let folder) = item, folder.ephemeral == true { return folder }
            return nil
        }).first {
            return folder.id
        }
        let folder = TabFolder(name: Self.claudeSpaceName, ephemeral: true)
        spaces[index].pinnedItems.append(.folder(folder))
        return folder.id
    }

    public mutating func createFolder(name: String, inSpace index: Int) -> UUID {
        let folder = TabFolder(name: name)
        spaces[index].pinnedItems.append(.folder(folder))
        return folder.id
    }

    /// Moves a space tab (pinned or not) into a folder, which pins it there. Favorites stay put.
    /// Returns false when the tab or folder doesn't exist, or the tab is a favorite.
    @discardableResult
    public mutating func moveTab(_ id: UUID, toFolder folderID: UUID) -> Bool {
        guard let location = location(of: id), let from = location.space,
              let to = spaces.indices.first(where: { folders(inSpace: $0).contains { $0.id == folderID } }) else {
            return false
        }
        let tab: BrowserTab?
        switch location.section {
        case .unpinned: tab = spaces[from].tabs.remove(at: location.index)
        case .pinned: tab = spaces[from].pinnedItems.removeTab(id)
        case .favorite: tab = nil
        }
        guard let tab else { return false }
        spaces[to].pinnedItems.updateFolder(folderID) { $0.items.append(.tab(tab)) }
        if from != to, spaces[from].selectedTabID == id {
            spaces[from].selectedTabID = spaces[from].allTabs.first?.id
        }
        return true
    }

    /// Removes a folder and everything in it (a Claude task's folder, when the user clears
    /// the task's tabs). Returns the ids of the tabs that went with it.
    @discardableResult
    public mutating func removeFolder(_ id: UUID) -> [UUID] {
        for s in spaces.indices {
            guard let folder = spaces[s].pinnedItems.removeFolder(id) else { continue }
            let removed = folder.items.tabs.map(\.id)
            if let selected = spaces[s].selectedTabID, removed.contains(selected) {
                spaces[s].selectedTabID = spaces[s].allTabs.first?.id
            }
            normalizeSplits()
            return removed
        }
        return []
    }
}

extension BrowserState {
    /// Removes a pinned tab (in or out of a folder) for good, without archiving it: a tab a
    /// Claude task opened in its folder and then closed. Pinned tabs otherwise only unload on close.
    /// With `droppingEmptyFolder`, a folder the tab leaves empty goes too, so a task whose
    /// tabs are all closed doesn't leave an empty folder behind.
    @discardableResult
    public mutating func removePinnedTab(_ id: UUID, droppingEmptyFolder: Bool = false) -> Bool {
        guard let location = location(of: id), location.section == .pinned, let s = location.space else { return false }
        let parent = folders(inSpace: s).first { $0.items.contains { $0.id == id } }?.id
        guard spaces[s].pinnedItems.removeTab(id) != nil else { return false }
        if droppingEmptyFolder, let parent,
           folders(inSpace: s).first(where: { $0.id == parent })?.items.isEmpty == true {
            _ = spaces[s].pinnedItems.removeFolder(parent)
        }
        if spaces[s].selectedTabID == id { spaces[s].selectedTabID = spaces[s].allTabs.first?.id }
        normalizeSplits()
        return true
    }
}

extension [PinnedItem] {
    mutating func removeFolder(_ id: UUID) -> TabFolder? {
        for i in indices {
            guard case .folder(var folder) = self[i] else { continue }
            if folder.id == id {
                remove(at: i)
                return folder
            }
            if let removed = folder.items.removeFolder(id) {
                self[i] = .folder(folder)
                return removed
            }
        }
        return nil
    }
}
