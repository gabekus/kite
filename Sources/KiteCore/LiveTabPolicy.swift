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
}
