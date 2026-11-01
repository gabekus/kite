import AppKit
import KiteCore

extension BrowserWindowController {
    /// After a sidebar drop: Arc's drop haptic and its move toasts (`MoveItemsToastType`; the
    /// wording is from Arc 1.169's strings).
    func sidebarDropped(_ outcome: SidebarDropOutcome) {
        // Arc's drop haptic: probably the generic pattern, performed now (binary, not confirmed).
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
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
}
