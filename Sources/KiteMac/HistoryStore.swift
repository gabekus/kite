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
        isDirty = true
        scheduleSave()
    }

    /// A title the entry already has (a page re-setting `document.title`) changes nothing and saves nothing.
    func updateTitle(_ url: URL, _ title: String) {
        // Checked first so a repeat doesn't touch `history` and wake its observers.
        guard history.updatesTitle(url, title) else { return }
        history.updateTitle(url, title)
        isDirty = true
        scheduleSave()
    }

    func search(_ query: String, limit: Int) -> [HistoryEntry] {
        history.search(query, limit: limit)
    }

    /// Import from Arc. Returns how many pages were new.
    @discardableResult
    func merge(_ entries: [HistoryEntry]) -> Int {
        let added = history.merge(entries)
        isDirty = true
        saveNow()
        return added
    }

    func removeAll() {
        history.removeAll()
        isDirty = true
        saveNow()
    }

    func remove(_ urls: [URL]) {
        history.remove(urls)
        isDirty = true
        saveNow()
    }

    /// Delete browsing data's history: pages visited at or after `since` (nil: all).
    func removeVisits(since: Date?) {
        history.removeVisits(since: since)
        isDirty = true
        saveNow()
    }

    /// Debounced: a page load sends its URL and title in quick succession.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// A deleted profile's history: dropped unsaved, since its folder is going.
    func forgetProfile(_ directory: String) {
        profileStores.removeValue(forKey: directory)?.saveTask?.cancel()
    }

    /// Saves this store and the other profiles' that changed. The encoding and the write happen
    /// on a background queue, from a snapshot taken now.
    func saveNow() {
        saveTask?.cancel()
        profileStores.values.forEach { $0.saveNow() }
        guard isDirty else { return }
        isDirty = false
        let file = file, snapshot = history
        Self.writes.async { Self.write(snapshot, to: file) }
    }

    /// Quit: saves what changed and waits for every write to land.
    func flush() {
        saveNow()
        Self.writes.sync {}
    }

    nonisolated private static func write(_ history: History, to file: HistoryFile) {
        do {
            try file.save(history)
        } catch {
            NSLog("Kite: couldn't save history: \(error)")
        }
    }
}
