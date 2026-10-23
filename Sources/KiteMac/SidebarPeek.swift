import AppKit

/// The hidden sidebar's peek, as Arc 1.169 does it (two recordings of Arc, measured at 60fps; see
/// docs/arc-visual-spec.md): with the sidebar hidden, resting the pointer on the window's left
/// edge slides the sidebar in as a floating card over the page, and leaving the card slides it
/// back out. The card is the sidebar itself, inset from the window, so its contents (traffic
/// lights included) sit exactly where they do docked, just shifted with the card.
enum Peek {
    /// Card inset from the window's left, top and bottom edges.
    static let inset: CGFloat = 5
    /// From the pointer reaching the edge to the card starting to move: 0.17 to 0.22s in the recordings.
    static let delay: TimeInterval = 0.17
    /// Width of the strip along the left edge that starts a peek. Unverified: in both recordings
    /// the pointer was pinned against the screen edge, so only "at the edge" was observed.
    static let edgeWidth: CGFloat = 4
    /// Slide in: a spring that overshoots by about 1.5%. Fits `spring(response: 0.18,
    /// dampingFraction: 0.8)`, one of the springs in Arc's binary (RMS 0.009).
    static let springResponse: Double = 0.18
    static let springDamping: Double = 0.8
    /// Slide out is the same 0.08s curve as the sidebar toggle.
    static let cornerRadius = ArcMetrics.Content.cornerRadius
    /// Arc's floating sidebar draws a 1pt border at 20% white.
    static let borderOpacity: CGFloat = 0.2

    /// A Core Animation spring for a layer's x, so the slide in needs no layout per frame.
    static func slideIn(_ layer: CALayer?, from dx: CGFloat) {
        guard let layer else { return }
        let animation = CASpringAnimation(keyPath: "position.x")
        let omega = 2 * Double.pi / springResponse
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * springDamping * omega
        animation.fromValue = dx
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "peekSlide")
    }
}

/// The peek card's background: the window's sidebar material and the space's theme, which
/// otherwise sit behind the whole window, here drawn just inside the card.
final class PeekCard: NSView {
    let material = NSVisualEffectView()
    let theme = ThemeView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Peek.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(Peek.borderOpacity).cgColor
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        for view in [material, theme] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Reports the pointer entering and leaving without taking clicks from what's underneath.
final class HoverStrip: NSView {
    var onHover: ((Bool) -> Void)?
    var isActive = false {
        didSet { if isActive != oldValue { inside = false; updateTrackingAreas() } }
    }
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isActive else { return }
        // A pointer already inside counts as inside, so leaving still reports.
        let assume: NSTrackingArea.Options = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } == true ? .assumeInside : []
        if !assume.isEmpty { inside = true }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, assume], owner: self))
    }

    /// Starts over from where the pointer is now. AppKit holds enters and exits back during a drag
    /// and sends them when it ends; this drops the ones it's holding.
    func resync() {
        guard isActive else { return }
        inside = false
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActive, !inside else { return }
        inside = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isActive, inside else { return }
        inside = false
        onHover?(false)
    }
}
