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
        // Only as big as the three buttons, so the sidebar toggle next to them keeps its clicks.
        group.frame = CGRect(x: (center.x - size.width / 2).rounded(),
                             y: host.isFlipped ? (center.y - size.height / 2).rounded() : host.bounds.height - (center.y + size.height / 2).rounded(),
                             width: CGFloat(buttons.count - 1) * pitch + size.width, height: size.height)
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

/// Shows the buttons' ×, – and + marks while the pointer is over any of them, as the
/// titlebar does. AppKit's window buttons ask their superview `_mouseInGroup:` for this.
private final class ButtonGroup: NSView {
    private var inside = false {
        didSet { subviews.forEach { $0.needsDisplay = true } }
    }

    @objc(_mouseInGroup:) func mouseInGroup(_ button: NSButton) -> Bool { inside }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }
}
