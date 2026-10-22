import Foundation

/// Ranks open tabs for the command bar's "switch to tab" results.
public enum TabSearch {
    public struct Match: Hashable, Sendable {
        public var tab: BrowserTab
        public var spaceID: UUID
        public var score: Int
    }

    public static func rank(_ query: String, in state: BrowserState, limit: Int = 6) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var matches: [Match] = []
        for tab in state.favorites {
            if let score = score(q, tab) { matches.append(Match(tab: tab, spaceID: state.selectedSpaceID, score: score + 5)) }
        }
        for space in state.spaces {
            for tab in space.allTabs {
                guard var score = score(q, tab) else { continue }
                if space.id == state.selectedSpaceID { score += 5 }
                matches.append(Match(tab: tab, spaceID: space.id, score: score))
            }
        }
        matches.sort { a, b in
            a.score != b.score ? a.score > b.score : a.tab.lastActiveAt > b.tab.lastActiveAt
        }
        return Array(matches.prefix(limit))
    }

    static func score(_ q: String, _ tab: BrowserTab) -> Int? {
        let title = tab.title.lowercased()
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
