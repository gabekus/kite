import AppKit
import KiteCore

/// Arc's Add Left / Right / Top / Bottom Split: command bar actions (`addLeftSplit`…`addBottomSplit`),
/// not in its menu bar. An empty pane on that side of the focused one, then the command bar to fill it.
extension BrowserWindowController {
    @objc func addLeftSplit(_ sender: Any?) { addSplit(on: .leading) }
    @objc func addRightSplit(_ sender: Any?) { addSplit(on: .trailing) }
    @objc func addTopSplit(_ sender: Any?) { addSplit(on: .top) }
    @objc func addBottomSplit(_ sender: Any?) { addSplit(on: .bottom) }

    /// Like Add Split View: the pane is marked pending first, so showing it doesn't hand focus to its page,
    /// and Esc on the command bar takes the still-empty pane away again.
    private func addSplit(on side: SplitEdge) {
        guard store.state.selectedTab != nil else { return NSSound.beep() }
        // A full split, or a side off the split's axis: nothing, as Add Split View does for a fifth pane.
        guard store.state.splitSides.contains(side) else { return }
        store.hideCommandBar()
        let pane = UUID()
        store.pendingSplitPane = pane
        guard store.mutate({ $0.addSplitPane(side: side, id: pane) }) == .added(pane) else {
            store.pendingSplitPane = nil
            return
        }
        store.showCommandBar(.editCurrent)
    }

    /// Menu validation for the four side commands; nil for other items.
    func validateSplitSideItem(_ item: NSMenuItem) -> Bool? {
        let side: SplitEdge
        switch item.action {
        case #selector(addLeftSplit(_:)): side = .leading
        case #selector(addRightSplit(_:)): side = .trailing
        case #selector(addTopSplit(_:)): side = .top
        case #selector(addBottomSplit(_:)): side = .bottom
        default: return nil
        }
        return store.state.splitSides.contains(side)
    }
}
