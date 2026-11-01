import AppKit
import KiteCore

/// Little Kite: Arc's "Little Arc". A small window with one page and no sidebar, for links
/// from other apps (when Kite menu → Open Links from Other Apps in Little Kite is on) and
/// File → New Little Kite Window (⌥⌘N). "Open in <Space>" (⌘O) moves the live page into the
/// main window as a tab in that space and closes this window; ⌘W just closes it.
///
/// Layout from Arc 1.171 (`ArcMetrics.LittleWindow`, docs/arc-visual-spec.md): traffic lights,
/// back, the URL pill (host centred, copy link), then the Open In box; the page below, edge to edge.
@MainActor
final class LittleKiteWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private typealias M = ArcMetrics.LittleWindow

    /// Where "Open in" sends the page.
    struct Destination {
        let id: UUID
        let name: String
        let theme: Theme
    }

    /// What the window needs from the main window; AppDelegate fills these in.
    struct Host {
        /// The space "Open in" names (the main window's current one), and the others for the chevron.
        var currentSpace: () -> Destination
        var spaces: () -> [Destination]
        var resolve: (String) -> URL?
        /// Moves the page into the main window as a tab in that space and brings the main window forward.
        var move: (_ page: WebPage, _ url: URL?, _ title: String?, _ spaceID: UUID) -> Void
        /// Links the page opens in a new tab or popup go to the main window.
        var openTab: (URL) -> Void
        var adoptPopup: (WebPage) -> Void
    }

    private let engine: WebEngine
    private let host: Host
    private var page: WebPage?
    private(set) var url: URL?
    private var pageTitle: String?
    private var canGoBack = false

    private let root = LittleRootView()
    private let materialView = NSVisualEffectView()
    private let themeView = ThemeView()
    private let webContainer = NSView()
    private var trafficLights: TrafficLights?
    private let backButton = NSButton()
    private let pill = LittlePillView()
    private let openIn = OpenInBox()

    /// Called once the window has closed, so the app delegate can let go of it.
    var didClose: ((LittleKiteWindowController) -> Void)?

    init(engine: WebEngine, url: URL?, host: Host) {
        self.engine = engine
        self.host = host
        self.url = url
        let window = LittleKiteWindow(
            contentRect: NSRect(origin: .zero, size: M.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.minSize = M.minSize
        window.isReleasedWhenClosed = false
        window.title = LittleKite.windowTitle(pageTitle: nil)
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        // Arc keeps one size for every Little Arc window (`LittleBrowserWindow_size`); so does this.
        if !window.setFrameUsingName(Self.frameName) { fitOnScreen(window) }
        buildViews()
        applyDestination()
        if let url { load(url) } else { pill.beginEditing(text: "") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let frameName = "LittleKiteWindow"

    /// The default size, shrunk to the screen, centred.
    private func fitOnScreen(_ window: NSWindow) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return window.center() }
        let size = NSSize(width: min(M.defaultSize.width, visible.width), height: min(M.defaultSize.height, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
    }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        window.contentView = root
        root.onLayout = { [weak self] in self?.layout() }

        materialView.material = .sidebar
        materialView.blendingMode = .behindWindow
        materialView.state = .followsWindowActiveState
        for view in [materialView, themeView] as [NSView] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        webContainer.wantsLayer = true
        webContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(webContainer)

        trafficLights = TrafficLights(window: window, host: root,
                                      center: M.trafficLightCenter, hoverArea: M.trafficLightHoverArea)

        backButton.isBordered = false
        backButton.bezelStyle = .regularSquare
        backButton.imagePosition = .imageOnly
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        backButton.toolTip = "Back"
        backButton.setAccessibilityLabel("Back")
        backButton.title = ""
        root.addSubview(backButton)

        pill.onCopy = { [weak self] in self?.copyURL(nil) }
        pill.onBeginEditing = { [weak self] in self?.url?.absoluteString ?? "" }
        pill.onCommit = { [weak self] text in
            guard let self, let url = self.host.resolve(text) else { return }
            self.load(url)
        }
        root.addSubview(pill)

        openIn.onMove = { [weak self] in self?.openInCurrentSpace(nil) }
        openIn.onChevron = { [weak self] view in self?.showSpacesMenu(from: view) }
        root.addSubview(openIn)
        updateBackButton()
    }

    private func layout() {
        let bounds = root.bounds
        let width = bounds.width
        webContainer.frame = CGRect(x: 0, y: M.toolbarHeight, width: width, height: max(0, bounds.height - M.toolbarHeight))
        page?.view.frame = webContainer.bounds
        backButton.frame = M.backButton

        let boxWidth = openIn.fittingWidth
        openIn.frame = CGRect(x: width - M.openInTrailing - boxWidth, y: M.openInY, width: boxWidth, height: M.openInHeight)
        let pillMaxX = openIn.frame.minX - M.openInGap
        pill.frame = CGRect(x: M.pillX, y: M.pillY, width: max(0, pillMaxX - M.pillX), height: M.pillHeight)
    }

    /// The window takes the theme of the space "Open in" names, like Arc's.
    private func applyDestination() {
        let destination = host.currentSpace()
        themeView.setTheme(destination.theme, animated: false)
        let appearance = NSAppearance(named: destination.theme.prefersDarkForeground ? .aqua : .darkAqua)
        window?.appearance = appearance
        openIn.spaceName = destination.name
        root.needsLayout = true
    }

    // MARK: Page

    private func load(_ url: URL) {
        self.url = url
        pill.host = LittleKite.displayHost(of: url)
        if let page {
            page.load(url)
        } else {
            let page = engine.makePage(url: url, restoring: nil)
            attach(page)
        }
    }

    private func attach(_ page: WebPage) {
        self.page = page
        page.onEvent = { [weak self] event in self?.handle(event) }
        page.view.frame = webContainer.bounds
        page.view.autoresizingMask = [.width, .height]
        webContainer.addSubview(page.view)
        page.setVisible(true)
        page.focus()
    }

    private func handle(_ event: PageEvent) {
        switch event {
        case .title(let title):
            pageTitle = title
            window?.title = LittleKite.windowTitle(pageTitle: title)
        case .url(let url):
            guard let url else { return }
            self.url = url
            pill.host = LittleKite.displayHost(of: url)
        case let .navigationState(_, canGoBack, _):
            self.canGoBack = canGoBack
            updateBackButton()
        case .openInNewTab(let url, _), .openInLinkPeek(let url):
            host.openTab(url)
        case .popup(let popup):
            host.adoptPopup(popup)
        case .closeRequested:
            close()
        case .favicon, .progress, .blockedCount, .crashed, .addExtension:
            break
        }
    }

    private func updateBackButton() {
        backButton.isEnabled = canGoBack
        backButton.alphaValue = canGoBack ? 1 : 0.4
    }

    // MARK: Commands

    @objc func goBack(_ sender: Any?) { page?.goBack() }
    @objc func goForward(_ sender: Any?) { page?.goForward() }

    @objc func reload(_ sender: Any?) {
        guard let page else { return }
        if page.isLoading { page.stopLoading() } else { page.reload() }
    }

    @objc func copyURL(_ sender: Any?) {
        guard let url else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// ⌘O and the Open In button.
    @objc func openInCurrentSpace(_ sender: Any?) {
        move(to: host.currentSpace().id)
    }

    /// File → Archive Tab (⌘W) and Close Window in a Little Kite window both just close it.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }

    /// ⌘L, like the main window's location field.
    @objc func openLocation(_ sender: Any?) { pill.beginEditing(text: url?.absoluteString ?? "") }

    private func move(to spaceID: UUID) {
        guard let page else { return NSSound.beep() }
        page.view.removeFromSuperview()
        page.onEvent = nil
        self.page = nil
        host.move(page, url, pageTitle, spaceID)
        close()
    }

    private func showSpacesMenu(from view: NSView) {
        let menu = NSMenu()
        for space in host.spaces() {
            let item = NSMenuItem(title: space.name, action: #selector(moveToSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func moveToSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        move(to: id)
    }

    /// Kite's shortcuts for this window, before the menu bar (whose commands act on the main window).
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "w": closeTab(nil)
        case "o": openInCurrentSpace(nil)
        case "[": goBack(nil)
        case "]": goForward(nil)
        case "r": reload(nil)
        case "l": openLocation(nil)
        default: return false
        }
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return canGoBack
        case #selector(openInCurrentSpace(_:)): return page != nil
        default: return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.frameName)
        if let page {
            page.onEvent = nil
            page.close()
        }
        page = nil
        didClose?(self)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }
    func windowDidExitFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }
    func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
}

/// Offers ⌘-keys to the Little Kite window before the page and the menu bar see them.
final class LittleKiteWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Top-left origin, and a hook for laying out by hand.
private final class LittleRootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - URL pill

/// Arc's command bar placeholder: a translucent pill with the host centred and a copy-link
/// button. Clicking it edits the URL in place.
private final class LittlePillView: NSView, NSTextFieldDelegate {
    private typealias M = ArcMetrics.LittleWindow

    var host = "" {
        didSet { hostLabel.stringValue = host }
    }
    var onCopy: (() -> Void)?
    var onCommit: ((String) -> Void)?
    /// The text to start editing with.
    var onBeginEditing: (() -> String)?

    private let hostLabel = PassthroughLabel(labelWithString: "")
    private let field = NSTextField()
    private let copyButton = NSButton()
    private var hovered = false {
        didSet { updateFill() }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = M.pillCornerRadius
        layer?.cornerCurve = .continuous

        hostLabel.font = .systemFont(ofSize: M.hostFontSize, weight: .medium)
        hostLabel.alignment = .center
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.textColor = .labelColor
        addSubview(hostLabel)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: M.hostFontSize)
        field.placeholderString = "Search or Enter URL…"
        field.delegate = self
        field.isHidden = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Address")
        addSubview(field)

        copyButton.isBordered = false
        copyButton.bezelStyle = .regularSquare
        copyButton.imagePosition = .imageOnly
        copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy Link"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        addSubview(copyButton)
        copyButton.setAccessibilityLabel("Copy Link")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Address")
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = M.pillButtonSize
        copyButton.frame = CGRect(x: bounds.width - M.pillTrailingInset - size, y: (bounds.height - size) / 2, width: size, height: size)
        let leading = M.pillLeadingInset
        let trailing = copyButton.frame.minX - 8
        let labelHeight: CGFloat = 16
        // Centred between the pill's leading inset and its buttons, as Arc's host text is.
        hostLabel.frame = CGRect(x: leading, y: (bounds.height - labelHeight) / 2, width: max(0, trailing - leading), height: labelHeight)
        field.frame = hostLabel.frame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func updateFill() {
        // Arc's colour assets: near-white in dark, near-black in light, a little stronger on hover.
        let color = isDark
            ? NSColor(displayP3Red: 0.98, green: 0.984, blue: 1, alpha: hovered ? M.pillFillDarkHovered : M.pillFillDark)
            : NSColor(displayP3Red: 0.055, green: 0.059, blue: 0.063, alpha: hovered ? M.pillFillLightHovered : M.pillFillLight)
        layer?.backgroundColor = color.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { beginEditing(text: onBeginEditing?() ?? host) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    func beginEditing(text: String) {
        field.stringValue = text
        field.isHidden = false
        hostLabel.isHidden = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing() {
        field.isHidden = true
        hostLabel.isHidden = false
    }

    func controlTextDidEndEditing(_ notification: Notification) { endEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            endEditing()
            window?.makeFirstResponder(nil)
            if !text.isEmpty { onCommit?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    @objc private func copyClicked() { onCopy?() }
}

// MARK: - Open In

/// "Open in <Space> ⌘O" and a chevron for the other spaces, in one bordered box (Arc's
/// LittleBrowserMoveButton and the "reveals more 'Open In' destinations" button).
private final class OpenInBox: NSView {
    private typealias M = ArcMetrics.LittleWindow

    var spaceName = "" {
        didSet { updateTitle() }
    }
    var onMove: (() -> Void)?
    var onChevron: ((NSView) -> Void)?

    private let moveButton = NSButton()
    private let keycap = PassthroughLabel(labelWithString: "⌘O")
    private let divider = NSView()
    private let chevron = NSButton()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = M.openInCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        moveButton.isBordered = false
        moveButton.bezelStyle = .regularSquare
        moveButton.target = self
        moveButton.action = #selector(moveClicked)
        moveButton.alignment = .left
        addSubview(moveButton)

        keycap.font = .systemFont(ofSize: 12, weight: .semibold)
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 4
        addSubview(keycap)

        divider.wantsLayer = true
        addSubview(divider)

        chevron.isBordered = false
        chevron.bezelStyle = .regularSquare
        chevron.imagePosition = .imageOnly
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More Spaces")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.toolTip = "Open in Another Space"
        chevron.setAccessibilityLabel("Open in Another Space")
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        addSubview(chevron)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var titleWidth: CGFloat { ceil(moveButton.attributedTitle.size().width) }
    private var keycapWidth: CGFloat { ceil(keycap.attributedStringValue.size().width) + 8 }

    /// Title, keycap, divider and chevron with Arc's spacing.
    var fittingWidth: CGFloat {
        M.openInLeadingInset + titleWidth + 6 + keycapWidth + 7 + 7 + M.pillButtonSize + M.openInChevronTrailing
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let titleHeight: CGFloat = 17
        let buttonWidth = titleWidth + 6 + keycapWidth
        moveButton.frame = CGRect(x: M.openInLeadingInset, y: (h - titleHeight) / 2, width: buttonWidth, height: titleHeight)
        keycap.frame = CGRect(x: moveButton.frame.minX + titleWidth + 6, y: (h - M.keycapHeight) / 2,
                              width: keycapWidth, height: M.keycapHeight)
        let dividerX = moveButton.frame.maxX + 7
        divider.frame = CGRect(x: dividerX, y: 7, width: 1, height: h - 14)
        chevron.frame = CGRect(x: bounds.width - M.openInChevronTrailing - M.pillButtonSize, y: (h - M.pillButtonSize) / 2,
                               width: M.pillButtonSize, height: M.pillButtonSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTitle()
    }

    private func updateTitle() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let font = NSFont.systemFont(ofSize: M.openInFontSize, weight: .medium)
        let leading = NSMutableParagraphStyle()
        leading.alignment = .left
        let title = NSMutableAttributedString(string: "Open in ", attributes: [
            .font: font, .foregroundColor: ink.withAlphaComponent(M.openInDimOpacity), .paragraphStyle: leading,
        ])
        title.append(NSAttributedString(string: spaceName, attributes: [
            .font: NSFont.systemFont(ofSize: M.openInFontSize, weight: .semibold), .foregroundColor: ink, .paragraphStyle: leading,
        ]))
        moveButton.attributedTitle = title
        moveButton.setAccessibilityLabel("Open in \(spaceName)")
        moveButton.toolTip = "Move this page to \(spaceName) (⌘O)"
        keycap.textColor = ink.withAlphaComponent(0.8)
        keycap.layer?.backgroundColor = ink.withAlphaComponent(0.1).cgColor
        divider.layer?.backgroundColor = ink.withAlphaComponent(0.12).cgColor
        // Arc's box is darker than the toolbar, with a hairline border.
        layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.6)).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
        needsLayout = true
        superview?.needsLayout = true
    }

    @objc private func moveClicked() { onMove?() }
    @objc private func chevronClicked() { onChevron?(chevron) }
}

/// A label that lets clicks through to the view under it.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
