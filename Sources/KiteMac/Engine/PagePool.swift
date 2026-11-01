import AppKit
import KiteCore

/// Creates, tracks and hibernates the page behind each tab, for either engine.
///
/// Only the selected tab (or its split's panes) is on screen; the rest are told they're hidden so the
/// engine throttles them. At most `policy.maxLiveTabs` pages exist at once and
/// the least recently shown are torn down (keeping whatever history the engine
/// can save). On launch nothing loads except the selected tab.
@MainActor
final class PagePool {
    let engine: WebEngine
    private unowned let store: BrowserStore
    private var policy = LiveTabPolicy(maxLiveTabs: 6)

    private var pages: [UUID: WebPage] = [:]
    private var lastShown: [UUID: Date] = [:]
    private var savedState: [UUID: Any] = [:]
    private var visibleIDs: Set<UUID> = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Installs started from Google's "Add to Kite" buttons, by extension id.
    private var extensionInstalls: [String: BackgroundExtensionInstall] = [:]

    init(engine: WebEngine, store: BrowserStore) {
        self.engine = engine
        self.store = store
        watchMemoryPressure()
    }

    /// Called for every page made, including popups (before their tab exists).
    var onPageCreated: ((UUID, WebPage) -> Void)?
    /// Called when a tab's page stops loading.
    var onLoadFinished: ((UUID) -> Void)?
    /// A link clicked in tab `UUID` opens in Arc's Peek card (`LinkPeek`); nil opens it as a new tab.
    var onLinkPeek: ((UUID, URL) -> Void)?

    func loadedPage(_ id: UUID) -> WebPage? { pages[id] }
    var livePages: [UUID: WebPage] { pages }

    func page(for tab: BrowserTab) -> WebPage {
        if let existing = pages[tab.id] { return existing }
        // A tab on one of Kite's own pages gets a blank page; the window draws the page over it.
        let url = InternalPage(tab.url) == nil ? tab.url : nil
        let page = engine.makePage(url: url, restoring: savedState.removeValue(forKey: tab.id))
        register(page, id: tab.id)
        return page
    }

    /// Takes over a page made elsewhere (a Little Kite window's), for a new tab. Returns the tab's id.
    func adopt(_ page: WebPage) -> UUID {
        let id = UUID()
        register(page, id: id)
        return id
    }

    /// The tabs now on screen: one, or a split's panes.
    func didShow(_ ids: [UUID]) {
        let shown = Set(ids)
        for previous in visibleIDs.subtracting(shown) { pages[previous]?.setVisible(false) }
        visibleIDs = shown
        let now = Date()
        for id in ids {
            pages[id]?.setVisible(true)
            lastShown[id] = now
        }
        hibernate(policy.tabsToEvict(live: lastShown, protected: shown))
    }

    /// Drops pages for tabs that no longer exist, and saved history for tabs that can't come back.
    func retain(live: Set<UUID>, restorable: Set<UUID>) {
        for id in pages.keys where !live.contains(id) {
            discard(id, keepHistory: true)
        }
        for id in savedState.keys where !restorable.contains(id) {
            savedState[id] = nil
        }
    }

    /// A new selected tab showing `page`, which already exists (a popup, or a Peek's page expanded). `url` is
    /// what it shows already: WebKit doesn't report a page's URL again until it changes.
    func openTab(with page: WebPage, url: URL? = nil) {
        // Register before the tab exists so selecting it reuses this page.
        let newID = UUID()
        register(page, id: newID)
        store.mutate { $0.openTab(id: newID, url: url) }
    }

    /// Registers `page` (a Peek's) for a tab the caller is about to add with `id`.
    func register(existing page: WebPage, id: UUID) {
        register(page, id: id)
    }

    func discard(_ id: UUID, keepHistory: Bool) {
        guard let page = pages.removeValue(forKey: id) else { return }
        savedState[id] = keepHistory ? page.hibernationState() : nil
        lastShown[id] = nil
        page.onEvent = nil
        page.linkPeekPolicy = nil
        page.close()
        store.clearPage(id)
    }

    // MARK: Private

    private func register(_ page: WebPage, id: UUID) {
        pages[id] = page
        lastShown[id] = Date()
        page.onEvent = { [weak self] event in self?.handle(event, from: id) }
        page.linkPeekPolicy = { [weak self] url, shift in
            guard let self, self.onLinkPeek != nil else { return false }
            let state = self.store.state
            return LinkPeek.opensInPeek(section: state.location(of: id)?.section, from: state.tab(id)?.url, to: url, shift: shift)
        }
        onPageCreated?(id, page)
    }

    private func handle(_ event: PageEvent, from id: UUID) {
        switch event {
        case .title(let title):
            store.pageTitleChanged(id, title)
        case .url(let url):
            store.pageURLChanged(id, url)
        case .favicon(let url):
            store.faviconChanged(id, url)
        case .progress(let progress):
            store.updatePage(id) { $0.progress = progress }
        case let .navigationState(isLoading, canGoBack, canGoForward):
            store.updatePage(id) {
                if isLoading { $0.crashCode = nil }
                $0.isLoading = isLoading
                $0.canGoBack = canGoBack
                $0.canGoForward = canGoForward
            }
            if !isLoading {
                markInstalledExtensions(in: id)
                onLoadFinished?(id)
            }
        case .addExtension(let extensionID):
            guard extensionInstalls[extensionID] == nil, let source = pages[id],
                  let storeURL = ChromeWebStore.detailURL(for: extensionID) else { return }
            extensionInstalls[extensionID] = BackgroundExtensionInstall(
                extensionID: extensionID, storeURL: storeURL, engine: engine, source: source
            ) { [weak self] in self?.extensionInstalls[extensionID] = nil }
        case let .openInNewTab(url, foreground):
            store.mutate { $0.openTab(url: url, select: foreground) }
        case .popup(let page):
            openTab(with: page)
        case .openInLinkPeek(let url):
            // Out of the engine's navigation callback before making another page.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let onLinkPeek { onLinkPeek(id, url) } else { store.mutate { $0.openTab(url: url) } }
            }
        case .closeRequested:
            store.mutate { $0.close(tab: id) }
        case .linkHover(let hover):
            guard let view = pages[id]?.view else { return }
            LinkPreviewController.shared.hover(hover, in: view)
        case .blockedCount(let count):
            store.updatePage(id) { $0.blockedCount = count }
        case .crashed(let code):
            store.updatePage(id) {
                $0.crashCode = code
                $0.isLoading = false
            }
        }
    }

    /// On Google results, extensions that are already installed say "Added".
    private func markInstalledExtensions(in id: UUID) {
        guard let page = pages[id], GoogleSearch.isResultsPage(store.state.tab(id)?.url) else { return }
        for extensionID in BackgroundExtensionInstall.installedIDs() {
            guard let script = GoogleResultsScript.label(extensionID, "Added", disabled: true) else { continue }
            page.evaluateJavaScript(script) { _ in }
        }
    }

    /// Hibernates tabs unless they're playing media or using the camera or mic.
    private func hibernate(_ ids: [UUID]) {
        for id in ids {
            pages[id]?.checkBusy { [weak self] busy in
                guard let self, !busy, !self.visibleIDs.contains(id) else { return }
                self.discard(id, keepHistory: true)
            }
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hibernate(self.pages.keys.filter { !self.visibleIDs.contains($0) })
            }
        }
        source.resume()
        memoryPressure = source
    }
}
