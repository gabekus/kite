import Foundation
import JavaScriptCore
import KiteCore
import Observation

/// The profile's Boosts (boosts.json), read by both engines when a page starts loading.
/// Incognito windows never run them, as in Arc ("Boosts can't be installed or used in Incognito Mode").
@MainActor
@Observable
final class BoostsModel {
    static let shared = BoostsModel()

    private(set) var library = BoostLibrary()
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func start(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            library = try decoder.decode(BoostLibrary.self, from: data)
        } catch {
            NSLog("Kite: couldn't read boosts.json: \(error)")
        }
    }

    // MARK: Editing

    func create(for url: URL?) -> Boost? {
        let boost = library.create(for: url)
        if boost != nil { save() }
        return boost
    }

    func update(_ id: UUID, _ change: (inout Boost) -> Void) {
        library.update(id, change)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        library.rename(id, to: name)
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        library.setEnabled(id, enabled)
        save()
    }

    func delete(_ id: UUID) {
        library.delete(id)
        save()
    }

    // MARK: Applying

    /// The document-start script for a page about to load `url`, or nil when no Boost runs there.
    func script(for url: URL?) -> String? {
        let boosts = library.activeBoosts(for: url)
        guard !boosts.isEmpty else { return nil }
        return BoostScript.source(for: boosts, isValidJS: Self.isValidJS)
    }

    /// Whether `source` parses as JavaScript. Kite's document-start scripts are joined into one,
    /// so a Boost's syntax error would otherwise stop the ad blocker's scriptlets too.
    static func isValidJS(_ source: String) -> Bool {
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context, script, nil, 1, nil)
    }

    private func save() {
        guard let fileURL else { return }
        saveTask?.cancel()
        let library = library
        // Typing in the editor saves on every keystroke; write once it pauses.
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(library).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("Kite: couldn't save boosts.json: \(error)")
            }
        }
    }

    /// Writes a pending save now (at quit).
    func flush() {
        guard saveTask != nil, let fileURL else { return }
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
