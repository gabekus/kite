import AppKit

/// Moves the window's close/minimize/zoom buttons into the sidebar's top row,
/// the way Arc does, and hides them while the sidebar is hidden (they come
/// back while the pointer is over their spot).
///
/// AppKit lays the titlebar out again whenever it likes (resize, full screen,
/// becoming key), so `place()` runs again after any of its frames move. Like Electron's
/// `trafficLightPosition`, it reframes the titlebar container so the buttons sit
/// centered at the wanted height, then sets each button's x.
@MainActor
final class TrafficLights {
    private static let center = ArcMetrics.Window.trafficLightCenter
    private static let pitch = ArcMetrics.Window.trafficLightPitch

    private weak var window: NSWindow?
    private let hoverZone = HoverZone()
    private var sidebarVisible = true
    private var hovering = false
    private var isPlacing = false
    private var isAnimating = false
    private var placeQueued = false
    private var burstStart: TimeInterval = 0
    private var burstCount = 0
    private var observers: [NSObjectProtocol] = []

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
        observeTitlebar(window)
    }

    /// Puts the buttons back after AppKit's own titlebar layout moves them.
    private func observeTitlebar(_ window: NSWindow) {
        let center = NotificationCenter.default
        var views: [NSView] = buttons
        if let container = buttons.first?.superview?.superview { views.append(container) }
        for view in views {
            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queuePlace() }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queuePlace() }
            })
        }
    }

    /// After AppKit's layout pass finishes, so the two don't fight inside it. Gives up
    /// for a moment if AppKit keeps undoing it, rather than looping.
    private func queuePlace() {
        guard !isPlacing, !placeQueued else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - burstStart > 1 { burstStart = now; burstCount = 0 }
        burstCount += 1
        guard burstCount <= 10 else { return }
        placeQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.placeQueued = false
                self?.place()
            }
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
        isPlacing = true
        defer { isPlacing = false }
        let size = first.frame.size
        let margin = (Self.center.y - size.height / 2).rounded()

        let firstX = (Self.center.x - size.width / 2).rounded()
        let lastMaxX = firstX + CGFloat(buttons.count - 1) * Self.pitch + size.width
        // Only as wide as the buttons: the titlebar takes every click inside it (for dragging
        // and double-click zoom), and full width it would cover the sidebar's top row.
        let frame = CGRect(x: 0, y: window.frame.height - (size.height + 2 * margin),
                           width: lastMaxX + 2, height: size.height + 2 * margin)
        if container.frame != frame { container.frame = frame }

        var x = firstX
        for button in buttons {
            let origin = CGPoint(x: x, y: margin)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            x += Self.pitch
        }
        // AppKit shows the buttons again when it lays the titlebar out (e.g. on becoming key).
        if !shouldShow, !isAnimating {
            for button in buttons where !button.isHidden { button.isHidden = true }
        }
    }

    private var shouldShow: Bool { sidebarVisible || hovering || isFullScreen }

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
        let alpha: CGFloat = shouldShow ? 1 : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Hidden as well as transparent, so invisible buttons don't take clicks meant for the page.
        if alpha > 0 { buttons.forEach { $0.isHidden = false } }
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduceMotion ? 0.15 : 0
            for button in buttons {
                button.animator().alphaValue = alpha
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAnimating = false
                guard alpha == 0, !self.shouldShow else { return }
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
