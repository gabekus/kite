import Foundation
import Observation
import KiteCore

/// Live per-tab page status that isn't worth persisting.
struct PageStatus: Equatable {
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var blockedCount = 0
    /// Set when the page's process crashed: the exit code shown on the crashed-tab page.
    var crashCode: Int?
    /// What the page plays (MediaStateScript), and when it last started and stopped; nil without media.
    var media: MediaActivity?
    /// The browser's tab mute (WebPage.isAudioMuted).
    var isAudioMuted = false

    /// Whether the tab is playing media now (muted or not): the base for audio indicators.
    var isPlayingAudio: Bool { media?.state.isPlaying == true }
}

/// Tabs › Reveal Tab in Sidebar: the sidebar row to scroll into view. `serial` changes on
/// every request, so revealing the same row twice scrolls twice.
struct RevealRequest: Equatable {
    var rowID: UUID
    var serial: Int
}

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

/// Owns the `BrowserState` for the app. SwiftUI views observe it directly; the
/// AppKit window controller gets explicit callbacks so it can swap web views.
@MainActor
@Observable
final class BrowserStore {
    private(set) var state: BrowserState
    private(set) var pages: [UUID: PageStatus] = [:]
    private(set) var commandBar: CommandBarMode?
    /// The space whose header name is being edited in place.
    private(set) var renamingSpaceID: UUID?
    /// The tab whose sidebar title is being edited in place (Arc's Rename… / double-click).
    private(set) var renamingTabID: UUID?
    private(set) var isSidebarVisible = true
    private(set) var revealRequest: RevealRequest?
    /// macOS light/dark, which dark pages follow in `.matchSystem`.
    private(set) var systemIsDark = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onPageChange: ((UUID) -> Void)?
    /// nil for an incognito window: nothing is written to disk.
    @ObservationIgnored private let session: SessionStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Browsing history to record into; nil for an incognito window.
    @ObservationIgnored var history: HistoryStore?
    /// The URL each tab last recorded, so repeated reports of one page count once.
    @ObservationIgnored private var recordedURLs: [UUID: URL] = [:]

    private static let spaceIcons = ["🌿", "🎨", "📚", "🎧", "🧪", "✈️", "🍳", "🎮"]

    /// An incognito window's store: one dark space, never saved.
    static func incognito() -> BrowserStore {
        let store = BrowserStore(state: BrowserState(spaces: [Space(name: "Incognito", icon: "🕶️", theme: Theme.presets[3])]))
        store.tidiesPinnedTabs = false
        return store
    }

    /// Another normal window's store: a copy of the shared sidebar with its own selection,
    /// kept in step through `link`. The main window's store writes the session.
    static func linked(_ state: BrowserState, to link: WindowLink) -> BrowserStore {
        let store = BrowserStore(state: state)
        link.add(store)
        return store
    }

    /// A Blank Window's store (Arc's standalone-sidebar window): its own tabs, outside the
    /// shared sidebar. Arc titles them "Explore" ("Title for Explore tabs in a standalone-sidebar window").
    static func blank(_ state: BrowserState? = nil) -> BrowserStore {
        BrowserStore(state: state ?? BrowserState(spaces: [Space(name: "Explore", icon: "🧭", theme: Theme.presets[0])]))
    }

    /// The normal windows this store's changes are copied to; nil for incognito and blank windows.
    @ObservationIgnored weak var link: WindowLink?
    /// After every change: AppDelegate saves the extra windows (windows.json).
    @ObservationIgnored var didChangeState: (() -> Void)?
    /// Tidy Tab Titles names the tabs pinned here; off in incognito, where nothing leaves the window.
    @ObservationIgnored var tidiesPinnedTabs = true

    /// Takes a change made in another normal window, keeping this window's selection.
    func adopt(_ other: BrowserState) {
        state = state.adoptingContent(of: other)
        scheduleSave()
        onChange?()
        didChangeState?()
    }

    private init(state: BrowserState) {
        session = nil
        self.state = state
    }

    init(session: SessionStore) {
        self.session = session
        do {
            state = try session.load() ?? .makeDefault()
        } catch {
            NSLog("Kite: couldn't read session, starting fresh: \(error)")
            state = .makeDefault()
        }
    }

    @discardableResult
    func mutate<R>(_ body: (inout BrowserState) -> R) -> R {
        let before = state
        let result = body(&state)
        // A tab pinned by any path (menu, drag into a folder, automation) remembers its page.
        state.syncPinnedURLs()
        scheduleSave()
        onChange?()
        link?.propagate(from: self)
        didChangeState?()
        // Tidy Tab Titles: a tab pinned by any path gets a short name from Claude.
        if tidiesPinnedTabs, TidyTabTitles.isEnabled() {
            let pinned = TidyTabTitles.newlyPinnedTabs(before: before, after: state)
            if !pinned.isEmpty { TidyTabTitlesController.shared.tabsPinned(pinned, in: self) }
        }
        return result
    }

    /// Archives unpinned tabs left unused longer than the user's setting.
    func archiveStaleTabs() {
        guard let interval = state.archiveAfter.seconds else { return }
        mutate { $0.archiveStaleTabs(olderThan: interval) }
    }

    func addSpace() {
        let n = state.spaces.count
        mutate {
            $0.addSpace(
                name: "Space \(n + 1)",
                icon: Self.spaceIcons[n % Self.spaceIcons.count],
                theme: Theme.presets[n % Theme.presets.count]
            )
        }
    }

    // MARK: Chrome state

    func beginRenaming(space id: UUID) {
        if !isSidebarVisible { toggleSidebar() }
        mutate { $0.selectSpace(id) }
        renamingSpaceID = id
    }

    func endRenaming() { renamingSpaceID = nil }

    func beginRenaming(tab id: UUID) {
        renamingTabID = id
    }

    func endRenamingTab() { renamingTabID = nil }

    func showCommandBar(_ mode: CommandBarMode) {
        commandBar = mode
        onChange?()
    }

    func hideCommandBar() {
        guard commandBar != nil else { return }
        commandBar = nil
        // Closed without picking a page for the new pane: cancel the split.
        if let pane = pendingSplitPane {
            pendingSplitPane = nil
            state.cancelSplitPane(pane)
            scheduleSave()
            link?.propagate(from: self)
            didChangeState?()
        }
        onChange?()
    }

    /// The empty pane Add Split View just opened, until a page is picked for it.
    @ObservationIgnored var pendingSplitPane: UUID?

    func setSystemIsDark(_ dark: Bool) {
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        onChange?()
    }

    func reveal(row id: UUID) {
        revealRequest = RevealRequest(rowID: id, serial: (revealRequest?.serial ?? 0) + 1)
        onChange?()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        onChange?()
    }

    // MARK: Page events from web views

    func pageTitleChanged(_ id: UUID, _ title: String?) {
        guard let title, !title.isEmpty, !showsInternalPage(id) else { return }
        if let url = recordedURLs[id] { history?.updateTitle(url, title) }
        guard state.tab(id)?.title != title else { return }
        mutate { $0.update(tab: id) { $0.title = title } }
    }

    func pageURLChanged(_ id: UUID, _ url: URL?) {
        guard let url else { return }
        // The blank page under kite://history reports about:blank; the tab keeps its own URL.
        if showsInternalPage(id), !History.records(url) { return }
        // Before the tab check: a typed URL is already on the tab when the page reports it.
        if recordedURLs[id] != url {
            recordedURLs[id] = url
            history?.recordVisit(url, title: "")
        }
        guard state.tab(id)?.url != url else { return }
        mutate { $0.update(tab: id) { $0.url = url } }
    }

    private func showsInternalPage(_ id: UUID) -> Bool {
        InternalPage(state.tab(id)?.url) != nil
    }

    func faviconChanged(_ id: UUID, _ url: URL?) {
        guard state.tab(id)?.faviconURL != url else { return }
        mutate { $0.update(tab: id) { $0.faviconURL = url } }
    }

    func updatePage(_ id: UUID, _ body: (inout PageStatus) -> Void) {
        var page = pages[id] ?? PageStatus()
        body(&page)
        guard page != pages[id] else { return }
        pages[id] = page
        onPageChange?(id)
    }

    func clearPage(_ id: UUID) {
        pages[id] = nil
        recordedURLs[id] = nil
        hiddenAt[id] = nil
        miniPlayerDismissed.remove(id)
    }

    // MARK: Media

    /// When each tab last left the screen, for the Mini Player.
    private(set) var hiddenAt: [UUID: Date] = [:]
    /// Tabs whose Mini Player was closed, until they play again.
    private(set) var miniPlayerDismissed: Set<UUID> = []

    func mediaChanged(_ id: UUID, _ state: MediaState?) {
        let wasPlaying = pages[id]?.isPlayingAudio ?? false
        updatePage(id) { $0.media = MediaActivity.update($0.media, with: state, now: Date()) }
        if state?.isPlaying == true, !wasPlaying { miniPlayerDismissed.remove(id) }
    }

    func tabsLeftScreen(_ ids: some Sequence<UUID>, at date: Date = Date()) {
        for id in ids { hiddenAt[id] = date }
    }

    func dismissMiniPlayer(_ id: UUID) {
        miniPlayerDismissed.insert(id)
    }

    /// The tab whose media the sidebar's Mini Player shows, if any.
    var miniPlayerTabID: UUID? {
        let media = pages.compactMapValues(\.media).filter { state.tab($0.key) != nil }
        guard !media.isEmpty else { return nil }
        return MiniPlayer.tab(
            media: media,
            visible: Set(state.visibleTabs.map(\.id)),
            hiddenAt: hiddenAt,
            dismissed: miniPlayerDismissed
        )
    }

    // MARK: Persistence

    /// Saves are debounced; title and URL updates arrive in bursts while pages load.
    private func scheduleSave() {
        guard session != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try session?.save(state)
        } catch {
            NSLog("Kite: couldn't save session: \(error)")
        }
    }
}

/// Arc's normal windows share one sidebar and each shows its own space and tab. Every normal
/// window has its own store; a change in one is copied into the rest, which keep their selection.
@MainActor
final class WindowLink {
    private struct Weak { weak var store: BrowserStore? }
    private var stores: [Weak] = []

    var all: [BrowserStore] { stores.compactMap(\.store) }

    func add(_ store: BrowserStore) {
        stores.removeAll { $0.store == nil }
        stores.append(Weak(store: store))
        store.link = self
    }

    func remove(_ store: BrowserStore) {
        stores.removeAll { $0.store == nil || $0.store === store }
        if store.link === self { store.link = nil }
    }

    func propagate(from source: BrowserStore) {
        for other in all where other !== source {
            other.adopt(source.state)
        }
    }
}
