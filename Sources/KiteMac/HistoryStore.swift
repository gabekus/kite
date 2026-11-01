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

    private struct File: Codable {
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

    func updateTitle(_ url: URL, _ title: String) {
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
        saveNow()
        return added
    }

    func removeAll() {
        history.removeAll()
        saveNow()
    }

    func remove(_ urls: [URL]) {
        history.remove(urls)
        saveNow()
    }

    /// Delete browsing data's history: pages visited at or after `since` (nil: all).
    func removeVisits(since: Date?) {
        history.removeVisits(since: since)
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

    func saveNow() {
        saveTask?.cancel()
        profileStores.values.forEach { $0.saveNow() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(version: History.currentVersion, history: history))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save history: \(error)")
        }
    }
}
