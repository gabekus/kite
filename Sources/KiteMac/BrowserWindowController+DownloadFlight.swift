import AppKit
import KiteCore
import QuartzCore

/// Arc's `DownloadToLibrary`: when a download starts, an arrow flies from where it started (the
/// pointer) into the sidebar's Library button. See `DownloadFlight` for the throw.
extension BrowserWindowController {
    @objc func downloadDidStart(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        // `object` is the view the download came from, when the engine says (WebKit does).
        if let source = (notification.object as? NSView)?.window {
            guard source === window else { return }
        } else {
            // Chromium doesn't say which window: the frontmost browser window, as Arc's key window.
            let front = NSApp.orderedWindows.first { $0.windowController is BrowserWindowController }
            guard front === window else { return }
        }
        // Arc throws into a bin at the window's corner when the sidebar is hidden (`DownloadBin`);
        // Kite doesn't have the bin yet, so it only flies while the Library button shows.
        guard store.isSidebarVisible, !library.isOpen, let contentView = window.contentView else { return }
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let flight = DownloadFlight(pointer: .init(x: pointer.x, y: pointer.y), windowHeight: window.frame.height)
        else { return }
        DownloadFlightView.fly(flight, in: contentView)
    }
}

/// The flying arrow, over everything in the window and never in the way of a click. Added for one
/// flight and removed when it lands.
final class DownloadFlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    static func fly(_ flight: DownloadFlight, in container: NSView) {
        let view = DownloadFlightView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        container.addSubview(view, positioned: .above, relativeTo: nil)
        view.launch(flight)
    }

    private func launch(_ flight: DownloadFlight) {
        guard let layer, let window else { return removeFromSuperview() }
        let icon = CALayer()
        let size = DownloadFlight.iconSize
        icon.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        icon.contentsScale = window.backingScaleFactor
        icon.contents = Self.iconImage(size: size, appearance: effectiveAppearance)
        icon.contentsGravity = .resizeAspect
        icon.name = "DownloadFlight"
        layer.addSublayer(icon)

        let frames = flight.frames
        guard let last = frames.last, flight.duration > 0 else { return removeFromSuperview() }
        // Window points to this view's points (the same while it fills the window's content).
        let points = frames.map { convert(NSPoint(x: $0.position.x, y: $0.position.y), from: nil) }
        let times = frames.map { NSNumber(value: $0.time / flight.duration) }

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = points.map { NSValue(point: $0) }
        let scaleX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        scaleX.values = frames.map { NSNumber(value: $0.scaleX) }
        let scaleY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        scaleY.values = frames.map { NSNumber(value: $0.scaleY) }
        for animation in [position, scaleX, scaleY] {
            animation.keyTimes = times
            animation.calculationMode = .linear
        }
        let group = CAAnimationGroup()
        group.animations = [position, scaleX, scaleY]
        group.duration = flight.duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)

        // Ends where the last sample left it (sunk into the button, scaled to nothing).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.position = points.last ?? .zero
        icon.transform = CATransform3DMakeScale(last.scaleX, last.scaleY, 1)
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        icon.add(group, forKey: "downloadFlight")
        CATransaction.commit()
    }

    /// Arc's `DownloadIconView`: a 30pt `arrow.down.circle`, template-tinted, on its palette's
    /// background colour (Kite: the window background behind the label colour).
    private static func iconImage(size: CGFloat, appearance: NSAppearance) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
                    .applying(.init(paletteColors: [.labelColor]))
                image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                if let image {
                    let fit = min(rect.width / image.size.width, rect.height / image.size.height)
                    let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
                    image.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                          width: drawn.width, height: drawn.height))
                }
            }
            return image != nil
        }
    }
}
