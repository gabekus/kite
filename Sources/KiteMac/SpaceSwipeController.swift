import AppKit
import KiteCore
import SwiftUI

/// Two fingers swiping sideways over the sidebar page between spaces, as in Arc, where the sidebar's
/// scroll view hands its wheel events to the window's controller to page the spaces. The pages follow
/// the fingers, rubber-band past the first and last space, and the theme crossfades with them; a release
/// settles on a space (`SpaceSwipe.landing`).
@MainActor
final class SpaceSwipeController {
    let model = SpaceSwipeModel()
    private let store: BrowserStore
    /// The sidebar's view, in whichever container shows it (docked or peeking).
    private let sidebar: () -> NSView?
    /// Mid-swipe crossfade between the current space's theme and the neighbour's.
    private let showTheme: (_ from: Theme, _ to: Theme, _ progress: Float) -> Void
    /// The release: settle on this theme from wherever the crossfade was.
    private let settleTheme: (Theme) -> Void
    private var swipe: SpaceSwipe?
    /// After the fingers lift, the trackpad's momentum events still belong to the swipe.
    private var swallowingMomentum = false
    /// A gesture that started vertically scrolls the tab list for its whole length.
    private var verticalGesture = false

    init(store: BrowserStore, sidebar: @escaping () -> NSView?,
         showTheme: @escaping (Theme, Theme, Float) -> Void, settleTheme: @escaping (Theme) -> Void) {
        self.store = store
        self.sidebar = sidebar
        self.showTheme = showTheme
        self.settleTheme = settleTheme
    }

    /// The window hands every scroll event here first, before the view under the pointer sees it.
    func install(in window: BrowserWindow) {
        window.scrollInterceptor = { [weak self] event in self?.handle(event) ?? false }
    }

    /// True when the event was the swipe's.
    private func handle(_ event: NSEvent) -> Bool {
        if swallowingMomentum {
            if event.momentumPhase.isEmpty { swallowingMomentum = false } else {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowingMomentum = false }
                return true
            }
        }
        // Only trackpad gestures page; a mouse wheel's sideways clicks don't.
        guard event.hasPreciseScrollingDeltas else { return false }
        let phase = event.phase

        if swipe == nil {
            if phase.contains(.mayBegin) || phase.contains(.began) { verticalGesture = false }
            guard phase.contains(.began) || (phase.contains(.changed) && !verticalGesture) else { return false }
            guard isOverSidebar(event) else { return false }
            let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
            // No movement yet: decide on the first event that has some.
            if dx == 0, dy == 0 { return false }
            if dy >= dx {
                verticalGesture = true
                return false
            }
            begin()
        }
        guard swipe != nil else { return false }

        if phase.contains(.changed) || phase.contains(.began) {
            // With natural scrolling the deltas already follow the fingers; without it they're reversed.
            let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            swipe!.move(by: delta, at: event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime)
            show()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            finish(cancelled: phase.contains(.cancelled))
            swallowingMomentum = true
        }
        return true
    }

    private func isOverSidebar(_ event: NSEvent) -> Bool {
        guard let view = sidebar(), let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        // An event made without a window (the ui tool's) carries a screen point.
        let point = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        return view.bounds.contains(view.convert(point, from: nil))
    }

    private func begin() {
        let state = store.state
        let index = state.selectedSpaceIndex
        // Caught mid-settle: carry on from where the pages are.
        swipe = SpaceSwipe(pageWidth: Double(model.pageWidth), hasPrevious: index > 0,
                           hasNext: index < state.spaces.count - 1, travel: Double(model.offset))
        model.showsNeighbours = true
    }

    private func show() {
        guard let swipe else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.offset = CGFloat(swipe.offset) }
        let state = store.state
        let index = state.selectedSpaceIndex
        let current = state.spaces[index].theme
        let neighbour = swipe.direction == 0 ? current : state.spaces[index + swipe.direction].theme
        showTheme(current, neighbour, Float(swipe.progress))
    }

    private func finish(cancelled: Bool) {
        guard let swipe else { return }
        self.swipe = nil
        let landing = cancelled ? 0 : swipe.landing
        let state = store.state
        let target = state.spaces[state.selectedSpaceIndex + landing]
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if landing != 0 {
                // The pages don't move this frame: the new space's page is where the old one's
                // neighbour was, so the offset shifts by the page the selection moved.
                store.mutate { $0.selectSpace(target.id) }
                model.offset += CGFloat(landing) * model.pageWidth
            }
        }
        settleTheme(target.theme)
        withAnimation(Self.settle) {
            model.offset = 0
        } completion: { [weak self] in
            guard let self, self.swipe == nil else { return }
            self.model.showsNeighbours = false
        }
    }

    /// The release's settle. Unmeasured on Arc's pages: this is the spring its theme switch was
    /// measured with, so the pages and the colour land together.
    static let settle = Animation.spring(response: ArcMetrics.Motion.spaceSwitchResponse,
                                         dampingFraction: ArcMetrics.Motion.spaceSwitchDamping)
}
