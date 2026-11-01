import AppKit
import KiteCore

/// An installed web app's window: no sidebar, a slim toolbar in the manifest's theme_color (back,
/// forward, reload, the page title, Open in Kite), and the page edge to edge below. Like Chrome's
/// app windows, links the user clicks out of the app's scope open in the main window, while redirects
/// (sign-in flows) stay here and show the site's host next to the title. Pages share Kite's profile.
///
/// Arc has no app windows; the toolbar's sizes are Kite's own, close to Little Kite's.
@MainActor
final class WebAppWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    struct Host {
        var openTab: (URL) -> Void
        var adoptPopup: (WebPage) -> Void
        var move: (_ page: WebPage, _ url: URL?, _ title: String?) -> Void
    }

    enum Metrics {
        static let defaultSize = CGSize(width: 1200, height: 820)
        static let minSize = CGSize(width: 400, height: 300)
        static let toolbarHeight: CGFloat = 38
        /// Traffic lights centred in the toolbar, at the main window's x.
        static let trafficLightCenter = CGPoint(x: 20, y: 19)
        static let buttonSize: CGFloat = 24
        static let firstButtonX: CGFloat = 78
        static let buttonGap: CGFloat = 2
        static let titleFontSize: CGFloat = 13
    }

    let app: WebApp
    private let engine: WebEngine
    private let host: Host
    private var page: WebPage?
    private(set) var url: URL?
    private var pageTitle: String?
    private var canGoBack = false
    private var canGoForward = false
    private var isLoading = false

    private let root = FlippedRootView()
    private let toolbar = NSView()
    private let material = NSVisualEffectView()
    private let webContainer = NSView()
    private var trafficLights: TrafficLights?
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let openInKiteButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")

    var didClose: ((WebAppWindowController) -> Void)?

    init(app: WebApp, url: URL? = nil, engine: WebEngine, host: Host) {
        self.app = app
        self.engine = engine
        self.host = host
        let window = WebAppWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        window.title = app.name
        window.setAccessibilityIdentifier("webApp.\(app.id)")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        // Each app keeps its own window size, as Chrome's do.
        if !window.setFrameUsingName(frameName) { window.center() }
        buildViews()
        applyTheme()
        load(url.flatMap { app.contains($0) ? $0 : nil } ?? app.startURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var frameName: String { "WebAppWindow-\(app.id)" }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        window.contentView = root
        root.onLayout = { [weak self] in self?.layout() }

        toolbar.wantsLayer = true
        material.material = .titlebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        material.autoresizingMask = [.width, .height]
        toolbar.addSubview(material)
        toolbar.setAccessibilityElement(true)
        toolbar.setAccessibilityRole(.toolbar)
        toolbar.setAccessibilityLabel("App Toolbar")
        root.addSubview(toolbar)

        webContainer.wantsLayer = true
        webContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(webContainer)

        trafficLights = TrafficLights(window: window, host: root, center: Metrics.trafficLightCenter,
                                      hoverArea: ArcMetrics.Window.trafficLightHoverArea.offsetBy(dx: 0, dy: -5))

        configure(backButton, symbol: "chevron.left", label: "Back", action: #selector(goBack(_:)))
        configure(forwardButton, symbol: "chevron.right", label: "Forward", action: #selector(goForward(_:)))
        configure(reloadButton, symbol: "arrow.clockwise", label: "Reload", action: #selector(reload(_:)))
        configure(openInKiteButton, symbol: "arrow.up.forward.app", label: "Open in Kite", action: #selector(openInKite(_:)))

        titleLabel.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel("Title")
        toolbar.addSubview(titleLabel)
        updateTitle()
        updateButtons()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.title = ""
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        toolbar.addSubview(button)
    }

    private func layout() {
        let bounds = root.bounds
        let h = Metrics.toolbarHeight
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        material.frame = toolbar.bounds
        webContainer.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        page?.view.frame = webContainer.bounds

        // The toolbar isn't flipped: y from the bottom.
        let size = Metrics.buttonSize
        let y = (h - size) / 2
        var x = Metrics.firstButtonX
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + Metrics.buttonGap
        }
        openInKiteButton.frame = CGRect(x: bounds.width - 10 - size, y: y, width: size, height: size)
        // Centred in the window, kept clear of the buttons on both sides.
        let inset = max(x + 8, bounds.width - openInKiteButton.frame.minX + 8)
        let labelHeight: CGFloat = 17
        titleLabel.frame = CGRect(x: inset, y: (h - labelHeight) / 2, width: max(0, bounds.width - 2 * inset), height: labelHeight)
    }

    /// theme_color fills the toolbar (and the window behind it), with ink that reads on it; without one,
    /// the system title bar material.
    private func applyTheme() {
        guard let hex = app.themeColor, let rgb = WebApps.components(of: hex) else {
            material.isHidden = false
            return
        }
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        material.isHidden = true
        toolbar.layer?.backgroundColor = color.cgColor
        window?.backgroundColor = color
        window?.appearance = NSAppearance(named: WebApps.prefersDarkForeground(on: hex) ? .aqua : .darkAqua)
    }

    // MARK: Page

    private func load(_ url: URL) {
        self.url = url
        if let page {
            page.load(url)
            return
        }
        let page = engine.makePage(url: url, restoring: nil)
        self.page = page
        page.onEvent = { [weak self] event in self?.handle(event) }
        page.contextMenuHost = { .littleKite }
        // A link the user clicks out of the app's scope goes to the main window (reported as a peek).
        page.linkPeekPolicy = { [weak self] url, _ in
            guard let self, WebApps.isWeb(url) else { return false }
            return !self.app.contains(url)
        }
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
            updateTitle()
        case .url(let url):
            guard let url else { return }
            self.url = url
            updateTitle()
        case let .navigationState(isLoading, canGoBack, canGoForward):
            self.isLoading = isLoading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            updateButtons()
        case .openInLinkPeek(let url), .openInNewTab(let url, _), .openInSplit(let url):
            host.openTab(url)
        case let .openLink(url, target):
            let delegate = NSApp.delegate as? AppDelegate
            switch target {
            case .newWindow: delegate?.openNewWindow(url: url)
            case .incognitoWindow: delegate?.openIncognitoWindow(url: url)
            case .newTab, .splitView, .littleKite: host.openTab(url)
            }
        case .popup(let popup):
            host.adoptPopup(popup)
        case .closeRequested:
            close()
        case .linkHover(let hover):
            if let view = page?.view { LinkPreviewController.shared.hover(hover, in: view) }
        case .permissionRequest(let request):
            // No prompt UI here yet: deny, as a page with no answer would get.
            request.respond(nil)
        case .favicon, .progress, .blockedCount, .crashed, .addExtension, .media, .permissionRequestCancelled:
            break
        }
    }

    /// The page's title (the app's name until it has one); a page that left the app's scope, such as a
    /// sign-in redirect, also shows its host.
    private func updateTitle() {
        let title = WebApps.windowTitle(appName: app.name, pageTitle: pageTitle)
        window?.title = title
        if let url, WebApps.isWeb(url), !app.contains(url), let host = url.host {
            titleLabel.stringValue = "\(host) — \(title)"
        } else {
            titleLabel.stringValue = title
        }
    }

    private func updateButtons() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        backButton.alphaValue = canGoBack ? 1 : 0.4
        forwardButton.alphaValue = canGoForward ? 1 : 0.4
        let symbol = isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isLoading ? "Stop" : "Reload")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
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

    /// ⌘W and File › Archive Tab close the app window.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }

    /// Moves the live page into the main window as a tab (Chrome's "Open in Chrome").
    @objc func openInKite(_ sender: Any?) {
        guard let page else { return NSSound.beep() }
        page.view.removeFromSuperview()
        page.onEvent = nil
        page.linkPeekPolicy = nil
        self.page = nil
        host.move(page, url, pageTitle)
        close()
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "w": closeTab(nil)
        case "[": goBack(nil)
        case "]": goForward(nil)
        case "r": reload(nil)
        default: return false
        }
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        case #selector(openInKite(_:)), #selector(reload(_:)): return page != nil
        case #selector(copyURL(_:)): return url != nil
        default: return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: frameName)
        if let page {
            page.onEvent = nil
            page.linkPeekPolicy = nil
            page.close()
        }
        page = nil
        didClose?(self)
    }

    func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: frameName) }
    func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: frameName) }
    func windowDidEnterFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }
    func windowDidExitFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }
}

/// Offers ⌘-keys to the app window before the page and the menu bar see them.
final class WebAppWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Top-left origin, and a hook for laying out by hand.
private final class FlippedRootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}
