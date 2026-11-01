import Foundation
import JavaScriptCore
import KiteCore
import Observation

extension Notification.Name {
    /// The zaps some site hides changed (a zap, an undo, a Boost turned on or off or deleted);
    /// open pages replace their zap CSS live.
    static let kiteZapsChanged = Notification.Name("KiteZapsChanged")
}

/// The profile's Boosts (boosts.json), read by both engines when a page starts loading.
/// Incognito windows never run them, as in Arc ("Boosts can't be installed or used in Incognito Mode").
@MainActor
@Observable
final class BoostsModel {
    static let shared = BoostsModel()

    private(set) var library = BoostLibrary()
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Each site's active zap CSS when it was last announced, to post `kiteZapsChanged` only
    /// when it changes (not on every keystroke in the editor).
    @ObservationIgnored private var announcedZaps: [String: String] = [:]

    func start(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                library = try decoder.decode(BoostLibrary.self, from: data)
            } catch {
                NSLog("Kite: couldn't read boosts.json: \(error)")
                // Don't overwrite a file Kite can't read with zaps alone.
                return
            }
        }
        migrateZaps(from: fileURL.deletingLastPathComponent().appendingPathComponent("zaps.json"))
        announcedZaps = zapTable()
    }

    /// Zap shipped on its own first, in zaps.json. Its zaps move into each site's Boost once;
    /// the file is then renamed zaps.json.migrated (kept, never deleted) so it isn't read again.
    private func migrateZaps(from zapsURL: URL) {
        guard let data = try? Data(contentsOf: zapsURL),
              let zaps = try? JSONDecoder().decode(ZapLibrary.self, from: data) else { return }
        if library.migrate(zaps) {
            guard write(library) else { return }
        }
        let manager = FileManager.default
        var destination = zapsURL.appendingPathExtension("migrated")
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = zapsURL.appendingPathExtension("migrated-\(suffix)")
            suffix += 1
        }
        do {
            try manager.moveItem(at: zapsURL, to: destination)
        } catch {
            NSLog("Kite: couldn't rename zaps.json after moving its zaps into Boosts: \(error)")
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

    // MARK: Zaps

    /// The Boost whose zaps the picker shows for `domain`.
    func zapBoost(forDomain domain: String, preferring preferred: UUID?) -> Boost? {
        library.zapBoost(forDomain: domain, preferring: preferred)
    }

    /// Adds a zap to the site's Boost (made if it has none); returns that Boost's id.
    @discardableResult
    func addZap(_ selector: String, domain: String, preferring preferred: UUID?) -> UUID? {
        let id = library.addZap(selector, domain: domain, preferring: preferred)
        if id != nil { save() }
        return id
    }

    /// Arc's removeZap.
    func removeZap(_ selector: String, from id: UUID) {
        library.removeZap(selector, from: id)
        save()
    }

    /// Brings a live page's zap CSS up to date: its site's active zaps, minus `except` (the
    /// picker shows that one again while its cell is hovered). Pages in incognito windows are
    /// never given this (they don't run Boosts).
    func applyZapsLive(to page: WebPage, except: String? = nil) {
        page.evaluateJavaScript(ZapScript.hostScript) { [weak self, weak page] host in
            guard let self, let page, let domain = ZapLibrary.domain(ofHost: host as? String) else { return }
            let css = ZapLibrary.css(self.library.activeZaps(forDomain: domain).filter { $0 != except })
            page.evaluateJavaScript(ZapScript.apply(css: css)) { _ in }
        }
    }

    private func zapTable() -> [String: String] {
        var table: [String: String] = [:]
        for domain in Set(library.boosts.map(\.domain)) {
            let css = library.zapCSS(forDomain: domain)
            if !css.isEmpty { table[domain] = css }
        }
        return table
    }

    private func announceZapsIfChanged() {
        let table = zapTable()
        guard table != announcedZaps else { return }
        announcedZaps = table
        NotificationCenter.default.post(name: .kiteZapsChanged, object: self)
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
        announceZapsIfChanged()
        guard fileURL != nil else { return }
        saveTask?.cancel()
        let library = library
        // Typing in the editor saves on every keystroke; write once it pauses.
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write(library)
        }
    }

    /// Writes a pending save now (at quit).
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        write(library)
    }

    @discardableResult
    private func write(_ library: BoostLibrary) -> Bool {
        guard let fileURL else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(library).write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("Kite: couldn't save boosts.json: \(error)")
            return false
        }
    }
}
