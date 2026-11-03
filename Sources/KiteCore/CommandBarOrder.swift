import Foundation

/// Where ⌘T's results go, after Arc 1.171 (observed in an incognito and a regular window, 3 Nov 2026;
/// docs/arc-visual-spec.md, "Command bar order"). Arc ranks with a model it trains on what you pick, so its order
/// varies; this follows what it did for a favorite it hadn't learned. A matching tab sits right under the typed
/// search (and any strong menu command above that), above the search engine's suggestions. One tab can lead,
/// above the search, so Return switches to it:
/// - a favorite whose address you're typing ("mai" … "mail.googl" for mail.google.com), at any length;
/// - for a query of up to three characters, the best match when it starts the tab's title, a word or its host.
public enum CommandBarOrder {
    static let tabFirstMaxLength = 3
    /// A host prefix (Arc put a tab first for "127", its host's start); weaker matches stay under the search.
    static let tabFirstMinStrength = TabSearch.hostPrefix

    /// Which of `matches` (best first) goes above the search, if any; `query` may be untrimmed.
    public static func leader(_ query: String, matches: [TabSearch.Match]) -> Int? {
        if let favorite = matches.firstIndex(where: { $0.isFavorite && $0.completesHost }) { return favorite }
        guard let best = matches.first, best.strength >= tabFirstMinStrength,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count <= tabFirstMaxLength
        else { return nil }
        return 0
    }

    /// Strong commands, the leading tab if there is one, the typed search, the other tabs, the engine's
    /// suggestions, history and weak commands.
    public static func arrange<T>(
        leader: T?, strongCommands: [T], search: T, tabs: [T], engine: [T], history: [T], weakCommands: [T]
    ) -> [T] {
        strongCommands + [leader].compactMap { $0 } + [search] + tabs + engine + history + weakCommands
    }
}
