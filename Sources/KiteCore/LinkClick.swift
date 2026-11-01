import Foundation

/// Where a modifier-clicked link in a page opens.
///
/// Arc's rule (decompiled, see docs/arc-visual-spec.md "⌥⌘-click opens a link in Split View"): a click that
/// Chromium would open in a background tab (⌘-click) opens in Little Kite when ⌥ and ⌘ are held and
/// Settings › Links › "Open Little Kite when clicking on links with ⌥⌘ held" is on (Arc's
/// `optionCommandClickLittleArcEntryPointEnabled`), otherwise in Split View when ⌥ is held. ⇧⌘-click stays a
/// foreground tab and ⇧-click stays Peek (`LinkPeek`).
public enum LinkClick {
    public enum Destination: Equatable, Sendable {
        case backgroundTab
        case foregroundTab
        case splitView
        case littleKite
    }

    /// A ⌘-clicked link (`command` false for Chromium's middle-click): ⇧ opens and switches to a tab, ⌥⌘ opens
    /// it in Little Kite while `opensLittleKite`, other ⌥ clicks open it in Split View, the rest a background tab.
    public static func commandClickDestination(shift: Bool, option: Bool, command: Bool = true,
                                               opensLittleKite: Bool = false) -> Destination {
        if shift { return .foregroundTab }
        guard option else { return .backgroundTab }
        return opensLittleKite && command ? .littleKite : .splitView
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
