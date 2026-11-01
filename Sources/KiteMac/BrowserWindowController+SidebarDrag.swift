import AppKit
import KiteCore

extension BrowserWindowController {
    /// After a sidebar drop: Arc's drop haptic and its move toasts (`MoveItemsToastType`; the
    /// wording is from Arc 1.169's strings).
    func sidebarDropped(_ outcome: SidebarDropOutcome) {
        // Arc's drop haptic: probably the generic pattern, performed now (binary, not confirmed),
        // unless Settings › Advanced › "Haptic feedback when reordering tabs" is off.
        if TabReorderHaptics.isEnabled() {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        let state = store.state
        switch outcome {
        case .moved:
            break
        case .pinned:
            showToast("Pinned Tab to \(state.selectedSpace.name)")
        case .unpinned:
            showToast("Un-Pinned Tab from \(state.selectedSpace.name)")
        case .movedToSpace(let space, let tab):
            // Arc's toast is clickable as a whole; Kite's toast takes an action button instead.
            showToast("Tab moved! Click to go there.", action: (title: "Go", run: { [weak self] in
                self?.store.mutate { state in
                    state.selectSpace(space)
                    state.select(tab: tab)
                }
            }))
        }
    }

    /// Arc's command bar "Move to Today in <space>": the current tab (its split, if it's in one) to the
    /// top of that space's Today.
    @objc func moveTabToToday(_ sender: NSMenuItem) {
        moveSelectedTab(toSpaceAt: sender.tag - 1, pinned: false)
    }

    /// Arc's "Move to Pinned in <space>": to the end of that space's pinned items.
    @objc func moveTabToPinned(_ sender: NSMenuItem) {
        moveSelectedTab(toSpaceAt: sender.tag - 1, pinned: true)
    }

    @objc func toggleFavoriteTab(_ sender: Any?) {
        guard let tab = store.state.selectedTab else { return }
        store.mutate { $0.toggleFavorite(tab: tab.id) }
    }

    private func moveSelectedTab(toSpaceAt index: Int, pinned: Bool) {
        let state = store.state
        guard let tab = state.selectedTab, state.spaces.indices.contains(index) else { return }
        let space = state.spaces[index]
        let target: SidebarDropTarget = pinned
            ? .pinned(space: space.id, folder: nil, before: nil)
            : .unpinned(space: space.id, before: space.tabs.first?.id)
        var outcome: SidebarDropOutcome?
        store.mutate { outcome = $0.dropSidebarItems([$0.sidebarDragID(for: tab.id)], on: target) }
        if let outcome { sidebarDropped(outcome) }
    }
}
