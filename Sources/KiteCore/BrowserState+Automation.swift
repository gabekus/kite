import Foundation

// Additions for Claude's Kite tools (spaces, folders). Nothing here changes how
// existing mutations behave; these only ever add.

extension BrowserState {
    /// The name of the folder Claude's own tabs go in, inside the space they belong to. Kite never makes
    /// a space by this name (Gabe's rule): Claude gets folders in existing spaces, never a space of its own.
    public static let claudeFolderName = "Claude"

    /// Whether Claude may make a space with this name (create_space). Never a Claude space.
    public static func claudeMayCreateSpace(named name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(claudeFolderName) != .orderedSame
    }

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

    /// Every folder in a space's pinned section, depth first. None for an index past the end (a
    /// space that was deleted).
    public func folders(inSpace index: Int) -> [TabFolder] {
        guard spaces.indices.contains(index) else { return [] }
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
    /// Whether the tab sits in a Claude folder (Claude, or Claude › a session), at any depth.
    public func isInClaudeFolder(tab id: UUID) -> Bool {
        func search(_ items: [PinnedItem], inClaude: Bool) -> Bool {
            items.contains { item in
                switch item {
                case .tab(let tab): inClaude && tab.id == id
                case .folder(let folder): search(folder.items, inClaude: inClaude || folder.ephemeral == true)
                }
            }
        }
        return spaces.contains { search($0.pinnedItems, inClaude: false) }
    }

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
        let folder = TabFolder(name: Self.claudeFolderName, ephemeral: true)
        spaces[index].pinnedItems.append(.folder(folder))
        return folder.id
    }

    /// A task's own folder inside the space's Claude folder, so each task's tabs stay together.
    /// Ephemeral too: it goes once its tabs have archived or closed.
    public mutating func claudeTaskFolder(named name: String, inSpace id: UUID) -> UUID? {
        guard let claude = claudeFolder(inSpace: id), let index = spaceIndex(id) else { return nil }
        let folder = TabFolder(name: name, ephemeral: true)
        guard spaces[index].pinnedItems.updateFolder(claude, { $0.items.append(.folder(folder)) }) else { return nil }
        return folder.id
    }

    public static let maxSessionFolderName = 40

    /// A session folder's name: one line, trimmed and capped; nil when empty.
    public static func cleanSessionFolderName(_ name: String) -> String? {
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(maxSessionFolderName))
    }

    /// The session folder name for a Claude session that never named one (a client whose tool list predates
    /// `session`, or one that left it out), so its tabs still sit together rather than loose in the Claude
    /// folder: the site of its first page and the time, like "developer.ups.com · 14:05".
    public static func automaticSessionFolderName(for url: URL?, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        return cleanSessionFolderName("\(host ?? "Claude") · \(formatter.string(from: date))") ?? claudeFolderName
    }

    /// The folder for one Claude session inside the space's Claude folder (Claude › Session name), reused
    /// when a folder by that name (any case) is already there. Ephemeral like the Claude folder.
    public mutating func claudeSessionFolder(named name: String, inSpace id: UUID) -> UUID? {
        guard let name = Self.cleanSessionFolderName(name), let claude = claudeFolder(inSpace: id),
              let index = spaceIndex(id) else { return nil }
        let existing = folders(inSpace: index).first { $0.id == claude }?.items.compactMap { item -> TabFolder? in
            if case .folder(let folder) = item, folder.name.localizedCaseInsensitiveCompare(name) == .orderedSame { return folder }
            return nil
        }.first
        if let existing { return existing.id }
        let folder = TabFolder(name: name, ephemeral: true)
        guard spaces[index].pinnedItems.updateFolder(claude, { $0.items.append(.folder(folder)) }) else { return nil }
        return folder.id
    }

    /// Drops ephemeral (Claude) folders left empty, deepest first.
    mutating func dropEmptyEphemeralFolders(inSpace index: Int) {
        func pruned(_ items: [PinnedItem]) -> [PinnedItem] {
            items.compactMap { item in
                guard case .folder(var folder) = item else { return item }
                folder.items = pruned(folder.items)
                return folder.ephemeral == true && folder.items.isEmpty ? nil : .folder(folder)
            }
        }
        spaces[index].pinnedItems = pruned(spaces[index].pinnedItems)
    }

    public mutating func createFolder(name: String, inSpace index: Int) -> UUID {
        let folder = TabFolder(name: name)
        spaces[index].pinnedItems.append(.folder(folder))
        return folder.id
    }

    /// The user's New Folder (Tabs › New Folder…, the + menu, a space's right-click menu): an empty
    /// "New Folder" at the end of the pinned section of `index`, else of the selected space.
    public mutating func createNewFolder(inSpace index: Int? = nil) {
        _ = createFolder(name: "New Folder", inSpace: index ?? selectedSpaceIndex)
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
            // A task's folder was the Claude folder's last: that goes too.
            if folder.ephemeral == true { dropEmptyEphemeralFolders(inSpace: s) }
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
    /// A tab that tab `opener`'s page opened (a link to a new tab, a popup). As in Arc it goes to the top
    /// of the unpinned tabs, except from a tab in a Claude folder: there it stays with Claude's work, pinned
    /// right after its opener (after its split, when it's in one) in the same folder, the session's own
    /// when the opener has one, so pages a task opens don't land among the user's tabs.
    @discardableResult
    public mutating func openTab(id: UUID = UUID(), url: URL?, openedBy opener: UUID, select: Bool = true,
                                 now: Date = Date()) -> UUID {
        guard isInEphemeralFolder(opener), let s = location(of: opener)?.space else {
            return openTab(id: id, url: url, select: select, now: now)
        }
        var tab = BrowserTab(id: id, url: url, lastActiveAt: now)
        tab.openedByPage = true
        let after = split(containing: opener)?.split.tabIDs.last ?? opener
        guard spaces[s].pinnedItems.insertItem(.tab(tab), after: after)
                || spaces[s].pinnedItems.insertItem(.tab(tab), after: opener) else {
            return openTab(id: id, url: url, select: select, now: now)
        }
        if select {
            spaces[s].selectedTabID = id
            selectedSpaceID = spaces[s].id
        }
        return id
    }

    /// Whether a tab sits in an ephemeral (Claude) folder, at any depth.
    public func isInEphemeralFolder(_ id: UUID) -> Bool {
        guard let s = location(of: id)?.space else { return false }
        return folders(inSpace: s).contains { $0.ephemeral == true && $0.items.contains { $0.id == id } }
    }

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
            dropEmptyEphemeralFolders(inSpace: s)
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
