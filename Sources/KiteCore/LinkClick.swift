import Foundation

/// Where a modifier-clicked link in a page opens.
///
/// Arc's rule (decompiled, see docs/arc-visual-spec.md "⌥⌘-click opens a link in Split View"): a click that
/// Chromium would open in a background tab (⌘-click) opens in Split View instead when ⌥ is held too, unless
/// Arc's ⌥⌘-click Little Arc entry point is on (Kite has none). ⇧⌘-click stays a foreground tab and ⇧-click
/// stays Peek (`LinkPeek`).
public enum LinkClick {
    public enum Destination: Equatable, Sendable {
        case backgroundTab
        case foregroundTab
        case splitView
    }

    /// A ⌘-clicked link: ⇧ opens and switches to a tab, ⌥ opens it in Split View, otherwise a background tab.
    public static func commandClickDestination(shift: Bool, option: Bool) -> Destination {
        if shift { return .foregroundTab }
        return option ? .splitView : .backgroundTab
    }
}

extension BrowserState {
    /// A link clicked in tab `source` with ⌥⌘: opens `url` in a new pane right after that tab, as
    /// Add Split View does, and focuses it. A tab that isn't split yet becomes a two-pane split.
    /// A full split takes nothing (Arc's "Cannot Add New Pane"; Gabe wants nothing to happen).
    @discardableResult
    public mutating func openLinkInSplit(url: URL, from source: UUID, id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        guard location(of: source) != nil else { return .noTab }
        if let split = split(containing: source)?.split, split.tabIDs.count >= SplitView.maxPanes { return .full }
        if selectedTab?.id != source { select(tab: source, now: now) }
        let result = addSplitPane(id: id, now: now)
        if case .added(let pane) = result { update(tab: pane) { $0.url = url } }
        return result
    }
}
