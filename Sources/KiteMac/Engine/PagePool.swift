import AppKit
import KiteCore

/// Creates, tracks and hibernates the page behind each tab, for either engine.
///
/// Only the selected tab is on screen; the rest are told they're hidden so the
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
    private var visibleID: UUID?
    private var memoryPressure: DispatchSourceMemoryPressure?

    init(engine: WebEngine, store: BrowserStore) {
        self.engine = engine
        self.store = store
        watchMemoryPressure()
    }

    func loadedPage(_ id: UUID) -> WebPage? { pages[id] }

    func page(for tab: BrowserTab) -> WebPage {
        if let existing = pages[tab.id] { return existing }
        let page = engine.makePage(url: tab.url, restoring: savedState.removeValue(forKey: tab.id))
        register(page, id: tab.id)
        return page
    }

    func didShow(_ id: UUID) {
        if let previous = visibleID, previous != id { pages[previous]?.setVisible(false) }
        visibleID = id
        pages[id]?.setVisible(true)
        lastShown[id] = Date()
        hibernate(policy.tabsToEvict(live: lastShown, protected: [id]))
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

    func discard(_ id: UUID, keepHistory: Bool) {
        guard let page = pages.removeValue(forKey: id) else { return }
        savedState[id] = keepHistory ? page.hibernationState() : nil
        lastShown[id] = nil
        page.onEvent = nil
        page.close()
        store.clearPage(id)
    }

    // MARK: Private

    private func register(_ page: WebPage, id: UUID) {
        pages[id] = page
        lastShown[id] = Date()
        page.onEvent = { [weak self] event in self?.handle(event, from: id) }
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
                $0.isLoading = isLoading
                $0.canGoBack = canGoBack
                $0.canGoForward = canGoForward
            }
        case let .openInNewTab(url, foreground):
            store.mutate { $0.openTab(url: url, select: foreground) }
        case .popup(let page):
            // Register before the tab exists so selecting it reuses this page.
            let newID = UUID()
            register(page, id: newID)
            store.mutate { $0.openTab(id: newID, url: nil) }
        case .closeRequested:
            store.mutate { $0.close(tab: id) }
        }
    }

    /// Hibernates tabs unless they're playing media or using the camera or mic.
    private func hibernate(_ ids: [UUID]) {
        for id in ids {
            pages[id]?.checkBusy { [weak self] busy in
                guard let self, !busy, id != self.visibleID else { return }
                self.discard(id, keepHistory: true)
            }
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hibernate(self.pages.keys.filter { $0 != self.visibleID })
            }
        }
        source.resume()
        memoryPressure = source
    }
}
