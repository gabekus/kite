import Foundation

/// A named group of Today tabs, shown as Arc's tab group header (`TabGroupHeaderCellView`)
/// above the first of its tabs. Tidy Tabs makes them.
public struct TodayTabGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    /// Members, in sidebar order.
    public var tabIDs: [UUID]

    public init(id: UUID = UUID(), title: String, tabIDs: [UUID]) {
        self.id = id
        self.title = title
        self.tabIDs = tabIDs
    }
}

/// Arc Max's Tidy Tabs: the "Tidy" button on the Today divider asks an LLM to sort the space's
/// unpinned tabs into named groups, then puts each group's tabs together under a header.
/// Kite asks its built-in Claude. Evidence is in docs/arc-visual-spec.md → Tidy Tabs.
public enum TidyTabs {
    /// Settings key, the same name as Arc's (`tidyTabsEnabled`, on in Gabe's Arc).
    public static let enabledKey = "tidyTabsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Arc's name for the group of tabs that fit nowhere else ("Tab group of miscellaneous tabs").
    public static let otherTitle = "Other"

    /// Fewer tabs than this have nothing to tidy. Arc's threshold (`canAutoOrganizeTodayTabs`)
    /// isn't in its strings; this one is Kite's.
    public static let minimumTabs = 3

    /// Claude Code's arguments for one Tidy: headless, no tools at all, the fast model, and
    /// nothing kept afterwards. The prompt goes on stdin; the reply comes back as plain text.
    public static let claudeArguments = [
        "-p",
        "--output-format", "text",
        "--model", "haiku",
        "--strict-mcp-config",
        "--tools", "",
        "--no-session-persistence",
        "--system-prompt", systemPrompt,
    ]

    static let systemPrompt =
        "You sort a person's open browser tabs into named groups. Reply with the JSON array asked for and nothing else. "
        + UntrustedContent.notice

    /// One tab as the model sees it.
    public struct Item: Hashable, Sendable {
        public var title: String
        public var url: URL?

        public init(title: String, url: URL?) {
            self.title = title
            self.url = url
        }
    }

    /// One group from the model: a title and the 1-based numbers of its tabs.
    public struct Assignment: Hashable, Sendable {
        public var title: String
        public var tabs: [Int]

        public init(title: String, tabs: [Int]) {
            self.title = title
            self.tabs = tabs
        }
    }

    /// The prompt (on stdin). Tabs are numbered from 1; titles and hosts come from web pages,
    /// so they're wrapped as untrusted.
    public static func prompt(for items: [Item]) -> String {
        let lines = items.enumerated().map { i, item in
            let title = String(item.title.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            let host = item.url?.host() ?? ""
            return "\(i + 1): \(title)\(host.isEmpty ? "" : " (\(host))")"
        }.joined(separator: "\n")
        return """
            Sort these browser tabs into a few groups by topic or task, the way a person tidying their tabs would. \
            Give each group a short title (one to three words, no emoji). Use between 2 and 7 groups. Every tab goes \
            in exactly one group; put tabs that fit nowhere else in a group titled "\(otherTitle)".

            Here are the tabs, in the format 'number: title (site)':
            \(UntrustedContent.wrap(lines, source: "tab titles"))

            Reply with only a JSON array, no other text, like:
            [{"title": "Trip planning", "tabs": [1, 4]}, {"title": "Other", "tabs": [2, 3]}]
            """
    }

    /// The model's groups, or nil when the reply has none. Tolerates a ```json fence or prose
    /// around the array. Unknown and repeated numbers are dropped; tabs the reply left out join
    /// "Other". Fewer than two groups means nothing was tidied (Arc: "No tab groups found").
    public static func parse(_ reply: String, tabCount: Int) -> [Assignment]? {
        guard tabCount > 0, let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let raw = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [[String: Any]]
        else { return nil }
        var seen = Set<Int>()
        var groups: [Assignment] = []
        for entry in raw {
            let title = ((entry["title"] ?? entry["name"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let numbers = (entry["tabs"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                .filter { (1...tabCount).contains($0) && seen.insert($0).inserted }
            guard !title.isEmpty, !numbers.isEmpty else { continue }
            if let i = groups.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                groups[i].tabs += numbers
            } else {
                groups.append(Assignment(title: String(title.prefix(40)), tabs: numbers))
            }
        }
        let missing = (1...tabCount).filter { !seen.contains($0) }
        if !missing.isEmpty {
            if let i = groups.firstIndex(where: { $0.title.caseInsensitiveCompare(otherTitle) == .orderedSame }) {
                groups[i].tabs += missing
            } else {
                groups.append(Assignment(title: otherTitle, tabs: missing))
            }
        }
        return groups.count >= 2 ? groups : nil
    }
}

extension BrowserState {
    /// What Tidy works on: the space's unpinned tabs that aren't already under a header.
    public func tidyCandidates(inSpace spaceID: UUID) -> [BrowserTab] {
        guard let s = spaceIndex(spaceID) else { return [] }
        let grouped = Set(spaces[s].tabGroups.flatMap(\.tabIDs))
        return spaces[s].tabs.filter { !grouped.contains($0.id) }
    }

    public func canTidyTabs(inSpace spaceID: UUID) -> Bool {
        tidyCandidates(inSpace: spaceID).count >= TidyTabs.minimumTabs
    }

    /// Puts each group's tabs together under a new header, in the model's order, after any
    /// tabs that weren't part of the request (opened while it ran, or already grouped).
    /// `tabs` are the candidates the prompt numbered. Returns false when nothing changed.
    @discardableResult
    public mutating func applyTidy(inSpace spaceID: UUID, tabs: [UUID], groups: [TidyTabs.Assignment]) -> Bool {
        guard let s = spaceIndex(spaceID) else { return false }
        let present = Set(spaces[s].tabs.map(\.id))
        let alreadyGrouped = Set(spaces[s].tabGroups.flatMap(\.tabIDs))
        var claimed = Set<UUID>()
        let made = groups.compactMap { group -> TodayTabGroup? in
            let ids = group.tabs.compactMap { n -> UUID? in
                guard tabs.indices.contains(n - 1) else { return nil }
                let id = tabs[n - 1]
                guard present.contains(id), !alreadyGrouped.contains(id), claimed.insert(id).inserted else { return nil }
                return id
            }
            return ids.isEmpty ? nil : TodayTabGroup(title: group.title, tabIDs: ids)
        }
        guard made.count >= 2 else { return false }
        let byID = Dictionary(uniqueKeysWithValues: spaces[s].tabs.map { ($0.id, $0) })
        let rest = spaces[s].tabs.filter { !claimed.contains($0.id) }
        // New and ungrouped tabs stay on top, then the old groups, then the new ones.
        let ungrouped = rest.filter { !alreadyGrouped.contains($0.id) }
        let oldGrouped = rest.filter { alreadyGrouped.contains($0.id) }
        spaces[s].tabs = ungrouped + oldGrouped + made.flatMap { $0.tabIDs.compactMap { byID[$0] } }
        spaces[s].tabGroups += made
        normalizeSplits()
        pruneTabGroups()
        return true
    }

    /// The header shown above a tab: the group whose first member (in sidebar order) it is.
    public func tabGroupHeader(above tabID: UUID, inSpace space: Space) -> TodayTabGroup? {
        guard !space.tabGroups.isEmpty else { return nil }
        let order = Dictionary(uniqueKeysWithValues: space.tabs.enumerated().map { ($1.id, $0) })
        return space.tabGroups.first { group in
            group.tabIDs.min { (order[$0] ?? .max) < (order[$1] ?? .max) } == tabID
        }
    }

    /// The header's context menu → Remove Header: the tabs stay where they are.
    @discardableResult
    public mutating func removeTabGroupHeader(_ groupID: UUID) -> TodayTabGroup? {
        for s in spaces.indices {
            if let i = spaces[s].tabGroups.firstIndex(where: { $0.id == groupID }) {
                return spaces[s].tabGroups.remove(at: i)
            }
        }
        return nil
    }

    /// Undo for Tidy and Remove Header: the space's Today list and headers as they were,
    /// minus tabs that have gone since.
    public mutating func restoreToday(inSpace spaceID: UUID, tabs order: [UUID], groups: [TodayTabGroup]) {
        guard let s = spaceIndex(spaceID) else { return }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Tabs opened since the snapshot keep their place on top.
        spaces[s].tabs = spaces[s].tabs.enumerated()
            .sorted { ((rank[$0.element.id] ?? -1), $0.offset) < ((rank[$1.element.id] ?? -1), $1.offset) }
            .map(\.element)
        spaces[s].tabGroups = groups
        pruneTabGroups()
    }

    /// Drops members that left Today (closed, pinned, moved) and headers left with no tabs.
    public mutating func pruneTabGroups() {
        for s in spaces.indices where !spaces[s].tabGroups.isEmpty {
            let ids = Set(spaces[s].tabs.map(\.id))
            var claimed = Set<UUID>()
            spaces[s].tabGroups = spaces[s].tabGroups.compactMap { group in
                var group = group
                group.tabIDs = group.tabIDs.filter { ids.contains($0) && claimed.insert($0).inserted }
                return group.tabIDs.isEmpty ? nil : group
            }
        }
    }
}
