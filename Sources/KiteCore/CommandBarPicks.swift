import Foundation

/// What you picked in ⌘T for what you typed, so the same text leads to it next time ("gmail" → the Gmail
/// favorite after you chose it once). Arc ranks with a model it trains on device from its picks; a single pick
/// didn't change Arc's order in testing (3 Nov 2026), so this is Kite's own, more direct version.
public struct CommandBarPick: Codable, Hashable, Sendable {
    public var query: String
    public var tabID: UUID
    public var at: Date
}

extension BrowserState {
    public static let commandBarPickLimit = 200

    static func pickKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Records a ⌘T pick for `typed`: a tab remembers it; anything else (a search, a URL) forgets what that
    /// text led to before.
    public mutating func recordCommandBarPick(typed: String, tab id: UUID?, now: Date = Date()) {
        let key = Self.pickKey(typed)
        guard !key.isEmpty else { return }
        commandBarPicks.removeAll { $0.query == key }
        guard let id else { return }
        commandBarPicks.insert(CommandBarPick(query: key, tabID: id, at: now), at: 0)
        if commandBarPicks.count > Self.commandBarPickLimit { commandBarPicks.removeLast() }
    }

    /// Delete browsing data › History forgets these too: they're what was typed.
    public mutating func forgetCommandBarPicks(since: Date?) {
        commandBarPicks.removeAll { pick in since.map { pick.at >= $0 } ?? true }
    }

    /// The tab last picked for this text, or for longer text it starts ("gm" finds a pick made for "gmail"),
    /// when it's still open and isn't the tab you're on.
    public func learnedTab(for typed: String) -> BrowserTab? {
        let key = Self.pickKey(typed)
        guard !key.isEmpty else { return nil }
        let selected = selectedTab?.id
        let candidates = commandBarPicks.filter { $0.query == key || (key.count >= 2 && $0.query.hasPrefix(key)) }
        // An exact pick beats a longer one; then the latest.
        for pick in candidates.sorted(by: { ($0.query == key ? 1 : 0, $0.at) > ($1.query == key ? 1 : 0, $1.at) })
        where pick.tabID != selected {
            if let tab = tab(pick.tabID) { return tab }
        }
        return nil
    }
}
