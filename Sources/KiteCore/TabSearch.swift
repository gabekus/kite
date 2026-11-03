import Foundation

/// Ranks open tabs for the command bar's "switch to tab" results.
public enum TabSearch {
    public struct Match: Hashable, Sendable {
        public var tab: BrowserTab
        public var spaceID: UUID
        public var score: Int
        /// The match itself (one of the strengths below), without the current space's lift.
        public var strength: Int
    }

    /// Match strengths, strongest first.
    public static let titlePrefix = 100, wordPrefix = 80, hostPrefix = 70, inTitle = 60, inAddress = 40

    public static func rank(_ query: String, in state: BrowserState, limit: Int = 6) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var matches: [Match] = []
        for tab in state.favorites {
            guard let score = score(q, tab) else { continue }
            matches.append(Match(tab: tab, spaceID: state.selectedSpaceID, score: score + 5, strength: score))
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
        return Array(rank(query, in: state, limit: limit + 1).filter { $0.tab.id != selected }.prefix(limit))
    }

    static func host(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The favorite (not the tab you're on) whose address is being typed: its page's or pinned page's host (it may
    /// have been redirected to sign in) starts with `typed` but isn't all of it. With an inline completion after
    /// what was typed, the host must start with all of `shown` too, so the row matches the field. Searched among
    /// every favorite, so better title matches can't push it out.
    public static func addressFavorite(_ typed: String, shown: String, in state: BrowserState) -> BrowserTab? {
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let field = shown.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let selected = state.selectedTab?.id
        // Of several (mail.google.com and maps.google.com for "ma"), the one used last.
        return state.favorites.filter { tab in
            let hosts = [tab.url, tab.pinnedURL].compactMap(host)
            // A whole host typed opens it, even when the other host only starts with it.
            return tab.id != selected && !hosts.contains(q) && hosts.contains { $0.hasPrefix(q) && $0.hasPrefix(field) }
        }.max { $0.lastActiveAt < $1.lastActiveAt }
    }

    /// Whether `q` (trimmed, lowercased) finds the tab at all, by its page or, for a pinned tab or favorite sent
    /// elsewhere (to sign in, say), its pinned page's host.
    static func matches(_ q: String, _ tab: BrowserTab) -> Bool {
        score(q, tab) != nil || host(tab.pinnedURL).map { $0.hasPrefix(q) } == true
    }

    static func score(_ q: String, _ tab: BrowserTab) -> Int? {
        // A renamed tab is found by its name as well as its page's title.
        let title = [tab.customTitle, tab.title].compactMap { $0 }.joined(separator: " ").lowercased()
        let host = host(tab.url) ?? ""
        let url = tab.url?.absoluteString.lowercased() ?? ""

        if title.hasPrefix(q) { return titlePrefix }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return wordPrefix }
        if host.hasPrefix(q) { return hostPrefix }
        if title.contains(q) { return inTitle }
        if url.contains(q) { return inAddress }
        return nil
    }
}
