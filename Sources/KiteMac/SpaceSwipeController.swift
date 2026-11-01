import AppKit
import KiteCore
import SwiftUI

/// Two fingers swiping sideways over the sidebar page between spaces, as in Arc, where the sidebar's
/// scroll view hands its wheel events to the window's controller to page the spaces. The pages follow
/// the fingers, rubber-band past the first and last space, and the theme crossfades with them; a release
/// settles on a space (`SpaceSwipe.landing`).
///
/// Every frame, the swipe's and the settle's alike, is one offset for the whole strip of pages, set without
/// animation (`SpacePages`): the settle is stepped here once a display frame rather than left to a SwiftUI
/// animation, so the strip is always where `model.offset` says and a swipe can catch it mid-settle.
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
    /// The settle under way: where it started, where it ends and when.
    private var settling: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    /// A swipe that lands on a neighbour selects it once the pages are at rest (`commitLanding`).
    private var pendingLanding: (space: UUID, landing: Int)?
    private var clock: FrameClock?

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
        // Caught mid-settle: carry on from where the pages are, with the selected space's neighbours.
        stopSettling()
        commitLanding()
        if model.anchor != nil { set { $0.anchor = nil } }
        let state = store.state
        let index = state.selectedSpaceIndex
        swipe = SpaceSwipe(pageWidth: Double(model.pageWidth), hasPrevious: index > 0,
                           hasNext: index < state.spaces.count - 1, travel: Double(model.offset))
    }

    private func show() {
        guard let swipe else { return }
        set { $0.offset = CGFloat(swipe.offset) }
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
        settleTheme(target.theme)
        // The pages slide on to the neighbour's page before the space is selected: selecting it redraws the
        // sidebar and swaps the web page, 30-50ms of work that would stall the first frames of the slide.
        if landing != 0 { pendingLanding = (target.id, landing) }
        settle(to: -CGFloat(landing) * model.pageWidth)
    }

    /// Selects the space a swipe landed on. The pages don't move: the new space's page is where the old
    /// one's neighbour was, so the offset shifts by the page the selection moved, and the old space's
    /// pages stay built until the strip is at rest.
    private func commitLanding() {
        guard let landing = pendingLanding else { return }
        pendingLanding = nil
        let state = store.state
        guard state.spaceIndex(landing.space) != nil else { return }
        set { model in
            model.anchor = state.selectedSpace.id
            selectingBySwipe = true
            store.mutate { $0.selectSpace(landing.space) }
            selectingBySwipe = false
            model.offset += CGFloat(landing.landing) * model.pageWidth
        }
    }

    private var selectingBySwipe = false

    /// A switch from the keyboard, the menu or the strip slides the pages too, as Arc's do: the new page
    /// comes in from the side it lies on.
    func spaceChanged(from old: Int, to new: Int) {
        guard !selectingBySwipe, swipe == nil, old != new, model.pageWidth > 0 else { return }
        // A swipe's landing still to come is overtaken by this switch.
        pendingLanding = nil
        stopSettling()
        let state = store.state
        set { model in
            if old < state.spaces.count { model.anchor = state.spaces[old].id }
            model.offset = (new > old ? 1 : -1) * model.pageWidth
        }
        settle()
    }

    /// Arc's page slide, fitted to a 1px-row recording of Spaces › Previous Space (1 Nov 2026): 97% of
    /// the way 0.09s in and settled by 0.2s, quicker than the theme's colour, with no overshoot. A
    /// critically damped spring of this response, stepped once a frame (`SpaceSwipe.settle`).
    static let settleResponse = ArcMetrics.Motion.spacePageResponse

    private func settle(to target: CGFloat = 0) {
        guard model.offset != target else { return finishSettling() }
        settling = (model.offset, target, CACurrentMediaTime())
        guard let view = sidebar(), view.window != nil, !view.isHiddenOrHasHiddenAncestor else {
            // No sidebar on screen to time frames from: just land.
            set { $0.offset = target }
            return finishSettling()
        }
        if clock == nil { clock = FrameClock(view: view) { [weak self] in self?.stepSettle() } }
        clock?.start()
    }

    private func stepSettle() {
        guard let settling else { return stopSettling() }
        // Drawn for the frame being made, so the strip is where the spring is when it reaches the screen.
        let now = clock?.targetTimestamp ?? CACurrentMediaTime()
        let left = SpaceSwipe.settle(from: Double(settling.from - settling.to), elapsed: now - settling.start,
                                     response: Self.settleResponse)
        set { $0.offset = settling.to + CGFloat(left) }
        if left == 0 { finishSettling() }
    }

    private func finishSettling() {
        stopSettling()
        commitLanding()
        // At rest: build the new space's neighbours on the next pass, so it doesn't add to the selection's.
        guard model.anchor != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.swipe == nil, self.settling == nil, self.model.anchor != nil else { return }
            self.set { $0.anchor = nil }
        }
    }

    private func stopSettling() {
        settling = nil
        clock?.stop()
    }

    /// Changes the pages' model with no SwiftUI animation: every frame is placed by hand.
    private func set(_ change: (SpaceSwipeModel) -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { change(model) }
    }
}
