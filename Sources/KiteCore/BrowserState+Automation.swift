import Foundation

// Additions for Claude's Kite tools (spaces, folders). Nothing here changes how
// existing mutations behave; these only ever add.

extension BrowserState {
    /// The name of the space Claude's tabs can open into.
    public static let claudeSpaceName = "Claude"

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
    public mutating func claudeSpace(theme: Theme) -> UUID {
        if let index = space(matching: Self.claudeSpaceName) { return spaces[index].id }
        return addBackgroundSpace(name: Self.claudeSpaceName, icon: "✳️", theme: theme)
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
}
