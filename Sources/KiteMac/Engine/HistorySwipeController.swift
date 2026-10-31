import AppKit
import KiteCore

/// Two-finger swipe back/forward over a Chromium page (WebKit pages use
/// `allowsBackForwardNavigationGestures`).
///
/// A horizontal scroll gesture navigates only when the page under the pointer can't scroll
/// that way itself, like Chromium's `HistorySwiper` (which Arc ships): the renderer is asked
/// when the gesture begins, and the gesture's events keep reaching the page until it's clear
/// the page won't use them. Once tracking, the gesture's events stop reaching the page and
/// Chromium's history overlay (a dark circle with an arrow) slides in from the edge.
/// Honours System Settings › Trackpad › Swipe between pages.
@MainActor
final class HistorySwipeController {
    private let view: NSView
    private let canNavigate: (HistorySwipe.Direction) -> Bool
    private let navigate: (HistorySwipe.Direction) -> Void
    private let evaluate: (String, @escaping (Any?) -> Void) -> Void
    private let zoomFactor: () -> Double

    private enum State {
        case idle
        /// Gesture began; waiting for the axis and the renderer's answer. Events still reach the page.
        case pending(dx: CGFloat, dy: CGFloat)
        /// Not a history swipe; the page has the rest of the gesture.
        case passthrough
        case tracking(HistorySwipe.Direction, dx: CGFloat)
        /// A tracked gesture ended; its momentum events are swallowed too.
        case finished
    }

    private var state = State.idle
    private var gesture = 0
    private var pageScroll: HistorySwipe.PageScroll?
    private var answered = false
    private var overlay: HistoryOverlayView?

    /// Gives up waiting for the renderer once a gesture has moved this far (points).
    private static let answerDeadlineDistance: CGFloat = 80

    init(view: NSView,
         canNavigate: @escaping (HistorySwipe.Direction) -> Bool,
         navigate: @escaping (HistorySwipe.Direction) -> Void,
         evaluate: @escaping (String, @escaping (Any?) -> Void) -> Void,
         zoomFactor: @escaping () -> Double) {
        self.view = view
        self.canNavigate = canNavigate
        self.navigate = navigate
        self.evaluate = evaluate
        self.zoomFactor = zoomFactor
        Self.register(self)
    }

    // MARK: Routing

    private final class WeakController {
        weak var controller: HistorySwipeController?
        init(_ controller: HistorySwipeController) { self.controller = controller }
    }

    private static var controllers: [ObjectIdentifier: WeakController] = [:]
    private static weak var active: HistorySwipeController?
    private static var monitor: Any?

    private static func register(_ controller: HistorySwipeController) {
        controllers = controllers.filter { $0.value.controller != nil }
        controllers[ObjectIdentifier(controller.view)] = WeakController(controller)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { route(event) } ? nil : event
        }
    }

    /// The last gesture's outcome, for `ui input` to report.
    private(set) static var lastOutcome = "no gesture"

    /// Offers a scroll event to the page under it; true when the swipe consumed it. Real events
    /// arrive through the local monitor; `ui input` scrolls, which go straight to the window,
    /// call this first so they take the same path.
    @discardableResult
    static func route(_ event: NSEvent, in window: NSWindow? = nil) -> Bool {
        guard event.type == .scrollWheel, !(event.phase.isEmpty && event.momentumPhase.isEmpty) else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            active = controller(at: event, in: window)
            if active == nil { lastOutcome = "not over a Chromium page" }
        }
        guard let active else { return false }
        return active.handle(event)
    }

    private static func controller(at event: NSEvent, in fallback: NSWindow?) -> HistorySwipeController? {
        // Events made from CGEvents (ui input) carry no window; their location is on screen.
        guard let window = event.window ?? fallback, let content = window.contentView else { return nil }
        let location = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        var view = content.superview?.hitTest(location) ?? content.hitTest(location)
        while let current = view {
            if let controller = controllers[ObjectIdentifier(current)]?.controller { return controller }
            view = current.superview
        }
        return nil
    }

    // MARK: Gesture

    private func handle(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            if case .finished = state { return true }
            return false
        }
        switch event.phase {
        case .mayBegin:
            return false
        case .began:
            begin(at: event)
            return false
        case .changed:
            return changed(event)
        case .ended, .cancelled:
            return end(completed: event.phase == .ended)
        default:
            return false
        }
    }

    private func begin(at event: NSEvent) {
        let locationInWindow = event.window == nil
            ? (view.window?.convertPoint(fromScreen: event.locationInWindow) ?? event.locationInWindow) : event.locationInWindow
        removeOverlay()
        gesture += 1
        state = .pending(dx: 0, dy: 0)
        pageScroll = nil
        answered = false
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, view.window != nil else {
            Self.lastOutcome = "off: System Settings › Trackpad › Swipe between pages is off"
            state = .passthrough
            return
        }
        // The point in the page's CSS pixels.
        var point = view.convert(locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
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
            guard let direction = HistorySwipe.direction(dx: dx, dy: dy) else {
                Self.lastOutcome = "page scroll: not horizontal"
                state = .passthrough
                return false
            }
            guard answered else {
                if abs(dx) + abs(dy) > Self.answerDeadlineDistance {
                    Self.lastOutcome = "page scroll: the page didn't answer in time"
                    state = .passthrough
                }
                return false
            }
            // No answer (a page that's still loading, or a renderer error) counts as a page
            // that doesn't scroll sideways.
            let scroll = pageScroll ?? HistorySwipe.PageScroll(canScrollLeft: false, canScrollRight: false, blocksOverscroll: false)
            guard scroll.allowsNavigation(direction) else {
                Self.lastOutcome = "page scroll: the page can scroll \(direction == .back ? "left" : "right") or blocks overscroll"
                state = .passthrough
                return false
            }
            guard canNavigate(direction) else {
                Self.lastOutcome = "page scroll: nothing to go \(direction.rawValue) to"
                state = .passthrough
                return false
            }
            Self.lastOutcome = "tracking \(direction.rawValue)"

            state = .tracking(direction, dx: dx)
            showOverlay(direction)
            update(direction, dx: dx)
            return true
        case let .tracking(direction, dx):
            let dx = dx + event.scrollingDeltaX
            state = .tracking(direction, dx: dx)
            update(direction, dx: dx)
            return true
        case .finished:
            return true
        case .idle, .passthrough:
            return false
        }
    }

    private func end(completed: Bool) -> Bool {
        defer { Self.activeDidEnd(self) }
        guard case let .tracking(direction, dx) = state else {
            state = .idle
            return false
        }
        state = .finished
        let finished = HistorySwipe.progress(dx: dx, direction: direction, pageWidth: view.bounds.width).finished
        removeOverlay()
        if completed && finished { navigate(direction) }
        Self.lastOutcome = completed && finished ? "navigated \(direction.rawValue)" : (completed ? "released before the threshold, no \(direction.rawValue)" : "cancelled \(direction.rawValue)")
        return true
    }

    private static func activeDidEnd(_ controller: HistorySwipeController) {
        // Stay active through a tracked gesture's momentum, which carries no phase of its own.
        if case .finished = controller.state { return }
        if active === controller { active = nil }
    }

    // MARK: Overlay

    private func showOverlay(_ direction: HistorySwipe.Direction) {
        removeOverlay()
        let overlay = HistoryOverlayView(direction: direction, frame: view.bounds)
        view.addSubview(overlay)
        self.overlay = overlay
    }

    private func update(_ direction: HistorySwipe.Direction, dx: CGFloat) {
        let (progress, finished) = HistorySwipe.progress(dx: dx, direction: direction, pageWidth: view.bounds.width)
        overlay?.setProgress(progress, finished: finished)
    }

    private func removeOverlay() {
        guard let overlay else { return }
        self.overlay = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HistorySwipe.fadeOutDuration
            overlay.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { overlay.removeFromSuperview() }
        }
    }
}

/// Chromium's history overlay, hosted like Arc's `PaneHostHistoryOverlayContainerView`: a
/// clipping, click-through container over the page holding the shield.
final class HistoryOverlayView: NSView {
    let direction: HistorySwipe.Direction
    private let shield = NSView()
    private let shape = CAShapeLayer()

    init(direction: HistorySwipe.Direction, frame: NSRect) {
        self.direction = direction
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityIdentifier("HistorySwipeOverlay")

        // A layer-hosting view, as in Chromium.
        shield.layer = shape
        shield.wantsLayer = true
        shield.frame = NSRect(x: 0, y: 0, width: HistorySwipe.shieldRadius * 2, height: HistorySwipe.shieldHeight)
        shield.setAccessibilityIdentifier("HistorySwipeShield.\(direction.rawValue)")
        addSubview(shield)

        // The arrow fills the inner half of the circle, inset 10 pt (Chromium). The arrow image
        // itself is unverified: Chromium draws its IDR_ARROW_BACKWARD/FORWARD resource, which
        // Kite can't ship; this is an SF Symbol at a guessed size.
        let offset = direction == .back ? HistorySwipe.shieldRadius : 0
        let arrowFrame = NSRect(x: offset, y: 0, width: HistorySwipe.shieldRadius, height: HistorySwipe.shieldHeight)
            .insetBy(dx: HistorySwipe.arrowInset, dy: 0)
        let symbol = direction == .back ? "arrow.backward" : "arrow.forward"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: direction == .back ? "Back" : "Forward")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        let arrow = NSImageView(frame: arrowFrame)
        arrow.image = image
        arrow.contentTintColor = .white
        arrow.imageScaling = .scaleNone
        arrow.autoresizingMask = [.minYMargin, .maxYMargin]
        shield.addSubview(arrow)
        setProgress(0, finished: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setProgress(_ progress: CGFloat, finished: Bool) {
        let (shieldFrame, alpha) = HistorySwipe.shield(direction: direction, progress: progress, finished: finished,
                                                       parentWidth: bounds.width, parentHeight: bounds.height)
        let frame = CGRect(x: shieldFrame.x, y: shieldFrame.y, width: shieldFrame.width, height: shieldFrame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shield.frame.size != frame.size || shape.path == nil {
            shape.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
        }
        shield.frame = frame
        shape.fillColor = CGColor(gray: 0, alpha: alpha)
        CATransaction.commit()
    }
}
