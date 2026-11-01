import AppKit
import KiteCore

/// Arc's Peek: a link from a pinned tab or favorite to another site (or any ⇧-clicked link) opens in a card
/// over the page instead of navigating the tab. Esc, ⌘W, the close button, a click outside the card or a
/// two-finger swipe right close it, and Edit › Undo Close Peek (⌘Z) brings it back; the other buttons turn its page
/// into a tab or a split pane. Like Arc's `modalByWindowContent`, a Peek belongs to its tab: showing another tab
/// parks it, and it's back when its tab is shown again; meanwhile the tab's sidebar row shows the Peek's badge.
/// (`setPeeking` is the sidebar's reveal.)
@MainActor
final class LinkPeekSession {
    let sourceTabID: UUID
    let page: WebPage
    let view: LinkPeekView
    var url: URL?
    var title: String?
    var favicon: URL?
    var keyMonitor: Any?
    var swipe: LinkPeekSwipeController?

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
        discardParkedLinkPeek(of: tabID)
        let split = store.state.selectedSplit
        let splitTitle: String? = (split?.tabIDs.count ?? 1) < SplitView.maxPanes
            ? (split == nil ? "Create Split View" : "Add to Split View") : nil
        let page = pool.engine.makePage(url: url, restoring: nil)
        let session = LinkPeekSession(sourceTabID: tabID, page: page, url: url, splitTitle: splitTitle)
        linkPeek = session
        updateLinkPeekBadge(session)
        page.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            handleLinkPeekEvent(event, session: session)
        }
        session.view.onControl = { [weak self] control in
            switch control {
            case .close: self?.closeLinkPeek(animated: true, undoable: true)
            case .expand: self?.expandLinkPeek()
            case .split: self?.splitLinkPeek()
            }
        }
        session.view.onBackgroundClick = { [weak self] in self?.closeLinkPeek(animated: true, undoable: true) }
        presentLinkPeek(session)
        let pointerInWindow = window.mouseLocationOutsideOfEventStream
        let pointer = session.view.convert(pointerInWindow, from: nil)
        let fallback = session.view.bounds.contains(pointer) ? pointer : nil
        page.setVisible(true)
        page.focus()
        // Arc tweens the card from the clicked element: ask the source page what is under the pointer, and
        // crossfades from a picture of it (`sourceSnapshot`).
        guard let sourcePage = pool.loadedPage(tabID), sourcePage.view.window === window else {
            return session.view.animateIn(from: nil, pointer: fallback)
        }
        session.view.prepareToAnimateIn()
        var started = false
        var found: NSRect?
        let start: (NSRect?, NSImage?) -> Void = { [weak self, weak session] source, image in
            guard !started, let session, self?.linkPeek === session else { return }
            started = true
            session.view.animateIn(from: source, pointer: fallback, image: image)
        }
        linkPeekSource(in: sourcePage, to: url, atWindowPoint: pointerInWindow, convertedTo: session.view) { [weak sourcePage] source, inPage in
            guard let source, let inPage, let sourcePage else { return start(source, nil) }
            found = source
            sourcePage.captureImage(area: inPage) { data in start(source, data.flatMap(NSImage.init(data:))) }
        }
        // The page answers within a frame or two; don't hold the card back for a busy one (it then opens from
        // the element without the snapshot, or from the pointer).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { start(found, nil) }
    }

    /// Puts the Peek's card over the content and takes keys and swipes: when it opens, and when its tab is shown
    /// again after another tab parked it.
    private func presentLinkPeek(_ session: LinkPeekSession) {
        guard let window else { return }
        // Esc closes it, as Arc's "Exit the current context. Such as closing a Peek window".
        session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, event.window === window, event.keyCode == 53, store.commandBar == nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            closeLinkPeek(animated: true, undoable: true)
            return nil
        }
        installOverContent(session.view)
        let page = session.page
        session.swipe = LinkPeekSwipeController(
            view: session.view,
            evaluate: { [weak page] script, completion in
                guard let page else { return completion(nil) }
                page.evaluateJavaScript(script, completion: completion)
            },
            zoomFactor: { [weak page] in page?.zoomFactor ?? 1 },
            dismiss: { [weak self, weak session] in
                guard let self, let session, linkPeek === session else { return }
                closeLinkPeek(animated: true, undoable: true)
            }
        )
    }

    /// Another tab came forward: the Peek stays with its own tab, out of sight, its page kept loaded.
    func parkLinkPeek() {
        guard let session = linkPeek else { return }
        linkPeek = nil
        if let monitor = session.keyMonitor { NSEvent.removeMonitor(monitor) }
        session.keyMonitor = nil
        session.swipe?.stop()
        session.swipe = nil
        session.view.removeFromSuperview()
        session.page.setVisible(false)
        parkedLinkPeeks[session.sourceTabID] = session
    }

    /// Tab `tabID` is shown again: its parked Peek comes back over it as it was (Arc keeps the modal with its
    /// window content). Nothing animates.
    func unparkLinkPeek(for tabID: UUID?) {
        guard linkPeek == nil, let tabID, let session = parkedLinkPeeks.removeValue(forKey: tabID) else { return }
        linkPeek = session
        presentLinkPeek(session)
        session.page.setVisible(true)
        session.page.focus()
    }

    /// Closes parked Peeks whose tab is gone (or all of them, with nil).
    func discardParkedLinkPeeks(keeping live: Set<UUID>?) {
        for id in parkedLinkPeeks.keys where live?.contains(id) != true { discardParkedLinkPeek(of: id) }
    }

    private func discardParkedLinkPeek(of tabID: UUID) {
        guard let session = parkedLinkPeeks.removeValue(forKey: tabID) else { return }
        session.page.onEvent = nil
        if session.view.page != nil { session.page.close() }
        store.linkPeekBadges[tabID] = nil
    }

    /// The source tab's sidebar badge shows the Peek's page icon.
    private func updateLinkPeekBadge(_ session: LinkPeekSession) {
        let badge = LinkPeekBadge(page: session.url, icon: session.favicon)
        if store.linkPeekBadges[session.sourceTabID] != badge { store.linkPeekBadges[session.sourceTabID] = badge }
    }

    /// The frame (in `view`) of the clicked element in `page`, from the page itself: the element under
    /// `point` (window points) when it's in a link to `url`, else that link (`LinkPeek.sourceRectScript`).
    /// Also gives it in the page's own points from its top-left corner (for `captureImage`), clipped to the page.
    private func linkPeekSource(in page: WebPage, to url: URL, atWindowPoint point: NSPoint, convertedTo view: NSView,
                                completion: @escaping (NSRect?, CGRect?) -> Void) {
        let pageView = page.view
        var local = pageView.convert(point, from: nil)
        if !pageView.isFlipped { local.y = pageView.bounds.height - local.y }
        let zoom = page.zoomFactor > 0 ? page.zoomFactor : 1
        let at = pageView.bounds.contains(local) ? (x: Double(local.x / zoom), y: Double(local.y / zoom)) : nil
        page.evaluateJavaScript(LinkPeek.sourceRectScript(point: at, url: url.absoluteString)) { [weak pageView, weak view] result in
            guard let pageView, let view, let frame = LinkPeek.sourceFrame(scriptResult: result, zoom: zoom) else {
                return completion(nil, nil)
            }
            let fromTop = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            var rect = fromTop
            if !pageView.isFlipped { rect.origin.y = pageView.bounds.height - rect.maxY }
            let visible = fromTop.intersection(NSRect(origin: .zero, size: pageView.bounds.size))
            // Only a source wholly on the page has a picture that matches its frame.
            completion(view.convert(rect, from: pageView), visible == fromTop && !visible.isEmpty ? visible : nil)
        }
    }

    /// Closes the Peek. `undoable` is for the user's own dismissals (Esc, ⌘W, the close button, a click outside,
    /// the swipe, Redo): like Arc, they register "Close Peek" on the window's undo manager, so Edit › Undo Close
    /// Peek (⌘Z) reopens it. Replacing it or turning it into a tab or pane doesn't.
    func closeLinkPeek(animated: Bool, undoable: Bool = false) {
        guard let session = linkPeek else { return }
        linkPeek = nil
        if store.linkPeekBadges[session.sourceTabID] != nil { store.linkPeekBadges[session.sourceTabID] = nil }
        if undoable, let url = session.url, let undoManager = window?.undoManager {
            let sourceTabID = session.sourceTabID
            undoManager.registerUndo(withTarget: self) { controller in
                controller.reopenLinkPeek(url, from: sourceTabID)
            }
            undoManager.setActionName(LinkPeek.closeUndoActionName)
        }
        if let monitor = session.keyMonitor { NSEvent.removeMonitor(monitor) }
        session.swipe?.stop()
        session.page.onEvent = nil
        let finish = {
            session.view.removeFromSuperview()
            if session.view.page != nil { session.page.close() }
        }
        if animated { session.view.animateOut(completion: finish) } else { finish() }
        shownPage?.focus()
    }

    /// Undo Close Peek: the Peek comes back over the tab it was opened from, at the page it was showing. Arc's undo
    /// step keeps the URL, not the page, so the page loads again. Redo closes it again (Arc's `redoClose`).
    private func reopenLinkPeek(_ url: URL, from tabID: UUID) {
        guard store.state.location(of: tabID) != nil else { return }
        if store.state.selectedTab?.id != tabID { store.mutate { $0.select(tab: tabID) } }
        openLinkPeek(url, from: tabID)
        guard let session = linkPeek, session.sourceTabID == tabID, let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak session] controller in
            guard let session, controller.linkPeek === session else { return }
            controller.closeLinkPeek(animated: true, undoable: true)
        }
        undoManager.setActionName(LinkPeek.closeUndoActionName)
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
            updateLinkPeekBadge(session)
        case .favicon(let icon):
            session.favicon = icon
            updateLinkPeekBadge(session)
        case .title(let title):
            session.title = title
        case .closeRequested:
            if linkPeek === session { closeLinkPeek(animated: true) } else { discardParkedLinkPeek(of: session.sourceTabID) }
        case .openInNewTab(let url, let foreground):
            store.mutate { $0.openTab(url: url, select: foreground) }
        case .openInLinkPeek(let url):
            store.mutate { $0.openTab(url: url) }
        case .openInSplit(let url):
            // The Peek's page isn't a pane yet: a ⌥⌘-click in it opens a background tab, like ⌘-click.
            store.mutate { $0.openTab(url: url, select: false) }
        case .openInLittleKite(let url):
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.openLittleKiteWindow(url: url) }
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
        case .progress, .navigationState, .blockedCount, .crashed, .addExtension, .linkHover, .media, .callControls, .capturing,
             .permissionRequestCancelled:
            break
        }
    }
}
