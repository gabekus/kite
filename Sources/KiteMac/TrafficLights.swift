import AppKit

/// Close/minimize/zoom buttons in the sidebar's top row, built the way Arc 1.169's binary
/// does it: hide the window's own titlebar buttons and make standalone ones with
/// `NSWindow.standardWindowButton(_:for:)` inside the sidebar. Being part of the sidebar,
/// they slide and hide with it, and the titlebar never moves or takes clicks for them.
@MainActor
final class TrafficLights {
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private weak var window: NSWindow?
    private let group = ButtonGroup()

    init(window: NSWindow, host: NSView) {
        self.window = window
        let buttons = Self.kinds.compactMap { NSWindow.standardWindowButton($0, for: window.styleMask) }
        let actions = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.toggleFullScreen(_:))]
        guard let size = buttons.first?.frame.size else { return }

        let center = ArcMetrics.Window.trafficLightCenter
        let pitch = ArcMetrics.Window.trafficLightPitch
        // Wide enough for Arc's hover area, which runs to x 73; the group takes no clicks of its
        // own, so the sidebar toggle at x 71 keeps them.
        let originX = (center.x - size.width / 2).rounded()
        group.frame = CGRect(x: originX,
                             y: host.isFlipped ? (center.y - size.height / 2).rounded() : host.bounds.height - (center.y + size.height / 2).rounded(),
                             width: max(CGFloat(buttons.count - 1) * pitch + size.width, ArcMetrics.Window.trafficLightHoverArea.maxX - originX),
                             height: size.height)
        group.hoverArea = ArcMetrics.Window.trafficLightHoverArea.offsetBy(dx: -originX, dy: -(center.y - size.height / 2).rounded())
        group.autoresizingMask = host.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
        for (index, (button, action)) in zip(buttons, actions).enumerated() {
            button.setFrameOrigin(CGPoint(x: CGFloat(index) * pitch, y: 0))
            button.target = window
            button.action = action
            group.addSubview(button)
        }
        host.addSubview(group)
        fullScreenChanged()
    }

    /// In full screen the window's own buttons appear in the menu-bar reveal, so those come
    /// back and the sidebar's hide.
    func fullScreenChanged() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        for kind in Self.kinds { window.standardWindowButton(kind)?.isHidden = !fullScreen }
        group.isHidden = fullScreen
    }
}

/// Arc keeps its traffic lights grey, even in the key window, until the pointer is on them;
/// then all three show their colours and marks (measured in Arc 1.169: (89,90,90) at each centre
/// while away, full colour on hover). Arc's binary dims them by appearance: 0.33 in dark, 0.1
/// in light. Here the buttons are drawn transparent while away and plain circles stand in.
private final class ButtonGroup: NSView {
    private let dim = DimmedLights()
    /// Window points from the top-left, shifted to the group's top-left.
    var hoverArea: CGRect = .zero {
        didSet { updateTrackingAreas() }
    }
    private var inside = false {
        didSet { update() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== dim else { return }
        // Keep the stand-in circles on top, centred on each button.
        dim.frame = bounds
        dim.autoresizingMask = [.width, .height]
        dim.centers = subviews.filter { $0 !== dim }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        addSubview(dim, positioned: .above, relativeTo: nil)
        update()
    }

    private func update() {
        for button in subviews where button !== dim {
            button.alphaValue = inside ? 1 : 0
            button.needsDisplay = true
        }
        dim.isHidden = inside
    }

    /// AppKit's window buttons ask their superview this to decide whether to show their marks.
    @objc(_mouseInGroup:) func mouseInGroup(_ button: NSButton) -> Bool { inside }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Not `.inVisibleRect`, which tracks the whole visible rect rather than this one.
        let rect = isFlipped ? hoverArea : CGRect(x: hoverArea.minX, y: bounds.height - hoverArea.maxY, width: hoverArea.width, height: hoverArea.height)
        addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === dim ? nil : hit
    }

    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }
}

/// Three plain circles where the buttons are, in the label colour at Arc's dimmed opacity.
private final class DimmedLights: NSView {
    static let diameter: CGFloat = 12
    var centers: [CGPoint] = [] {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.33) : NSColor.black.withAlphaComponent(0.1)).setFill()
        let r = Self.diameter / 2
        for c in centers {
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: Self.diameter, height: Self.diameter)).fill()
        }
    }
}
