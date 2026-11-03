import AppKit
import KiteCore

/// Small AppKit pieces the sidebar's rows are built from: a rounded fill, a one-line label, symbol
/// buttons, a favicon and closure-driven menus. Each is layer-backed, redraws only when a property it
/// shows changes, and does no work while nothing changes (no timers, no per-frame callbacks).
private typealias M = ArcMetrics.Sidebar

/// A view whose subviews use top-left coordinates, like the SwiftUI layouts the rows replace.
class SidebarFlippedView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A flipped container that takes no presses itself: they go to the row under it, while its controls
/// (buttons) still get their own.
class SidebarPassthroughView: SidebarFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

/// An image that takes no presses (SwiftUI's `Image` has no gesture of its own).
final class SidebarImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSView {
    /// Whether this view draws in dark mode.
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// A rounded rectangle with Arc's continuous corners, filled with a colour that may depend on the
/// appearance. It takes no clicks.
final class FillView: NSView {
    var cornerRadius: CGFloat = M.cornerRadius { didSet { layer?.cornerRadius = cornerRadius } }
    /// The fill for the current appearance (asked again when the appearance changes).
    var fill: (Bool) -> NSColor = { _ in .clear } { didSet { applyFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyFill() }
    override func viewDidChangeEffectiveAppearance() { applyFill() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyFill() {
        let color = fill(isDarkAppearance)
        layer?.backgroundColor = color.alphaComponent == 0 ? nil : color.cgColor
    }
}

/// The sidebar's white wash (SwiftUI's `ChromeFill`): `strength` over a dark theme, about 3.5 times
/// that (at most 0.7) over a light one.
func chromeFill(_ strength: Double) -> (Bool) -> NSColor {
    { dark in NSColor.white.withAlphaComponent(dark ? strength : min(strength * 3.5, 0.7)) }
}

/// A tab or split row's pill (SwiftUI's `TabPillFill`).
func tabPillFill(selected: Bool, hovered: Bool) -> (Bool) -> NSColor {
    { dark in
        if selected { return NSColor.white.withAlphaComponent(dark ? M.selectedFill : M.selectedFillLight) }
        if hovered {
            return dark ? NSColor.white.withAlphaComponent(M.hoverFill)
                : NSColor(srgbRed: 0.055, green: 0.059, blue: 0.063, alpha: M.hoverFillLight)
        }
        return .clear
    }
}

/// One line of text in the sidebar's primary colour, cut off at the end. Drawn like SwiftUI's `Text`:
/// the line box is the font's ascent plus descent plus leading, rounded up to whole points.
final class SidebarLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight = .regular, opacity: Double = M.tabTextOpacity) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: size, weight: weight)
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        alphaValue = opacity
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// The width the whole string needs on one line.
    var naturalWidth: CGFloat { ceil(attributedStringValue.size().width) }

    /// SwiftUI's line height for this font.
    var lineHeight: CGFloat {
        guard let font else { return 17 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// NSTextField's cell draws its text 2pt in from each side; the frame reaches past the text's own
    /// box by that much so the glyphs land where SwiftUI's would.
    static let cellInset: CGFloat = 2

    /// Lays the label out with its text box (not the cell) at `rect`.
    func place(textRect rect: CGRect) {
        frame = rect.insetBy(dx: -Self.cellInset, dy: 0)
    }
}

/// A clickable SF Symbol (SwiftUI's `Button { Image(systemName:) }.buttonStyle(.plain)`): drawn centred in
/// its frame at `opacity`, with a tooltip and an accessibility label. Optionally with a hover wash.
final class SymbolButton: NSView {
    var action: () -> Void = {}
    var symbol: String { didSet { if symbol != oldValue { updateImage() } } }
    var pointSize: CGFloat { didSet { if pointSize != oldValue { updateImage() } } }
    var weight: NSFont.Weight { didSet { if weight != oldValue { updateImage() } } }
    var opacity: Double = 0.6 { didSet { applyOpacity() } }
    /// Opacity while the pointer is on it; nil keeps `opacity`.
    var hoverOpacity: Double? { didSet { applyOpacity() } }
    /// A wash behind the symbol while hovered (the address field's buttons), with its corner radius.
    var hoverWash: (strength: Double, cornerRadius: CGFloat)? { didSet { applyHover() } }
    var tint: NSColor? { didSet { imageView.contentTintColor = tint ?? .labelColor } }
    var isEnabled = true { didSet { applyOpacity() } }
    var disabledOpacity: Double = 0.25
    private(set) var isHovered = false

    private let imageView = SidebarImageView()
    private let wash = FillView()
    private var tracking: NSTrackingArea?
    private var pressed = false

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, label: String? = nil) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: .zero)
        wantsLayer = true
        wash.isHidden = true
        addSubview(wash)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if let label { setAccessibilityLabel(label) }
        updateImage()
        applyOpacity()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // Like SwiftUI's Button, it takes the click that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        wash.frame = bounds
        imageView.frame = bounds
        if imageView.image?.size != bounds.size { updateImage() }
    }

    /// Shown instead of `symbol` when set (a template image, tinted like the symbol).
    var customImage: NSImage? { didSet { updateImage() } }

    private func updateImage() {
        let box = bounds.size == .zero ? NSSize(width: 24, height: 24) : bounds.size
        if let customImage { return imageView.image = place(customImage, in: box, placement: .center) }
        imageView.image = symbolImage(symbol, pointSize: pointSize, weight: weight, box: box, placement: .center)
    }

    /// SwiftUI's `.opacity` on the button: the symbol and its hover wash together.
    private func applyOpacity() {
        let base = isHovered ? (hoverOpacity ?? opacity) : opacity
        alphaValue = isEnabled ? base : disabledOpacity
    }

    private func applyHover() {
        if let hoverWash {
            wash.cornerRadius = hoverWash.cornerRadius
            wash.fill = chromeFill(hoverWash.strength)
            wash.isHidden = !isHovered
        } else {
            wash.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds, not `.inVisibleRect`: since macOS 14 views don't clip, so a visible-rect area on a view
        // near the window's root can span the whole window.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyOpacity()
        applyHover()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}

/// A favicon (SwiftUI's `FaviconView`): the page's icon, a symbol for Kite's own pages, or a globe,
/// clipped to a continuous rounded square of 19% of its side.
final class FaviconImageView: NSView {
    private let imageView = SidebarImageView()
    private var url: URL?
    private var symbol: String?
    private var loading: Task<Void, Never>?
    let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = side * 0.19
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    func show(tab: BrowserTab) { show(page: tab.url, icon: tab.faviconURL) }

    func show(page: URL?, icon: URL?) {
        let source = FaviconSource(page: page, icon: icon)
        guard source.url != url || source.symbol != symbol || imageView.image == nil else { return }
        url = source.url
        symbol = source.symbol
        loading?.cancel()
        loading = nil
        if let symbol {
            // SwiftUI's `.resizable().scaledToFit()`.
            setSymbol(symbol, opacity: 0.8, scaling: .scaleProportionallyUpOrDown)
        } else if let url, let image = FaviconCache.shared.cached(url) {
            setImage(image)
        } else {
            // SwiftUI's `.resizable()`: stretched to the whole square.
            setSymbol("globe", opacity: 0.6, scaling: .scaleAxesIndependently)
            guard let url else { return }
            loading = Task { [weak self] in
                guard let image = await FaviconCache.shared.image(for: url), !Task.isCancelled,
                      let self, self.url == url else { return }
                self.setImage(image)
            }
        }
    }

    private func setSymbol(_ name: String, opacity: Double, scaling: NSImageScaling) {
        let placement: SymbolPlacement = scaling == .scaleAxesIndependently ? .stretch : .fit
        imageView.image = symbolImage(name, box: NSSize(width: side, height: side), placement: placement)
        imageView.imageScaling = .scaleNone
        imageView.alphaValue = opacity
    }

    private func setImage(_ image: NSImage) {
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.alphaValue = 1
    }
}

/// What a favicon shows: the page's reported icon, else the site's /favicon.ico, or Kite's symbol for
/// its own pages. Shared with SwiftUI's `FaviconView`.
struct FaviconSource {
    var url: URL?
    var symbol: String?

    init(page: URL?, icon: URL?) {
        switch InternalPage(page) {
        case .history: symbol = "clock.arrow.circlepath"
        case .archive: symbol = "archivebox"
        case .siteSettings, .settings: symbol = "gearshape"
        case .searchEngines: symbol = "magnifyingglass"
        case nil: break
        }
        if let icon {
            url = icon
        } else if let page, let scheme = page.scheme, ["http", "https"].contains(scheme), let host = page.host() {
            url = URL(string: "\(scheme)://\(host)/favicon.ico")
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, enabled: enabled, checked: checked, handler: handler)
        addItem(item)
        return item
    }

    /// A line of text that can't be chosen (SwiftUI's `Text` in a menu).
    func addLabel(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addSeparator() { addItem(.separator()) }

    @discardableResult
    func addSubmenu(_ title: String, enabled: Bool = true, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        item.isEnabled = enabled
        addItem(item)
        return item
    }

    /// A section header (SwiftUI's `Section("…")` in a menu).
    func addSectionHeader(_ title: String) {
        if #available(macOS 14.0, *) {
            addItem(.sectionHeader(title: title))
        } else {
            addLabel(title)
        }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Symbols side by side as one template image, `spacing` apart (negative overlaps), centred on one line,
/// like SwiftUI's `HStack(spacing:) { Image(systemName:)… }`.
@MainActor func symbolRow(_ symbols: [(name: String, size: CGFloat, weight: NSFont.Weight)], spacing: CGFloat) -> NSImage? {
    let images = symbols.compactMap {
        NSImage(systemSymbolName: $0.name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: $0.size, weight: $0.weight))
    }
    guard images.count == symbols.count, !images.isEmpty else { return nil }
    let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(images.count - 1)
    let height = images.map(\.size.height).max() ?? 0
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        var x: CGFloat = 0
        for part in images {
            part.draw(in: NSRect(x: x, y: (height - part.size.height) / 2, width: part.size.width, height: part.size.height))
            x += part.size.width + spacing
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// How a symbol sits in its box, after SwiftUI's `Image(systemName:)`: centred at its own size (a fixed
/// font), fitted (`.resizable().scaledToFit()`) or stretched to fill it (`.resizable()`). SwiftUI lays a
/// symbol out by its glyph's bounds (the image's alignment rect), not the image's padded size, so these do
/// too. NSImageView would centre the padded image and never scale a symbol.
enum SymbolPlacement {
    case center, fit, stretch
}

/// A template image `box` big with the symbol drawn in it as SwiftUI would place it.
@MainActor private var symbolImages: [String: NSImage] = [:]

@MainActor func symbolImage(_ name: String, pointSize: CGFloat = 0, weight: NSFont.Weight = .regular, box: NSSize,
                 placement: SymbolPlacement) -> NSImage? {
    // Drawn once per symbol, size and box: rows and buttons ask again whenever they're reconfigured.
    let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(box.width)x\(box.height)|\(placement)"
    if let cached = symbolImages[key] { return cached }
    let image = makeSymbolImage(name, pointSize: pointSize, weight: weight, box: box, placement: placement)
    if let image { symbolImages[key] = image }
    return image
}

@MainActor private func makeSymbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, box: NSSize,
                                        placement: SymbolPlacement) -> NSImage? {
    guard var symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    if pointSize > 0, let configured = symbol.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) {
        symbol = configured
    }
    if placement == .center, let at = SymbolOrigins.measured[.init(name, pointSize, weight, box.width, box.height)] {
        let size = symbol.size
        let out = NSImage(size: box, flipped: false) { _ in
            symbol.draw(in: NSRect(x: at.x, y: box.height - at.top - size.height, width: size.width, height: size.height))
            return true
        }
        out.isTemplate = true
        return out
    }
    return place(symbol, in: box, placement: placement)
}

/// Where SwiftUI draws each SF Symbol the sidebar uses in its frame: the symbol image's origin (x, and top from
/// the frame's top), in points. SwiftUI lays a symbol out by metrics AppKit doesn't expose and rounds them to
/// the pixel grid in ways no single rule reproduced (measured on 2 Nov 2026, macOS 15, at 2x: each symbol
/// rendered by ImageRenderer in its frame, then the AppKit drawing searched in quarter points for the closest
/// match; the max channel delta left, all glyph-edge anti-aliasing, is noted). ImageRenderer doesn't round
/// every symbol the way a window does: the header's were then checked against captures of the SwiftUI sidebar
/// on screen, and the ones that landed half a point (or a quarter) high there carry that correction. Symbols
/// not here fall back to `place(_:in:placement:)`'s rule.
enum SymbolOrigins {
    struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, _ width: CGFloat, _ height: CGFloat) {
            self.name = name
            self.size = size
            self.weight = weight.rawValue
            self.width = width
            self.height = height
        }
    }

    static let measured: [Key: (x: CGFloat, top: CGFloat)] = [
        Key("xmark", 9.0, .bold, 24.0, 24.0): (7.5, 7.0), // max 66
        Key("xmark", 9.0, .bold, 16.0, 16.0): (3.5, 3.0), // max 66
        Key("arrow.uturn.backward", 10.0, .semibold, 24.0, 24.0): (6.5, 6.0), // max 62
        Key("stop.fill", 8.0, .bold, 24.0, 24.0): (7.5, 7.75), // max 73
        Key("plus", 14.0, .medium, 18.0, 18.0): (2.0, 2.0), // max 46
        Key("folder", 14.0, .regular, 18.0, 18.0): (-0.5, 1.0), // max 40
        Key("folder.fill", 14.0, .regular, 18.0, 18.0): (-0.5, 1.0), // max 35
        Key("sidebar.left", 15.0, .regular, 32.0, 32.0): (5.5, 8.0), // max 50
        Key("arrow.left", 15.0, .regular, 32.0, 32.0): (7.0, 9.0), // max 53 (on screen: +0.5)
        Key("arrow.right", 15.0, .regular, 32.0, 32.0): (7.0, 9.0), // max 55 (on screen: +0.5)
        Key("arrow.left", 15.0, .regular, 28.0, 28.0): (5.0, 7.0), // max 53 (inferred from its neighbours on screen: +0.5)
        Key("arrow.right", 15.0, .regular, 28.0, 28.0): (5.0, 7.0), // max 55 (inferred from its neighbours on screen: +0.5)
        Key("arrow.clockwise", 15.0, .regular, 32.0, 32.0): (8.0, 7.0), // max 80 (on screen: +0.25)
        Key("arrow.clockwise.circle", 15.0, .regular, 32.0, 32.0): (7.0, 7.75), // max 66 (inferred from its neighbours on screen: +0.25)
        Key("xmark", 15.0, .regular, 32.0, 32.0): (8.0, 9.0), // max 51 (inferred from its neighbours on screen: +0.25)
        Key("chevron.down", 9.0, .semibold, 16.0, 32.0): (3.0, 12.0), // max 59
        Key("ellipsis", 15.0, .regular, 28.0, 28.0): (5.5, 11.25), // max 67
        Key("ellipsis", 15.0, .regular, 32.0, 32.0): (7.5, 13.25), // max 67
        Key("moon", 11.0, .semibold, 24.0, 24.0): (5.5, 6.0), // max 53 (on screen: +0.5)
        Key("moon.fill", 11.0, .semibold, 24.0, 24.0): (5.5, 5.5), // max 94 (inferred from its neighbours on screen: +0.5)
        Key("slider.horizontal.3", 12.0, .semibold, 30.0, 30.0): (7.5, 8.5), // max 83 (on screen: +0.5)
        Key("desktopcomputer.and.arrow.down", 12.0, .semibold, 30.0, 30.0): (6.5, 6.5), // max 36 (inferred from its neighbours on screen: +0.5)
        Key("puzzlepiece.extension", 12.0, .semibold, 30.0, 30.0): (6.5, 8.0), // max 81 (on screen: +0.5)
        Key("chevron.right", 9.0, .bold, 26.0, 26.0): (9.5, 7.0), // max 42
    ]
}

/// `image` (a template) drawn into a `box`-sized template image by its alignment rect.
@MainActor func place(_ image: NSImage, in box: NSSize, placement: SymbolPlacement) -> NSImage {
    let size = image.size
    var align = image.alignmentRect
    if align.isEmpty { align = NSRect(origin: .zero, size: size) }
    var sx: CGFloat = 1, sy: CGFloat = 1
    switch placement {
    case .center: break
    case .fit:
        // A resizable symbol is scaled by its glyph's ink, not its padded image.
        align = inkBounds(image)
        let s = min(box.width / align.width, box.height / align.height)
        sx = s; sy = s
    case .stretch:
        align = inkBounds(image)
        sx = box.width / align.width; sy = box.height / align.height
    }
    var rect: NSRect
    if placement == .center {
        // Measured against SwiftUI's own rendering of ten sidebar symbols (ImageRenderer, 2x): across, the
        // alignment rect is centred and rounded up to the half point; down, it's centred with its baseline
        // rounded to the half point.
        let x = ((box.width - align.width) / 2 * 2).rounded(.up) / 2 - align.minX
        let baseline = ((box.height + align.height) / 2 * 2).rounded() / 2
        let bottom = baseline + align.minY
        rect = NSRect(x: x, y: box.height - bottom, width: size.width, height: size.height)
    } else {
        // The glyph's box, centred in `box`; the whole image drawn around it.
        let glyph = NSRect(x: (box.width - align.width * sx) / 2, y: (box.height - align.height * sy) / 2,
                           width: align.width * sx, height: align.height * sy)
        rect = NSRect(x: glyph.minX - align.minX * sx, y: glyph.minY - align.minY * sy, width: size.width * sx, height: size.height * sy)
    }
    let out = NSImage(size: box, flipped: false) { _ in
        image.draw(in: rect)
        return true
    }
    out.isTemplate = true
    return out
}

@MainActor private var inkCache: [ObjectIdentifier: NSRect] = [:]

/// Where `image` actually draws (non-clear pixels), in its own points: a symbol's glyph without its padding.
@MainActor func inkBounds(_ image: NSImage) -> NSRect {
    if let cached = inkCache[ObjectIdentifier(image)] { return cached }
    let scale: CGFloat = 8
    let w = Int(ceil(image.size.width * scale)), h = Int(ceil(image.size.height * scale))
    var result = NSRect(origin: .zero, size: image.size)
    if w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
       let data = rep.bitmapData {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX >= minX, maxY >= minY {
            // Bitmap rows run top down; image points run bottom up.
            result = NSRect(x: CGFloat(minX) / scale, y: CGFloat(h - 1 - maxY) / scale,
                            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }
    }
    inkCache[ObjectIdentifier(image)] = result
    return result
}

/// A symbol at its own size, as a template: for an un-framed `Image(systemName:)`, whose frame is the image and
/// whose glyph sits where the image puts it.
@MainActor func rawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    image?.isTemplate = true
    return image
}
