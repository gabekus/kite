#if canImport(CEFBridge)
import AppKit
import KiteCore

// Extensions › Add Extensions from Arc…: Arc's Web Store extensions that the front window's
// profile doesn't have yet, added one after another through the store's own Add flow.
// Delete with ArcImportController.swift once Arc has shut down.

@MainActor
enum ArcExtensionsInstaller {
    /// Arc's extensions for the Kite profile `engine` uses (see `BrowserState.arcProfiles`),
    /// leaving out ones turned off in Arc and ones the profile already has.
    static func missing(for engine: WebEngine, state: BrowserState) -> [ArcExtensionsImport.Extension] {
        guard let profile = engine.profileDirectory else { return [] }
        let installed = BackgroundExtensionInstall.installedIDs(profile: profile)
        var result: [ArcExtensionsImport.Extension] = []
        for arc in state.arcProfiles(inKiteProfile: profile) {
            for item in read(profile: arc) where !installed.contains(item.id) && !result.contains(where: { $0.id == item.id }) {
                result.append(item)
            }
        }
        return result
    }

    /// One Arc profile's enabled Web Store extensions, by name.
    static func read(profile: String, in arcFolder: URL = ArcImportController.arcDirectory) -> [ArcExtensionsImport.Extension] {
        let folder = arcFolder.appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
        let files = FileManager.default
        let preferences = ["Secure Preferences", "Preferences"].compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
        let disabled = ArcExtensionsImport.disabledIDs(preferences: preferences)
        let extensions = folder.appendingPathComponent("Extensions", isDirectory: true)
        var result: [ArcExtensionsImport.Extension] = []
        for id in (try? files.contentsOfDirectory(atPath: extensions.path)) ?? [] where !disabled.contains(id) {
            // The newest version folder that has a manifest.
            let versions = ((try? files.contentsOfDirectory(atPath: extensions.appendingPathComponent(id).path)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in versions {
                let root = extensions.appendingPathComponent(id).appendingPathComponent(version, isDirectory: true)
                guard let manifest = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { continue }
                let item = ArcExtensionsImport.storeExtension(id: id, manifest: manifest) { locale in
                    try? Data(contentsOf: root.appendingPathComponent("_locales/\(locale)/messages.json"))
                }
                if let item { result.append(item) }
                break
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adding, by profile: the ones still to go and the install running now.
    private static var queues: [String: [ArcExtensionsImport.Extension]] = [:]
    private static var running: [String: BackgroundExtensionInstall] = [:]

    static func isAdding(in engine: WebEngine) -> Bool {
        engine.profileDirectory.map { running[$0] != nil } ?? false
    }

    /// Asks, then adds `extensions` to `engine`'s profile one at a time; Chrome asks for each.
    static func add(_ extensions: [ArcExtensionsImport.Extension], to engine: WebEngine, window: NSWindow?) {
        guard let profile = engine.profileDirectory, !extensions.isEmpty, running[profile] == nil else { return }
        let names = extensions.map(\.name)
        if BrowserImportController.testMode != nil {
            // Chrome's dialogs can't be answered from a test, so this only says what it would add.
            FileHandle.standardError.write(Data("KITE_TEST_IMPORT: Arc extensions for \(profile): \(names.joined(separator: " | "))\n".utf8))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add \(extensions.count == 1 ? "1 extension" : "\(extensions.count) extensions") from Arc?"
        alert.informativeText = names.joined(separator: "\n")
            + "\n\nKite adds each from the Chrome Web Store, and Chrome asks you to confirm it."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let start = {
            queues[profile] = extensions
            next(profile: profile, engine: engine)
        }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { start() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { start() }
        }
    }

    private static func next(profile: String, engine: WebEngine) {
        guard var queue = queues[profile], !queue.isEmpty else {
            queues[profile] = nil
            running[profile] = nil
            ExtensionsModel.shared(engine: engine).refresh()
            return
        }
        let item = queue.removeFirst()
        queues[profile] = queue
        guard let store = ChromeWebStore.detailURL(for: item.id) else { return next(profile: profile, engine: engine) }
        running[profile] = BackgroundExtensionInstall(extensionID: item.id, storeURL: store, engine: engine, source: nil) {
            ExtensionsModel.shared(engine: engine).refresh()
            next(profile: profile, engine: engine)
        }
    }
}
#endif
