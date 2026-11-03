import Foundation

/// Ranks open tabs for the command bar's "switch to tab" results.
public enum TabSearch {
    public struct Match: Hashable, Sendable {
        public var tab: BrowserTab
        public var spaceID: UUID
        public var score: Int
        /// The match itself, without the current space's lift: 100 title prefix, 80 word prefix, 70 host prefix,
        /// 60 inside the title, 40 inside the address.
        public var strength: Int
    }

    public static func rank(_ query: String, in state: BrowserState, limit: Int = 6) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var matches: [Match] = []
        for tab in state.favorites {
            if let score = score(q, tab) { matches.append(Match(tab: tab, spaceID: state.selectedSpaceID, score: score + 5, strength: score)) }
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

    static func score(_ q: String, _ tab: BrowserTab) -> Int? {
        // A renamed tab is found by its name as well as its page's title.
        let title = [tab.customTitle, tab.title].compactMap { $0 }.joined(separator: " ").lowercased()
        let host = (tab.url?.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let url = tab.url?.absoluteString.lowercased() ?? ""

        if title.hasPrefix(q) { return 100 }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 80 }
        if host.hasPrefix(q) { return 70 }
        if title.contains(q) { return 60 }
        if url.contains(q) { return 40 }
        return nil
    }
}

