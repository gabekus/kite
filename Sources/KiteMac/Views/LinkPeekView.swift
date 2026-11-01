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
        let column = LinkPeek.controlsFrame(
            card: .init(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: cardRect.height),
            buttons: buttons.count
        )
        controls.frame = NSRect(x: column.x, y: column.y, width: column.width, height: column.height)
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

    /// Opens from `point` (in this view; the clicked link's spot, when known) with Arc's open spring.
    func animateIn(from point: NSPoint?) {
        layoutSubtreeIfNeeded()
        guard let layer = motion.layer else { return }
        let rect = cardFrame
        let origin = point ?? NSPoint(x: rect.midX, y: rect.midY)
        // Arc tweens from the link's own frame; Kite only knows the pointer, so it grows from a fifth of the card there.
        let scale: CGFloat = 0.2
        let from = Self.transform(scale: scale, around: NSPoint(x: rect.midX, y: rect.midY), to: origin, in: bounds, flipped: true)
        add(spring: LinkPeek.openSpring, keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity), on: layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.1
        layer.add(fade, forKey: "linkPeekFade")
    }

    /// Shrinks a little and fades with Arc's close spring, then runs `completion`.
    func animateOut(completion: @escaping () -> Void) {
        guard let layer = motion.layer else { return completion() }
        let rect = cardFrame
        let to = Self.transform(scale: 0.95, around: NSPoint(x: rect.midX, y: rect.midY), to: NSPoint(x: rect.midX, y: rect.midY), in: bounds, flipped: true)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let duration = add(spring: LinkPeek.closeSpring, keyPath: "transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: to), on: layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = min(duration, 0.15)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "linkPeekFade")
        CATransaction.commit()
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
        animation.isRemovedOnCompletion = keyPath != "transform" || (to as? NSValue)?.caTransform3DValue.isIdentity == true
        layer.add(animation, forKey: "linkPeekSpring")
        return animation.duration
    }

    /// Scales by `scale` about `center` and moves `center` to `target`. The layer's anchor is its
    /// bottom-left corner (AppKit's), so the scale is done about the centre by hand.
    private static func transform(scale: CGFloat, around center: NSPoint, to target: NSPoint, in bounds: NSRect, flipped: Bool) -> CATransform3D {
        // Layer space is bottom-up even when the view is flipped.
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
