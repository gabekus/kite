import AppKit

/// Moves the window's close/minimize/zoom buttons into the sidebar's top row,
/// the way Arc does, and hides them while the sidebar is hidden (they come
/// back while the pointer is over their spot).
///
/// AppKit lays the titlebar out again on resize and full-screen changes, so
/// `place()` has to run after each of those. Same approach as Electron's
/// `trafficLightPosition`: grow the titlebar container so the buttons sit
/// centered at the wanted height, then set each button's x.
@MainActor
final class TrafficLights {
    private static let center = ArcMetrics.Window.trafficLightCenter
    private static let pitch = ArcMetrics.Window.trafficLightPitch

    private weak var window: NSWindow?
    private let hoverZone = HoverZone()
    private var sidebarVisible = true
    private var hovering = false

    init(window: NSWindow, hoverHost: NSView) {
        self.window = window
        hoverZone.translatesAutoresizingMaskIntoConstraints = false
        hoverHost.addSubview(hoverZone)
        NSLayoutConstraint.activate([
            hoverZone.leadingAnchor.constraint(equalTo: hoverHost.leadingAnchor),
            hoverZone.topAnchor.constraint(equalTo: hoverHost.topAnchor),
            hoverZone.widthAnchor.constraint(equalToConstant: 80),
            hoverZone.heightAnchor.constraint(equalToConstant: 40),
        ])
        hoverZone.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.updateVisibility(animated: true)
        }
    }

    private var buttons: [NSButton] {
        guard let window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func place() {
        // In full screen the buttons live in the menu-bar reveal; leave them to AppKit.
        guard let window, !isFullScreen, let first = buttons.first,
              let container = first.superview?.superview else { return }
        let size = first.frame.size
        let margin = (Self.center.y - size.height / 2).rounded()

        var frame = container.frame
        frame.size.height = size.height + 2 * margin
        frame.origin.y = window.frame.height - frame.height
        if container.frame != frame { container.frame = frame }

        var x = (Self.center.x - size.width / 2).rounded()
        for button in buttons {
            let origin = CGPoint(x: x, y: margin)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            x += Self.pitch
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        updateVisibility(animated: true)
    }

    func fullScreenChanged() {
        hoverZone.isHidden = isFullScreen
        updateVisibility(animated: false)
        place()
    }

    private func updateVisibility(animated: Bool) {
        hoverZone.isActive = !sidebarVisible
        let alpha: CGFloat = sidebarVisible || hovering || isFullScreen ? 1 : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Hidden as well as transparent, so invisible buttons don't take clicks meant for the page.
        if alpha > 0 { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduceMotion ? 0.15 : 0
            for button in buttons {
                button.animator().alphaValue = alpha
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, alpha == 0, !self.sidebarVisible, !self.hovering, !self.isFullScreen else { return }
                self.buttons.forEach { $0.isHidden = true }
            }
        }
    }
}

/// Reports the pointer entering and leaving, without taking clicks from what's
/// underneath (the buttons sit above it in the titlebar).
private final class HoverZone: NSView {
    var onHover: ((Bool) -> Void)?
    var isActive = false {
        didSet { if !isActive, inside { inside = false; onHover?(false) } }
    }
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActive else { return }
        inside = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard inside else { return }
        inside = false
        onHover?(false)
    }
}
