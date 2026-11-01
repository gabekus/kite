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
    /// The tab volume from the Mini Player (TabVolume, 0...1); it lives with the page, like the mute.
    var tabVolume: Double = 1
    /// Since when the page has used the camera or microphone (Arc's Mini Player `Recording`); nil when it doesn't.
    var capturingSince: Date?
    /// The page's Media Session call controls (Mini Player's Toggle Microphone / Toggle Camera).
    var callControls = CallControls()

    /// Whether the tab is playing media now (muted or not): the base for audio indicators.
    var isPlayingAudio: Bool { media?.state.isPlaying == true }
    /// Whether you'd hear it if the tab weren't muted (Arc's TabCellState.isAudible).
    var isAudible: Bool { media?.state.isAudible == true }
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

/// The page a tab's Peek shows, for the badge on the tab's sidebar row.
struct LinkPeekBadge: Equatable {
    var page: URL?
    var icon: URL?
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
    /// Arc's Create a Space page: the space being made (already in the strip, so its theme shows live),
    /// the one to go back to on Cancel, and whether a colour has been picked yet.
    private(set) var spaceCreation: SpaceCreation?
    /// Change Space Icon…: the space whose header should open the icon picker.
    private(set) var iconPickerRequest: UUID?

    struct SpaceCreation: Equatable {
        let spaceID: UUID
        let returnTo: UUID
        var themeChosen = false
    }
    /// The tab whose sidebar title is being edited in place (Arc's Rename… / double-click).
    private(set) var renamingTabID: UUID?
    /// The folder whose name is being edited in place in the sidebar.
    private(set) var renamingFolderID: UUID?
    /// The live folder showing its intro popover in this window.
    var liveFolderIntroID: UUID?
    private(set) var isSidebarVisible = true
    private(set) var revealRequest: RevealRequest?
    /// macOS light/dark, which dark pages follow in `.matchSystem`.
    private(set) var systemIsDark = false
    /// Spaces whose Tidy Tabs request is out with Claude (the Tidy button spins).
    var tidyingSpaceIDs: Set<UUID> = []
    /// Instant Links at work, newest first: each shows a row at the top of its space's Today.
    var instantLinksRows: [InstantLinks.Pending] = []
    /// Tidy Tab Titles names that just landed: the row wipes from the old title to the new one,
    /// with sparks (Arc's TabCellView.isAnimatingAiRename). Keyed by tab, with the old title.
    private(set) var aiRenames: [UUID: AIRename] = [:]

    struct AIRename: Equatable {
        let oldTitle: String
        let start: Date
    }

    /// Plays the rename animation on a tab's row, then forgets it once the sparks are gone.
    func animateAIRename(_ id: UUID, from oldTitle: String) {
        let rename = AIRename(oldTitle: oldTitle, start: Date())
        aiRenames[id] = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + TidyTabTitleAnimation.totalDuration) { [weak self] in
            if self?.aiRenames[id] == rename { self?.aiRenames[id] = nil }
        }
    }

    /// Tabs with a Peek open over them (on screen or parked while another tab is shown), and the Peek's page:
    /// their sidebar rows show Arc's Peek badge with its icon (TabCellState `modalIcon`).
    var linkPeekBadges: [UUID: LinkPeekBadge] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onPageChange: ((UUID) -> Void)?
    /// nil for an incognito window: nothing is written to disk.
    @ObservationIgnored private let session: SessionStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The default profile's browsing history, which leads to the other profiles'; nil for an
    /// incognito window, which records none.
    @ObservationIgnored var historyRoot: HistoryStore?
    /// The current space's profile's history.
    var history: HistoryStore? { historyRoot?.forProfile(state.selectedProfileDirectory) }
    /// The history a tab's visits go to: its own profile's.
    private func history(forTab id: UUID) -> HistoryStore? { historyRoot?.forProfile(state.profileDirectory(ofTab: id)) }
    /// The URL each tab last recorded, so repeated reports of one page count once.
    @ObservationIgnored private var recordedURLs: [UUID: URL] = [:]

    static let spaceIcons = ["🌿", "🎨", "📚", "🎧", "🧪", "✈️", "🍳", "🎮"]

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
    /// Where a sidebar drag that leaves the sidebar can drop: the window's page area (Split View).
    @ObservationIgnored weak var sidebarDragContent: SidebarDragContentTarget?
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
        // A Create a Space page left open at quit leaves a nameless, empty space behind.
        for space in state.spaces where space.name.isEmpty && space.allTabs.isEmpty { state.deleteSpace(space.id) }
    }

    @discardableResult
    func mutate<R>(_ body: (inout BrowserState) -> R) -> R {
        let before = state
        let result = body(&state)
        // A tab pinned by any path (menu, drag into a folder, automation) remembers its page.
        state.syncPinnedURLs()
        // Tidy Tabs' headers lose tabs that left Today, and go when they have none.
        state.pruneTabGroups()
        // Rows that come, go or move animate in the sidebar, like Arc's. SwiftUI applies the
        // change on its next pass, so arming after the change is in time.
        if Self.sidebarRows(of: before) != Self.sidebarRows(of: state) { SidebarRowsAnimator.arm() }
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

    /// Every space's top-level row identities, in order.
    private static func sidebarRows(of state: BrowserState) -> [[UUID]] {
        state.spaces.flatMap { [$0.pinnedItems.map(\.id), $0.tabs.map(\.id)] }
    }

    /// Archives unpinned tabs left unused longer than the user's setting.
    func archiveStaleTabs() {
        guard let interval = state.archiveAfter.seconds else { return }
        mutate { $0.archiveStaleTabs(olderThan: interval) }
    }

    /// + › New Space: a nameless space right after this one, shown as Arc's Create a Space page. It keeps
    /// this space's theme until a colour is picked.
    func beginNewSpace() {
        if let creation = spaceCreation { return mutate { $0.selectSpace(creation.spaceID) } }
        if !isSidebarVisible { toggleSidebar() }
        let current = state.selectedSpace
        let id = mutate { $0.insertSpace(name: "", icon: "", theme: current.theme, profile: current.profile) }
        spaceCreation = SpaceCreation(spaceID: id, returnTo: current.id)
    }

    func spaceThemeChosen() { spaceCreation?.themeChosen = true }

    func finishNewSpace(name: String) {
        guard let creation = spaceCreation else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mutate { $0.renameSpace(creation.spaceID, to: name) }
        spaceCreation = nil
    }

    func cancelNewSpace() {
        guard let creation = spaceCreation else { return }
        spaceCreation = nil
        mutate {
            $0.deleteSpace(creation.spaceID)
            $0.selectSpace(creation.returnTo)
        }
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

    func requestIconPicker(space id: UUID) {
        if !isSidebarVisible { toggleSidebar() }
        mutate { $0.selectSpace(id) }
        iconPickerRequest = id
    }

    func iconPickerShown() { iconPickerRequest = nil }

    func beginRenaming(tab id: UUID) {
        renamingTabID = id
    }

    func endRenamingTab() { renamingTabID = nil }

    func beginRenaming(folder id: UUID) {
        if !isSidebarVisible { toggleSidebar() }
        renamingFolderID = id
    }

    func endRenamingFolder() { renamingFolderID = nil }

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

    // MARK: Profiles

    /// Arc's Create a new Profile: the profile, with `spaces` moved into it.
    func createProfile(named name: String, spaces: [UUID]) throws -> Profile {
        var made: Result<Profile, Error> = .failure(ProfileNameError.invalid)
        mutate { state in made = Result { try state.createProfile(named: name, spaces: spaces) } }
        return try made.get()
    }

    func renameProfile(_ directory: String, to name: String) throws {
        var outcome: Result<Void, Error> = .success(())
        mutate { state in outcome = Result { try state.renameProfile(directory, to: name) } }
        try outcome.get()
    }

    /// Forgets the profile now; its data goes at the next launch (ProfileFolders).
    func deleteProfile(_ directory: String) {
        let profile = state.profile(directory)
        guard state.canDeleteProfile(directory), mutate({ $0.deleteProfile(directory) }) else { return }
        historyRoot?.forgetProfile(directory)
        ProfileFolders.delete(profile)
    }

    func setProfile(_ directory: String?, forSpace id: UUID) {
        mutate { $0.setProfile(directory, forSpace: id) }
    }

    // MARK: Page events from web views

    func pageTitleChanged(_ id: UUID, _ title: String?) {
        guard let title, !title.isEmpty, !showsInternalPage(id) else { return }
        if let url = recordedURLs[id] { history(forTab: id)?.updateTitle(url, title) }
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
            history(forTab: id)?.recordVisit(url, title: "")
        }
        let previous = state.tab(id)?.url
        guard previous != url else { return }
        mutate { $0.update(tab: id) { $0.url = url } }
        LiveFoldersController.shared?.tabURLChanged(id, from: previous, to: url, in: self)
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

    func captureChanged(_ id: UUID, _ capturing: Bool) {
        guard capturing != (pages[id]?.capturingSince != nil) else { return }
        updatePage(id) { $0.capturingSince = capturing ? Date() : nil }
        if capturing { miniPlayerDismissed.remove(id) }
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
        let capturing = pages.compactMapValues(\.capturingSince).filter { state.tab($0.key) != nil }
        guard !media.isEmpty || !capturing.isEmpty else { return nil }
        return MiniPlayer.tab(
            media: media,
            capturing: capturing,
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
