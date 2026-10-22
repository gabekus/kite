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
        /// Grab area along the sidebar's trailing edge, inside its padding.
        static let resizeHandleWidth: CGFloat = 8
        static let inset: CGFloat = 8
        static let cornerRadius: CGFloat = 10
        static let glowMargin: CGFloat = 28
    }

    let store: BrowserStore
    let pool: PagePool
    private let rootView = RootView()
    private let themeView = ThemeView()
    private let glowView = GlowView(margin: Layout.glowMargin)
    private let contentFrame = ShadowView(cornerRadius: Layout.cornerRadius)
    private let contentClip = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private let resizeHandle = SidebarResizeHandle()
    private var sidebarHost: NSHostingView<SidebarView>!
    private var commandBarHost: NSHostingView<CommandBarOverlay>!
    private var contentLeading: NSLayoutConstraint!
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

    init(store: BrowserStore, engine: WebEngine) {
        self.store = store
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
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        window.setFrameAutosaveName("KiteMainWindow")
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
    }

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

        for view in [themeView, sidebarHost!, resizeHandle, contentFrame, glowView, commandBarHost!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        for view in [contentClip, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        contentFrame.addSubview(contentClip)
        contentClip.addSubview(emptyLabel)

        contentLeading = contentFrame.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: sidebarWidth)
        sidebarWidthConstraint = sidebarHost.widthAnchor.constraint(equalToConstant: sidebarWidth)
        NSLayoutConstraint.activate([
            themeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            themeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            themeView.topAnchor.constraint(equalTo: rootView.topAnchor),
            themeView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarWidthConstraint,

            resizeHandle.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: rootView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: Layout.resizeHandleWidth),

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
        if sidebarVisible { contentLeading.constant = width }
        // Lay out now so the theme's cutout moves in the same frame as the page.
        rootView.layoutSubtreeIfNeeded()
    }

    private func layoutChanged() {
        // Metal works top-left; AppKit's origin is bottom-left.
        let frame = contentFrame.frame
        themeView.cutoutRect = CGRect(x: frame.minX, y: rootView.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        themeView.cutoutCornerRadius = Layout.cornerRadius
    }

    // MARK: Sync with the store

    private func sync() {
        let state = store.state
        let space = state.selectedSpace

        themeView.setTheme(space.theme, animated: shownSpaceID != nil)
        glowView.setTheme(space.theme)
        sidebarHost.appearance = NSAppearance(named: space.theme.prefersDarkForeground ? .aqua : .darkAqua)
        shownSpaceID = space.id

        let selected = state.selectedTab
        if selected?.id != shownTabID {
            show(selected)
        }
        let live = state.allTabIDs
        pool.retain(live: live, restorable: live.union(state.recentlyClosed.map(\.tab.id)))
        appliedDark = appliedDark.filter { live.contains($0.key) }
        applyDarkPage()

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
        page.view.frame = contentClip.bounds
        page.view.autoresizingMask = [.width, .height]
        contentClip.addSubview(page.view)
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            contentLeading.animator().constant = visible ? sidebarWidth : Layout.inset
            sidebarHost.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Commands

    private func commit(_ suggestion: CommandSuggestion, mode: CommandBarMode) {
        store.hideCommandBar()
        switch suggestion {
        case .open(let url), .search(_, let url):
            if mode == .editCurrent, let id = store.state.selectedTab?.id {
                store.mutate { $0.update(tab: id) { $0.url = url } }
                pool.loadedPage(id)?.load(url)
            } else {
                store.mutate { $0.openTab(url: url) }
            }
        case .switchTab(let tab):
            store.mutate { $0.select(tab: tab.id) }
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
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}
