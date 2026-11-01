import AppKit
#if canImport(CEFBridge)
import Combine
#endif
import KiteCore
import Observation

/// Little Kite: Arc's "Little Arc". A small window with one page and no sidebar, for links
/// from other apps (when Kite menu → Open Links from Other Apps in Little Kite is on) and
/// File → New Little Kite Window (⌥⌘N). "Open in <Space>" (⌘O) moves the live page into the
/// main window as a tab in that space and closes this window; ⌘W just closes it.
///
/// Layout from Arc 1.171 (`ArcMetrics.LittleWindow`, docs/arc-visual-spec.md): traffic lights,
/// back, the URL pill (host centred, extensions, copy link), then the Open In box; the page below,
/// edge to edge, with the downloads tray over its bottom edge while this window has downloads.
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
        /// Kite's profiles, the one a new Little Kite starts in (the current space's), and each one's engine.
        var profiles: () -> [Profile]
        var initialProfile: () -> Profile
        var engine: (Profile) -> WebEngine
        /// Moves the page into the main window as a tab in that space and brings the main window forward.
        /// `profileDirectory` is the profile the page was made in.
        var move: (_ page: WebPage, _ url: URL?, _ title: String?, _ spaceID: UUID, _ profileDirectory: String?) -> Void
        /// Links the page opens in a new tab or popup go to the main window.
        var openTab: (URL) -> Void
        var adoptPopup: (WebPage) -> Void
    }

    private var engine: WebEngine
    /// The page's profile, shown at the pill's leading edge while Kite has more than one.
    private(set) var profile: Profile
    private let host: Host
    private var page: WebPage?
    private(set) var url: URL?
    private var pageTitle: String?
    private var canGoBack = false
    /// The page's waiting permission request and Arc's prompt for it, over the page's top-leading corner.
    private var permissionRequest: PermissionRequest?
    private var permissionPrompt: PermissionPromptCard?

    private let root = LittleRootView()
    private let materialView = NSVisualEffectView()
    private let themeView = ThemeView()
    private let webContainer = NSView()
    private var trafficLights: TrafficLights?
    private let backButton = NSButton()
    private let pill = LittlePillView()
    private let openIn = OpenInBox()
    private var moveMenu: LittleMoveMenuController?
    /// Downloads this window's page started (Arc's Little Arc downloads tray).
    private let downloadsTray = LittleDownloadsTrayView()
    private var tray = LittleKite.DownloadsTray()
    private var downloadStarts: NSObjectProtocol?
    private var observesDownloads = false
    #if canImport(CEFBridge)
    private var extensionsChanges: AnyCancellable?
    #endif

    /// When the window was last in use, for "Archive Little Kites after:" (`archiveIfStale`).
    private(set) var lastActiveAt = Date()

    /// Called once the window has closed, so the app delegate can let go of it.
    var didClose: ((LittleKiteWindowController) -> Void)?

    init(url: URL?, host: Host) {
        let profile = host.initialProfile()
        self.profile = profile
        engine = host.engine(profile)
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
        webContainer.layer?.backgroundColor = NSColor.pageBackdrop.cgColor
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
        pill.onProfile = { [weak self] view in self?.showProfileMenu(from: view) }
        pill.onBeginEditing = { [weak self] in self?.url?.absoluteString ?? "" }
        pill.onCommit = { [weak self] text in
            guard let self, let url = self.host.resolve(text) else { return }
            self.load(url)
        }
        root.addSubview(pill)

        openIn.onMove = { [weak self] in self?.openInCurrentSpace(nil) }
        openIn.onChevron = { [weak self] _ in self?.toggleMoveMenu(nil) }
        root.addSubview(openIn)

        downloadsTray.onDismiss = { [weak self] id in
            self?.tray.dismiss(id)
            self?.refreshTray()
        }
        root.addSubview(downloadsTray)
        setUpExtensionsButton()
        updateBackButton()
        updateProfileIndicator()
    }

    /// Arc shows the pill's extensions button only while extensions are installed
    /// (`hasExtensions`); it opens the same extensions menu as the main window's.
    private func setUpExtensionsButton() {
        #if canImport(CEFBridge)
        if engine is ChromiumEngine {
            let model = ExtensionsModel.shared(engine: engine)
            extensionsChanges = model.$extensions.receive(on: DispatchQueue.main).sink { [weak self] list in
                MainActor.assumeIsolated { self?.pill.showsExtensions = !list.isEmpty }
            }
            pill.onExtensions = { view in ExtensionsMenu.present(model: model, from: view) }
            model.refresh()
        }
        #endif
        // WebKit test builds have no extensions: this shows the button so its layout can be checked.
        if UIDiagnostics.enabledByEnvironment, ProcessInfo.processInfo.environment["KITE_TEST_LITTLE_EXTENSIONS_BUTTON"] == "1" {
            pill.showsExtensions = true
        }
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
        let trayHeight = LittleKite.DownloadsTray.height
        downloadsTray.frame = CGRect(x: 0, y: max(M.toolbarHeight, bounds.height - trayHeight), width: width, height: trayHeight)
    }

    /// The window takes the theme of the space "Open in" names, like Arc's.
    private func applyDestination() {
        let destination = host.currentSpace()
        themeView.setTheme(destination.theme, animated: false)
        let appearance = NSAppearance(named: destination.theme.prefersDarkForeground ? .aqua : .darkAqua)
        window?.appearance = appearance
        openIn.spaceName = destination.name
        openIn.showsChevron = LittleKite.hasAdditionalDestinations(spaceCount: host.spaces().count)
        root.needsLayout = true
    }

    /// Arc's profile indicator: the page's profile, while there's more than one to tell apart.
    private func updateProfileIndicator() {
        pill.profileName = LittleKite.showsProfileIndicator(profileCount: host.profiles().count) ? profile.name : nil
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
        page.contextMenuHost = { .littleKite }
        page.view.frame = webContainer.bounds
        page.view.autoresizingMask = [.width, .height]
        webContainer.addSubview(page.view)
        followDownloads(of: page)
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
        case .openInNewTab(let url, _), .openInLinkPeek(let url), .openInSplit(let url):
            host.openTab(url)
        case .openInLittleKite(let url):
            // Out of the engine's navigation callback before making another page.
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.openLittleKiteWindow(url: url) }
        case let .openLink(url, target):
            let app = NSApp.delegate as? AppDelegate
            switch target {
            case .newWindow: app?.openNewWindow(url: url)
            case .incognitoWindow: app?.openIncognitoWindow(url: url)
            // Little Kite's menu has no Split View or Little Kite items.
            case .newTab, .splitView, .littleKite: host.openTab(url)
            }
        case .pageCommand(.viewPageSource):
            if let url, let source = URL(string: "view-source:" + url.absoluteString) { host.openTab(source) }
        case .pageCommand:
            // Save As… and Print… act on a tab; Kite doesn't run them in Little Kite yet.
            NSSound.beep()
        case .popup(let popup):
            host.adoptPopup(popup)
        case .closeRequested:
            close()
        case .linkHover(let hover):
            if let view = page?.view { LinkPreviewController.shared.hover(hover, in: view) }
        case .permissionRequest(let request):
            showPermissionPrompt(request)
        case .permissionRequestCancelled(let id):
            if permissionRequest?.id == id { showPermissionPrompt(nil) }
        case .favicon, .progress, .blockedCount, .crashed, .addExtension, .media, .callControls, .capturing:
            break
        }
    }

    /// Shows `request`'s prompt (nil removes it), dismissing any older request still waiting.
    private func showPermissionPrompt(_ request: PermissionRequest?) {
        if let old = permissionRequest, old.id != request?.id { old.respond(nil) }
        permissionPrompt?.removeFromSuperview()
        permissionPrompt = nil
        permissionRequest = request
        guard let request else { return }
        let card = PermissionPromptCard(request: request) { [weak self] allow in
            guard let self, self.permissionRequest?.id == request.id else { return }
            self.permissionRequest = nil
            request.respond(allow)
            self.showPermissionPrompt(nil)
        }
        card.place(in: webContainer.bounds, of: webContainer)
        webContainer.addSubview(card)
        permissionPrompt = card
        card.animateIn()
    }

    private func updateBackButton() {
        backButton.isEnabled = canGoBack
        backButton.alphaValue = canGoBack ? 1 : 0.4
    }

    // MARK: Downloads tray

    /// Puts each download the page starts in the tray.
    private func followDownloads(of page: WebPage) {
        stopFollowingDownloads()
        downloadStarts = NotificationCenter.default.addObserver(forName: DownloadsModel.didStartDownload, object: page.view,
                                                                queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? UUID else { return }
            MainActor.assumeIsolated {
                self?.tray.add(id)
                self?.refreshTray()
            }
        }
    }

    private func stopFollowingDownloads() {
        if let downloadStarts { NotificationCenter.default.removeObserver(downloadStarts) }
        downloadStarts = nil
    }

    /// Shows the tray's downloads as the list has them now, and keeps following the list while
    /// the tray has any.
    private func refreshTray() {
        let items = Dictionary(DownloadsModel.shared.list.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tray.keep(only: Set(items.keys))
        downloadsTray.show(tray, items: items)
        guard !tray.isEmpty, !observesDownloads else { return }
        observesDownloads = true
        withObservationTracking {
            _ = DownloadsModel.shared.list
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observesDownloads = false
                    self.refreshTray()
                }
            }
        }
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
        showPermissionPrompt(nil)
        page.view.removeFromSuperview()
        page.onEvent = nil
        self.page = nil
        stopFollowingDownloads()
        host.move(page, url, pageTitle, spaceID, engine.profileDirectory)
        close()
    }

    /// The chevron: Arc's searchable "Open In" menu (`toggleMoveMenu:`), over the Open In box.
    @objc func toggleMoveMenu(_ sender: Any?) {
        if let moveMenu, moveMenu.isOpen { return moveMenu.dismiss() }
        guard let window, page != nil else { return NSSound.beep() }
        applyDestination()
        let options = host.spaces().map { space in
            LittleMoveMenuController.Option(id: space.id, name: space.name, color: Self.swatchColor(space.theme))
        }
        let menu = LittleMoveMenuController(parent: window, anchor: openIn, options: options,
                                            primaryID: host.currentSpace().id) { [weak self] id in self?.move(to: id) }
        menu.didClose = { [weak self, weak menu] in
            if let menu, self?.moveMenu === menu { self?.moveMenu = nil }
        }
        moveMenu = menu
        menu.show()
    }

    private static func swatchColor(_ theme: Theme) -> NSColor {
        guard let c = theme.colors.first else { return .controlAccentColor }
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }

    // MARK: Profile

    /// Arc's `showChangeProfileMenu`: the profiles, the page's ticked.
    private func showProfileMenu(from view: NSView) {
        let menu = NSMenu()
        for profile in host.profiles() {
            let item = NSMenuItem(title: profile.name, action: #selector(changeProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = profile.directory == self.profile.directory ? .on : .off
            menu.addItem(item)
        }
        // Menus are modal, so a background test run can't read one: it prints the items instead and picks
        // the profile named in KITE_TEST_LITTLE_PROFILE_PICK.
        if UIDiagnostics.enabledByEnvironment, let pick = ProcessInfo.processInfo.environment["KITE_TEST_LITTLE_PROFILE_PICK"] {
            let line = menu.items.map { $0.title + ($0.state == .on ? " ✓" : "") }.joined(separator: " | ")
            FileHandle.standardError.write(Data("KITE_TEST_LITTLE_PROFILE_MENU: \(line)\n".utf8))
            if let item = menu.items.first(where: { $0.title == pick }) { changeProfile(item) }
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func changeProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        switchProfile(to: profile)
    }

    /// Reloads the page in `profile` (its own cookies and logins), as Arc's `setProfile` does: the page
    /// starts again from its URL, since its state belongs to the old profile.
    func switchProfile(to profile: Profile) {
        guard profile.directory != self.profile.directory else { return }
        self.profile = profile
        engine = host.engine(profile)
        if let page {
            showPermissionPrompt(nil)
            stopFollowingDownloads()
            page.onEvent = nil
            page.view.removeFromSuperview()
            page.close()
            self.page = nil
            canGoBack = false
            updateBackButton()
        }
        updateProfileIndicator()
        if let url { load(url) }
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
        showPermissionPrompt(nil)
        if let page {
            page.onEvent = nil
            page.close()
        }
        page = nil
        stopFollowingDownloads()
        didClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { lastActiveAt = Date() }
    func windowDidResignKey(_ notification: Notification) { lastActiveAt = Date() }

    /// Settings › Links › "Archive Little Kites after:": closes the window once it has gone unused that
    /// long (Arc's `autoArchiveLittleArcTimeThreshold`). In use means key while Kite is the active app.
    @discardableResult
    func archiveIfStale(_ threshold: LittleKite.ArchiveThreshold, now: Date = Date()) -> Bool {
        let inUse = window?.isKeyWindow == true && NSApp.isActive
        if inUse { lastActiveAt = now }
        guard threshold.isStale(lastActive: lastActiveAt, inUse: inUse, now: now) else { return false }
        close()
        return true
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
    var onExtensions: ((NSView) -> Void)?
    /// The page's profile at the leading edge (Arc's profile indicator); nil hides it.
    var profileName: String? {
        didSet {
            profileButton.isHidden = profileName == nil
            profileButton.name = profileName ?? ""
            needsLayout = true
        }
    }
    var onProfile: ((NSView) -> Void)?
    /// Arc's extensions button, shown while extensions are installed.
    var showsExtensions = false {
        didSet {
            extensionsButton.isHidden = !showsExtensions
            needsLayout = true
        }
    }
    var onCommit: ((String) -> Void)?
    /// The text to start editing with.
    var onBeginEditing: (() -> String)?

    private let hostLabel = PassthroughLabel(labelWithString: "")
    private let field = NSTextField()
    private let copyButton = NSButton()
    private let extensionsButton = NSButton()
    private let profileButton = ProfileIndicatorView()
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

        extensionsButton.isBordered = false
        extensionsButton.bezelStyle = .regularSquare
        extensionsButton.imagePosition = .imageOnly
        extensionsButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        extensionsButton.contentTintColor = .secondaryLabelColor
        extensionsButton.toolTip = "Extensions"
        extensionsButton.setAccessibilityLabel("Extensions")
        extensionsButton.target = self
        extensionsButton.action = #selector(extensionsClicked)
        extensionsButton.isHidden = true
        addSubview(extensionsButton)

        profileButton.onClick = { [weak self] in self?.profileClicked() }
        profileButton.isHidden = true
        addSubview(profileButton)
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
        let buttons = LittleKite.pillButtons(pillWidth: Double(bounds.width), showsExtensions: showsExtensions)
        copyButton.frame = CGRect(x: buttons.copyX, y: (bounds.height - size) / 2, width: size, height: size)
        if let x = buttons.extensionsX {
            let width = LittleKite.Pill.extensionsWidth, height = LittleKite.Pill.extensionsHeight
            extensionsButton.frame = CGRect(x: x, y: (Double(bounds.height) - height) / 2, width: width, height: height)
        }
        var leading = M.pillLeadingInset
        if !profileButton.isHidden {
            typealias P = LittleKite.ProfileIndicator
            profileButton.frame = CGRect(x: P.x, y: (Double(bounds.height) - 16) / 2,
                                         width: Double(profileButton.fittingWidth), height: 16)
            leading = profileButton.frame.maxX + CGFloat(P.trailingGap)
        }
        let trailing = CGFloat(buttons.labelTrailing)
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
    private func profileClicked() { onProfile?(profileButton) }
    @objc private func extensionsClicked() { onExtensions?(extensionsButton) }
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
    /// Arc's `hasAdditionalDestinations`: no chevron (or divider) with only one space.
    var showsChevron = true {
        didSet {
            chevron.isHidden = !showsChevron
            divider.isHidden = !showsChevron
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    private let moveButton = NSButton()
    private let keycap = PassthroughLabel(labelWithString: "⌘O")
    private let divider = NSView()
    private let chevron = FirstMouseButton()

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
        // Arc's title for it: "More Spaces".
        chevron.toolTip = "More Spaces"
        chevron.setAccessibilityLabel("More Spaces")
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
        let content = M.openInLeadingInset + titleWidth + 6 + keycapWidth
        return showsChevron ? content + 7 + 7 + M.pillButtonSize + M.openInChevronTrailing : content + M.openInLeadingInset
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

/// Arc's profile indicator in the Little Arc pill: a 14pt profile image, then the profile's name.
/// A click opens the profile menu (Arc's `onClickChangeProfile`).
private final class ProfileIndicatorView: NSView {
    private typealias P = LittleKite.ProfileIndicator

    var name = "" {
        didSet {
            label.stringValue = name
            setAccessibilityLabel("Profile: \(name)")
            needsLayout = true
        }
    }
    var onClick: (() -> Void)?

    private let image = NSImageView()
    private let label = PassthroughLabel(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(P.imageSize) - 1, weight: .medium))
        image.contentTintColor = .secondaryLabelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        label.font = .systemFont(ofSize: CGFloat(P.fontSize), weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        // Arc's tooltip on it in the Little Arc toolbar.
        toolTip = "Change profile"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        CGFloat(P.imageSize + P.nameGap) + min(ceil(label.attributedStringValue.size().width) + 4, 160)
    }

    override func layout() {
        super.layout()
        let size = CGFloat(P.imageSize)
        image.frame = CGRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
        let x = size + CGFloat(P.nameGap)
        label.frame = CGRect(x: x, y: (bounds.height - 15) / 2, width: max(0, bounds.width - x), height: 15)
    }

    /// The whole indicator is one button.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Takes the click that makes the window key, so the toolbar's menus open from a background window too.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A label that lets clicks through to the view under it.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
