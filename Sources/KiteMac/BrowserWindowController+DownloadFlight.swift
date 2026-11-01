import AppKit
import KiteCore
import QuartzCore
import SwiftUI

/// Arc's `DownloadToLibrary`: when a download starts, an arrow flies from where it started (the
/// pointer) into the sidebar's Library button, or into Arc's `DownloadBin` at the window's bottom-left
/// corner while the sidebar is hidden. See `DownloadFlight` and `DownloadBin` for the numbers.
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
        guard !library.isOpen, let contentView = window.contentView else { return }
        let target: DownloadFlight.Target = store.isSidebarVisible ? .libraryButton : .bin
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let flight = DownloadFlight(pointer: .init(x: pointer.x, y: pointer.y),
                                          windowHeight: window.frame.height, target: target)
        else { return }
        switch target {
        case .libraryButton: DownloadFlightView.fly(flight, in: contentView)
        case .bin: DownloadBinView.fly(flight, in: contentView)
        }
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
        guard let layer = view.layer,
              launch(flight, in: layer, of: view, done: { [weak view] in view?.removeFromSuperview() })
        else { return view.removeFromSuperview() }
    }

    /// Adds the arrow to `layer` (the layer of `view`) and throws it; false if there was nothing to throw.
    /// `done` runs when the keyframes end. The arrow stays where the last sample left it: sunk into the
    /// Library button and scaled to nothing, or in the bin.
    static func launch(_ flight: DownloadFlight, in layer: CALayer, of view: NSView,
                       done: @escaping () -> Void) -> Bool {
        guard let window = view.window else { return false }
        let frames = flight.frames
        let duration = flight.totalDuration
        guard let last = frames.last, duration > 0 else { return false }
        let icon = CALayer()
        let size = DownloadFlight.iconSize
        icon.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        icon.contentsScale = window.backingScaleFactor
        icon.contents = iconImage(size: size, appearance: view.effectiveAppearance)
        icon.contentsGravity = .resizeAspect
        icon.name = "DownloadFlight"
        layer.addSublayer(icon)

        // Window points to the view's points (the same while it fills the window's content).
        let points = frames.map { view.convert(NSPoint(x: $0.position.x, y: $0.position.y), from: nil) }
        let times = frames.map { NSNumber(value: $0.time / duration) }

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
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.position = points.last ?? .zero
        icon.transform = CATransform3DMakeScale(last.scaleX, last.scaleY, 1)
        CATransaction.setCompletionBlock(done)
        icon.add(group, forKey: "downloadFlight")
        CATransaction.commit()
        return true
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

/// Arc's `DownloadBin`: while the sidebar is hidden, a tile holding the Library button slides in at the
/// window's bottom-left corner, catches every arrow thrown while it's out, and slides away with them 1 s
/// after the last one lands. One per window; a throw while it's leaving starts a new one.
final class DownloadBinView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    private let tile = NSHostingView(rootView: DownloadBinTile())
    /// Holds the arrows, above the tile.
    private let arrows = NSView()
    /// Arrows still in the air or within `DownloadBin.linger` of landing.
    private var pending = 0
    private(set) var leaving = false

    static func fly(_ flight: DownloadFlight, in container: NSView) {
        let bin = container.subviews.lazy.compactMap { $0 as? DownloadBinView }.first { !$0.leaving }
            ?? DownloadBinView(in: container)
        bin.add(flight)
    }

    private init(in container: NSView) {
        super.init(frame: container.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        setAccessibilityElement(false)
        // Room around the 62pt frame for the tile's 12pt shadow.
        let side = DownloadBin.frameSize + 4 * DownloadBin.shadowRadius
        tile.frame = NSRect(x: DownloadBin.shownX - side / 2, y: DownloadBin.centerY - side / 2, width: side, height: side)
        tile.wantsLayer = true
        tile.layer?.masksToBounds = false
        tile.layer?.name = "DownloadBin"
        addSubview(tile)
        arrows.frame = bounds
        arrows.autoresizingMask = [.width, .height]
        arrows.wantsLayer = true
        addSubview(arrows)
        container.addSubview(self, positioned: .above, relativeTo: nil)
        slide(tile.layer, by: DownloadBin.hiddenX - DownloadBin.shownX, entering: true, done: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func add(_ flight: DownloadFlight) {
        guard let layer = arrows.layer, DownloadFlightView.launch(flight, in: layer, of: arrows, done: {}) else {
            if pending == 0 { leave() }
            return
        }
        pending += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + flight.landingTime + DownloadBin.linger) { [weak self] in
            guard let self else { return }
            pending -= 1
            if pending == 0 { leave() }
        }
    }

    /// Slides the tile and the arrows in it back off the window's edge, then goes.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        let offset = DownloadBin.hiddenX - DownloadBin.shownX
        slide(tile.layer, by: offset, entering: false) { [weak self] in self?.removeFromSuperview() }
        slide(arrows.layer, by: offset, entering: false, done: nil)
    }

    /// Arc's spring (damping 0.9, response 0.82) on x: in from `offset` to where the layer sits, or out
    /// from there to `offset`.
    private func slide(_ layer: CALayer?, by offset: Double, entering: Bool, done: (() -> Void)?) {
        guard let layer else { return }
        let spring = CASpringAnimation(keyPath: "position.x")
        spring.mass = 1
        spring.stiffness = DownloadBin.slide.stiffness
        spring.damping = DownloadBin.slide.damping
        spring.fromValue = entering ? offset : 0
        spring.toValue = entering ? 0 : offset
        spring.isAdditive = true
        spring.duration = spring.settlingDuration
        if !entering {
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        if let done { CATransaction.setCompletionBlock(done) }
        layer.add(spring, forKey: entering ? "downloadBinIn" : "downloadBinOut")
        CATransaction.commit()
    }
}

/// The bin's tile (Arc's `DownloadBin` body): a 46pt rounded rectangle (12pt continuous corners) with a
/// 12pt shadow, white at 0.15 in dark mode and black at 0.3 in light, holding the same Library button view
/// the sidebar shows. Arc fills it with a palette colour that wasn't resolved; Kite uses the window
/// background.
private struct DownloadBinTile: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: DownloadBin.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: (dark ? Color.white : Color.black).opacity(DownloadBin.shadowOpacity(dark: dark)),
                        radius: DownloadBin.shadowRadius)
            LibraryIcon()
        }
        .padding(DownloadBin.padding)
        .frame(width: DownloadBin.frameSize, height: DownloadBin.frameSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityIdentifier("DownloadBin")
    }
}
