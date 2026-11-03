import Foundation

/// Where ⌘T's results go for a typed query (not a URL), after Arc 1.171 (observed in an incognito and a regular
/// window, 3 Nov 2026; docs/arc-visual-spec.md, "Command bar order"). Arc ranks with a model it trains on what you
/// pick, so its order varies; this follows what it did for a favorite it hadn't learned. A matching tab sits right
/// under the typed search (and any strong menu command above that), above the search engine's suggestions. For a
/// query of up to three characters that starts the tab's title, one of its words or its host, the tab comes
/// first, so Return switches to it.
public enum CommandBarOrder {
    static let tabFirstMaxLength = 3
    /// A host prefix (Arc put a tab first for "127", its host's start); weaker matches stay under the search.
    static let tabFirstMinStrength = TabSearch.hostPrefix

    /// Whether the best tab match goes above the typed search; `query` may be untrimmed.
    public static func tabFirst(_ query: String, best: TabSearch.Match?) -> Bool {
        guard let best, best.strength >= tabFirstMinStrength else { return false }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).count <= tabFirstMaxLength
    }

    /// Strong commands, then the typed search (with the best tab above it when `tabFirst`), the other tabs, the
    /// engine's suggestions, history and weak commands.
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
