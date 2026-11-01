import Foundation

public struct BrowserTab: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var url: URL?
    public var title: String
    public var faviconURL: URL?
    public var lastActiveAt: Date
    /// Where a pinned tab or favorite belongs (Arc's `savedURL`): the page it was pinned at,
    /// which "Back to Pinned URL" returns to. Nil for unpinned tabs. See `syncPinnedURLs()`.
    public var pinnedURL: URL?
    /// A name the user gave the tab (Arc's Rename), shown instead of the page's title and kept
    /// when the page's title changes. nil shows the page's title. Older sessions decode it as nil.
    public var customTitle: String?

    public init(
        id: UUID = UUID(),
        url: URL?,
        title: String = "",
        faviconURL: URL? = nil,
        lastActiveAt: Date = Date(),
        pinnedURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.lastActiveAt = lastActiveAt
        self.pinnedURL = pinnedURL
    }

    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        return url?.absoluteString ?? "New Tab"
    }
}

public struct TabFolder: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isExpanded: Bool
    public var items: [PinnedItem]
    /// Set for a live folder (LiveFolders.swift), whose tabs come from a source. Older sessions decode it as nil.
    public var live: LiveFolder?

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true, items: [PinnedItem] = [], live: LiveFolder? = nil) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.items = items
        self.live = live
    }
}

/// The pinned section is a tree: tabs and (nestable) folders.
public indirect enum PinnedItem: Identifiable, Hashable, Codable, Sendable {
    case tab(BrowserTab)
    case folder(TabFolder)

    public var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .folder(let folder): folder.id
        }
    }
}

extension [PinnedItem] {
    /// Every tab in sidebar order, depth first.
    public var tabs: [BrowserTab] {
        flatMap { item -> [BrowserTab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(let folder): folder.items.tabs
            }
        }
    }

    @discardableResult
    mutating func updateTab(_ id: UUID, _ body: (inout BrowserTab) -> Void) -> Bool {
        for i in indices {
            switch self[i] {
            case .tab(var tab) where tab.id == id:
                body(&tab)
                self[i] = .tab(tab)
                return true
            case .folder(var folder):
                if folder.items.updateTab(id, body) {
                    self[i] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    mutating func removeTab(_ id: UUID) -> BrowserTab? {
        for i in indices {
            switch self[i] {
            case .tab(let tab) where tab.id == id:
                remove(at: i)
                return tab
            case .folder(var folder):
                if let tab = folder.items.removeTab(id) {
                    self[i] = .folder(folder)
                    return tab
                }
            default:
                continue
            }
        }
        return nil
    }

    @discardableResult
    mutating func updateFolder(_ id: UUID, _ body: (inout TabFolder) -> Void) -> Bool {
        for i in indices {
            guard case .folder(var folder) = self[i] else { continue }
            if folder.id == id {
                body(&folder)
                self[i] = .folder(folder)
                return true
            }
            if folder.items.updateFolder(id, body) {
                self[i] = .folder(folder)
                return true
            }
        }
        return false
    }
}

/// A space is a named set of tabs with its own theme, like a lightweight profile.
public struct Space: Identifiable, Hashable, Codable, Sendable {
    public static let symbolPrefix = "symbol:"
    public var id: UUID
    public var name: String
    /// An emoji, `symbol:` and an SF Symbol name (Arc's Icon tab), or empty: Arc shows an icon-less space as a dot.
    public var icon: String
    public var theme: Theme
    public var pinnedItems: [PinnedItem]
    /// Unpinned tabs, newest first.
    public var tabs: [BrowserTab]
    public var selectedTabID: UUID?
    /// Tabs shown side by side. Each member also stays in `pinnedItems` or `tabs`.
    public var splits: [SplitView]
    /// Arc's tab group headers in Today, from Tidy Tabs (see TidyTabs.swift). Each header sits
    /// above the first of its tabs in `tabs`.
    public var tabGroups: [TodayTabGroup] = []
    /// The folder of the profile this space uses (Profiles.swift); nil is the default profile.
    public var profile: String?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        theme: Theme,
        pinnedItems: [PinnedItem] = [],
        tabs: [BrowserTab] = [],
        selectedTabID: UUID? = nil,
        splits: [SplitView] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.theme = theme
        self.pinnedItems = pinnedItems
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.splits = splits
    }

    /// Pinned tabs in sidebar order, including those inside folders.
    public var pinned: [BrowserTab] { pinnedItems.tabs }

    /// Sidebar order: pinned first, then unpinned.
    public var allTabs: [BrowserTab] { pinned + tabs }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, theme, pinnedItems, pinned, tabs, selectedTabID, splits, tabGroups, profile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        theme = try c.decode(Theme.self, forKey: .theme)
        // Sessions from before folders stored a flat `pinned` array.
        if let items = try c.decodeIfPresent([PinnedItem].self, forKey: .pinnedItems) {
            pinnedItems = items
        } else {
            pinnedItems = (try c.decodeIfPresent([BrowserTab].self, forKey: .pinned) ?? []).map(PinnedItem.tab)
        }
        tabs = try c.decode([BrowserTab].self, forKey: .tabs)
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        splits = try c.decodeIfPresent([SplitView].self, forKey: .splits) ?? []
        tabGroups = try c.decodeIfPresent([TodayTabGroup].self, forKey: .tabGroups) ?? []
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(theme, forKey: .theme)
        try c.encode(pinnedItems, forKey: .pinnedItems)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        if !splits.isEmpty { try c.encode(splits, forKey: .splits) }
        if !tabGroups.isEmpty { try c.encode(tabGroups, forKey: .tabGroups) }
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

public struct ClosedTab: Hashable, Codable, Sendable {
    public var tab: BrowserTab
    public var spaceID: UUID
    public var index: Int
    /// When it went into the archive (Arc's `archivedAt`). nil for entries saved before Kite kept it.
    public var archivedAt: Date? = nil
    /// How it got there (Arc's `ArchiveReason`). nil for entries saved before Kite kept it.
    public var reason: ArchiveReason? = nil
}

public enum TabSection: Hashable, Sendable {
    case favorite
    case pinned
    case unpinned
}

public struct TabLocation: Hashable, Sendable {
    /// Nil for favorites, which belong to no space.
    public var space: Int?
    public var section: TabSection
    /// Position within its section (pinned tabs are counted depth first).
    public var index: Int
}

public enum CloseOutcome: Equatable, Sendable {
    /// The tab is gone (it can still be reopened from `recentlyClosed`).
    case removed
    /// Pinned tabs stay in the sidebar; the shell should drop their page.
    case unloaded
    case notFound
}
