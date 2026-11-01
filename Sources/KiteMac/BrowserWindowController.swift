import AppKit
import KiteCore
import SwiftUI

/// One browser window: theme backdrop, sidebar, the selected tab's web view,
/// the loading glow, and the command bar overlay, back to front.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private enum Layout {
        static let defaultSidebarWidth: CGFloat = 240
        static let sidebarWidths = ArcMetrics.Sidebar.widths
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
    /// View → Show Toolbar's bar across the top of the card.
    private var toolbarHost: NSHostingView<PageToolbar>!
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private let resizeHandle = SidebarResizeHandle()
    private var sidebarHost: NSHostingView<SidebarView>!
    /// The sidebar's Claude button; the app delegate connects it (not in incognito windows).
    let claudeButton = ClaudeButtonModel()
    let downloadsButton = DownloadsButtonModel()
    /// Claude's chat bubble over the page; AppDelegate connects it to Claude Tasks.
    let claudeBubble = ClaudeBubbleModel()
    private var claudeBubbleHost: NSHostingView<ClaudeBubble>!
    private var trafficLights: TrafficLights!
    private var commandBarHost: NSHostingView<CommandBarOverlay>!
    private var contentLeading: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarTop: NSLayoutConstraint!
    private var sidebarBottom: NSLayoutConstraint!
    /// The resize handle straddles the content card's edge when docked, the peek card's right edge while peeking.
    private var resizeHandleDocked: NSLayoutConstraint!
    private var resizeHandlePeek: NSLayoutConstraint!
    /// A resize drag is under way; a peeking card doesn't slide out until it ends.
    private var resizingSidebar = false
    private let peekCard = PeekCard()
    private let peekEdge = HoverStrip()
    private let peekZone = HoverStrip()
    private var peeking = false
    private var peekTimer: DispatchWorkItem?
    private var sidebarWidth: CGFloat
    private var appearanceObservation: NSKeyValueObservation?
    private var firstResponderObservation: NSKeyValueObservation?
    /// Keys typed while the command bar's field doesn't exist yet, and the monitor holding them.
    private var heldKeys: [NSEvent] = []
    private var heldKeyMonitor: Any?

    /// The focused tab: the selected one, or the focused pane of its split.
    private var shownTabID: UUID?
    private var shownSpaceID: UUID?
    private(set) weak var shownPage: WebPage?
    /// Every tab on screen in pane order, and its page: one, or a split's panes.
    private var shownTabIDs: [UUID] = []
    private var shownPages: [UUID: WebPage] = [:]
    private let splitPanes = SplitPanesView()
    private var paneClickMonitor: Any?
    private var spaceSwipe: SpaceSwipeController!
    /// The page card, in window coordinates: where Chrome's extension install dialog hangs.
    var webAreaInWindow: NSRect { contentFrame.convert(contentFrame.bounds, to: nil) }
    /// After every sync: tabs, selection or pages may have changed.
    var didSync: (() -> Void)?
    /// The crashed-tab page over the shown tab, while its renderer is dead.
    private var sadTab: NSHostingView<SadTabView>?
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
        let window = BrowserWindow(
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
        // A page that navigates while the command bar is open takes the keyboard (Chromium
        // focuses the new page); the bar takes it back so typing and Esc keep working.
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.keepCommandBarFocused() }
            }
        }
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// True while closing the window should only hide it: Claude tasks are working in its tabs.
    var hidesInsteadOfClosing: (() -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isIncognito, hidesInsteadOfClosing?() == true else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
        paneClickMonitor = nil
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

        let actions = SidebarActions(
            goBack: { [weak self] in self?.goBack(nil) },
            goForward: { [weak self] in self?.goForward(nil) },
            reload: { [weak self] in self?.reload(nil) },
            forceReload: { [weak self] in self?.forceReload(nil) },
            toggleSidebar: { [weak self] in self?.store.toggleSidebar() },
            closeTab: { [weak self] id in self?.close(tab: id) },
            addSplitView: { [weak self] in self?.addSplitView(nil) },
            editTheme: { [weak self] id in self?.editTheme(ofSpace: id) },
            renameSpace: { [weak self] id in self?.renameSpace(id: id) },
            changeSpaceIcon: { [weak self] id in self?.changeIcon(ofSpace: id) },
            deleteSpace: { [weak self] id in self?.deleteSpace(id) }
        )
        spaceSwipe = SpaceSwipeController(
            store: store,
            sidebar: { [weak self] in self?.sidebarHost },
            showTheme: { [weak self] from, to, progress in
                self?.themeView.setInteractiveTheme(from: from, to: to, progress: progress)
                self?.peekCard.theme.setInteractiveTheme(from: from, to: to, progress: progress)
            },
            settleTheme: { [weak self] theme in
                self?.themeView.finishInteractiveTheme(landingOn: theme)
                self?.peekCard.theme.finishInteractiveTheme(landingOn: theme)
            }
        )
        var sidebar = SidebarView(
            store: store,
            actions: actions,
            supportsDarkPages: pool.engine.supportsDarkPages,
            claude: claudeButton,
            downloads: downloadsButton,
            swipe: spaceSwipe.model
        )
        var toolbar = PageToolbar(store: store, actions: actions)
        #if canImport(CEFBridge)
        // Extensions run in the persistent Chromium profile only.
        if !isIncognito, pool.engine is ChromiumEngine {
            let extensions = ExtensionsModel.shared(engine: pool.engine)
            toolbar.extensions = extensions
            sidebar.showExtensions = { view in ExtensionsMenu.present(model: extensions, from: view) }
            sidebar.fieldAccessory = AnyView(OnePasswordFieldButton(model: extensions))
        }
        #endif
        sidebarHost = NSHostingView(rootView: sidebar)
        toolbarHost = NSHostingView(rootView: toolbar)
        toolbarHost.sizingOptions = []
        toolbarHost.isHidden = true
        contentClip.toolbar = toolbarHost
        commandBarHost = NSHostingView(rootView: CommandBarOverlay(store: store) { [weak self] suggestion, mode in
            self?.commit(suggestion, mode: mode)
        })
        for host in [sidebarHost as NSView, commandBarHost] {
            (host as? NSHostingView<SidebarView>)?.sizingOptions = []
            (host as? NSHostingView<CommandBarOverlay>)?.sizingOptions = []
        }
        commandBarHost.isHidden = true
        claudeBubbleHost = NSHostingView(rootView: ClaudeBubble(model: claudeBubble, store: store))
        claudeBubbleHost.sizingOptions = []
        claudeBubbleHost.isHidden = true
        claudeBubble.onOpenChange = { [weak self] open in self?.claudeBubbleOpened(open) }

        var dragStartWidth: CGFloat = 0
        resizeHandle.onBegin = { [weak self] in
            dragStartWidth = self?.sidebarWidth ?? 0
            self?.resizingSidebar = true
        }
        resizeHandle.onDrag = { [weak self] dx in self?.setSidebarWidth(dragStartWidth + dx) }
        resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            // Like Arc, a peek released away from the card stays out until the pointer comes back and leaves.
            resizingSidebar = false
            peekZone.resync()
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }

        materialView.material = .sidebar
        materialView.blendingMode = .behindWindow
        materialView.state = .followsWindowActiveState

        for view in [materialView, themeView, peekCard, sidebarHost!, contentFrame, glowView, resizeHandle, claudeBubbleHost!, commandBarHost!, peekEdge, peekZone] as [NSView] {
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
        sidebarTop = sidebarHost.topAnchor.constraint(equalTo: rootView.topAnchor)
        sidebarBottom = sidebarHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        resizeHandleDocked = resizeHandle.centerXAnchor.constraint(equalTo: contentFrame.leadingAnchor)
        resizeHandlePeek = resizeHandle.centerXAnchor.constraint(equalTo: sidebarHost.trailingAnchor)
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
            sidebarTop,
            sidebarBottom,
            sidebarWidthConstraint,

            peekCard.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            peekCard.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            peekCard.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            peekCard.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),

            peekEdge.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            peekEdge.topAnchor.constraint(equalTo: rootView.topAnchor),
            peekEdge.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            peekEdge.widthAnchor.constraint(equalToConstant: Peek.edgeWidth),

            // The card, the inset to its left (the pointer resting on the window's edge keeps it out) and,
            // like Arc, a margin to its right.
            peekZone.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            peekZone.topAnchor.constraint(equalTo: rootView.topAnchor),
            peekZone.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            peekZone.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor, constant: ArcMetrics.Sidebar.peekHoverMargin),

            // Like Arc: straddles the card's edge and spans the card's height, above the page and glow.
            // Peeking, it moves to the floating card's right edge but keeps the content card's height.
            resizeHandleDocked,
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

            // ⌘J sits where ⌘T does, so it covers the window the same way.
            claudeBubbleHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            claudeBubbleHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            claudeBubbleHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            claudeBubbleHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            commandBarHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            commandBarHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        trafficLights = TrafficLights(window: window, host: sidebarHost)

        // The peeking sidebar draws over the page; its views are raised by z-position rather
        // than reordered, which would drop their constraints.
        for view in [peekCard, sidebarHost!, resizeHandle, claudeBubbleHost!, commandBarHost!] as [NSView] { view.wantsLayer = true }
        commandBarHost.layer?.zPosition = 20
        claudeBubbleHost.layer?.zPosition = 15
        peekCard.isHidden = true
        peekEdge.onHover = { [weak self] inside in self?.edgeHovered(inside) }
        peekZone.onHover = { [weak self] inside in
            guard let self, !inside, !resizingSidebar else { return }
            setPeeking(false)
        }

        splitPanes.onDividerDrag = { [weak self] index, fraction, minimum in
            guard let self, let split = store.state.selectedSplit else { return }
            store.mutate { $0.moveSplitDivider(split.id, index: index, fraction: fraction, minimum: minimum) }
        }
        // Clicking into a pane focuses it. Web views take their own clicks, so watch from outside.
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.focusPane(under: event)
            return event
        }
        if let window = window as? BrowserWindow { spaceSwipe.install(in: window) }
    }

    private func focusPane(under event: NSEvent) {
        guard event.window === window, shownTabIDs.count > 1, splitPanes.superview != nil else { return }
        let point = splitPanes.convert(event.locationInWindow, from: nil)
        guard let id = splitPanes.pane(at: point), id != shownTabID else { return }
        store.mutate { $0.select(tab: id) }
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
        if sidebarVisible { contentLeading.constant = width } else if !peeking { sidebarLeading.constant = -width }
        // Lay out now so the theme's cutout moves in the same frame as the page.
        rootView.layoutSubtreeIfNeeded()
    }

    private func layoutChanged() {
        // Metal works top-left; AppKit's origin is bottom-left.
        // The theme shows through the gaps between a split's panes.
        let frame = shownTabIDs.count > 1 ? .zero : cardCoverDuringToggle ?? contentFrame.frame
        themeView.cutoutRect = CGRect(x: frame.minX, y: rootView.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        themeView.cutoutCornerRadius = Layout.cornerRadius
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
        peekCard.theme.setTheme(space.theme, animated: shownSpaceID != nil)
        peekCard.material.appearance = appearance
        shownSpaceID = space.id
        // Hidden in the titlebar, but it names the window in the Window menu and Mission Control.
        let title = state.selectedTab?.title ?? ""
        if isIncognito {
            window?.title = title.isEmpty ? "Incognito" : title + " (Incognito)"
        } else {
            window?.title = title.isEmpty ? space.name : title
        }

        let selected = state.selectedTab
        let visible = state.visibleTabs
        if selected?.id != shownTabID || visible.map(\.id) != shownTabIDs {
            show(visible, focused: selected?.id)
        }
        if let split = state.selectedSplit {
            splitPanes.setLayout(factors: split.normalizedFactors, orientation: split.orientation)
        }
        let live = state.allTabIDs
        pool.retain(live: live, restorable: live.union(state.recentlyClosed.map(\.tab.id)))
        applyDarkPage()
        adblocker.setPolicy(enabled: state.blocksAds, allowedHosts: state.adblockAllowedHosts)

        updateCommandBar()
        updateSidebar()
        updateToolbar()
        didSync?()
    }

    /// Puts `tabs` on screen, side by side when there are several, and focuses `focused`.
    private func show(_ tabs: [BrowserTab], focused: UUID?) {
        hideFindBar()
        let ids = tabs.map(\.id)
        if ids != shownTabIDs {
            for page in shownPages.values { page.view.removeFromSuperview() }
            splitPanes.setPanes([])
            splitPanes.removeFromSuperview()
            shownPages = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, pool.page(for: $0)) })
            shownTabIDs = ids
            if tabs.count > 1 {
                splitPanes.setPanes(ids.map { ($0, shownPages[$0]!.view) })
                contentClip.addSubview(splitPanes, positioned: .below, relativeTo: toolbarHost)
                contentClip.page = splitPanes
            } else if let id = ids.first, let page = shownPages[id] {
                page.view.autoresizingMask = []
                contentClip.addSubview(page.view, positioned: .below, relativeTo: toolbarHost)
                contentClip.page = page.view
            } else {
                contentClip.page = nil
            }
            setSplitChrome(tabs.count > 1)
            updateToolbar()
        }
        shownTabID = focused
        shownPage = focused.flatMap { shownPages[$0] }
        emptyLabel.isHidden = !tabs.isEmpty
        guard let focused else {
            glowView.setLoading(false, progress: 0)
            updateSadTab()
            return
        }
        pool.didShow(ids)
        // A new split pane's command bar is about to open and takes the focus.
        if store.commandBar == nil, store.pendingSplitPane == nil {
            shownPage?.focus()
        }
        pageChanged(focused)
    }

    /// How far the focused pane's top and trailing edges sit inside the content card (zero without a split).
    var focusedPaneInsets: (top: CGFloat, trailing: CGFloat) {
        guard shownTabIDs.count > 1, let id = shownTabID, let frame = splitPanes.frame(of: id) else { return (0, 0) }
        // The split view is flipped and fills the card.
        return (frame.minY, splitPanes.bounds.width - frame.maxX)
    }

    /// A split's panes are cards of their own, so the shared card stops drawing while one is shown.
    private func setSplitChrome(_ split: Bool) {
        contentClip.layer?.backgroundColor = split ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.cgColor
        contentFrame.layer?.shadowOpacity = split ? 0 : ShadowView.opacity
        layoutChanged()
    }

    /// Dark pages follow the site, so this re-checks every pane on screen whenever a URL changes.
    /// The page remembers what it was last told and skips repeats, so a page made
    /// again for the same tab (discarded, restored) still gets it.
    private func applyDarkPage() {
        for (id, page) in shownPages {
            page.setForceDark(store.state.wantsDarkPage(for: store.state.tab(id)?.url, systemIsDark: store.systemIsDark))
        }
    }

    private func pageChanged(_ id: UUID) {
        guard id == shownTabID else { return }
        let page = store.pages[id] ?? PageStatus()
        glowView.setLoading(page.isLoading, progress: page.progress)
        updateSadTab()
    }

    private func updateSadTab() {
        guard let code = shownTabID.flatMap({ store.pages[$0]?.crashCode }) else {
            sadTab?.removeFromSuperview()
            sadTab = nil
            return
        }
        let view = SadTabView(code: code) { [weak self] in self?.shownPage?.reload() }
        let host = sadTab ?? NSHostingView(rootView: view)
        host.rootView = view
        // In a split it covers only the crashed pane.
        if shownTabIDs.count > 1, let id = shownTabID, let pane = splitPanes.frame(of: id) {
            host.frame = splitPanes.convert(pane, to: contentClip)
            host.autoresizingMask = []
        } else {
            host.frame = contentClip.bounds
            host.autoresizingMask = [.width, .height]
        }
        // Re-adding brings it above a page shown since.
        contentClip.addSubview(host)
        sadTab = host
    }

    private func updateToolbar() {
        // Arc disables Show Toolbar in split view tabs; the bar belongs to a single page.
        let visible = store.state.showsToolbar && shownTabIDs.count <= 1
        toolbarHost.isHidden = !visible
        contentClip.topInset = visible ? PageToolbar.Metrics.inset : 0
    }

    /// ⌘J: Claude's chat bubble.
    @objc func toggleClaudeBubble(_ sender: Any?) {
        claudeBubble.toggle()
    }

    private func claudeBubbleOpened(_ open: Bool) {
        claudeBubbleHost.isHidden = !open
        if open {
            // ⌘J and ⌘T share a spot: only one shows at a time.
            store.hideCommandBar()
            window?.makeFirstResponder(claudeBubbleHost)
        } else if store.commandBar == nil {
            // Closed by ⌘T opening: leave the focus in ⌘T's field.
            shownPage?.focus()
        }
    }

    @objc func toggleToolbar(_ sender: Any?) {
        store.mutate { $0.showsToolbar.toggle() }
    }

    private func updateCommandBar() {
        let visible = store.commandBar != nil
        if visible != commandBarVisible {
            commandBarVisible = visible
            commandBarHost.isHidden = !visible
            if visible {
                claudeBubble.close()
            } else {
                releaseHeldKeys(replay: false)
                for page in shownPages.values { page.allowFocus() }
                // Closed by ⌘J opening: leave the focus in Claude's field.
                if !claudeBubble.isOpen { shownPage?.focus() }
            }
        }
        // Also when ⌘T or ⌘L comes while the bar is already open.
        keepCommandBarFocused()
    }

    private var commandBarHasFocus: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: commandBarHost) == true
    }

    private func keepCommandBarFocused(attempt: Int = 0) {
        guard commandBarVisible else { return }
        if !commandBarHasFocus { focusCommandBar(attempt: attempt) }
        if commandBarHasFocus { releaseHeldKeys(replay: true) }
    }

    /// Hands the bar's field the keyboard before the next key event is handled, so typing
    /// straight after ⌘T or ⌘L lands in the bar rather than the page. SwiftUI's own focus
    /// request (onAppear) comes a run loop later, after those keys are gone.
    private func focusCommandBar(attempt: Int = 0) {
        // Builds the bar's views now instead of on the next display pass.
        commandBarHost.layoutSubtreeIfNeeded()
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(field(in:)).first
        }
        guard let field = field(in: commandBarHost) else {
            // The bar's first open in a session: SwiftUI makes the field on a later pass.
            // Hold what's typed meanwhile so it lands in the bar, not the page.
            holdKeys()
            guard attempt < 50 else { return releaseHeldKeys(replay: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.keepCommandBarFocused(attempt: attempt + 1)
            }
            return
        }
        // Otherwise Chromium still thinks its page has the keyboard and takes it back on the
        // next navigation, or when a new page (a split pane, a tab at launch) starts up.
        for page in shownPages.values { page.blur() }
        window?.makeFirstResponder(field)
    }

    private func holdKeys() {
        guard heldKeyMonitor == nil else { return }
        heldKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.hold(event) == true ? nil : event
        }
    }

    private func hold(_ event: NSEvent) -> Bool {
        // Shortcuts still go to the menu.
        guard event.window === window, !event.modifierFlags.contains(.command) else { return false }
        heldKeys.append(event)
        return true
    }

    private func releaseHeldKeys(replay: Bool) {
        guard let monitor = heldKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        heldKeyMonitor = nil
        let keys = heldKeys
        heldKeys = []
        if replay { keys.forEach { window?.sendEvent($0) } }
    }

    private func updateSidebar() {
        let visible = store.isSidebarVisible
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        resizeHandle.isHidden = !visible
        sidebarHost.isHidden = false
        peekTimer?.cancel()
        peekEdge.isActive = false
        // Docking a peeking sidebar: the card grows out to the window's edges, then is plain sidebar.
        let wasPeeking = peeking
        peeking = false
        peekZone.isActive = false
        sidebarTop.constant = 0
        sidebarBottom.constant = 0
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
                if wasPeeking { self.raiseSidebar(false) }
                self.peekEdge.isActive = !self.sidebarVisible
                self.layoutChanged()
            }
        })
    }

    // MARK: Peek

    private func edgeHovered(_ inside: Bool) {
        peekTimer?.cancel()
        guard inside, !sidebarVisible, !peeking else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setPeeking(true) }
        }
        peekTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Peek.delay, execute: work)
    }

    private func setPeeking(_ peek: Bool) {
        guard peek != peeking, !sidebarVisible else { return }
        peeking = peek
        peekTimer?.cancel()
        sidebarToggles += 1
        let toggle = sidebarToggles
        let offscreen = -(sidebarWidth + Peek.inset)

        if peek {
            peekEdge.isActive = false
            sidebarHost.isHidden = false
            raiseSidebar(true)
            sidebarLeading.constant = Peek.inset
            sidebarTop.constant = Peek.inset
            sidebarBottom.constant = -Peek.inset
            rootView.layoutSubtreeIfNeeded()
            // Final frames are set once; Core Animation springs the layers in from off the edge.
            Peek.slideIn(sidebarHost.layer, from: offscreen)
            Peek.slideIn(peekCard.layer, from: offscreen)
            peekZone.isActive = true
            resizeHandle.isHidden = false
            return
        }

        peekZone.isActive = false
        resizeHandle.isHidden = true
        let curve = ArcMetrics.Motion.sidebarToggleCurve
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ArcMetrics.Motion.sidebarToggleDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: curve.x1, curve.y1, curve.x2, curve.y2)
            context.allowsImplicitAnimation = true
            sidebarLeading.constant = offscreen
            rootView.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, toggle == self.sidebarToggles else { return }
                self.sidebarHost.isHidden = true
                self.raiseSidebar(false)
                self.sidebarLeading.constant = -self.sidebarWidth
                self.sidebarTop.constant = 0
                self.sidebarBottom.constant = 0
                self.peekEdge.isActive = true
            }
        })
    }

    /// Puts the sidebar and its card above the page while peeking, and back under it after.
    private func raiseSidebar(_ raise: Bool) {
        peekCard.isHidden = !raise
        peekCard.layer?.zPosition = raise ? 10 : 0
        sidebarHost.layer?.zPosition = raise ? 11 : 0
        resizeHandle.layer?.zPosition = raise ? 12 : 0
        resizeHandleDocked.isActive = !raise
        resizeHandlePeek.isActive = raise
        rootView.frontViews = raise ? [resizeHandle, sidebarHost] : []
    }

    // MARK: Commands

    private func commit(_ suggestion: CommandSuggestion, mode: CommandBarMode) {
        // A page picked for a new split pane keeps the split; anything else leaves it to be cancelled.
        switch suggestion {
        case .open, .search, .siteSearch, .history: store.pendingSplitPane = nil
        default: break
        }
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
        if let valid = validateSplitItem(item) { return valid }
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
        case #selector(goBack(_:)), #selector(goForward(_:)) where item.isHidden:
            // ⌘← / ⌘→ belong to a focused AppKit text field (the command bar) for line start/end.
            // A disabled key equivalent passes the key on.
            return !(window?.firstResponder is NSText)
        case #selector(toggleToolbar(_:)):
            item.title = store.state.showsToolbar ? "Hide Toolbar" : "Show Toolbar"
            return store.state.selectedSplit == nil
        case #selector(toggleStayOnTop(_:)):
            item.state = window?.level == .floating ? .on : .off
        case #selector(setAsDefaultBrowser(_:)):
            item.state = Self.isDefaultBrowser ? .on : .off
        case #selector(share(_:)), #selector(savePageAs(_:)),
             #selector(clearCookiesAndRefresh(_:)), #selector(clearCacheAndRefresh(_:)):
            return store.state.selectedTab?.url != nil
        case #selector(stopLoading(_:)):
            return shownPage?.isLoading ?? false
        case #selector(showOnePassword(_:)):
            #if canImport(CEFBridge)
            return !isIncognito
            #else
            return false
            #endif
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
    @objc func editTheme(_ sender: Any?) { editTheme(ofSpace: store.state.selectedSpaceID) }

    func editTheme(ofSpace id: UUID) {
        if !store.isSidebarVisible { store.toggleSidebar() }
        ThemeEditor.present(store: store, spaceID: id, from: sidebarHost)
    }
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
    /// The toolbar across the top, when shown; the page starts below `topInset`.
    weak var toolbar: NSView? {
        didSet {
            guard let toolbar, toolbar.superview !== self else { return }
            addSubview(toolbar)
            layoutPage()
        }
    }
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { layoutPage() } }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPage()
    }

    private func layoutPage() {
        let frame = CGRect(x: 0, y: 0, width: max(bounds.width, minimumPageWidth), height: bounds.height - topInset)
        if let page, page.frame != frame { page.frame = frame }
        toolbar?.frame = CGRect(x: 0, y: bounds.height - PageToolbar.Metrics.inset, width: bounds.width, height: PageToolbar.Metrics.inset)
    }
}

/// Reports layout passes so the theme can skip pixels under the web content.
final class RootView: NSView {
    var onLayout: (() -> Void)?
    /// Take clicks, first to last, ahead of the views above them in subview order (they're raised by z-position).
    var frontViews: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for front in frontViews where !front.isHidden {
            if let hit = front.hitTest(convert(point, from: superview)) { return hit }
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Draws the content card's shadow from an explicit path, which spares Core
/// Animation an offscreen pass to work out the shape every frame.
final class ShadowView: NSView {
    static let opacity: Float = 0.18
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Self.opacity
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
