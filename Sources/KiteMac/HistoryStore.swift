import Foundation
import KiteCore
import Observation

/// Browsing history on disk (history.json), shared by every normal window.
/// Incognito windows get no store, so they never record.
@MainActor
@Observable
final class HistoryStore {
    private(set) var history = History()
    @ObservationIgnored private let file: HistoryFile
    /// Other profiles' histories, made from the default profile's store.
    @ObservationIgnored private var profileStores: [String: HistoryStore] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Changed since the last save: a save leaves clean stores alone.
    @ObservationIgnored private var isDirty = false
    /// Every store's writes, in order, off the main thread.
    private static let writes = DispatchQueue(label: "dev.gabek.Kite.history-writes", qos: .utility)
    /// What `search` compares, by entry key, made at the first search and kept up to date by single
    /// visits and titles; anything bigger drops it. Typing in the command bar searches on every key.
    @ObservationIgnored private var searchItems: [String: HistorySearchItem]?
    /// Drops `searchItems` a while after the last search: about 400 bytes an entry.
    @ObservationIgnored private var forgetSearchItems: Task<Void, Never>?

    init(fileURL: URL) {
        file = HistoryFile(fileURL: fileURL)
        do {
            if let loaded = try file.load() { history = loaded }
        } catch {
            // HistoryFile kept the unreadable file for a bug report rather than overwriting it.
            NSLog("Kite: couldn't read history, starting fresh: \(error)")
        }
    }

    /// `directory`'s history: this store for the default profile, else one kept in that profile's
    /// Chromium folder, so deleting the profile deletes it.
    func forProfile(_ directory: String) -> HistoryStore {
        if directory == Profile.defaultDirectory { return self }
        if let store = profileStores[directory] { return store }
        let url = file.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Chromium", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("Kite History.json")
        let store = HistoryStore(fileURL: url)
        profileStores[directory] = store
        return store
    }

    func recordVisit(_ url: URL, title: String) {
        history.recordVisit(url, title: title)
        updateSearchItem(url)
        isDirty = true
        scheduleSave()
    }

    /// A title the entry already has (a page re-setting `document.title`) changes nothing and saves nothing.
    func updateTitle(_ url: URL, _ title: String) {
        // Checked first so a repeat doesn't touch `history` and wake its observers.
        guard history.updatesTitle(url, title) else { return }
        history.updateTitle(url, title)
        updateSearchItem(url)
        isDirty = true
        scheduleSave()
    }

    func search(_ query: String, limit: Int) -> [HistoryEntry] {
        // Reading `history` here is what lets the command bar's observation see changes.
        let entries = history.entries
        // A visit past the entry limit prunes thousands at once.
        let items = searchItems?.count == entries.count ? searchItems ?? [:] : entries.mapValues(HistorySearchItem.init)
        searchItems = items
        forgetSearchItems?.cancel()
        forgetSearchItems = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.searchItems = nil
        }
        return History.search(query, in: items.values, limit: limit)
    }

    private func updateSearchItem(_ url: URL) {
        guard searchItems != nil else { return }
        let key = url.absoluteString
        searchItems?[key] = history.entries[key].map(HistorySearchItem.init)
    }

    /// Import from Arc. Returns how many pages were new.
    @discardableResult
    func merge(_ entries: [HistoryEntry]) -> Int {
        let added = history.merge(entries)
        searchItems = nil
        isDirty = true
        saveNow()
        return added
    }

    func removeAll() {
        history.removeAll()
        searchItems = nil
        isDirty = true
        saveNow()
    }

    func remove(_ urls: [URL]) {
        history.remove(urls)
        searchItems = nil
        isDirty = true
        saveNow()
    }

    /// Delete browsing data's history: pages visited at or after `since` (nil: all).
    func removeVisits(since: Date?) {
        history.removeVisits(since: since)
        searchItems = nil
        isDirty = true
        saveNow()
    }

    /// Debounced: a page load sends its URL and title in quick succession. A page whose title
    /// keeps ticking still gets saved every 30 s.
    private func scheduleSave() {
        let delay = debounce.changed(at: ProcessInfo.processInfo.systemUptime)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// A deleted profile's history: dropped unsaved, since its folder is going.
    func forgetProfile(_ directory: String) {
        profileStores.removeValue(forKey: directory)?.saveTask?.cancel()
    }

    /// Saves this store and the other profiles' that changed. The encoding and the write happen
    /// on a background queue, from a snapshot taken now. A write that fails leaves the store
    /// changed, so the next save or the quit flush tries again.
    func saveNow() {
        saveTask?.cancel()
        debounce.saved()
        profileStores.values.forEach { $0.saveNow() }
        guard isDirty else { return }
        isDirty = false
        let file = file, snapshot = history, status = writeStatus
        Self.writes.async { [weak self] in
            status.failed = !Self.write(snapshot, to: file)
            guard status.failed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.isDirty = true } }
        }
    }

    /// Quit: waits for the writes under way, then writes what's still unsaved (a failed write
    /// included) before returning.
    func flush() {
        saveTask?.cancel()
        debounce.saved()
        profileStores.values.forEach { $0.flush() }
        let status = writeStatus
        let failed = Self.writes.sync { status.failed }
        guard isDirty || failed else { return }
        isDirty = false
        let file = file, snapshot = history
        Self.writes.sync { status.failed = !Self.write(snapshot, to: file) }
    }

    /// Whether this store's last write failed. Only touched on `writes`.
    private final class WriteStatus: @unchecked Sendable {
        var failed = false
    }
    @ObservationIgnored private let writeStatus = WriteStatus()
    @ObservationIgnored private var debounce = CappedDebounce(quiet: 3, maxWait: 30)

    nonisolated private static func write(_ history: History, to file: HistoryFile) -> Bool {
        do {
            try file.save(history)
            return true
        } catch {
            NSLog("Kite: couldn't save history: \(error)")
            return false
        }
    }
}
