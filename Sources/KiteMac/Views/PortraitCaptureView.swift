import AppKit
import KiteCore

/// Capture in Portrait Mode's popover (Arc's `WindowScreenshotPopoverContent`): the preview, a
/// colour slider over Arc's nine brand colours, round buttons for the website's colour and the
/// desktop wallpaper, the watermark toggle, and Copy. Every change is saved straight away, as
/// Arc writes its user defaults.
final class PortraitCaptureController: NSViewController {
    enum Metrics {
        static let maxPreview = NSSize(width: 320, height: 240)
        static let padding: CGFloat = 12
        /// Arc's round selection buttons and watermark toggle: 24 pt.
        static let buttonSize: CGFloat = 24
        static let sliderHeight: CGFloat = 24
        /// Preview images are rendered at most this many pixels wide.
        static let previewPixels: CGFloat = 640
    }

    private let source: PortraitSource
    private var settings: PortraitSettings { didSet { settings.save(); settingsChanged() } }
    private let onCopy: (PortraitSettings) -> Void
    private let preview = NSImageView()
    private let slider = PaletteSlider()
    private let websiteButton = PortraitCircleButton()
    private let wallpaperButton = PortraitCircleButton()
    private let watermarkButton = PortraitToggleButton()

    init(source: PortraitSource, settings: PortraitSettings, onCopy: @escaping (PortraitSettings) -> Void) {
        self.source = source
        self.settings = settings
        self.onCopy = onCopy
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let layout = PortraitCapture.layout(pageWidth: Double(source.pointSize.width), pageHeight: Double(source.pointSize.height))
        // Never narrower than the controls under it.
        let fit = max(min(Metrics.maxPreview.width / CGFloat(layout.width), Metrics.maxPreview.height / CGFloat(layout.height)),
                      280 / CGFloat(layout.width))
        let shown = NSSize(width: (CGFloat(layout.width) * fit).rounded(), height: (CGFloat(layout.height) * fit).rounded())

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.setAccessibilityLabel("Portrait capture preview")

        slider.percentage = settings.colorPercentage
        slider.onChange = { [weak self] value in
            self?.settings.colorPercentage = value
            self?.settings.background = .color
        }
        slider.setAccessibilityLabel("Background colour")

        websiteButton.fill = PortraitRenderer.color(for: PortraitSettings(background: .website, colorPercentage: 0, showsWatermark: true),
                                                    website: source.websiteColor)
        websiteButton.toolTip = "Use Website Color"
        websiteButton.setAccessibilityLabel("Use Website Color")
        websiteButton.target = self
        websiteButton.action = #selector(useWebsiteColor(_:))

        wallpaperButton.image = source.wallpaper
        wallpaperButton.fill = .black
        wallpaperButton.toolTip = "Use Desktop Wallpaper"
        wallpaperButton.setAccessibilityLabel("Use Desktop Wallpaper")
        wallpaperButton.target = self
        wallpaperButton.action = #selector(useWallpaper(_:))

        watermarkButton.toolTip = "Show Watermark"
        watermarkButton.setAccessibilityLabel("Show Watermark")
        watermarkButton.target = self
        watermarkButton.action = #selector(toggleWatermark(_:))

        let copy = PortraitPushButton(title: "Copy", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                                      target: self, action: #selector(copyPicture(_:)))
        copy.imagePosition = .imageLeading
        copy.bezelStyle = .push
        copy.keyEquivalent = "\r"

        let controls = NSStackView(views: [slider, websiteButton, wallpaperButton, watermarkButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        let footer = NSStackView(views: [controls, copy])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.distribution = .fill

        let stack = NSStackView(views: [preview, footer])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Metrics.padding, left: Metrics.padding, bottom: Metrics.padding, right: Metrics.padding)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: shown.width),
            preview.heightAnchor.constraint(equalToConstant: shown.height),
            footer.widthAnchor.constraint(equalTo: preview.widthAnchor),
            slider.heightAnchor.constraint(equalToConstant: Metrics.sliderHeight),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        for button in [websiteButton, wallpaperButton, watermarkButton] as [NSView] {
            button.widthAnchor.constraint(equalToConstant: Metrics.buttonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Metrics.buttonSize).isActive = true
        }
        view = stack
        settingsChanged()
    }

    private func settingsChanged() {
        slider.isSelected = settings.background == .color
        websiteButton.isSelected = settings.background == .website
        wallpaperButton.isSelected = settings.background == .wallpaper
        watermarkButton.isOn = settings.showsWatermark
        let scale = min(source.pixelScale, Metrics.previewPixels / max(source.pointSize.width, 1))
        if let image = PortraitRenderer.render(source, settings: settings, scale: max(scale, 0.25)) {
            preview.image = NSImage(cgImage: image, size: .zero)
        }
    }

    @objc private func useWebsiteColor(_ sender: Any?) { settings.background = .website }
    @objc private func useWallpaper(_ sender: Any?) { settings.background = .wallpaper }
    @objc private func toggleWatermark(_ sender: Any?) { settings.showsWatermark.toggle() }
    @objc private func copyPicture(_ sender: Any?) { onCopy(settings) }
}

/// The colour slider: Arc's nine colours as a rounded gradient track, with a knob.
final class PaletteSlider: NSView {
    var percentage: Double = 0 { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: (bounds.height - 12) / 2)
        let colors = PortraitCapture.palette.map(PortraitRenderer.paletteColor)
        let path = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        NSGradient(colors: colors)?.draw(in: path, angle: 0)
        NSColor.black.withAlphaComponent(0.1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let x = track.minX + track.height / 2 + CGFloat(percentage) * (track.width - track.height)
        let knob = NSRect(x: x - 9, y: bounds.midY - 9, width: 18, height: 18)
        let knobPath = NSBezierPath(ovalIn: knob)
        PortraitRenderer.sliderColor(at: percentage).setFill()
        knobPath.fill()
        NSColor.white.setStroke()
        knobPath.lineWidth = isSelected ? 3 : 2
        knobPath.stroke()
    }

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inset: CGFloat = 7
        let value = Double(min(max((point.x - inset) / max(bounds.width - 2 * inset, 1), 0), 1))
        percentage = value
        onChange?(value)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { percentage }
}

/// A round swatch (Arc's `CircularSelectionButton`): a colour or an image, ringed when selected.
final class PortraitCircleButton: NSButton {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }

    convenience init() {
        self.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(ovalIn: circle)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fill.setFill()
        circle.fill()
        if let image {
            let side = max(circle.width / max(image.size.width, 1), circle.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * side, height: image.size.height * side)
            image.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
}

/// The watermark toggle (Arc's `WindowScreenshotWatermarkToggle`: a 24 pt square with 6 pt
/// continuous corners on an ultra-thin material, its icon swapping for on and off). Kite dims
/// the icon when off.
final class PortraitToggleButton: NSButton {
    var isOn = true { didSet { alphaValue = isOn ? 1 : 0.4; state = isOn ? .on : .off } }

    convenience init() {
        self.init(frame: .zero)
        title = ""
        bezelStyle = .smallSquare
        isBordered = false
        setButtonType(.toggle)
        image = NSImage(systemSymbolName: "signature", accessibilityDescription: "Watermark")
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PortraitPushButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}
