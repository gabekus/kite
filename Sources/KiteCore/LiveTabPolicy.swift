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
        let plan = evictionPlan(live: live, protected: protected)
        return Array(plan.candidates.prefix(plan.count))
    }

    /// How many tabs must go, and every tab that may, least recently shown first. Whether a tab is busy
    /// (playing media, using the camera) is only known by asking its page, so the caller walks the
    /// candidates and a busy one's place goes to the next: busy tabs count towards the limit.
    public func evictionPlan(live: [UUID: Date], protected: Set<UUID>) -> (count: Int, candidates: [UUID]) {
        let excess = live.count - max(maxLiveTabs, 1)
        guard excess > 0 else { return (0, []) }
        let candidates = live
            .filter { !protected.contains($0.key) }
            .sorted { $0.value < $1.value }
            .map(\.key)
        return (excess, candidates)
    }
}
