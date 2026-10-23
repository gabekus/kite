import AppKit
import KiteCore
import SwiftUI

/// One browser window: theme backdrop, sidebar, the selected tab's web view,
/// the loading glow, and the command bar overlay, back to front.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private enum Layout {
        static let defaultSidebarWidth: CGFloat = 240
        static let sidebarWidths: ClosedRange<CGFloat> = 180...400
        static let inset = ArcMetrics.Content.inset
        static let cornerRadius = ArcMetrics.Content.cornerRadius
        static let glowMargin: CGFloat = 28
    }

    let store: BrowserStore
    let pool: PagePool
    private let adblocker: Adblocker
    private let rootView = RootView()
    /// The system's sidebar material under the space's tint, like Arc's translucent window.
    private let materialView = NSVisualEffectView()
    private let themeView = ThemeView()
    private let glowView = GlowView(margin: Layout.glowMargin)
    let contentFrame = ShadowView(cornerRadius: Layout.cornerRadius)
    private let contentClip = ContentClipView()
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private let resizeHandle = SidebarResizeHandle()
    private var sidebarHost: NSHostingView<SidebarView>!
    private var trafficLights: TrafficLights!
    private var commandBarHost: NSHostingView<CommandBarOverlay>!
    private var contentLeading: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarWidth: CGFloat
    private var appearanceObservation: NSKeyValueObservation?

    private var shownTabID: UUID?
    private var shownSpaceID: UUID?
    private(set) weak var shownPage: WebPage?
    /// Last dark-pages setting sent to each page, so it's only re-sent on change.
    private var appliedDark: [UUID: Bool] = [:]
    private var commandBarVisible = false
    private var sidebarVisible = true
    /// While the sidebar slides: the part of the window the card covers at both ends of the slide.
    private var cardCoverDuringToggle: CGRect?
    private var sidebarToggles = 0

    /// Incognito windows keep nothing: no saved frame, and every page closes with the window.
    let isIncognito: Bool

    init(store: BrowserStore, engine: WebEngine, adblocker: Adblocker, incognito: Bool = false) {
        self.store = store
        self.adblocker = adblocker
        self.isIncognito = incognito
        self.pool = PagePool(engine: engine, store: store)
        let savedWidth = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        self.sidebarWidth = savedWidth > 0 ? Self.clampedSidebarWidth(savedWidth) : Layout.defaultSidebarWidth
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        // Clear, so the sidebar material can show the desktop through the tint.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        if !incognito { window.setFrameAutosaveName("KiteMainWindow") }
        super.init(window: window)
        window.delegate = self

        buildViews()
        store.onChange = { [weak self] in self?.sync() }
        store.onPageChange = { [weak self] id in self?.pageChanged(id) }
        // Dark pages in "Match System" follow macOS switching light/dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.store.setSystemIsDark(app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            }
        }
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        store.saveNow()
        if isIncognito { pool.retain(live: [], restorable: []) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }
    func windowDidExitFullScreen(_ notification: Notification) { trafficLights?.fullScreenChanged() }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        window.contentView = rootView
        rootView.onLayout = { [weak self] in self?.layoutChanged() }

        contentClip.wantsLayer = true
        contentClip.layer?.cornerRadius = Layout.cornerRadius
        contentClip.layer?.cornerCurve = .continuous
        contentClip.layer?.masksToBounds = true
        contentClip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)

        sidebarHost = NSHostingView(rootView: SidebarView(
            store: store,
            actions: SidebarActions(
                goBack: { [weak self] in self?.goBack(nil) },
                goForward: { [weak self] in self?.goForward(nil) },
                reload: { [weak self] in self?.reload(nil) },
                toggleSidebar: { [weak self] in self?.store.toggleSidebar() },
                closeTab: { [weak self] id in self?.close(tab: id) }
            ),
            supportsDarkPages: pool.engine.supportsDarkPages
        ))
        commandBarHost = NSHostingView(rootView: CommandBarOverlay(store: store) { [weak self] suggestion, mode in
            self?.commit(suggestion, mode: mode)
        })
        for host in [sidebarHost as NSView, commandBarHost] {
            (host as? NSHostingView<SidebarView>)?.sizingOptions = []
            (host as? NSHostingView<CommandBarOverlay>)?.sizingOptions = []
        }
        commandBarHost.isHidden = true

        var dragStartWidth: CGFloat = 0
        resizeHandle.onBegin = { [weak self] in dragStartWidth = self?.sidebarWidth ?? 0 }
        resizeHandle.onDrag = { [weak self] dx in self?.setSidebarWidth(dragStartWidth + dx) }
        resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }

        materialView.material = .sidebar
        materialView.blendingMode = .behindWindow
        materialView.state = .followsWindowActiveState

        for view in [materialView, themeView, sidebarHost!, contentFrame, glowView, resizeHandle, commandBarHost!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        for view in [contentClip, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        contentFrame.addSubview(contentClip)
        contentClip.addSubview(emptyLabel)

        contentLeading = contentFrame.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: sidebarWidth)
        sidebarLeading = sidebarHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        sidebarWidthConstraint = sidebarHost.widthAnchor.constraint(equalToConstant: sidebarWidth)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: rootView.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            themeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            themeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            themeView.topAnchor.constraint(equalTo: rootView.topAnchor),
            themeView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarLeading,
            sidebarHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarWidthConstraint,

            // Like Arc: straddles the card's edge and spans the card's height, above the page and glow.
            resizeHandle.centerXAnchor.constraint(equalTo: contentFrame.leadingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: ArcMetrics.Content.resizeZoneVerticalInset),
            resizeHandle.bottomAnchor.constraint(equalTo: contentFrame.bottomAnchor, constant: -ArcMetrics.Content.resizeZoneVerticalInset),
            resizeHandle.widthAnchor.constraint(equalToConstant: 2 * ArcMetrics.Content.resizeZoneHalfWidth),

            contentLeading,
            contentFrame.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Layout.inset),
            contentFrame.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Layout.inset),
            contentFrame.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Layout.inset),

            contentClip.leadingAnchor.constraint(equalTo: contentFrame.leadingAnchor),
            contentClip.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor),
            contentClip.topAnchor.constraint(equalTo: contentFrame.topAnchor),
            contentClip.bottomAnchor.constraint(equalTo: contentFrame.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: contentClip.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentClip.centerYAnchor),

            glowView.leadingAnchor.constraint(equalTo: contentFrame.leadingAnchor, constant: -Layout.glowMargin),
            glowView.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor, constant: Layout.glowMargin),
            glowView.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: -Layout.glowMargin),
            glowView.bottomAnchor.constraint(equalTo: contentFrame.bottomAnchor, constant: Layout.glowMargin),

            commandBarHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            commandBarHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        trafficLights = TrafficLights(window: window, host: sidebarHost)
    }

    private static let sidebarWidthKey = "SidebarWidth"

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, Layout.sidebarWidths.lowerBound), Layout.sidebarWidths.upperBound)
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let width = Self.clampedSidebarWidth(width.rounded())
        guard width != sidebarWidth else { return }
        sidebarWidth = width
        sidebarWidthConstraint.constant = width
        if sidebarVisible { contentLeading.constant = width } else { sidebarLeading.constant = -width }
        // Lay out now so the theme's cutout moves in the same frame as the page.
        rootView.layoutSubtreeIfNeeded()
    }

    private func layoutChanged() {
        // Metal works top-left; AppKit's origin is bottom-left.
        let frame = cardCoverDuringToggle ?? contentFrame.frame
        themeView.cutoutRect = CGRect(x: frame.minX, y: rootView.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        themeView.cutoutCornerRadius = Layout.cornerRadius
        let sidebar = sidebarHost.frame
        themeView.glowRegion = sidebarVisible
            ? CGRect(x: sidebar.minX, y: rootView.bounds.height - sidebar.maxY, width: sidebar.width, height: sidebar.height)
            : .zero
    }

    // MARK: Sync with the store

    private func sync() {
        let state = store.state
        let space = state.selectedSpace

        themeView.setTheme(space.theme, animated: shownSpaceID != nil)
        glowView.setTheme(space.theme)
        let appearance = NSAppearance(named: space.theme.prefersDarkForeground ? .aqua : .darkAqua)
        sidebarHost.appearance = appearance
        materialView.appearance = appearance
        shownSpaceID = space.id
        // Hidden in the titlebar, but it names the window in the Window menu and Mission Control.
        let title = state.selectedTab?.title ?? ""
        if isIncognito {
            window?.title = title.isEmpty ? "Incognito" : title + " (Incognito)"
        } else {
            window?.title = title.isEmpty ? space.name : title
        }

        let selected = state.selectedTab
        if selected?.id != shownTabID {
            show(selected)
        }
        let live = state.allTabIDs
        pool.retain(live: live, restorable: live.union(state.recentlyClosed.map(\.tab.id)))
        appliedDark = appliedDark.filter { live.contains($0.key) }
        applyDarkPage()
        adblocker.setPolicy(enabled: state.blocksAds, allowedHosts: state.adblockAllowedHosts)

        updateCommandBar()
        updateSidebar()
    }

    private func show(_ tab: BrowserTab?) {
        hideFindBar()
        shownPage?.view.removeFromSuperview()
        shownPage = nil
        shownTabID = tab?.id
        emptyLabel.isHidden = tab != nil
        guard let tab else {
            glowView.setLoading(false, progress: 0)
            return
        }

        let page = pool.page(for: tab)
        page.view.autoresizingMask = []
        contentClip.addSubview(page.view)
        contentClip.page = page.view
        shownPage = page
        pool.didShow(tab.id)
        if store.commandBar == nil {
            page.focus()
        }
        pageChanged(tab.id)
    }

    /// Dark pages follow the site, so this re-checks whenever the shown tab's URL changes.
    private func applyDarkPage() {
        guard let id = shownTabID, let page = shownPage else { return }
        let dark = store.state.wantsDarkPage(for: store.state.tab(id)?.url, systemIsDark: store.systemIsDark)
        guard appliedDark[id] != dark else { return }
        appliedDark[id] = dark
        page.setForceDark(dark)
    }

    private func pageChanged(_ id: UUID) {
        guard id == shownTabID else { return }
        let page = store.pages[id] ?? PageStatus()
        glowView.setLoading(page.isLoading, progress: page.progress)
    }

    private func updateCommandBar() {
        let visible = store.commandBar != nil
        guard visible != commandBarVisible else { return }
        commandBarVisible = visible
        commandBarHost.isHidden = !visible
        if !visible {
            shownPage?.focus()
        }
    }

    private func updateSidebar() {
        let visible = store.isSidebarVisible
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        resizeHandle.isHidden = !visible
        sidebarHost.isHidden = false
        sidebarToggles += 1
        let toggle = sidebarToggles

        // Like Arc: set the final frames once inside an implicit animation group and let Core
        // Animation move the layers, so nothing lays out again until the slide ends.
        rootView.layoutSubtreeIfNeeded()
        let from = contentFrame.frame
        contentLeading.constant = visible ? sidebarWidth : Layout.inset
        sidebarLeading.constant = visible ? 0 : -sidebarWidth
        let to = CGRect(x: contentLeading.constant, y: from.minY, width: from.maxX - contentLeading.constant, height: from.height)
        // The page keeps the wider of its two widths until the slide ends, so it never stops short
        // of the card's edge: a hide widens it now, a show narrows it at the end. And the theme
        // skips drawing only where the card covers the window the whole way.
        contentClip.minimumPageWidth = max(from.width, to.width)
        cardCoverDuringToggle = from.intersection(to)
        layoutChanged()

        let curve = ArcMetrics.Motion.sidebarToggleCurve
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ArcMetrics.Motion.sidebarToggleDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: curve.x1, curve.y1, curve.x2, curve.y2)
            context.allowsImplicitAnimation = true
            rootView.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, toggle == self.sidebarToggles else { return }
                self.contentClip.minimumPageWidth = 0
                self.cardCoverDuringToggle = nil
                self.sidebarHost.isHidden = !self.sidebarVisible
                self.layoutChanged()
            }
        })
    }

    // MARK: Commands

    private func commit(_ suggestion: CommandSuggestion, mode: CommandBarMode) {
        store.hideCommandBar()
        switch suggestion {
        case .open(let url), .search(_, let url), .siteSearch(_, _, let url):
            open(url, mode: mode)
        case .history(let entry):
            open(entry.url, mode: mode)
        case .switchTab(let tab):
            store.mutate { $0.select(tab: tab.id) }
        case .command(let command):
            // After the bar closes, so the command sees the page as first responder, not the bar's field.
            DispatchQueue.main.async { command.perform() }
        }
    }

    private func open(_ url: URL, mode: CommandBarMode) {
        if mode == .editCurrent, let id = store.state.selectedTab?.id {
            store.mutate { $0.update(tab: id) { $0.url = url } }
            pool.loadedPage(id)?.load(url)
        } else {
            store.mutate { $0.openTab(url: url) }
        }
    }

    func close(tab id: UUID) {
        if store.mutate({ $0.close(tab: id) }) == .unloaded {
            pool.discard(id, keepHistory: false)
        }
    }

    @objc func newTab(_ sender: Any?) {
        store.showCommandBar(.newTab)
    }

    @objc func openLocation(_ sender: Any?) {
        store.showCommandBar(store.state.selectedTab == nil ? .newTab : .editCurrent)
    }

    @objc func closeTab(_ sender: Any?) {
        // ⌘W in another window (DevTools, a panel) closes that window, not a tab.
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(sender)
        } else if store.commandBar != nil {
            store.hideCommandBar()
        } else if let id = store.state.selectedTab?.id {
            close(tab: id)
        } else {
            NSSound.beep()
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        store.mutate { $0.reopenLastClosed() }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        store.toggleSidebar()
    }

    @objc func reload(_ sender: Any?) {
        guard let page = shownPage else { return }
        if page.isLoading {
            page.stopLoading()
        } else {
            page.reload()
        }
    }

    @objc func goBack(_ sender: Any?) { shownPage?.goBack() }
    @objc func goForward(_ sender: Any?) { shownPage?.goForward() }

    @objc func showDevTools(_ sender: Any?) {
        guard let page = shownPage else { return NSSound.beep() }
        if pool.engine.supportsDevTools {
            page.showDevTools()
        } else {
            let alert = NSAlert()
            alert.messageText = "Web Inspector"
            alert.informativeText = "On the WebKit engine, right-click the page and choose Inspect Element."
            alert.runModal()
        }
    }

    @objc func toggleDarkPage(_ sender: Any?) {
        guard let tab = store.state.selectedTab else { return NSSound.beep() }
        store.mutate { $0.toggleDarkPage(for: tab.url) }
    }

    /// Blocking on or off for the current site. Reloads so the page shows the
    /// change right away. Arc has no ad-block control in its sidebar, so this
    /// lives in the View menu until Kite has Arc's site controls.
    @objc func toggleAdblockForSite(_ sender: Any?) {
        guard let tab = store.state.selectedTab, tab.url?.host() != nil else { return NSSound.beep() }
        store.mutate { $0.toggleAdblock(for: tab.url) }
        shownPage?.reload()
    }

    @objc func toggleAdblock(_ sender: Any?) {
        store.mutate { $0.blocksAds.toggle() }
        shownPage?.reload()
    }

    /// The Dark Pages menu: tags index `DarkPagesMode.allCases`.
    @objc func setDarkPagesMode(_ sender: NSMenuItem) {
        let modes = DarkPagesMode.allCases
        guard modes.indices.contains(sender.tag) else { return }
        store.mutate { $0.darkPages = modes[sender.tag] }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setDarkPagesMode(_:)):
            let modes = DarkPagesMode.allCases
            item.state = modes.indices.contains(item.tag) && modes[item.tag] == store.state.darkPages ? .on : .off
        case #selector(toggleDarkPage(_:)):
            let tab = store.state.selectedTab
            item.state = store.state.wantsDarkPage(for: tab?.url, systemIsDark: store.systemIsDark) ? .on : .off
            return pool.engine.supportsDarkPages && tab?.url?.host() != nil
        case #selector(toggleAdblock(_:)):
            item.state = store.state.blocksAds ? .on : .off
            return Adblocker.isAvailable
        case #selector(toggleAdblockForSite(_:)):
            let tab = store.state.selectedTab
            let on = store.state.blocksAds(on: tab?.url)
            item.state = on ? .on : .off
            let blocked = tab.flatMap { store.pages[$0.id]?.blockedCount } ?? 0
            item.title = on && pool.engine.countsBlockedRequests && blocked > 0
                ? "Block Ads on This Site (\(blocked) blocked)"
                : "Block Ads on This Site"
            return Adblocker.isAvailable && tab?.url?.host() != nil
        case #selector(togglePin(_:)):
            let pinned = store.state.selectedTab.flatMap { store.state.location(of: $0.id) }?.section == .pinned
            item.title = pinned ? "Unpin Tab" : "Pin Tab"
            return store.state.selectedTab != nil
        case #selector(selectSpaceNumber(_:)):
            // Arc lists only the spaces that exist, by name.
            let spaces = store.state.spaces
            let exists = spaces.indices.contains(item.tag - 1)
            item.isHidden = !exists
            guard exists else { return false }
            item.title = "\(spaces[item.tag - 1].icon) \(spaces[item.tag - 1].name)"
        case #selector(toggleStayOnTop(_:)):
            item.state = window?.level == .floating ? .on : .off
        case #selector(setAsDefaultBrowser(_:)):
            item.state = Self.isDefaultBrowser ? .on : .off
        case #selector(share(_:)), #selector(savePageAs(_:)),
             #selector(clearCookiesAndRefresh(_:)), #selector(clearCacheAndRefresh(_:)):
            return store.state.selectedTab?.url != nil
        case #selector(stopLoading(_:)):
            return shownPage?.isLoading ?? false
        case #selector(toggleFullScreenMode(_:)):
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        default:
            break
        }
        return true
    }

    @objc func zoomIn(_ sender: Any?) { setZoom { $0 + 0.1 } }
    @objc func zoomOut(_ sender: Any?) { setZoom { $0 - 0.1 } }
    @objc func actualSize(_ sender: Any?) { setZoom { _ in 1 } }

    private func setZoom(_ change: (Double) -> Double) {
        guard let page = shownPage else { return }
        page.zoomFactor = min(max(change(page.zoomFactor), 0.3), 3)
    }

    @objc func nextTab(_ sender: Any?) { store.mutate { $0.selectAdjacentTab(offset: 1) } }
    @objc func previousTab(_ sender: Any?) { store.mutate { $0.selectAdjacentTab(offset: -1) } }

    @objc func togglePin(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id else { return }
        store.mutate { $0.togglePin(tab: id) }
    }

    @objc func selectTabNumber(_ sender: NSMenuItem) {
        store.mutate { $0.selectTab(number: sender.tag) }
    }

    @objc func selectSpaceNumber(_ sender: NSMenuItem) {
        store.mutate { $0.selectSpace(at: sender.tag - 1) }
    }

    @objc func nextSpace(_ sender: Any?) { store.mutate { $0.selectAdjacentSpace(offset: 1) } }
    @objc func previousSpace(_ sender: Any?) { store.mutate { $0.selectAdjacentSpace(offset: -1) } }
    @objc func newSpace(_ sender: Any?) { store.addSpace() }
}

/// The sidebar's trailing edge. Reports horizontal drag distance since mouse-down.
final class SidebarResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    // The window keeps cursor rects where they were set, so move them with the sidebar's edge.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}

/// The card's clip. It sizes the shown page itself, so the page can stay wider than the card
/// while the sidebar slides.
final class ContentClipView: NSView {
    weak var page: NSView? {
        didSet { layoutPage() }
    }
    var minimumPageWidth: CGFloat = 0 {
        didSet { if minimumPageWidth != oldValue { layoutPage() } }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPage()
    }

    private func layoutPage() {
        let frame = CGRect(x: 0, y: 0, width: max(bounds.width, minimumPageWidth), height: bounds.height)
        if let page, page.frame != frame { page.frame = frame }
    }
}

/// Reports layout passes so the theme can skip pixels under the web content.
final class RootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Draws the content card's shadow from an explicit path, which spares Core
/// Animation an offscreen pass to work out the shape every frame.
final class ShadowView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let layer else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        // Inside an animation group (the sidebar's slide) the path follows the frame on its curve.
        let context = NSAnimationContext.current
        if context.allowsImplicitAnimation, context.duration > 0, let old = layer.shadowPath, old != path {
            let animation = CABasicAnimation(keyPath: "shadowPath")
            animation.fromValue = layer.presentation()?.shadowPath ?? old
            animation.toValue = path
            animation.duration = context.duration
            animation.timingFunction = context.timingFunction
            layer.add(animation, forKey: "shadowPath")
        }
        layer.shadowPath = path
    }
}
