import Foundation

/// Where ⌘T's results go for a typed query (not a URL), as Arc 1.171 orders them (observed in an incognito and
/// a regular window, 3 Nov 2026). Arc ranks with a model it trains on what you pick; this is the order it showed
/// for tabs and favorites it hadn't learned yet. A matching tab sits right under the typed search (and any strong
/// menu command above that), above the search engine's suggestions. For a query of up to three characters that
/// starts the tab's title, one of its words or its host, the tab comes first, so Return switches to it.
public enum CommandBarOrder {
    static let tabFirstMaxLength = 3
    /// A host prefix (Arc put a tab first for "127", its host's start); weaker matches stay under the search.
    static let tabFirstMinStrength = 70

    /// Whether the best tab match goes above the typed search; `query` may be untrimmed.
    public static func tabFirst(_ query: String, best: TabSearch.Match?) -> Bool {
        guard let best, best.strength >= tabFirstMinStrength else { return false }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).count <= tabFirstMaxLength
    }

    public static func arrange<T>(
        tabFirst: Bool, strongCommands: [T], search: T, tabs: [T], engine: [T], history: [T], weakCommands: [T]
    ) -> [T] {
        let rest = engine + history + weakCommands
        if tabFirst, let first = tabs.first {
            return strongCommands + [first, search] + tabs.dropFirst() + rest
        }
        return strongCommands + [search] + tabs + rest
    }
}
