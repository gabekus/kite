import AppKit
import KiteCore

/// A split's pages, each in its own card, with a draggable divider in each gap.
/// Fills the content card, which turns transparent while a split is shown.
@MainActor
final class SplitPanesView: NSView {
    private typealias M = ArcMetrics.Split

    private struct Pane {
        let id: UUID
        let card: ShadowView
        let clip: ContentClipView
        /// Arc's split button ("Split View Menu"), shown while the pointer is in the pane's top band.
        let menuButton: SplitPaneMenuButton
    }

    private var panes: [Pane] = []
    private var dividers: [SplitDividerView] = []
    private(set) var factors: [Double] = []
    private(set) var orientation: SplitOrientation = .horizontal

    /// Divider `index` moved: the leading pane's share of the pair, and the smallest share either may have.
    var onDividerDrag: ((_ index: Int, _ fraction: Double, _ minimumShare: Double) -> Void)?
    /// A pane's split button was clicked: the pane's tab and the button.
    var onPaneMenu: ((_ id: UUID, _ button: NSView) -> Void)?
    private var hoverAreas: [NSTrackingArea] = []
    /// The next layout change animates (Arc animates only a double-clicked divider evening out its panes).
    private var animatesNextLayout = false
    /// Whether the divider being dragged sits snapped to the middle of its panes.
    private var snappedDivider: Int?

    override var isFlipped: Bool { true }

    /// Replaces the panes. `pages` are in pane order.
    func setPanes(_ pages: [(id: UUID, view: NSView)]) {
        for pane in panes {
            pane.card.removeFromSuperview()
            pane.menuButton.removeFromSuperview()
        }
        for divider in dividers { divider.removeFromSuperview() }
        panes = pages.map { id, view in
            let card = ShadowView(cornerRadius: ArcMetrics.Content.cornerRadius)
            let clip = ContentClipView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = ArcMetrics.Content.cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            clip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            clip.autoresizingMask = [.width, .height]
            card.addSubview(clip)
            view.autoresizingMask = []
            clip.addSubview(view)
            clip.page = view
            addSubview(card)
            let button = SplitPaneMenuButton()
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onPaneMenu?(id, button)
            }
            return Pane(id: id, card: card, clip: clip, menuButton: button)
        }
        // Over the cards (and the pages in them).
        for pane in panes { addSubview(pane.menuButton) }
        dividers = (0..<max(pages.count - 1, 0)).map { index in
            let divider = SplitDividerView()
            divider.onDrag = { [weak self] point in self?.dragDivider(index, to: point) }
            divider.onDragEnd = { [weak self] in self?.snappedDivider = nil }
            divider.onDoubleClick = { [weak self] in self?.equalizeDivider(index) }
            addSubview(divider)
            return divider
        }
        layoutPanes()
    }

    func setLayout(factors: [Double], orientation: SplitOrientation) {
        guard factors != self.factors || orientation != self.orientation else { return }
        self.factors = factors
        self.orientation = orientation
        for divider in dividers { divider.isVertical = orientation == .vertical }
        guard animatesNextLayout else { return layoutPanes() }
        animatesNextLayout = false
        // Arc: `NSAnimationContext` with duration 0.2, ease-out and implicit animation, around the layout.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.equalizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layoutPanes(animated: true)
        }
    }

    /// The pane under a point in this view's coordinates.
    func pane(at point: NSPoint) -> UUID? {
        panes.first { !$0.card.isHidden && $0.card.frame.contains(point) }?.id
    }

    func frame(of id: UUID) -> CGRect? {
        panes.first { $0.id == id }?.card.frame
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutPanes()
    }

    private var isHorizontal: Bool { orientation == .horizontal }

    /// Room for the panes along the split's axis, gaps taken out.
    private var available: CGFloat {
        let length = isHorizontal ? bounds.width : bounds.height
        return max(length - M.gap * CGFloat(max(panes.count - 1, 0)), 0)
    }

    private func layoutPanes(animated: Bool = false) {
        func place(_ view: NSView, _ frame: CGRect) {
            if animated { view.animator().frame = frame } else { view.frame = frame }
        }
        guard !panes.isEmpty else { return }
        let shares = factors.count == panes.count ? factors : Array(repeating: 1 / Double(panes.count), count: panes.count)
        // Expand Current Split: one pane at 1, the rest at 0. The hidden panes and every divider
        // go away, so the expanded pane fills the split like a single page.
        if let expanded = shares.firstIndex(of: 1), shares.filter({ $0 == 0 }).count == panes.count - 1, panes.count > 1 {
            for (i, pane) in panes.enumerated() {
                pane.card.isHidden = i != expanded
                if i == expanded {
                    pane.card.frame = bounds
                    pane.card.needsLayout = true
                }
            }
            for divider in dividers { divider.isHidden = true }
            placeMenuButtons(animated: false)
            return
        }
        for pane in panes { pane.card.isHidden = false }
        for divider in dividers { divider.isHidden = false }
        var offset: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            // The last pane takes what's left, so rounding never leaves a sliver.
            let length = i == panes.count - 1
                ? (isHorizontal ? bounds.width : bounds.height) - offset
                : (available * shares[i]).rounded()
            place(pane.card, isHorizontal
                ? CGRect(x: offset, y: 0, width: length, height: bounds.height)
                : CGRect(x: 0, y: offset, width: bounds.width, height: length))
            pane.card.needsLayout = true
            offset += length
            if i < dividers.count {
                place(dividers[i], isHorizontal
                    ? CGRect(x: offset, y: 0, width: M.gap, height: bounds.height)
                    : CGRect(x: 0, y: offset, width: bounds.width, height: M.gap))
                offset += M.gap
            }
        }
        placeMenuButtons(animated: animated)
    }

    // MARK: Split button

    /// Each pane's split button sits in its top-right corner, where Arc's top bar has it, and the pane's top band
    /// (the bar's height) reveals it.
    private func placeMenuButtons(animated: Bool) {
        for pane in panes {
            let card = pane.card.frame
            let size = M.menuButtonSize
            let frame = CGRect(x: card.maxX - M.menuButtonTrailing - size, y: card.minY + M.menuButtonTop, width: size, height: size)
            if animated { pane.menuButton.animator().frame = frame } else { pane.menuButton.frame = frame }
            pane.menuButton.isHidden = pane.card.isHidden
        }
        updateTrackingAreas()
    }

    private func topBand(of card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY, width: card.width, height: min(M.menuRevealHeight, card.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in hoverAreas { removeTrackingArea(area) }
        // Always active: Arc's top bar reveals over a background window too (inferred; not checked in Arc).
        hoverAreas = panes.enumerated().compactMap { i, pane in
            guard !pane.card.isHidden else { return nil }
            let area = NSTrackingArea(rect: topBand(of: pane.card.frame), options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: ["pane": i])
            addTrackingArea(area)
            return area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["pane"] as? Int, panes.indices.contains(i) else { return }
        panes[i].menuButton.setRevealed(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["pane"] as? Int, panes.indices.contains(i) else { return }
        panes[i].menuButton.setRevealed(false)
    }

    private func dragDivider(_ index: Int, to point: NSPoint) {
        guard panes.indices.contains(index + 1) else { return }
        let leading = panes[index].card.frame
        let trailing = panes[index + 1].card.frame
        let start = isHorizontal ? leading.minX : leading.minY
        let pair = isHorizontal ? leading.width + trailing.width : leading.height + trailing.height
        guard pair > 0, available > 0 else { return }
        let position = (isHorizontal ? point.x : point.y) - start - M.gap / 2
        let (fraction, snapped) = SplitView.dividerFraction(position: Double(position), pairLength: Double(pair), snapDistance: M.centerSnapDistance)
        // Arc taps the trackpad as the divider lands in the middle.
        if snapped, snappedDivider != index {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snappedDivider = snapped ? index : nil
        onDividerDrag?(index, fraction, Double(M.minimumPaneWidth / available))
    }

    /// Arc's double-click on a divider: its two panes share their space evenly, animated.
    private func equalizeDivider(_ index: Int) {
        guard panes.indices.contains(index + 1), available > 0 else { return }
        animatesNextLayout = true
        onDividerDrag?(index, 0.5, Double(M.minimumPaneWidth / available))
        // Nothing changed (already even): don't animate some later layout.
        animatesNextLayout = false
    }
}

/// Arc's split button in a pane's top bar: "Split View Menu", 28×28 with `square.split.2x1`. Hidden until the
/// pointer is in the pane's top band; it stays up while its menu is open.
@MainActor
final class SplitPaneMenuButton: NSView {
    private typealias M = ArcMetrics.Split

    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var hovering = false
    private(set) var revealed = false
    /// Held up while the menu is open, so it doesn't vanish under the menu.
    var isMenuOpen = false {
        didSet { if !isMenuOpen { setRevealed(revealed) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = M.menuButtonCornerRadius
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: M.menuButtonSymbolSize, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Split View Menu")
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    // A test build takes synthetic clicks while in the background (`kite ui input`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    func setRevealed(_ revealed: Bool) {
        self.revealed = revealed
        let alpha: CGFloat = revealed || isMenuOpen ? 1 : 0
        guard alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.menuButtonFadeDuration
            animator().alphaValue = alpha
        }
    }

    // A hidden button takes no clicks: they go to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The whole button takes the click, not the icon inside it.
        alphaValue > 0 && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.windowBackgroundColor.withAlphaComponent(M.menuButtonFillOpacity)
            layer?.backgroundColor = (hovering ? base.blended(withFraction: 0.08, of: .labelColor) ?? base : base).cgColor
        }
    }
}

/// The gap between two panes: a resize cursor across it, and Arc's small grip in the middle
/// that brightens while the pointer is over it.
@MainActor
final class SplitDividerView: NSView {
    private typealias M = ArcMetrics.Split

    /// The drag's location in the superview's coordinates.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var isVertical = false {
        didSet {
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private let grip = CALayer()
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grip.cornerRadius = M.gripCornerRadius
        layer?.addSublayer(grip)
        updateGrip(hovering: false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    // A test build takes synthetic clicks on the divider while in the background (`kite ui input`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }

    override func layout() {
        super.layout()
        let size = isVertical ? CGSize(width: M.gripSize.height, height: M.gripSize.width) : M.gripSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGrip(hovering: false, animated: false)
    }

    private func updateGrip(hovering: Bool, animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = (dark ? NSColor.white : NSColor.black)
            .withAlphaComponent(hovering ? M.gripHoverOpacity : M.gripOpacity).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? M.gripFadeDuration : 0)
        CATransaction.setDisableActions(!animated)
        grip.backgroundColor = color
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isVertical ? .resizeUpDown : .resizeLeftRight)
    }

    // The window keeps cursor rects where they were set, so move them with the divider.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateGrip(hovering: true, animated: true) }
    override func mouseExited(with event: NSEvent) { updateGrip(hovering: false, animated: true) }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }
}
