import Foundation

/// Decides which tabs keep a live web view. Web views are the expensive part of
/// a browser (a web process each, often 100MB+), so only the most recently
/// shown few stay alive and the rest are hibernated with their history saved.
public struct LiveTabPolicy: Sendable {
    public var maxLiveTabs: Int

    public init(maxLiveTabs: Int = 6) {
        self.maxLiveTabs = maxLiveTabs
    }

    /// - Parameters:
    ///   - live: tabs that currently have a web view, with when each was last shown.
    ///   - protected: tabs that must stay alive (the visible tab, tabs playing media).
    /// - Returns: tabs to hibernate, least recently shown first.
    public func tabsToEvict(live: [UUID: Date], protected: Set<UUID>) -> [UUID] {
        let excess = live.count - max(maxLiveTabs, 1)
        guard excess > 0 else { return [] }
        return live
            .filter { !protected.contains($0.key) }
            .sorted { $0.value < $1.value }
            .prefix(excess)
            .map(\.key)
    }

    /// A tab picked to hibernate waits on an asynchronous busy check (media, camera or mic). When it answers,
    /// the hibernation still goes ahead only if the tab has the page it had when picked (`samePage`), isn't on
    /// screen, and hasn't been shown since (`shownAt` is when it was last shown, then and now).
    public static func stillHibernates(pickedShownAt: Date?, shownAt: Date?, samePage: Bool, visible: Bool) -> Bool {
        guard samePage, !visible, let pickedShownAt else { return false }
        return shownAt == pickedShownAt
    }
}
