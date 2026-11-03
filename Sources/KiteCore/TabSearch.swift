import Foundation

/// Ranks open tabs for the command bar's "switch to tab" results.
public enum TabSearch {
    public struct Match: Hashable, Sendable {
        public var tab: BrowserTab
        public var spaceID: UUID
        public var score: Int
        /// The match itself (one of the strengths below), without the current space's lift.
        public var strength: Int
        public var isFavorite = false
        /// A favorite whose host starts with what's typed but isn't all of it: its address is being typed.
        public var completesHost = false
    }

    /// Match strengths, strongest first.
    public static let titlePrefix = 100, wordPrefix = 80, hostPrefix = 70, inTitle = 60, inAddress = 40

    public static func rank(_ query: String, in state: BrowserState, limit: Int = 6) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var matches: [Match] = []
        for tab in state.favorites {
            guard let score = score(q, tab) else { continue }
            matches.append(Match(tab: tab, spaceID: state.selectedSpaceID, score: score + 5, strength: score,
                                 isFavorite: true, completesHost: completesHost(q, tab)))
        }
        for space in state.spaces {
            for tab in space.allTabs {
                guard let strength = score(q, tab) else { continue }
                let score = space.id == state.selectedSpaceID ? strength + 5 : strength
                matches.append(Match(tab: tab, spaceID: space.id, score: score, strength: strength))
            }
        }
        matches.sort { a, b in
            a.score != b.score ? a.score > b.score : a.tab.lastActiveAt > b.tab.lastActiveAt
        }
        return Array(matches.prefix(limit))
    }

    /// The command bar's "Switch to Tab" rows: the best matches, leaving out the tab you're on (Arc does, in ⌘T).
    public static func switchTargets(_ query: String, in state: BrowserState, limit: Int = 5) -> [Match] {
        let selected = state.selectedTab?.id
        return Array(rank(query, in: state, limit: limit == .max ? limit : limit + 1).filter { $0.tab.id != selected }.prefix(limit))
    }

    /// The page's host and, for a pinned tab or favorite that has moved on (redirected to sign in, say), its
    /// pinned page's.
    static func hosts(_ tab: BrowserTab) -> [String] {
        Set([tab.url, tab.pinnedURL]).compactMap { $0?.host()?.lowercased().replacingOccurrences(of: "www.", with: "") }
    }

    static func completesHost(_ q: String, _ tab: BrowserTab) -> Bool {
        hosts(tab).contains { $0.hasPrefix(q) && $0 != q }
    }

    static func score(_ q: String, _ tab: BrowserTab) -> Int? {
        // A renamed tab is found by its name as well as its page's title.
        let title = [tab.customTitle, tab.title].compactMap { $0 }.joined(separator: " ").lowercased()
        let hosts = hosts(tab)
        let url = tab.url?.absoluteString.lowercased() ?? ""

        if title.hasPrefix(q) { return titlePrefix }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return wordPrefix }
        if hosts.contains(where: { $0.hasPrefix(q) }) { return hostPrefix }
        if title.contains(q) { return inTitle }
        if url.contains(q) { return inAddress }
        return nil
    }
}
