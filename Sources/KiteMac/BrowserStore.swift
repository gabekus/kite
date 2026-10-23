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
    private(set) var isSidebarVisible = true
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
        BrowserStore(state: BrowserState(spaces: [Space(name: "Incognito", icon: "🕶️", theme: Theme.presets[3])]))
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
        let result = body(&state)
        scheduleSave()
        onChange?()
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

    func showCommandBar(_ mode: CommandBarMode) {
        commandBar = mode
        onChange?()
    }

    func hideCommandBar() {
        guard commandBar != nil else { return }
        commandBar = nil
        onChange?()
    }

    func setSystemIsDark(_ dark: Bool) {
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        onChange?()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        onChange?()
    }

    // MARK: Page events from web views

    func pageTitleChanged(_ id: UUID, _ title: String?) {
        guard let title, !title.isEmpty else { return }
        if let url = recordedURLs[id] { history?.updateTitle(url, title) }
        guard state.tab(id)?.title != title else { return }
        mutate { $0.update(tab: id) { $0.title = title } }
    }

    func pageURLChanged(_ id: UUID, _ url: URL?) {
        guard let url else { return }
        // Before the tab check: a typed URL is already on the tab when the page reports it.
        if recordedURLs[id] != url {
            recordedURLs[id] = url
            history?.recordVisit(url, title: "")
        }
        guard state.tab(id)?.url != url else { return }
        mutate { $0.update(tab: id) { $0.url = url } }
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
