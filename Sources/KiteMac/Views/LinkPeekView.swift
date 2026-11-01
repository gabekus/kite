import AppKit
import KiteCore

/// Arc's Peek card (`ModalV2HostView`, popover layout): the page in a rounded card over the content area, its
/// buttons in a column to the card's right. Clicking outside both closes it. Numbers are `LinkPeek`'s.
/// (The sidebar's hover reveal is `PeekCard`, unrelated.)
final class LinkPeekView: NSView {
    enum Control: CaseIterable {
        case close, expand, split
    }

    /// The card's shadow and hairline, behind `card` (which clips the page to its corners).
    private let cardShadow = NSView()
    private let card = NSView()
    private let controls = FlippedView()
    private var buttons: [Control: LinkPeekButton] = [:]
    /// Everything that moves when the card opens and closes.
    private let motion = FlippedView()
    private(set) var page: NSView?
    var onControl: ((Control) -> Void)?
    var onBackgroundClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init(page: NSView, splitTitle: String?) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("LinkPeek")
        wantsLayer = true
        motion.wantsLayer = true
        addSubview(motion)

        cardShadow.wantsLayer = true
        if let layer = cardShadow.layer {
            layer.cornerRadius = LinkPeek.cornerRadius
            layer.cornerCurve = .continuous
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderWidth = LinkPeek.borderWidth
            layer.borderColor = NSColor.black.withAlphaComponent(LinkPeek.borderOpacity).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Float(LinkPeek.shadowOpacity)
            layer.shadowRadius = LinkPeek.shadowRadius
            layer.shadowOffset = CGSize(width: 0, height: LinkPeek.shadowOffsetY)
        }
        card.wantsLayer = true
        card.setAccessibilityIdentifier("LinkPeekCard")
        if let layer = card.layer {
            layer.cornerRadius = LinkPeek.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        motion.addSubview(cardShadow)
        motion.addSubview(card)
        attach(page)

        controls.setAccessibilityIdentifier("LinkPeekControls")
        let shown: [(Control, String, String)] = [
            (.close, "xmark", "Close"),
            (.expand, "arrow.up.left.and.arrow.down.right", "Open as Tab"),
        ] + (splitTitle.map { [(.split, "square.split.1x2", $0)] } ?? [])
        for (control, symbol, title) in shown {
            let button = LinkPeekButton(symbol: symbol, title: title) { [weak self] in self?.onControl?(control) }
            button.frame.origin.y = CGFloat(buttons.count) * CGFloat(LinkPeek.controlRowHeight)
            buttons[control] = button
            controls.addSubview(button)
        }
        motion.addSubview(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func attach(_ page: NSView) {
        self.page = page
        page.removeFromSuperview()
        page.autoresizingMask = [.width, .height]
        page.frame = card.bounds
        card.addSubview(page)
    }

    /// Takes the page out (to become a tab); the card is left empty.
    func detachPage() -> NSView? {
        defer { page = nil }
        page?.removeFromSuperview()
        return page
    }

    var cardFrame: NSRect {
        let frame = LinkPeek.cardFrame(hostWidth: Double(bounds.width), hostHeight: Double(bounds.height))
        return NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    override func layout() {
        super.layout()
        motion.frame = bounds
        let cardRect = cardFrame
        card.frame = cardRect
        cardShadow.frame = cardRect.insetBy(dx: -CGFloat(LinkPeek.borderWidth), dy: -CGFloat(LinkPeek.borderWidth))
        cardShadow.layer?.shadowPath = CGPath(
            roundedRect: cardShadow.bounds, cornerWidth: LinkPeek.cornerRadius, cornerHeight: LinkPeek.cornerRadius, transform: nil
        )
        controls.frame = controlsRect
        if tug != .zero { applyTug() }
    }

    /// The buttons' column, slid back under the card by the swipe's tug.
    private var controlsRect: NSRect {
        let cardRect = cardFrame
        let column = LinkPeek.controlsFrame(
            card: .init(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: cardRect.height),
            buttons: buttons.count
        )
        return NSRect(x: column.x - LinkPeek.Swipe.controlsOffset(tug: tug), y: column.y, width: column.width, height: column.height)
    }

    // MARK: Swipe to dismiss

    /// How far the card follows a swipe right (`LinkPeek.Swipe`), in this view's points.
    private(set) var tug = LinkPeek.Swipe.Vector.zero
    private var tugSpring: Timer?
    /// The Peek is animating closed; a new swipe leaves it alone.
    private(set) var isClosing = false

    /// A swipe took over: Arc stops the card's running animations (the open spring) where they are.
    func beginTug() {
        stopTugSpring()
        for layer in [motion.layer, card.layer, cardShadow.layer].compactMap({ $0 }) {
            layer.removeAllAnimations()
        }
        motion.layer?.opacity = 1
    }

    func setTug(_ tug: LinkPeek.Swipe.Vector) {
        self.tug = tug
        applyTug()
    }

    /// The card moves with the tug and shrinks a little along it, its hairline fades, and the buttons tuck
    /// back toward it (Arc's `ModalV2HostView` layout).
    private func applyTug() {
        guard let layer = motion.layer else { return }
        let rect = cardFrame
        let center = NSPoint(x: rect.midX, y: rect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = tug == .zero ? CATransform3DIdentity : Self.transform(
            scale: LinkPeek.Swipe.scale(tug: tug), around: center,
            to: NSPoint(x: center.x + tug.x, y: center.y + tug.y), in: bounds, flipped: layerSpaceIsBottomUp
        )
        cardShadow.layer?.borderColor = NSColor.black.withAlphaComponent(LinkPeek.Swipe.borderOpacity(tug: tug)).cgColor
        controls.frame = controlsRect
        CATransaction.commit()
    }

    /// Springs the card back from the tug with Arc's tug spring, starting at `velocity` (tug points per second).
    func springTugBack(velocity: LinkPeek.Swipe.Vector) {
        stopTugSpring()
        let start = ProcessInfo.processInfo.systemUptime
        let from = tug
        let spring = LinkPeek.Swipe.tugSpring
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = ProcessInfo.processInfo.systemUptime - start
                let x = spring.settle(value: from.x, velocity: velocity.x, after: t)
                let y = spring.settle(value: from.y, velocity: velocity.y, after: t)
                let done = abs(x.value) < 0.01 && abs(y.value) < 0.01 && abs(x.velocity) < 0.1 && abs(y.velocity) < 0.1
                self.setTug(done ? .zero : .init(x: x.value, y: y.value))
                if done { self.stopTugSpring() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tugSpring = timer
    }

    private func stopTugSpring() {
        tugSpring?.invalidate()
        tugSpring = nil
    }

    // MARK: Clicks outside the card

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        // The empty area around the card and buttons is this view's own: a click there closes the Peek.
        return hit === motion ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Motion

    /// Where the card opened from (the clicked element, in this view), so it closes back there.
    private var source: NSRect?

    /// Hidden until `animateIn`, while the window asks the page where the clicked link is.
    func prepareToAnimateIn() {
        motion.layer?.opacity = 0
    }

    /// Opens with Arc's open spring from `source` (the clicked element's frame in this view, Arc's
    /// `tweenFromSource`), or when that isn't known, from a fifth of the card at `point` (the pointer).
    func animateIn(from source: NSRect?, pointer point: NSPoint?) {
        layoutSubtreeIfNeeded()
        guard let layer = motion.layer else { return }
        layer.opacity = 1
        let rect = cardFrame
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let from: CATransform3D
        if let source, let tween = Self.tween(from: source, card: rect) {
            self.source = source
            from = Self.transform(scale: tween.scale, around: center, to: NSPoint(x: center.x + tween.dx, y: center.y + tween.dy), in: bounds, flipped: layerSpaceIsBottomUp)
            for corner in [card.layer, cardShadow.layer].compactMap({ $0 }) {
                add(spring: LinkPeek.openSpring, keyPath: "cornerRadius", from: tween.cornerRadius, to: LinkPeek.cornerRadius, on: corner)
            }
        } else {
            from = Self.transform(scale: 0.2, around: center, to: point ?? center, in: bounds, flipped: layerSpaceIsBottomUp)
        }
        add(spring: LinkPeek.openSpring, keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity), on: layer)
        // Arc crossfades from a snapshot of the source (`sourceSnapshot`); Kite fades the card in instead.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.1
        layer.add(fade, forKey: "linkPeekFade")
    }

    /// Closes with Arc's close spring back toward where it opened from (or shrinks a little in place when
    /// that isn't known), fading out, then runs `completion`.
    func animateOut(completion: @escaping () -> Void) {
        stopTugSpring()
        isClosing = true
        guard let layer = motion.layer else { return completion() }
        // A swipe closes it from wherever the tug left the card.
        let start = layer.transform
        let rect = cardFrame
        let center = NSPoint(x: rect.midX, y: rect.midY)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let to: CATransform3D
        if let source, let tween = Self.tween(from: source, card: rect) {
            to = Self.transform(scale: tween.scale, around: center, to: NSPoint(x: center.x + tween.dx, y: center.y + tween.dy), in: bounds, flipped: layerSpaceIsBottomUp)
            for corner in [card.layer, cardShadow.layer].compactMap({ $0 }) {
                add(spring: LinkPeek.closeSpring, keyPath: "cornerRadius", from: LinkPeek.cornerRadius, to: tween.cornerRadius, on: corner)
            }
        } else {
            to = Self.transform(scale: 0.95, around: center, to: center, in: bounds, flipped: layerSpaceIsBottomUp)
        }
        let duration = add(spring: LinkPeek.closeSpring, keyPath: "transform", from: NSValue(caTransform3D: start), to: NSValue(caTransform3D: to), on: layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = min(duration, source == nil ? 0.15 : LinkPeek.closeSpring.response)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "linkPeekFade")
        CATransaction.commit()
    }

    /// Whether `motion`'s layer is positioned bottom-up in its superlayer. AppKit flips the layers of
    /// flipped views (`geometryFlipped`), so this host's is top-down like the view.
    private var layerSpaceIsBottomUp: Bool {
        !(motion.layer?.superlayer?.isGeometryFlipped ?? false) && !(motion.layer?.isGeometryFlipped ?? false)
    }

    private static func tween(from source: NSRect, card: NSRect) -> LinkPeek.SourceTween? {
        LinkPeek.sourceTween(
            source: .init(x: source.minX, y: source.minY, width: source.width, height: source.height),
            card: .init(x: card.minX, y: card.minY, width: card.width, height: card.height)
        )
    }

    @discardableResult
    private func add(spring: LinkPeek.Spring, keyPath: String, from: Any, to: Any, on layer: CALayer) -> CFTimeInterval {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.fillMode = .forwards
        // Opening ends at the layer's own values; closing holds the end state until the view is removed.
        let ends: Bool
        if keyPath == "transform" {
            ends = (to as? NSValue)?.caTransform3DValue.isIdentity == true
        } else {
            ends = (to as? Double) == LinkPeek.cornerRadius
        }
        animation.isRemovedOnCompletion = ends
        layer.add(animation, forKey: "linkPeekSpring." + keyPath)
        return animation.duration
    }

    /// Scales by `scale` about `center` and moves `center` to `target` (points in the flipped view). The
    /// layer's anchor is its origin corner (AppKit's), so the scale is done about the centre by hand.
    /// `flipped`: the layer's space is bottom-up, so y is mirrored first.
    private static func transform(scale: CGFloat, around center: NSPoint, to target: NSPoint, in bounds: NSRect, flipped: Bool) -> CATransform3D {
        let c = CGPoint(x: center.x, y: flipped ? bounds.height - center.y : center.y)
        let t = CGPoint(x: target.x, y: flipped ? bounds.height - target.y : target.y)
        var m = CATransform3DMakeTranslation(t.x, t.y, 0)
        m = CATransform3DScale(m, scale, scale, 1)
        return CATransform3DTranslate(m, -c.x, -c.y, 0)
    }
}

/// Lays its subviews out from the top, like the host.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension CATransform3D {
    var isIdentity: Bool { CATransform3DIsIdentity(self) }
}

/// One of the Peek's round buttons. Its look (size, fill) is not measured from Arc; see docs/arc-visual-spec.md.
final class LinkPeekButton: NSButton {
    static let diameter: CGFloat = 30
    private let action_: () -> Void

    init(symbol: String, title: String, action: @escaping () -> Void) {
        action_ = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        toolTip = title
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(LinkPeek.shadowOpacity)
        layer?.shadowRadius = LinkPeek.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -LinkPeek.shadowOffsetY)
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { action_() }
}
