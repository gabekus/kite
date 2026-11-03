import Foundation

/// Where ⌘T's results go, after Arc 1.171 (observed in an incognito and a regular window, 3 Nov 2026;
/// docs/arc-visual-spec.md, "Command bar order"). Arc ranks with a model it trains on what you pick, so its order
/// varies; this follows what it did for a favorite it hadn't learned. A matching tab sits right under the typed
/// search (and any strong menu command above that), above the search engine's suggestions. One tab can lead,
/// above the search or the Open row, so Return switches to it:
/// - a favorite whose address you're typing ("mai" … "mail.googl" for mail.google.com), at any length;
/// - for a query of up to three characters that doesn't look like a URL, the best match when it starts the tab's
///   title, a word or its host.
public enum CommandBarOrder {
    static let shortQueryMaxLength = 3
    /// A host prefix (Arc put a tab first for "127", its host's start); weaker matches stay under the search.
    static let shortQueryMinStrength = TabSearch.hostPrefix

    /// The tab that goes above everything but strong commands, from `matches` (best first) for what was typed,
    /// without any inline completion after it; `typed` may be untrimmed.
    public static func leader(_ typed: String, matches: [TabSearch.Match], looksLikeURL: Bool) -> TabSearch.Match? {
        if let favorite = matches.first(where: { $0.isFavorite && $0.completesHost }) { return favorite }
        guard !looksLikeURL, let best = matches.first, best.strength >= shortQueryMinStrength,
              typed.trimmingCharacters(in: .whitespacesAndNewlines).count <= shortQueryMaxLength
        else { return nil }
        return best
    }

    /// Strong commands, the leading tab if there is one, the typed search, the other tabs, the engine's
    /// suggestions, history and weak commands.
    public static func arrange<T>(
        leader: T?, strongCommands: [T], search: T, tabs: [T], engine: [T], history: [T], weakCommands: [T]
    ) -> [T] {
        strongCommands + [leader].compactMap { $0 } + [search] + tabs + engine + history + weakCommands
    }

    /// For a URL-looking query: the leading tab if there is one, the Open row, the other tabs, history and the
    /// typed search.
    public static func arrangeURL<T>(leader: T?, open: T, tabs: [T], history: [T], search: T) -> [T] {
        [leader].compactMap { $0 } + [open] + tabs + history + [search]
    }
}
