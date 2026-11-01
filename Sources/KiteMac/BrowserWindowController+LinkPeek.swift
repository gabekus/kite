import AppKit
import KiteCore

/// Arc's Peek: a link from a pinned tab or favorite to another site (or any ⇧-clicked link) opens in a card
/// over the page instead of navigating the tab. Esc, ⌘W, the close button or a click outside the card close
/// it; the other buttons turn its page into a tab or a split pane. (`setPeeking` is the sidebar's reveal.)
@MainActor
final class LinkPeekSession {
    let sourceTabID: UUID
    let page: WebPage
    let view: LinkPeekView
    var url: URL?
    var title: String?
    var keyMonitor: Any?

    init(sourceTabID: UUID, page: WebPage, url: URL, splitTitle: String?) {
        self.sourceTabID = sourceTabID
        self.page = page
        self.url = url
        self.view = LinkPeekView(page: page.view, splitTitle: splitTitle)
    }
}

extension BrowserWindowController {
    /// Opens `url` in a Peek over tab `tabID`, which must be on screen.
    func openLinkPeek(_ url: URL, from tabID: UUID) {
        guard let window, store.state.visibleTabs.contains(where: { $0.id == tabID }) else {
            store.mutate { $0.openTab(url: url) }
            return
        }
        closeLinkPeek(animated: false)
        let split = store.state.selectedSplit
        let splitTitle: String? = (split?.tabIDs.count ?? 1) < SplitView.maxPanes
            ? (split == nil ? "Create Split View" : "Add to Split View") : nil
        let page = pool.engine.makePage(url: url, restoring: nil)
        let session = LinkPeekSession(sourceTabID: tabID, page: page, url: url, splitTitle: splitTitle)
        linkPeek = session
        page.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            handleLinkPeekEvent(event, session: session)
        }
        session.view.onControl = { [weak self] control in
            switch control {
            case .close: self?.closeLinkPeek(animated: true)
            case .expand: self?.expandLinkPeek()
            case .split: self?.splitLinkPeek()
            }
        }
        session.view.onBackgroundClick = { [weak self] in self?.closeLinkPeek(animated: true) }
        // Esc closes it, as Arc's "Exit the current context. Such as closing a Peek window".
        session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, event.window === window, event.keyCode == 53, store.commandBar == nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            closeLinkPeek(animated: true)
            return nil
        }
        installOverContent(session.view)
        let pointerInWindow = window.mouseLocationOutsideOfEventStream
        let pointer = session.view.convert(pointerInWindow, from: nil)
        let fallback = session.view.bounds.contains(pointer) ? pointer : nil
        page.setVisible(true)
        page.focus()
        // Arc tweens the card from the clicked element: ask the source page what is under the pointer.
        guard let sourcePage = pool.loadedPage(tabID), sourcePage.view.window === window else {
            return session.view.animateIn(from: nil, pointer: fallback)
        }
        session.view.prepareToAnimateIn()
        var started = false
        let start: (NSRect?) -> Void = { [weak self, weak session] source in
            guard !started, let session, self?.linkPeek === session else { return }
            started = true
            session.view.animateIn(from: source, pointer: fallback)
        }
        linkPeekSource(in: sourcePage, to: url, atWindowPoint: pointerInWindow, convertedTo: session.view) { start($0) }
        // The page answers within a frame or two; don't hold the card back for a busy one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { start(nil) }
    }

    /// The frame (in `view`) of the clicked element in `page`, from the page itself: the element under
    /// `point` (window points) when it's in a link to `url`, else that link (`LinkPeek.sourceRectScript`).
    private func linkPeekSource(in page: WebPage, to url: URL, atWindowPoint point: NSPoint, convertedTo view: NSView,
                                completion: @escaping (NSRect?) -> Void) {
        let pageView = page.view
        var local = pageView.convert(point, from: nil)
        if !pageView.isFlipped { local.y = pageView.bounds.height - local.y }
        let zoom = page.zoomFactor > 0 ? page.zoomFactor : 1
        let at = pageView.bounds.contains(local) ? (x: Double(local.x / zoom), y: Double(local.y / zoom)) : nil
        page.evaluateJavaScript(LinkPeek.sourceRectScript(point: at, url: url.absoluteString)) { [weak pageView, weak view] result in
            guard let pageView, let view, let frame = LinkPeek.sourceFrame(scriptResult: result, zoom: zoom) else {
                return completion(nil)
            }
            var rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            if !pageView.isFlipped { rect.origin.y = pageView.bounds.height - rect.maxY }
            completion(view.convert(rect, from: pageView))
        }
    }

    func closeLinkPeek(animated: Bool) {
        guard let session = linkPeek else { return }
        linkPeek = nil
        if let monitor = session.keyMonitor { NSEvent.removeMonitor(monitor) }
        session.page.onEvent = nil
        let finish = {
            session.view.removeFromSuperview()
            if session.view.page != nil { session.page.close() }
        }
        if animated { session.view.animateOut(completion: finish) } else { finish() }
        shownPage?.focus()
    }

    /// The Peek's page becomes a new tab (Arc's expand), already loaded.
    private func expandLinkPeek() {
        guard let session = linkPeek, let url = session.url else { return }
        _ = session.view.detachPage()
        closeLinkPeek(animated: false)
        pool.openTab(with: session.page, url: url)
        if let title = session.title, let id = store.state.selectedTab?.id { store.pageTitleChanged(id, title) }
    }

    /// Arc's "Create Split View" / "Add to Split View": the Peek's page becomes a pane next to the tab.
    private func splitLinkPeek() {
        guard let session = linkPeek, let url = session.url else { return }
        _ = session.view.detachPage()
        closeLinkPeek(animated: false)
        let id = UUID()
        pool.register(existing: session.page, id: id)
        guard store.mutate({ $0.addSplitPane(id: id) }) == .added(id) else {
            pool.discard(id, keepHistory: false)
            return
        }
        store.mutate { $0.update(tab: id) { $0.url = url } }
        if let title = session.title { store.pageTitleChanged(id, title) }
    }

    private func handleLinkPeekEvent(_ event: PageEvent, session: LinkPeekSession) {
        switch event {
        case .url(let url):
            if let url { session.url = url }
        case .title(let title):
            session.title = title
        case .closeRequested:
            closeLinkPeek(animated: true)
        case .openInNewTab(let url, let foreground):
            store.mutate { $0.openTab(url: url, select: foreground) }
        case .openInLinkPeek(let url):
            store.mutate { $0.openTab(url: url) }
        case .openInSplit(let url):
            // The Peek's page isn't a pane yet: a ⌥⌘-click in it opens a background tab, like ⌘-click.
            store.mutate { $0.openTab(url: url, select: false) }
        case .popup(let popup):
            pool.openTab(with: popup)
        case let .openLink(url, target):
            openLinkFromPageMenu(url, target)
        case .pageCommand(.viewPageSource):
            if let url = session.url, let source = URL(string: "view-source:" + url.absoluteString) {
                store.mutate { _ = $0.openTab(url: source) }
            }
        case .pageCommand:
            // Save As… and Print… act on a tab; Kite doesn't run them on a Peek.
            NSSound.beep()
        case .permissionRequest(let request):
            // Kite doesn't prompt over a Peek yet (where Arc shows it there wasn't read).
            request.respond(nil)
        case .favicon, .progress, .navigationState, .blockedCount, .crashed, .addExtension, .linkHover, .media,
             .permissionRequestCancelled:
            break
        }
    }
}
