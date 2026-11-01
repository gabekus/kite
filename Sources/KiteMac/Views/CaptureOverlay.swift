import AppKit
import KiteCore

/// File › Capture…: covers the focused page, dims it and lets the user drag out a rectangle.
/// Colours are Arc's (ARC_Capture.bundle); the layout of the hint bubble and the selection
/// outline are Kite's own, since Arc's couldn't be watched (docs/arc-visual-spec.md, "Capture").
@MainActor
final class CaptureOverlayView: NSView {
    enum Metrics {
        /// Arc's "BlurredBackground" colour asset, light and dark.
        static let dimLight = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.33)
        static let dimDark = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)
        /// Arc's "OverlayBubbleBlue", "OverlayBubblePink" and "OverlayBubbleText" (Display P3).
        static let bubbleBlue = NSColor(displayP3Red: 0, green: 0.278, blue: 1, alpha: 0.5)
        static let bubblePink = NSColor(displayP3Red: 1, green: 0.6, blue: 0.6, alpha: 0.5)
        static let bubbleText = NSColor(displayP3Red: 0.204, green: 0.021, blue: 0.58, alpha: 1)
        /// Arc's tooltip text, without "Click or": Kite has no click-to-capture-an-element yet.
        static let hint = "Drag to capture a portion of this page"
        static let bubbleOffset = NSPoint(x: 14, y: 18)
    }

    /// The selection in this view's (flipped, top-left) coordinates.
    var onCapture: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    /// The view this overlay covers; it follows that view's frame.
    private weak var target: NSView?
    private var start: NSPoint?
    private(set) var selection: NSRect = .zero
    private let bubble = NSView()
    private let bubbleGradient = CAGradientLayer()
    private let bubbleLabel = NSTextField(labelWithString: Metrics.hint)

    init(covering target: NSView) {
        self.target = target
        super.init(frame: target.frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture")
        target.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(targetMoved), name: NSView.frameDidChangeNotification, object: target)

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 11
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.masksToBounds = true
        bubbleGradient.colors = [Metrics.bubbleBlue.cgColor, Metrics.bubblePink.cgColor]
        bubbleGradient.startPoint = CGPoint(x: 0, y: 0.5)
        bubbleGradient.endPoint = CGPoint(x: 1, y: 0.5)
        bubble.layer?.addSublayer(bubbleGradient)
        bubbleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        bubbleLabel.textColor = .white
        bubbleLabel.sizeToFit()
        bubble.frame.size = NSSize(width: bubbleLabel.frame.width + 20, height: 22)
        bubbleLabel.frame.origin = NSPoint(x: 10, y: (22 - bubbleLabel.frame.height) / 2)
        bubbleGradient.frame = bubble.bounds
        bubble.addSubview(bubbleLabel)
        bubble.isHidden = true
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The hint bubble never takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func targetMoved() {
        guard let target else { return }
        frame = target.frame
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? Metrics.dimDark : Metrics.dimLight).setFill()
        let path = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            path.appendRect(selection)
            path.windingRule = .evenOdd
        }
        path.fill()
        guard !selection.isEmpty else { return }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseEntered(with event: NSEvent) { moveBubble(to: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { moveBubble(to: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { bubble.isHidden = true }

    private func moveBubble(to point: NSPoint) {
        guard start == nil else { return }
        var origin = NSPoint(x: point.x + Metrics.bubbleOffset.x, y: point.y + Metrics.bubbleOffset.y)
        // Keep it on the page near the right and bottom edges.
        origin.x = min(origin.x, bounds.width - bubble.frame.width - 4)
        origin.y = min(origin.y, bounds.height - bubble.frame.height - 4)
        bubble.frame.origin = origin
        bubble.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        bubble.isHidden = true
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = Capture.selection(from: (start.x, start.y), to: (end.x, end.y), within: bounds.width, bounds.height)
        selection = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        let rect = Capture.Rect(x: selection.minX, y: selection.minY, width: selection.width, height: selection.height)
        guard Capture.isCapturable(rect) else {
            selection = .zero
            needsDisplay = true
            return
        }
        onCapture?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// What Arc's capture popover offers once a capture is taken, minus Easels: the image, Copy and Save.
@MainActor
final class CapturePreviewController: NSViewController {
    enum Metrics {
        static let maxImage = NSSize(width: 320, height: 240)
        static let padding: CGFloat = 12
        /// Arc's "ImageViewBackground" colour asset, light and dark.
        static let imageBackgroundLight = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        static let imageBackgroundDark = NSColor(srgbRed: 0.082, green: 0.11, blue: 0.188, alpha: 1)
    }

    private let image: NSImage
    private let onCopy: () -> Void
    private let onSave: () -> Void

    init(image: NSImage, onCopy: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.image = image
        self.onCopy = onCopy
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let size = image.size
        let fit = min(1, Metrics.maxImage.width / max(size.width, 1), Metrics.maxImage.height / max(size.height, 1))
        let shown = NSSize(width: max(80, (size.width * fit).rounded()), height: max(40, (size.height * fit).rounded()))

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        imageView.layer?.backgroundColor = (dark ? Metrics.imageBackgroundDark : Metrics.imageBackgroundLight).cgColor
        imageView.setAccessibilityLabel("Captured image")

        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
            button.imagePosition = .imageLeading
            button.bezelStyle = .push
            button.controlSize = .regular
            return button
        }
        let buttons = NSStackView(views: [button("Copy", "doc.on.doc", #selector(copyImage)),
                                          button("Save", "square.and.arrow.down", #selector(saveImage))])
        buttons.spacing = 8

        let stack = NSStackView(views: [imageView, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Metrics.padding, left: Metrics.padding, bottom: Metrics.padding, right: Metrics.padding)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: shown.width),
            imageView.heightAnchor.constraint(equalToConstant: shown.height),
        ])
        view = stack
    }

    @objc private func copyImage() { onCopy() }
    @objc private func saveImage() { onSave() }
}
