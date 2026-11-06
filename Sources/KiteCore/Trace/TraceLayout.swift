import Foundation

/// Where every tab sits in the sidebar, for the trace's tab events: diffing two of these after a sidebar change
/// says what changed (a tab opened, closed, moved, pinned; another tab or space in front; a folder made) without the
/// code that made the change having to say so. Titles and URLs aren't kept: a page's own changes are traced where
/// the page reports them.
public struct TraceLayout: Equatable, Sendable {
    public enum Section: String, Sendable { case favorite, pinned, unpinned }

    public struct Place: Equatable, Sendable {
        /// nil for a favorite.
        public var space: UUID?
        public var section: Section
        /// The folder directly holding it, if any.
        public var folder: UUID?
        /// The Claude › session folder it's in, by name.
        public var session: String?
        public var url: URL?
    }

    public var tabs: [UUID: Place]
    public var folders: Set<UUID>
    public var focus: BrowserState.Focus

    public init(_ state: BrowserState) {
        var tabs: [UUID: Place] = [:]
        tabs.reserveCapacity(state.favorites.count + state.spaces.reduce(0) { $0 + $1.tabs.count + 8 })
        var folders: Set<UUID> = []
        for tab in state.favorites { tabs[tab.id] = Place(space: nil, section: .favorite, url: tab.url) }
        for space in state.spaces {
            func walk(_ items: [PinnedItem], folder: UUID?, claude: Bool, session: String?) {
                for item in items {
                    switch item {
                    case .tab(let tab):
                        tabs[tab.id] = Place(space: space.id, section: .pinned, folder: folder, session: session, url: tab.url)
                    case .folder(let child):
                        folders.insert(child.id)
                        let isClaude = child.ephemeral == true && child.name == BrowserState.claudeFolderName && folder == nil
                        walk(child.items, folder: child.id, claude: isClaude,
                             session: claude && child.ephemeral == true ? child.name : session)
                    }
                }
            }
            walk(space.pinnedItems, folder: nil, claude: false, session: nil)
            for tab in space.tabs { tabs[tab.id] = Place(space: space.id, section: .unpinned, url: tab.url) }
        }
        self.tabs = tabs
        self.folders = folders
        focus = state.focus
    }

    /// One change between two layouts, as a trace event.
    public struct Change: Equatable, Sendable {
        public var name: String
        public var tab: UUID?
        public var url: URL?
        public var session: String?
        public var attrs: [String: JSONValue]
    }

    /// What changed from `before` to `self`: tabs opened and closed, moved (to another space, section or folder),
    /// pinned and unpinned, the tab and space in front, folders made and removed.
    public func changes(since before: TraceLayout) -> [Change] {
        var out: [Change] = []
        // Most changes move the selection only: skip walking the tabs when they're all where they were.
        let sameTabs = tabs.count == before.tabs.count && folders == before.folders && tabs == before.tabs
        if sameTabs { return focusChanges(since: before) }
        for (id, place) in tabs where before.tabs[id] == nil {
            out.append(Change(name: "tab.opened", tab: id, url: place.url, session: place.session,
                              attrs: ["section": .string(place.section.rawValue)]))
        }
        for (id, place) in before.tabs where tabs[id] == nil {
            out.append(Change(name: "tab.closed", tab: id, url: place.url, session: place.session,
                              attrs: ["section": .string(place.section.rawValue)]))
        }
        for (id, place) in tabs {
            guard let old = before.tabs[id], old.space != place.space || old.section != place.section || old.folder != place.folder else { continue }
            let name: String
            switch (old.section, place.section) {
            case (.unpinned, .pinned), (.unpinned, .favorite): name = "tab.pinned"
            case (.pinned, .unpinned), (.favorite, .unpinned): name = "tab.unpinned"
            default: name = "tab.moved"
            }
            var attrs: [String: JSONValue] = ["from": .string(old.section.rawValue), "to": .string(place.section.rawValue)]
            if old.space != place.space { attrs["space_changed"] = true }
            if old.folder != place.folder { attrs["folder_changed"] = true }
            if place.session != nil, old.session != place.session { attrs["into_session"] = true }
            out.append(Change(name: name, tab: id, url: place.url, session: place.session, attrs: attrs))
        }
        for id in folders.subtracting(before.folders) { out.append(Change(name: "folder.created", attrs: ["folder": .string(id.uuidString)])) }
        for id in before.folders.subtracting(folders) { out.append(Change(name: "folder.removed", attrs: ["folder": .string(id.uuidString)])) }
        out += focusChanges(since: before)
        return out.sorted { order($0.name) < order($1.name) }
    }

    private func focusChanges(since before: TraceLayout) -> [Change] {
        var out: [Change] = []
        if focus.space != before.focus.space {
            out.append(Change(name: "space.switched", tab: focus.tab, attrs: [:]))
        }
        if focus.tab != before.focus.tab, let tab = focus.tab {
            let place = tabs[tab]
            out.append(Change(name: "tab.selected", tab: tab, url: place?.url, session: place?.session,
                              attrs: ["section": .string(place?.section.rawValue ?? "unknown")]))
        }
        return out
    }

    private func order(_ name: String) -> Int {
        ["tab.closed", "folder.removed", "folder.created", "tab.opened", "tab.moved", "tab.pinned", "tab.unpinned",
         "space.switched", "tab.selected"].firstIndex(of: name) ?? 99
    }
}
