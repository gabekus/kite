import Foundation
import KiteCore

/// Browsing history on disk (history.json), shared by every normal window.
/// Incognito windows get no store, so they never record.
@MainActor
final class HistoryStore {
    private(set) var history = History()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

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

    func removeAll() {
        history.removeAll()
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

    func saveNow() {
        saveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(version: History.currentVersion, history: history))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save history: \(error)")
        }
    }
}
