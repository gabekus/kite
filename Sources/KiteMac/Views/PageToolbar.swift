import AppKit
import KiteCore
import Observation

/// View → Show Toolbar: Arc 1.169's bar across the top of the content card (measured
/// on the Mac): back, forward and reload on the left, the site's host in the middle,
/// Site Controls and Split View on the right, and a hairline under it. While it's on,
/// the sidebar drops its navigation buttons and URL field.
@MainActor
final class PageToolbar: NSView {
    enum Metrics {
        static let height: CGFloat = 32
        /// The bar plus its divider: how far the page moves down.
        static let inset: CGFloat = height + 1
        static let buttonPitch: CGFloat = 37
        /// The first icon's left edge is 15.5 from the card's; a 13pt icon centred in a 37pt slot.
        static let leading: CGFloat = 15.5 - (buttonPitch - 13) / 2
        /// The last icon's right edge is 14 from the card's; a 14pt icon centred in a 37pt slot.
        static let trailing: CGFloat = 14 - (buttonPitch - 14) / 2
        /// Arc's host group sits 11pt left of the card's centre.
        static let centerOffset: CGFloat = -11
        static let iconSize: CGFloat = 13
        static let fontSize: CGFloat = 13
        // Greys tuned so a capture of Kite reads like Arc's: bar #2D2D2D, divider #3B3B3B,
        // icons #C3C3C3 (disabled #6C6C6C), host #D2D2D2.
        static let background = grey(0x24)
        static let divider = grey(0x2C)
        static let enabled = grey(0xB8)
        static let disabled = grey(0x59)
        static let text = grey(0xC8)
        static let siteControlsSize: CGFloat = 16
        /// Room kept clear on each side of the centred address: the three navigation buttons plus
        /// a gap (the right side, Site Controls and Split View, is narrower). Kite's, not measured.
        static let urlInset: CGFloat = leading + 3 * buttonPitch + 12
        /// Split View's symbol, stretched to this box (SwiftUI's `.resizable()`).
        static let splitViewSize = NSSize(width: 14, height: 14.5)

        static func grey(_ level: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(level) / 255, green: CGFloat(level) / 255, blue: CGFloat(level) / 255, alpha: 1)
        }
    }

    /// Builds the menu for a right-click (or ⌃-click) anywhere on the bar; nil for none.
    var contextMenu: (() -> NSMenu?)?
    /// Opens Site Controls under the button.
    var showSiteControls: ((NSView) -> Void)?
    /// Chrome's install icon after the address, for an installable page; nil in incognito.
    var installApp: ((NSView) -> Void)? { didSet { update() } }

    private let store: BrowserStore
    private let actions: SidebarActions
    private let back = PageToolbar.symbolButton("arrow.left", "Back")
    private let forward = PageToolbar.symbolButton("arrow.right", "Forward")
    private let reload = PageToolbar.symbolButton("arrow.clockwise", "Reload")
    private let siteControls = PageToolbar.symbolButton("slider.horizontal.3", "Site Control Center", pointSize: 8, weight: .semibold)
    /// Site Controls' 16pt rounded frame around its symbol. Clicks on it are the button's.
    private let siteControlsRing = PassthroughView()
    private let splitView = PageToolbar.symbolButton("rectangle.split.2x1", "Add Split View")
    private let address = ToolbarAddressButton()
    private let install = SymbolButton(symbol: "desktopcomputer.and.arrow.down", pointSize: 12, weight: .semibold)
    #if canImport(CEFBridge)
    /// Pinned extensions and the extensions menu; nil where extensions don't run (incognito, WebKit).
    private let extensions: ToolbarExtensionItems?
    #endif
    private var defaultsObserver: NSObjectProtocol?
    private var hiddenButtons: Set<ChromeButton> = []

    #if canImport(CEFBridge)
    init(store: BrowserStore, actions: SidebarActions, extensions: ExtensionsSelection?) {
        self.store = store
        self.actions = actions
        self.extensions = extensions.map { ToolbarExtensionItems(selection: $0) }
        super.init(frame: .zero)
        setUp()
    }
    #else
    init(store: BrowserStore, actions: SidebarActions) {
        self.store = store
        self.actions = actions
        super.init(frame: .zero)
        setUp()
    }
    #endif

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static func symbolButton(_ symbol: String, _ label: String, pointSize: CGFloat = Metrics.iconSize,
                                     weight: NSFont.Weight = .medium) -> SymbolButton {
        let button = SymbolButton(symbol: symbol, pointSize: pointSize, weight: weight, label: label)
        button.opacity = 1
        // Not dimmed when disabled: Arc's disabled grey is the whole change.
        button.disabledOpacity = 1
        button.tint = Metrics.enabled
        button.toolTip = label
        return button
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = Metrics.background.cgColor
        divider.backgroundColor = Metrics.divider.cgColor
        layer?.addSublayer(divider)

        back.action = { [weak self] in self?.actions.goBack() }
        forward.action = { [weak self] in self?.actions.goForward() }
        reload.action = { [weak self] in self?.actions.reloadButton() }
        siteControls.action = { [weak self] in
            guard let self else { return }
            self.showSiteControls?(self.siteControls)
        }
        siteControlsRing.wantsLayer = true
        siteControlsRing.layer?.cornerRadius = 4
        siteControlsRing.layer?.cornerCurve = .continuous
        siteControlsRing.layer?.borderWidth = 1.25
        splitView.customImage = PageToolbar.splitViewImage()
        splitView.action = { [weak self] in self?.actions.addSplitView() }
        address.action = { [weak self] in
            guard let self else { return }
            self.store.showCommandBar(self.store.state.selectedTab == nil ? .newTab : .editCurrent)
        }
        install.hoverWash = (ArcMetrics.Sidebar.hoverFill, 6)
        install.opacity = 0.8
        install.hoverOpacity = 1
        install.tint = Metrics.enabled
        install.action = { [weak self] in
            guard let self else { return }
            self.installApp?(self.install)
        }
        for view in [back, forward, reload, siteControls, splitView, address, install] as [NSView] { addSubview(view) }
        siteControls.addSubview(siteControlsRing)
        #if canImport(CEFBridge)
        if let extensions {
            extensions.onSizeChange = { [weak self] in self?.needsLayout = true }
            addSubview(extensions)
        }
        #endif
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readDefaults() }
        }
        readDefaults()
        observe()
    }

    private let divider = CALayer()

    /// Split View's symbol stretched to 14×14.5 (SwiftUI's `.resizable()`; semibold here draws closest to SwiftUI's
    /// medium once stretched, measured on screen), where SwiftUI puts that frame in its
    /// 37×32 slot: centred, the half-pixel top rounded down to the pixel (9pt, measured on screen).
    private static func splitViewImage() -> NSImage? {
        let size = Metrics.splitViewSize, slot = NSSize(width: Metrics.buttonPitch, height: Metrics.height)
        guard let symbol = symbolImage("rectangle.split.2x1", pointSize: Metrics.iconSize, weight: .semibold, box: size, placement: .stretch) else { return nil }
        let image = NSImage(size: slot, flipped: true) { _ in
            symbol.draw(in: NSRect(x: (slot.width - size.width) / 2, y: 9, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Settings → Advanced → Toolbar hides buttons (their commands still work from the menu bar), and Kite menu →
    /// Show Full URL in Toolbar (Arc: "Show full URL when Toolbar is enabled") shows the whole URL.
    private func readDefaults() {
        let defaults = UserDefaults.standard
        let hidden = Set([ChromeButton.back, .forward, .reload, .siteControls, .splitView].filter { defaults.bool(forKey: $0.hiddenKey) })
        let full = ToolbarURL.showsFullURL(in: defaults)
        guard hidden != hiddenButtons || full != address.showsFullURL else { return }
        hiddenButtons = hidden
        address.showsFullURL = full
        update()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    /// The buttons' states and the address, from the selected tab.
    private func update() {
        let selected = store.state.selectedTab
        let page = selected.flatMap { store.pages[$0.id] } ?? PageStatus()
        func set(_ button: SymbolButton, enabled: Bool) {
            button.isEnabled = enabled
            button.tint = enabled ? Metrics.enabled : Metrics.disabled
        }
        set(back, enabled: page.canGoBack)
        set(forward, enabled: page.canGoForward)
        reload.symbol = page.isLoading ? "xmark" : "arrow.clockwise"
        set(reload, enabled: selected != nil)
        let hasSite = SiteControls.applies(to: selected?.url)
        set(siteControls, enabled: hasSite)
        siteControlsRing.layer?.borderColor = (hasSite ? Metrics.enabled : Metrics.disabled).cgColor
        address.url = selected?.url
        let offer = installApp == nil ? nil : WebAppInstallOffers.shared.offer(for: selected?.id)
        install.toolTip = offer.map { "Install \($0.name)" }
        install.setAccessibilityLabel(install.toolTip)
        install.isHidden = offer == nil
        back.isHidden = hiddenButtons.contains(.back)
        forward.isHidden = hiddenButtons.contains(.forward)
        reload.isHidden = hiddenButtons.contains(.reload)
        siteControls.isHidden = hiddenButtons.contains(.siteControls)
        splitView.isHidden = hiddenButtons.contains(.splitView)
        needsLayout = true
    }

    /// SwiftUI puts views on the device's pixel grid, a half pixel rounding up.
    private func snap(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    override func layout() {
        super.layout()
        let h = Metrics.height, pitch = Metrics.buttonPitch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 0, y: h, width: bounds.width, height: 1)
        CATransaction.commit()

        var x = Metrics.leading
        for button in [back, forward, reload] where !button.isHidden {
            button.frame = CGRect(x: x, y: 0, width: pitch, height: h)
            x += pitch
        }
        var end = bounds.width - Metrics.trailing
        if !splitView.isHidden {
            end -= pitch
            splitView.frame = CGRect(x: end, y: 0, width: pitch, height: h)
        }
        if !siteControls.isHidden {
            end -= pitch
            siteControls.frame = CGRect(x: end, y: 0, width: pitch, height: h)
            let ring = Metrics.siteControlsSize
            siteControlsRing.frame = CGRect(x: (pitch - ring) / 2, y: (h - ring) / 2, width: ring, height: ring)
        }
        #if canImport(CEFBridge)
        if let extensions {
            // Site Controls' icon sits 10.5pt into its 37pt slot; Arc leaves 12pt to it.
            end -= ToolbarExtensionItems.Metrics.siteControlsGap - (pitch - Metrics.siteControlsSize) / 2
            let width = extensions.fittingWidth
            end -= width
            extensions.frame = CGRect(x: end, y: 0, width: width, height: h)
        }
        #endif

        // The address and the install icon, centred between the insets and 11pt left; a long URL truncates.
        let available = bounds.width - 2 * Metrics.urlInset
        let installWidth: CGFloat = install.isHidden ? 0 : 2 + 24
        let addressWidth = min(address.naturalWidth, max(available - installWidth, 0))
        let groupX = snap(Metrics.urlInset + (available - addressWidth - installWidth) / 2 + Metrics.centerOffset)
        address.frame = CGRect(x: groupX, y: snap((h - address.height) / 2), width: addressWidth, height: address.height)
        install.frame = CGRect(x: groupX + addressWidth + 2, y: (h - 24) / 2, width: 24, height: 24)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?() ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return super.rightMouseDown(with: event) }
        // Nil under the test hook too, which has already logged the menu.
        if let menu = contextMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if canImport(CEFBridge)
        // SwiftUI's onAppear: the extensions are read again whenever the bar comes back.
        if window != nil { extensions?.refresh() }
        #endif
    }
}

/// The toolbar's address: a link symbol and the page's host (or full URL), clicking into the command bar.
/// Transparent while there's no page.
@MainActor
final class ToolbarAddressButton: NSView {
    var action: () -> Void = {}
    var url: URL? { didSet { if url != oldValue { apply() } } }
    var showsFullURL = false { didSet { if showsFullURL != oldValue { apply() } } }
    let height: CGFloat

    private let icon = SidebarImageView()
    private let label = SidebarLabel(size: PageToolbar.Metrics.fontSize, opacity: 1)
    private var pressed = false
    private static let iconPointSize: CGFloat = 11
    private static let spacing: CGFloat = 5

    override init(frame: NSRect) {
        label.textColor = PageToolbar.Metrics.text
        height = label.lineHeight
        super.init(frame: frame)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = PageToolbar.Metrics.enabled
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The symbol's layout size: SwiftUI sizes an `Image` of a symbol by its alignment rect.
    private var iconSize: NSSize { rawSymbol("link", pointSize: Self.iconPointSize, weight: .medium)?.alignmentRect.size ?? .zero }

    var naturalWidth: CGFloat { iconSize.width + Self.spacing + label.naturalWidth }

    private func apply() {
        let text = ToolbarURL.text(for: url, full: showsFullURL)
        label.stringValue = text
        setAccessibilityLabel(text)
        alphaValue = url == nil ? 0 : 1
        needsLayout = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        let box = NSSize(width: iconSize.width, height: bounds.height)
        icon.image = symbolImage("link", pointSize: Self.iconPointSize, weight: .medium, box: box, placement: .center)
        icon.frame = CGRect(origin: .zero, size: box)
        let x = box.width + Self.spacing
        label.place(textRect: CGRect(x: x, y: 0, width: max(bounds.width - x, 0), height: bounds.height))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, url != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard url != nil, super.hitTest(point) != nil else { return nil }
        return self
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// A view that draws and never takes a click: its button gets it.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
