import AppKit
import KiteCore

/// Arc's swipe right to dismiss a Peek (`DismissMechanism.swipedRightToDismiss`): a two-finger scroll to the
/// right over the Peek tugs the card along at 6% of the scroll; letting go far enough closes the Peek with its
/// close spring, otherwise the card springs back. Numbers are `LinkPeek.Swipe`'s.
///
/// Like Arc's `ModalV2HostViewController.scrollRecognizer` (built for rightward gestures only), it asks the
/// page first: a gesture over a page that can still scroll left (or blocks horizontal overscroll) stays the
/// page's, decided the same way as the swipe back/forward (`HistorySwipe.PageScroll`). Over the area around
/// the card it starts straight away, as Arc's does outside its content view. Gestures reach it before the
/// page's own swipe back/forward (`HistorySwipeController`'s claimers).
@MainActor
final class LinkPeekSwipeController: ScrollGestureClaimer {
    private weak var view: LinkPeekView?
    private let evaluate: (String, @escaping (Any?) -> Void) -> Void
    private let zoomFactor: () -> Double
    private let dismiss: () -> Void

    private enum State {
        case idle
        /// Waiting for the axis and the page's answer; events still reach the page.
        case pending(dx: CGFloat, dy: CGFloat)
        /// Not a dismiss swipe; the page has the rest of the gesture.
        case passthrough
        case tracking
        /// A tracked gesture ended; its momentum is swallowed too.
        case finished
    }

    private var state = State.idle
    private var gesture = 0
    private var answered = false
    private var pageScroll: HistorySwipe.PageScroll?
    private var translation = LinkPeek.Swipe.Vector.zero
    private var samples: [(time: Double, dx: Double, dy: Double)] = []
    private(set) var gestureOutcome = "no gesture"

    /// Gives up waiting for the page once a gesture has moved this far (points), as the swipe back does.
    private static let answerDeadlineDistance: CGFloat = 80

    init(view: LinkPeekView, evaluate: @escaping (String, @escaping (Any?) -> Void) -> Void,
         zoomFactor: @escaping () -> Double, dismiss: @escaping () -> Void) {
        self.view = view
        self.evaluate = evaluate
        self.zoomFactor = zoomFactor
        self.dismiss = dismiss
        HistorySwipeController.register(self, over: view)
    }

    func stop() {
        if let view { HistorySwipeController.unregister(view: view) }
    }

    // MARK: ScrollGestureClaimer

    func handleGesture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        if !event.momentumPhase.isEmpty {
            if case .finished = state { return true }
            return false
        }
        switch event.phase {
        case .began:
            begin(event, in: window)
            return false
        case .changed:
            return changed(event)
        case .ended, .cancelled:
            return end()
        default:
            return false
        }
    }

    // MARK: Gesture

    private func begin(_ event: NSEvent, in fallback: NSWindow?) {
        gesture += 1
        translation = .zero
        samples = []
        pageScroll = nil
        answered = false
        guard let view, view.window != nil, !view.isClosing else {
            state = .passthrough
            gestureOutcome = "peek: closing"
            return
        }
        state = .pending(dx: 0, dy: 0)
        gestureOutcome = "peek: undecided"
        let window = event.window ?? fallback ?? view.window
        let locationInWindow = event.window == nil
            ? (window?.convertPoint(fromScreen: event.locationInWindow) ?? event.locationInWindow) : event.locationInWindow
        // Outside the page (the area around the card, the buttons) there's nothing to ask.
        guard let page = view.page, let pageWindow = page.window, pageWindow === window else {
            answered = true
            return
        }
        var point = page.convert(locationInWindow, from: nil)
        guard page.bounds.contains(point) else {
            answered = true
            return
        }
        if !page.isFlipped { point.y = page.bounds.height - point.y }
        let zoom = max(zoomFactor(), 0.01)
        let current = gesture
        evaluate(HistorySwipe.scrollabilityScript(x: point.x / zoom, y: point.y / zoom)) { [weak self] result in
            guard let self, self.gesture == current else { return }
            self.answered = true
            self.pageScroll = HistorySwipe.PageScroll(result)
        }
    }

    private func changed(_ event: NSEvent) -> Bool {
        switch state {
        case let .pending(dx, dy):
            let dx = dx + event.scrollingDeltaX, dy = dy + event.scrollingDeltaY
            state = .pending(dx: dx, dy: dy)
            guard HistorySwipe.isDecided(dx: dx, dy: dy) else { return false }
            // Arc's recogniser takes rightward gestures only: content pulled right, as for swipe back.
            guard HistorySwipe.direction(dx: dx, dy: dy) == .back else {
                gestureOutcome = "peek: not a swipe right"
                state = .passthrough
                return false
            }
            guard answered else {
                if abs(dx) + abs(dy) > Self.answerDeadlineDistance {
                    gestureOutcome = "peek: the page didn't answer in time"
                    state = .passthrough
                }
                return false
            }
            // No answer (a page still loading) counts as a page that doesn't scroll sideways.
            let scroll = pageScroll ?? HistorySwipe.PageScroll(canScrollLeft: false, canScrollRight: false, blocksOverscroll: false)
            guard scroll.allowsNavigation(.back) else {
                gestureOutcome = "peek: the page can scroll left or blocks overscroll"
                state = .passthrough
                return false
            }
            state = .tracking
            gestureOutcome = "peek: tugging"
            view?.beginTug()
            move(by: dx, dy)
            return true
        case .tracking:
            move(by: event.scrollingDeltaX, event.scrollingDeltaY)
            return true
        case .finished:
            return true
        case .idle, .passthrough:
            return false
        }
    }

    private func move(by dx: CGFloat, _ dy: CGFloat) {
        let previous = translation.x
        translation = .init(x: translation.x + Double(dx), y: translation.y + Double(dy))
        samples.append((ProcessInfo.processInfo.systemUptime, Double(dx), Double(dy)))
        samples.removeAll { samples.last!.time - $0.time > 0.5 }
        if LinkPeek.Swipe.crossesHapticThreshold(from: previous, to: translation.x) {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        view?.setTug(LinkPeek.Swipe.tug(translation: translation))
    }

    private func end() -> Bool {
        guard case .tracking = state else {
            if case .pending = state { gestureOutcome = "peek: ended before it was a swipe" }
            state = .idle
            return false
        }
        state = .finished
        let velocity = LinkPeek.Swipe.velocity(samples: samples, end: ProcessInfo.processInfo.systemUptime)
        let release = LinkPeek.Swipe.release(velocity: velocity)
        let x = Int(translation.x.rounded())
        if LinkPeek.Swipe.dismisses(translationX: translation.x, release: release) {
            gestureOutcome = "peek: dismissed (\(x) pt, released \(release))"
            dismiss()
        } else {
            gestureOutcome = "peek: sprang back (\(x) pt, released \(release))"
            view?.springTugBack(velocity: LinkPeek.Swipe.tug(translation: velocity))
        }
        return true
    }
}
