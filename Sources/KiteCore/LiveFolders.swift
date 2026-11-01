import Foundation

/// Arc's Live Folders: a pinned folder whose tabs come from a data source and refresh by
/// themselves. Arc's only working source is GitHub, a "Pull Requests" folder of the open pull
/// requests you made or were asked to review, read from github.com with your signed-in session.
/// What Arc does was read from its binary (docs/arc-visual-spec.md, "Live Folders").
public struct LiveFolder: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case github

        /// The source's name in the space menu's Live Folders submenu and the delete alert.
        public var displayName: String {
            switch self {
            case .github: "GitHub"
            }
        }

        /// The intro popover's description (Arc's "Description of what to expect from a Github Live Folder").
        public var introText: String {
            switch self {
            case .github: "Pull requests from you and your team will show up here automatically"
            }
        }

        /// The folder's title (Arc's "The title for a GitHub automatic live folder").
        public var folderTitle: String {
            switch self {
            case .github: "Pull Requests"
            }
        }
    }

    /// Which pull requests the folder shows (Arc's `PullRequestFilter`, an option set with these values).
    public struct Filter: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let createdByMe = Filter(rawValue: 1)
        public static let reviewRequests = Filter(rawValue: 2)
        public static let teamReviewRequests = Filter(rawValue: 4)

        public static let all: [(filter: Filter, title: String)] = [
            (.createdByMe, "Created by Me"),
            (.reviewRequests, "Review Requests"),
            (.teamReviewRequests, "Team Review Requests"),
        ]
    }

    public var source: Source
    public var filter: Filter
    /// Pull requests the user removed from the folder: later refreshes leave them out (Arc's `hiddenItems`).
    public var hiddenItems: [URL]
    /// Repositories turned off in the folder's Repositories submenu.
    public var hiddenRepositories: [String]
    /// The repositories the last refresh found, for the Repositories submenu ("This list is
    /// generated based on your currently active pull requests.").
    public var repositories: [String]
    /// Items added by a refresh and not opened since (Arc's `showNewItemsAsUnread`).
    public var unread: [URL]
    /// The items the folder held after the last refresh. One of them missing while the source still
    /// returns it means the user removed it.
    public var known: [URL]
    public var lastFetch: Date?
    /// Why the last refresh failed; nil when it worked.
    public var lastError: String?

    public init(source: Source, filter: Filter = [.createdByMe, .reviewRequests]) {
        self.source = source
        self.filter = filter
        hiddenItems = []
        hiddenRepositories = []
        repositories = []
        unread = []
        known = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
        filter = try c.decodeIfPresent(Filter.self, forKey: .filter) ?? [.createdByMe, .reviewRequests]
        hiddenItems = try c.decodeIfPresent([URL].self, forKey: .hiddenItems) ?? []
        hiddenRepositories = try c.decodeIfPresent([String].self, forKey: .hiddenRepositories) ?? []
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? []
        unread = try c.decodeIfPresent([URL].self, forKey: .unread) ?? []
        known = try c.decodeIfPresent([URL].self, forKey: .known) ?? []
        lastFetch = try c.decodeIfPresent(Date.self, forKey: .lastFetch)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// One open pull request, as a refresh found it.
public struct LivePullRequest: Hashable, Codable, Sendable {
    public var url: URL
    public var title: String
    /// "owner/name".
    public var repository: String
    public var number: Int
    public var updatedAt: Date?

    public init(url: URL, title: String, updatedAt: Date? = nil) {
        self.url = url
        self.title = title
        self.updatedAt = updatedAt
        let parts = Self.pathParts(url) ?? []
        repository = parts.count == 4 ? "\(parts[0])/\(parts[1])" : ""
        number = parts.count == 4 ? Int(parts[3]) ?? 0 : 0
    }

    /// A pull request's own page (github.com/owner/name/pull/123, without a subpage, query or
    /// fragment), or nil. Arc's page script checks the same shape (`isPullRequestRootPage`).
    public static func canonicalURL(_ url: URL) -> URL? {
        guard let parts = pathParts(url), parts.count >= 4 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/pull/\(parts[3])")
    }

    private static func pathParts(_ url: URL) -> [String]? {
        guard url.host()?.lowercased() == "github.com" else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        return parts
    }
}

extension LiveFolder.Filter {
    /// The github.com searches that make up the folder, one per filter. `review-requested` also
    /// matches requests to the user's teams; `user-review-requested` only the user.
    public var githubQueries: [String] {
        var queries: [String] = []
        let base = "is:open is:pr archived:false sort:updated-desc"
        if contains(.createdByMe) { queries.append("\(base) author:@me") }
        if contains(.reviewRequests) { queries.append("\(base) user-review-requested:@me") }
        if contains(.teamReviewRequests) { queries.append("\(base) review-requested:@me") }
        return queries
    }

    /// The menu's summary of the filter: one title, or Arc's "Mixed".
    public var title: String {
        Self.all.first { $0.filter == self }?.title ?? "Mixed"
    }
}

extension TabFolder {
    /// A live folder's tab is identified by the pull request it was made for, even after the
    /// user navigated inside it.
    fileprivate static func liveKey(_ tab: BrowserTab) -> URL? {
        (tab.pinnedURL ?? tab.url).flatMap(LivePullRequest.canonicalURL)
    }

    /// Whether `tab` (a child of this live folder) was added by a refresh and not opened since.
    public func isUnread(_ tab: BrowserTab) -> Bool {
        guard let live, let key = Self.liveKey(tab) else { return false }
        return live.unread.contains(key)
    }
}

extension BrowserState {
    /// The space's live folder for `source`, if it has one.
    public func liveFolder(_ source: LiveFolder.Source, inSpace index: Int) -> TabFolder? {
        folders(inSpace: index).first { $0.live?.source == source }
    }

    /// Every live folder, with its space's index.
    public var liveFolders: [(space: Int, folder: TabFolder)] {
        spaces.indices.flatMap { s in folders(inSpace: s).filter { $0.live != nil }.map { (s, $0) } }
    }

    /// The space menu's Live Folders → GitHub: adds the space's Pull Requests folder at the end of
    /// its pinned section, or returns the one it has.
    @discardableResult
    public mutating func addLiveFolder(_ source: LiveFolder.Source, inSpace index: Int) -> UUID {
        liveFoldersTurnedOff.removeAll { $0 == source }
        if let existing = liveFolder(source, inSpace: index) { return existing.id }
        let folder = TabFolder(name: source.folderTitle, live: LiveFolder(source: source))
        spaces[index].pinnedItems.append(.folder(folder))
        return folder.id
    }

    /// Delete Live Folder: the folder and its tabs go without being archived, since the next
    /// refresh would bring them back anyway.
    public mutating func deleteLiveFolder(_ id: UUID) {
        if let source = liveFolders.first(where: { $0.folder.id == id })?.folder.live?.source,
           !liveFoldersTurnedOff.contains(source) {
            liveFoldersTurnedOff.append(source)
        }
        _ = removeFolder(id)
    }

    /// Arc files a pull request you just made or reviewed in its space's Pull Requests folder
    /// (`reparentPullRequestToLiveFolder`; its creation sources are pullRequestCreated and
    /// pullRequestReviewSubmitted). Making one shows up as GitHub leaving a compare page
    /// (…/compare/… or …/pull/new/…) for the pull request, and reviewing as a pull request URL whose
    /// fragment is a review (`#pullrequestreview-…`).
    public static func isPullRequestCreatedOrReviewed(from old: URL?, to new: URL) -> Bool {
        guard let pull = LivePullRequest.canonicalURL(new) else { return false }
        if new.fragment()?.hasPrefix("pullrequestreview-") == true { return true }
        guard let old, old.host()?.lowercased() == "github.com", LivePullRequest.canonicalURL(old) == nil else { return false }
        let parts = old.path().split(separator: "/").map(String.init)
        let repository = pull.path().split(separator: "/").prefix(2).joined(separator: "/")
        guard parts.count >= 3, parts.prefix(2).joined(separator: "/") == repository else { return false }
        return parts[2] == "compare" || (parts.count >= 4 && parts[2] == "pull" && parts[3] == "new")
    }

    /// Files tab `id` (on a pull request) in its space's GitHub live folder, making the folder unless
    /// the user turned GitHub's off. A tab in Today moves in; a pinned tab or favorite stays where it is.
    /// Returns the folder and whether it was made, or nil when nothing changed.
    public mutating func filePullRequest(tab id: UUID) -> (folder: UUID, created: Bool)? {
        guard !liveFoldersTurnedOff.contains(.github), let location = location(of: id), let s = location.space else { return nil }
        let existing = liveFolder(.github, inSpace: s)
        if let existing, existing.items.tabs.contains(where: { $0.id == id }) { return nil }
        if existing != nil && location.section != .unpinned { return nil }
        let folder = existing?.id ?? addLiveFolder(.github, inSpace: s)
        if location.section == .unpinned {
            moveTab(id, toFolder: folder)
            spaces[s].pinnedItems.updateFolder(folder) { $0.isExpanded = true }
        }
        return (folder, existing == nil)
    }

    /// A refresh came back with `items`, newest first. Rows follow the result: new pull requests are
    /// added unread, ones that closed or merged go, and the tab on screen stays until the user leaves it.
    public mutating func applyLiveFolderResult(_ id: UUID, items: [LivePullRequest], now: Date = Date()) {
        for s in spaces.indices {
            guard folders(inSpace: s).contains(where: { $0.id == id }) else { continue }
            let selected = spaces[s].selectedTabID
            spaces[s].pinnedItems.updateFolder(id) { folder in
                guard var live = folder.live else { return }
                var tabsByKey: [URL: BrowserTab] = [:]
                var others: [PinnedItem] = []
                for item in folder.items {
                    if case .tab(let tab) = item, let key = TabFolder.liveKey(tab), tabsByKey[key] == nil {
                        tabsByKey[key] = tab
                    } else {
                        others.append(item)
                    }
                }
                let fetched = Set(items.map(\.url))
                // Known, still returned, but no longer here: the user removed it.
                for url in live.known where tabsByKey[url] == nil && fetched.contains(url) && !live.hiddenItems.contains(url) {
                    live.hiddenItems.append(url)
                }
                var repositories: [String] = []
                for item in items where !repositories.contains(item.repository) { repositories.append(item.repository) }
                live.repositories = repositories

                var rows: [PinnedItem] = []
                var keys: [URL] = []
                for item in items where !keys.contains(item.url) {
                    guard !live.hiddenItems.contains(item.url), !live.hiddenRepositories.contains(item.repository) else { continue }
                    keys.append(item.url)
                    if var tab = tabsByKey.removeValue(forKey: item.url) {
                        // A tab that isn't on another page takes the pull request's new title.
                        if tab.url == nil || tab.url.flatMap(LivePullRequest.canonicalURL) == item.url, !item.title.isEmpty {
                            tab.title = item.title
                        }
                        rows.append(.tab(tab))
                    } else {
                        rows.append(.tab(BrowserTab(url: item.url, title: item.title, lastActiveAt: now, pinnedURL: item.url)))
                        if !live.unread.contains(item.url) { live.unread.append(item.url) }
                    }
                }
                // The tab on screen stays (at the end) rather than vanishing under the user.
                for (key, tab) in tabsByKey where tab.id == selected {
                    keys.append(key)
                    rows.append(.tab(tab))
                }
                folder.items = rows + others
                live.known = keys
                live.unread = live.unread.filter(keys.contains)
                live.lastFetch = now
                live.lastError = nil
                folder.live = live
            }
            if let selected, location(of: selected) == nil {
                spaces[s].selectedTabID = spaces[s].allTabs.first?.id
            }
            normalizeSplits()
            return
        }
    }

    /// A refresh failed; the folder keeps its rows and says why in its menu.
    public mutating func failLiveFolder(_ id: UUID, error: String, now: Date = Date()) {
        updateLiveFolder(id) {
            $0.lastFetch = now
            $0.lastError = error
        }
    }

    /// One of the folder's filter items: turns that filter on or off. The last one stays on.
    public mutating func toggleLiveFolderFilter(_ id: UUID, _ filter: LiveFolder.Filter) {
        updateLiveFolder(id) { live in
            var next = live.filter
            next.formSymmetricDifference(filter)
            if !next.isEmpty { live.filter = next }
        }
    }

    /// The Repositories submenu: shows or hides one repository's pull requests. Rows follow on the
    /// next refresh.
    public mutating func toggleLiveFolderRepository(_ id: UUID, _ repository: String) {
        updateLiveFolder(id) { live in
            if let i = live.hiddenRepositories.firstIndex(of: repository) {
                live.hiddenRepositories.remove(at: i)
            } else {
                live.hiddenRepositories.append(repository)
            }
        }
    }

    /// Opening a live folder's tab marks it read.
    mutating func markLiveItemRead(_ tabID: UUID) {
        for s in spaces.indices {
            for folder in folders(inSpace: s) where folder.live?.unread.isEmpty == false {
                guard let tab = folder.items.tabs.first(where: { $0.id == tabID }), let key = TabFolder.liveKey(tab) else { continue }
                spaces[s].pinnedItems.updateFolder(folder.id) { $0.live?.unread.removeAll { $0 == key } }
                return
            }
        }
    }

    private mutating func updateLiveFolder(_ id: UUID, _ body: (inout LiveFolder) -> Void) {
        for s in spaces.indices {
            let found = spaces[s].pinnedItems.updateFolder(id) { folder in
                guard var live = folder.live else { return }
                body(&live)
                folder.live = live
            }
            if found { return }
        }
    }
}
