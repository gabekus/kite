import AppKit
import KiteCore

/// Split orientation: Arc's command bar actions for top/bottom splits, and links dropped on the content's edges.
extension BrowserWindowController {
    /// Arc's "Add Vertical Split View" (`newVerticalSplitView`): Add Split View, in a top/bottom layout.
    @objc func addVerticalSplitView(_ sender: Any?) {
        guard store.state.selectedTab != nil else { return NSSound.beep() }
        guard (store.state.selectedSplit?.tabIDs.count ?? 0) < SplitView.maxPanes else { return }
        store.hideCommandBar()
        let pane = UUID()
        store.pendingSplitPane = pane
        guard store.mutate({ $0.addVerticalSplitPane(id: pane) }) == .added(pane) else {
            store.pendingSplitPane = nil
            return
        }
        store.showCommandBar(.editCurrent)
    }

    /// Arc's "Convert to Vertical Split View" (`convertToVerticalSplitView`).
    @objc func convertToVerticalSplitView(_ sender: Any?) { setSplitOrientation(.vertical) }

    /// Arc's "Convert to Horizontal Split View" (`convertToHorizontalSplitView`).
    @objc func convertToHorizontalSplitView(_ sender: Any?) { setSplitOrientation(.horizontal) }

    private func setSplitOrientation(_ orientation: SplitOrientation) {
        guard let split = store.state.selectedSplit, split.orientation != orientation else { return NSSound.beep() }
        store.mutate { $0.setSplitOrientation(split.id, orientation) }
    }

    /// A link dropped on an edge of the content area opens in a new pane there.
    func openDroppedLink(_ url: URL, on edge: SplitEdge) {
        store.hideCommandBar()
        store.mutate { $0.openInSplit(url: url, edge: edge) }
    }

    /// Menu validation for the orientation commands; nil for other items.
    func validateSplitLayoutItem(_ item: NSMenuItem) -> Bool? {
        let split = store.state.selectedSplit
        switch item.action {
        case #selector(addVerticalSplitView(_:)):
            return store.state.selectedTab != nil && (split?.tabIDs.count ?? 0) < SplitView.maxPanes
        case #selector(convertToVerticalSplitView(_:)):
            return split.map { $0.orientation != .vertical } ?? false
        case #selector(convertToHorizontalSplitView(_:)):
            return split.map { $0.orientation != .horizontal } ?? false
        default:
            return nil
        }
    }
}
