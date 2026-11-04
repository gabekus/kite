import Foundation
import KiteCore
import Observation

/// Browsing history on disk (history.json), shared by every normal window.
/// Incognito windows get no store, so they never record.
@MainActor
@Observable
final class HistoryStore {
    private(set) var history = History()
    @ObservationIgnored private let fileURL: URL
    /// Other profiles' histories, made from the default profile's store.
    @ObservationIgnored private var profileStores: [String: HistoryStore] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Changed since the last save. Saving one store saves every profile's, and most of them haven't changed.
    @ObservationIgnored private var isDirty = false
    /// Debounced saves encode and write here, off the main thread: a full history is 20,000 entries.
    /// Serial, so writes land in order, and `saveNow` waits behind any that are queued.
    private static let writeQueue = DispatchQueue(label: "dev.gabek.Kite.history-save", qos: .utility)

    private struct File: Codable, Sendable {
        var version: Int
        var history: History
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            history = try JSONDecoder().decode(File.self, from: data).history
        } catch {
            // Keep the unreadable file for a bug report rather than overwriting it.
            NSLog("Kite: couldn't read history, starting fresh: \(error)")
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    /// `directory`'s history: this store for the default profile, else one kept in that profile's
    /// Chromium folder, so deleting the profile deletes it.
    func forProfile(_ directory: String) -> HistoryStore {
        if directory == Profile.defaultDirectory { return self }
        if let store = profileStores[directory] { return store }
        let file = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Chromium", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("Kite History.json")
        let store = HistoryStore(fileURL: file)
        profileStores[directory] = store
        return store
    }

    func recordVisit(_ url: URL, title: String) {
        history.recordVisit(url, title: title)
        scheduleSave()
    }

    /// Pages send their title again on every load and on every title change (chat apps flash theirs),
    /// so an unchanged title neither touches `history`, which observers watch, nor saves.
    func updateTitle(_ url: URL, _ title: String) {
        guard let entry = history.entries[url.absoluteString], entry.title != title, !title.isEmpty else { return }
        history.updateTitle(url, title)
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
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.save(waiting: false)
        }
    }

    /// A deleted profile's history: dropped unsaved, since its folder is going.
    func forgetProfile(_ directory: String) {
        profileStores.removeValue(forKey: directory)?.saveTask?.cancel()
    }

    /// Writes this store and every profile's that changed, and returns once they're on disk.
    func saveNow() {
        save(waiting: true)
        // A debounced write already queued (the store is clean then) lands before this returns too: at quit.
        Self.writeQueue.sync {}
    }

    private func save(waiting: Bool) {
        profileStores.values.forEach { $0.save(waiting: waiting) }
        saveTask?.cancel()
        guard isDirty else { return }
        isDirty = false
        let file = File(version: History.currentVersion, history: history), url = fileURL
        let write = {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(file).write(to: url, options: .atomic)
            } catch {
                NSLog("Kite: couldn't save history: \(error)")
            }
        }
        if waiting { Self.writeQueue.sync(execute: write) } else { Self.writeQueue.async(execute: write) }
    }
}
