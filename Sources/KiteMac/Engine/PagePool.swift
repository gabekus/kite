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
    /// The window's engine: the default profile's, or incognito's. Tabs in a space with
    /// another profile get that profile's engine (`engine(forTab:)`).
    let engine: WebEngine
    private unowned let store: BrowserStore
    private var policy = LiveTabPolicy(maxLiveTabs: 6)

    private var pages: [UUID: WebPage] = [:]
    /// The profile folder each page was made in, so a space moved to another profile reloads.
    private var pageProfiles: [UUID: String] = [:]
    private var lastShown: [UUID: Date] = [:]
    /// Hidden tabs whose last busy check found media or capture in use: the live-tab limit skips them.
    private var busyIDs: Set<UUID> = []
    private var savedState: [UUID: Any] = [:]
    private var visibleIDs: Set<UUID> = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Each open popup's tab and the tab that opened it (window.open, or a link with
    /// rel=opener). Shared by every window, since a tab's page can move between them.
    private static var popupOpeners: [UUID: UUID] = [:]
    /// Installs started from Google's "Add to Kite" buttons, by extension id.
    private var extensionInstalls: [String: BackgroundExtensionInstall] = [:]

    init(engine: WebEngine, store: BrowserStore) {
        self.engine = engine
        self.store = store
        watchMemoryPressure()
    }

    /// Called for every page made, including popups (before their tab exists).
    var onPageCreated: ((UUID, WebPage) -> Void)?
    /// A tab's page opened another tab (a popup, a link to a new tab): Claude's tools follow the work there.
    var onTabOpened: ((_ child: UUID, _ opener: UUID) -> Void)?
    /// Called when a tab's page stops loading.
    var onLoadFinished: ((UUID) -> Void)?
    /// A tab's page started (true) or finished (false) loading (the install icon checks the page).
    var onLoadingChanged: ((UUID, WebPage, Bool) -> Void)?
    /// A link clicked in tab `UUID` opens in Arc's Peek card (`LinkPeek`); nil opens it as a new tab.
    var onLinkPeek: ((UUID, URL) -> Void)?
    /// The page menu's Open Link in New Window, Split View, Little Kite and Incognito Window.
    var onOpenLink: ((UUID, URL, PageContextMenu.LinkTarget) -> Void)?
    /// A link ⌥⌘-clicked in tab `id` with Settings › Links' Little Kite switch on. Without a handler
    /// (incognito windows: Little Kite runs on the normal profile) it opens in Split View instead.
    var onOpenLittleKite: ((UUID, URL) -> Void)?
    /// The page menu's Save As…, Print… and View Page Source, for tab `UUID`.
    var onPageCommand: ((UUID, PageContextMenu.PageCommand) -> Void)?
    /// What this window can do with a link, for the page menu.
    var contextMenuHost: (() -> PageContextMenu.Host)?
    /// Each tab's unanswered permission request (one at a time: a newer one dismisses the older).
    private(set) var permissionRequests: [UUID: PermissionRequest] = [:]
    /// A tab's permission request arrived, was answered or went away.
    var onPermissionRequestsChanged: (() -> Void)?

    /// Answers tab `id`'s permission request: true allows, false blocks ("Not Now"), nil dismisses.
    func answerPermissionRequest(_ id: UUID, allow: Bool?) {
        guard let request = permissionRequests.removeValue(forKey: id) else { return }
        request.respond(allow)
        onPermissionRequestsChanged?()
    }

    func loadedPage(_ id: UUID) -> WebPage? { pages[id] }
    /// While true, nothing hibernates: the window is asking its pages whether it may close.
    var holdsPages = false
    var livePages: [UUID: WebPage] { pages }

    /// The engine for tab `id`'s page: its space's profile (or, for a favorite, the current space's).
    func engine(forTab id: UUID) -> WebEngine {
        guard engine.profileDirectory != nil else { return engine }
        let state = store.state
        return engine.forProfile(state.profile(state.profileDirectory(ofTab: id)))
    }

    /// The engine for the current space's profile: extension popups and 1Password open in it.
    var currentEngine: WebEngine {
        guard engine.profileDirectory != nil else { return engine }
        let state = store.state
        return engine.forProfile(state.profile(state.selectedProfileDirectory))
    }

    /// The normal windows' pools this one shares tabs with, so a tab has one page between them.
    private(set) weak var shared: SharedPages?
    /// Another window took tab `UUID`'s page to show it there (`claim`).
    var onPageTaken: ((UUID) -> Void)?

    /// A linked window is closing: take back what this window shows a placeholder for from its pool.
    var onLinkedWindowClosing: ((PagePool) -> Void)?

    /// The live pages of this window and the windows it shares tabs with: each tab's page is in one of them.
    var linkedLivePages: [UUID: WebPage] {
        guard let shared else { return pages }
        return shared.livePages.merging(pages) { _, own in own }
    }

    func join(_ shared: SharedPages) {
        self.shared = shared
        shared.add(self)
    }

    /// The pages this window shared before it closed (`closeForWindow`).
    private weak var left: SharedPages?

    /// The closed window is shown again: it shares tabs with the other windows as before.
    func rejoinShared() {
        guard shared == nil, let left else { return }
        join(left)
    }

    /// This window is closing: the linked windows take the pages they show placeholders for, and every
    /// page still here closes, without asking (closing one of several windows ends no tabs, #338), so no
    /// renderer keeps running, or playing, with no window. Their history goes to a linked window, so
    /// those tabs load where they were when next shown.
    func closeForWindow() {
        let heir = shared?.closing(self)
        if let shared { left = shared }
        shared = nil
        for id in Array(pages.keys) { discard(id, keepHistory: heir != nil) }
        heir?.savedState.merge(savedState) { theirs, _ in theirs }
        savedState = [:]
    }

    /// `owner`'s window is about to close (before `closeForWindow`): this window takes the pages of `ids` that
    /// aren't on screen there, so Claude's background pages carry on here instead of closing and loading again.
    /// Pages on screen in the closing window close with it (their history comes here).
    func takeOver(_ ids: Set<UUID>, from owner: PagePool) {
        guard let shared, owner.shared === shared, owner !== self else { return }
        for id in ids {
            guard let page = owner.pages[id], page.view.window == nil, pages[id] == nil, let tab = store.state.tab(id) else { continue }
            _ = claim(tab)
        }
    }

    /// The tab's page wherever it is, made here when no linked window has one (automation, extensions).
    func page(for tab: BrowserTab) -> WebPage {
        if let existing = pages[tab.id] {
            if pageProfiles[tab.id] == engine(forTab: tab.id).profileDirectory { return existing }
            // Its space moved to another profile: nothing of the old page's session carries over.
            discard(tab.id, keepHistory: false)
        }
        if let elsewhere = shared?.livePage(tab.id, excluding: self) { return elsewhere.page }
        return makePage(for: tab)
    }

    /// The tab's page, to put on screen in this window: taken from the linked window showing it, so
    /// a tab never loads twice (Arc keeps one web content per tab and puts a placeholder where it was).
    func claim(_ tab: BrowserTab) -> WebPage {
        if let existing = pages[tab.id] {
            if pageProfiles[tab.id] == engine(forTab: tab.id).profileDirectory { return existing }
            discard(tab.id, keepHistory: false)
        }
        guard let (owner, page) = shared?.livePage(tab.id, excluding: self) else { return makePage(for: tab) }
        let profile = owner.pageProfiles[tab.id]
        let status = owner.store.pages[tab.id]
        let request = owner.release(tab.id)
        register(page, id: tab.id)
        pageProfiles[tab.id] = profile
        if let status { store.updatePage(tab.id) { $0 = status } }
        if let request {
            permissionRequests[tab.id] = request
            onPermissionRequestsChanged?()
        }
        return page
    }

    private func makePage(for tab: BrowserTab) -> WebPage {
        let engine = engine(forTab: tab.id)
        // A tab on one of Kite's own pages gets a blank page; the window draws the page over it.
        let url = InternalPage(tab.url) == nil ? tab.url : nil
        // History saved when the page hibernated, here or in a linked window.
        let restoring = savedState.removeValue(forKey: tab.id) ?? shared?.takeSavedState(tab.id, excluding: self)
        let page = engine.makePage(url: url, restoring: restoring)
        register(page, id: tab.id)
        pageProfiles[tab.id] = engine.profileDirectory
        // Before the engine asks for the first document's scripts.
        page.themeCSS = themeCSS(forTabs: [tab.id])[tab.id] ?? nil
        return page
    }

    /// Settings › Advanced › "Allow websites to get your theme data": each live page gets its
    /// space's theme as CSS (favorites, which are in every space, the current space's), or none
    /// when the switch is off. Pages that already have it are left alone.
    /// Runs after every store change, so it builds CSS only when a page's theme (or the switch) changed.
    func updateThemeCSS() {
        let ids = Set(pages.keys)
        let allowed = ThemeCSS.isAllowed()
        let key = ThemeCSSKey(allowed: allowed, themes: allowed ? themes(forTabs: ids) : [:], pages: ids)
        guard key != themeCSSKey else { return }
        themeCSSKey = key
        guard !ids.isEmpty else { return }
        for (id, css) in themeCSS(forTabs: ids) where pages[id]?.themeCSS != css {
            pages[id]?.themeCSS = css
        }
    }

    /// What the pages' theme CSS was last made from.
    private struct ThemeCSSKey: Equatable {
        var allowed: Bool
        var themes: [UUID: Theme]
        var pages: Set<UUID>
    }
    private var themeCSSKey: ThemeCSSKey?

    /// Each tab's space's theme; favorites, which are in every space, get the current space's.
    private func themes(forTabs ids: Set<UUID>) -> [UUID: Theme] {
        let state = store.state
        var themes: [UUID: Theme] = [:]
        for space in state.spaces {
            for tab in space.allTabs where ids.contains(tab.id) { themes[tab.id] = space.theme }
        }
        let current = state.selectedSpace.theme
        for id in ids where themes[id] == nil { themes[id] = current }
        return themes
    }

    private func themeCSS(forTabs ids: Set<UUID>) -> [UUID: String?] {
        guard ThemeCSS.isAllowed() else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) }) }
        let themes = themes(forTabs: ids)
        var cache: [Theme: String] = [:]
        func css(_ theme: Theme) -> String {
            if let known = cache[theme] { return known }
            let made = ThemeCSS.css(for: theme)
            cache[theme] = made
            return made
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, themes[$0].map(css)) })
    }

    /// Pages whose tab now belongs to another profile (its space moved): they're closed, and
    /// load again in the new profile when next shown.
    func discardPagesInWrongProfile() {
        guard engine.profileDirectory != nil else { return }
        for id in Array(pages.keys) {
            guard let made = pageProfiles[id], store.state.tab(id) != nil else { continue }
            if engine(forTab: id).profileDirectory != made { discard(id, keepHistory: false) }
        }
    }

    /// Lets go of tab `id`'s page without closing it, for another window that shows it now.
    /// Returns its unanswered permission request, which goes with it.
    fileprivate func release(_ id: UUID) -> PermissionRequest? {
        guard pages.removeValue(forKey: id) != nil else { return nil }
        pageProfiles[id] = nil
        lastShown[id] = nil
        busyIDs.remove(id)
        visibleIDs.remove(id)
        let request = permissionRequests.removeValue(forKey: id)
        if request != nil { onPermissionRequestsChanged?() }
        onPageTaken?(id)
        return request
    }

    fileprivate func takeSavedState(_ id: UUID) -> Any? { savedState.removeValue(forKey: id) }

    /// Takes over a page made elsewhere (a Little Kite window's), for a new tab. Returns the tab's id.
    func adopt(_ page: WebPage, profileDirectory: String? = nil) -> UUID {
        let id = UUID()
        register(page, id: id)
        pageProfiles[id] = profileDirectory ?? currentEngine.profileDirectory
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
        evictOverLimit()
        recheckBusyTabs()
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
    /// `opener` is the tab whose page opened it, for a popup; `source` the tab it came from otherwise (a
    /// Peek's), which places it as a tab that page opened (next to it in a Claude folder). `profileDirectory` is
    /// the profile the page was made in; a popup shares its opener's.
    func openTab(with page: WebPage, url: URL? = nil, opener: UUID? = nil, source: UUID? = nil, profileDirectory: String? = nil) {
        // Register before the tab exists so selecting it reuses this page.
        let newID = UUID()
        register(page, id: newID)
        pageProfiles[newID] = profileDirectory ?? opener.flatMap { pageProfiles[$0] } ?? currentEngine.profileDirectory
        if let opener { Self.popupOpeners[newID] = opener }
        store.mutateWithoutUndo { state in
            if let from = opener ?? source { state.openTab(id: newID, url: url, openedBy: from) } else { state.openTab(id: newID, url: url) }
        }
        if let from = opener ?? source { onTabOpened?(newID, from) }
    }

    /// A tab `opener`'s page opened at `url` (a link to a new tab): next to it in a Claude folder.
    func openTab(url: URL, openedBy opener: UUID, select: Bool) {
        let id = store.mutateWithoutUndo { $0.openTab(url: url, openedBy: opener, select: select) }
        onTabOpened?(id, opener)
    }

    /// A popup and its opener talk through `window.opener` and `postMessage` (Sign in with Apple
    /// and Google, OAuth), so neither page may hibernate while both are open: hibernating closes
    /// the page, which cuts the link for good, and the opener comes back without the dialog that
    /// was waiting for the popup. The popup takes the screen from its opener, so the opener is
    /// exactly the page memory pressure or the live-tab limit would pick.
    private func isLinkedToPopup(_ id: UUID) -> Bool {
        Self.popupOpeners.contains { popup, opener in
            (popup == id || opener == id) && store.state.tab(popup) != nil && store.state.tab(opener) != nil
        }
    }

    /// Registers `page` (a Peek's, made in `profileDirectory`) for a tab the caller is about to add with `id`.
    func register(existing page: WebPage, id: UUID, profileDirectory: String?) {
        register(page, id: id)
        pageProfiles[id] = profileDirectory
    }

    func discard(_ id: UUID, keepHistory: Bool) {
        guard let page = pages.removeValue(forKey: id) else { return }
        // A closed page can't be anyone's opener or popup again.
        Self.popupOpeners = Self.popupOpeners.filter { $0.key != id && $0.value != id }
        pageProfiles[id] = nil
        OAuthResumeTracker.forget(id)
        savedState[id] = keepHistory ? page.hibernationState() : nil
        lastShown[id] = nil
        busyIDs.remove(id)
        page.onEvent = nil
        page.linkPeekPolicy = nil
        page.contextMenuHost = nil
        answerPermissionRequest(id, allow: nil)
        page.close()
        store.clearPage(id)
    }

    // MARK: Private

    private func register(_ page: WebPage, id: UUID) {
        pages[id] = page
        // A different page under a known tab id (claimed from another window, or made again) may
        // not have this window's theme CSS yet.
        themeCSSKey = nil
        lastShown[id] = Date()
        page.onEvent = { [weak self] event in self?.handle(event, from: id) }
        page.contextMenuHost = { [weak self] in self?.contextMenuHost?() ?? PageContextMenu.Host() }
        page.linkPeekPolicy = { [weak self] url, shift in
            guard let self, self.onLinkPeek != nil else { return false }
            let state = self.store.state
            return LinkPeek.opensInPeek(section: state.location(of: id)?.section, from: state.tab(id)?.url, to: url, shift: shift,
                                       options: LinkPeek.Options(defaults: .standard))
        }
        onPageCreated?(id, page)
    }

    private func handle(_ event: PageEvent, from id: UUID) {
        switch event {
        case .title(let title):
            store.pageTitleChanged(id, title)
        case .url(let url):
            store.pageURLChanged(id, url)
            if let page = pages[id] { OAuthResumeTracker.page(page, movedTo: url, key: id) }
            // A prompt belongs to the site that asked; leaving it drops the prompt (as Chromium does).
            if let request = permissionRequests[id], let url,
               SiteControls.origin(of: url) != SiteControls.origin(of: request.origin) {
                answerPermissionRequest(id, allow: nil)
            }
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
                // For whoever watches every window's pages (Claude's handoffs), not just this window's.
                NotificationCenter.default.post(name: .kitePageFinishedLoading, object: self, userInfo: ["tab": id])
            }
            if let page = pages[id] { onLoadingChanged?(id, page, isLoading) }
        case .addExtension(let extensionID):
            guard extensionInstalls[extensionID] == nil, let source = pages[id],
                  let storeURL = ChromeWebStore.detailURL(for: extensionID) else { return }
            extensionInstalls[extensionID] = BackgroundExtensionInstall(
                extensionID: extensionID, storeURL: storeURL, engine: engine(forTab: id), source: source
            ) { [weak self] in self?.extensionInstalls[extensionID] = nil }
        case let .openInNewTab(url, foreground):
            openTab(url: url, openedBy: id, select: foreground)
        case .popup(let page):
            openTab(with: page, opener: id)
        case .openInLinkPeek(let url):
            // Out of the engine's navigation callback before making another page.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let onLinkPeek { onLinkPeek(id, url) } else { store.mutateWithoutUndo { $0.openTab(url: url) } }
            }
        case .openInSplit(let url):
            // Out of the engine's navigation callback before making another page.
            DispatchQueue.main.async { [weak self] in
                self?.store.mutateWithoutUndo { $0.openLinkInSplit(url: url, from: id) }
            }
        case .openInLittleKite(let url):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let onOpenLittleKite { onOpenLittleKite(id, url) } else { store.mutateWithoutUndo { $0.openLinkInSplit(url: url, from: id) } }
            }
        case .closeRequested:
            // A popup that closes itself (window.close() after signing in) hands the screen back
            // to the tab that opened it, as Chrome returns to the opener's window.
            let opener = Self.popupOpeners.removeValue(forKey: id)
            let wasSelected = store.state.selectedTab?.id == id
            store.mutateWithoutUndo { state in
                state.close(tab: id)
                if wasSelected, let opener, state.tab(opener) != nil { state.select(tab: opener) }
            }
        case .showForLeaveDialog:
            if store.state.tab(id) != nil { store.mutateWithoutUndo { $0.select(tab: id) } }
        case let .openLink(url, target):
            // Chromium opens Open Link in New Tab in the background.
            if target == .newTab { openTab(url: url, openedBy: id, select: false) } else { onOpenLink?(id, url, target) }
        case .pageCommand(let command):
            onPageCommand?(id, command)
        case .linkHover(let hover):
            guard let view = pages[id]?.view else { return }
            LinkPreviewController.shared.hover(hover, in: view)
        case .blockedCount(let count):
            store.updatePage(id) { $0.blockedCount = count }
        case .media(let media):
            store.mediaChanged(id, media)
            // The page's script starts at full volume after each navigation: send the tab's level again.
            if let media, let level = store.pages[id]?.tabVolume, TabVolume.needsReapply(tab: level, reported: media.tabVolume) {
                pages[id]?.runMediaCommand(.setVolume(level))
            }
        case .callControls(let call):
            store.updatePage(id) { $0.callControls = call }
        case .capturing(let capturing):
            store.captureChanged(id, capturing)
        case .crashed(let code):
            store.updatePage(id) {
                $0.crashCode = code
                $0.isLoading = false
            }
            answerPermissionRequest(id, allow: nil)
        case .permissionRequest(let request):
            permissionRequests.removeValue(forKey: id)?.respond(nil)
            permissionRequests[id] = request
            onPermissionRequestsChanged?()
        case .permissionRequestCancelled(let requestID):
            guard permissionRequests[id]?.id == requestID else { return }
            permissionRequests[id] = nil
            onPermissionRequestsChanged?()
        }
    }

    /// On Google results, extensions that are already installed say "Added".
    private func markInstalledExtensions(in id: UUID) {
        guard let page = pages[id], GoogleSearch.isResultsPage(store.state.tab(id)?.url) else { return }
        for extensionID in BackgroundExtensionInstall.installedIDs(profile: engine(forTab: id).profileDirectory) {
            guard let script = GoogleResultsScript.label(extensionID, "Added", disabled: true) else { continue }
            page.evaluateJavaScript(script) { _ in }
        }
    }

    /// Hibernates tabs unless they're playing media or using the camera or mic. A busy tab is remembered
    /// (`busyIDs`) and the live-tab limit picks again without it, so the next oldest goes instead.
    private func hibernate(_ ids: [UUID]) {
        // A window is asking its pages whether it may close: none may go unasked meanwhile.
        guard !holdsPages else { return }
        for id in ids where !isLinkedToPopup(id) {
            guard let page = pages[id] else { continue }
            let pickedShownAt = lastShown[id]
            page.checkBusy { [weak self, weak page] busy in
                guard let self, let page else { return }
                // The check is asynchronous: the tab may have been shown again, or have another page now.
                guard LiveTabPolicy.stillHibernates(pickedShownAt: pickedShownAt, shownAt: lastShown[id],
                                                    samePage: pages[id] === page, visible: visibleIDs.contains(id)),
                      !isLinkedToPopup(id) else { return }
                if busy {
                    if busyIDs.insert(id).inserted { evictOverLimit() }
                    return
                }
                busyIDs.remove(id)
                discard(id, keepHistory: true)
            }
        }
    }

    /// Hibernates the least recently shown tabs over the live-tab limit, keeping those on screen and busy ones.
    private func evictOverLimit() {
        hibernate(policy.tabsToEvict(live: lastShown, protected: visibleIDs.union(busyIDs)))
    }

    /// Tabs that were busy stop being skipped once they're idle (the music stopped), and the limit applies again.
    private func recheckBusyTabs() {
        for id in busyIDs where !visibleIDs.contains(id) {
            guard let page = pages[id] else {
                busyIDs.remove(id)
                continue
            }
            page.checkBusy { [weak self, weak page] busy in
                guard let self, let page, !busy, pages[id] === page, busyIDs.remove(id) != nil else { return }
                evictOverLimit()
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

/// The pages of the normal windows, which share one sidebar: each tab has at most one live page
/// between them, held by the window that last put it on screen. Incognito and Blank windows keep
/// their own tabs and don't join.
@MainActor
final class SharedPages {
    private struct Weak { weak var pool: PagePool? }
    private var pools: [Weak] = []

    func add(_ pool: PagePool) {
        pools.removeAll { $0.pool == nil || $0.pool === pool }
        pools.append(Weak(pool: pool))
    }

    /// `pool`'s window is closing: the others take back the pages they show placeholders for, then
    /// it leaves. Returns a window that stays, to keep the history of the pages it closes.
    fileprivate func closing(_ pool: PagePool) -> PagePool? {
        for case let other? in pools.map(\.pool) where other !== pool { other.onLinkedWindowClosing?(pool) }
        pools.removeAll { $0.pool == nil || $0.pool === pool }
        return pools.lazy.compactMap(\.pool).first
    }

    /// Every linked window's live pages.
    var livePages: [UUID: WebPage] {
        var all: [UUID: WebPage] = [:]
        for case let pool? in pools.map(\.pool) { all.merge(pool.livePages) { first, _ in first } }
        return all
    }

    /// The pool holding tab `id`'s page, other than `pool`.
    fileprivate func livePage(_ id: UUID, excluding pool: PagePool) -> (owner: PagePool, page: WebPage)? {
        for case let other? in pools.map(\.pool) where other !== pool {
            if let page = other.loadedPage(id) { return (other, page) }
        }
        return nil
    }

    fileprivate func takeSavedState(_ id: UUID, excluding pool: PagePool) -> Any? {
        for case let other? in pools.map(\.pool) where other !== pool {
            if let state = other.takeSavedState(id) { return state }
        }
        return nil
    }
}

extension Notification.Name {
    /// A page finished loading, in any window's pool (`userInfo["tab"]`: the tab's UUID).
    static let kitePageFinishedLoading = Notification.Name("KitePageFinishedLoading")
    /// A browser window put pages on screen (a tab came forward there, or a split changed).
    static let kitePagesShown = Notification.Name("KitePagesShown")
}
