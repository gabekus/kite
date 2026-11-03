#if canImport(CEFBridge)
import AppKit
import KiteCore

// Extensions › Add Extensions from Arc…: Arc's Web Store extensions that the front window's
// profile doesn't have yet, added one after another through the store's own Add flow.
// Delete with ArcImportController.swift once Arc has shut down.

@MainActor
enum ArcExtensionsInstaller {
    /// Arc's extensions for the Kite profile `engine` uses (see `BrowserState.arcProfiles`), less
    /// the ones it has and ones that didn't go in this session. Nothing on a test build without
    /// `KITE_ARC_DATA_PATH`, so tests never read the real Arc's.
    static func missing(for engine: WebEngine, state: BrowserState) -> ArcExtensionsImport.Found {
        guard let profile = engine.profileDirectory, readsArc else { return .init() }
        let installed = BackgroundExtensionInstall.installedIDs(profile: profile)
        var result = ArcExtensionsImport.Found()
        for arc in state.arcProfiles(inKiteProfile: profile) {
            let found = read(profile: arc)
            for item in found.available where !installed.contains(item.id) && !failed.contains(item.id)
                && !result.available.contains(item) {
                result.available.append(item)
            }
            for item in found.unavailable where !result.unavailable.contains(item) { result.unavailable.append(item) }
        }
        return result
    }

    static var readsArc: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KITE_SUPPORT_PATH"] == nil || environment["KITE_ARC_DATA_PATH"] != nil
    }

    /// One Arc profile's extensions. Kept while the profile's Extensions folder and preferences
    /// are unchanged, since the menu asks every time it's rebuilt.
    static func read(profile: String, in arcFolder: URL = ArcImportController.arcDirectory) -> ArcExtensionsImport.Found {
        let folder = arcFolder.appendingPathComponent("User Data", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
        let stamp = ["Extensions", "Secure Preferences", "Preferences"].map {
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
        }
        if let cached = cache[folder], cached.stamp == stamp { return cached.found }
        let found = ArcExtensionsImport.read(profileFolder: folder)
        cache[folder] = (stamp, found)
        return found
    }

    private static var cache: [URL: (stamp: [Double], found: ArcExtensionsImport.Found)] = [:]

    // MARK: Adding

    /// One run at a time, app-wide: Chrome's dialog says nothing about which profile it's for,
    /// and an install takes any dialog closing as its own.
    private static var queue: [ArcExtensionsImport.Extension] = []
    private static var running: BackgroundExtensionInstall?
    /// From the menu press until the run ends or the sheet is cancelled.
    private(set) static var isBusy = false
    /// Ones the store wouldn't add this session (cancelled, or no Add button): not offered again.
    private static var failed: Set<String> = []

    /// Asks, then adds `found.available` to `engine`'s profile one at a time; Chrome asks for each.
    static func add(_ found: ArcExtensionsImport.Found, to engine: WebEngine, window: NSWindow?) {
        guard engine.profileDirectory != nil, !found.available.isEmpty, !isBusy else { return }
        let names = found.available.map(\.name)
        if BrowserImportController.testMode != nil {
            // Chrome's dialogs can't be answered from a test, so this only says what it would add.
            let profile = engine.profileDirectory ?? ""
            let unavailable = found.unavailable.isEmpty ? "" : "; not available: \(found.unavailable.map(\.name).joined(separator: " | "))"
            FileHandle.standardError.write(Data("KITE_TEST_IMPORT: Arc extensions for \(profile): \(names.joined(separator: " | "))\(unavailable)\n".utf8))
            return
        }
        isBusy = true
        let alert = NSAlert()
        alert.messageText = "Add \(found.available.count == 1 ? "1 extension" : "\(found.available.count) extensions") from Arc to this profile?"
        var text = names.joined(separator: "\n")
            + "\n\nKite adds each from the Chrome Web Store, and Chrome asks you to confirm it. Cancel one to stop."
        if !found.unavailable.isEmpty {
            text += "\n\nNot available in Kite (built for an older Chrome): " + found.unavailable.map(\.name).joined(separator: ", ") + "."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return isBusy = false }
            queue = found.available
            next(engine: engine, window: window)
        }
        guard let window else { return answer(alert.runModal()) }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response) }
        }
    }

    private static func next(engine: WebEngine, window: NSWindow?) {
        ExtensionsModel.shared(engine: engine).refresh()
        guard !queue.isEmpty, let profile = engine.profileDirectory else {
            queue = []
            running = nil
            isBusy = false
            return
        }
        let item = queue.removeFirst()
        guard let store = ChromeWebStore.detailURL(for: item.id) else { return next(engine: engine, window: window) }
        // The window that started the run, while it's open; else the main one.
        let parent = window?.isVisible == true ? window : nil
        running = BackgroundExtensionInstall(extensionID: item.id, storeURL: store, engine: engine, source: nil, window: parent) {
            // Cancelled in Chrome's dialog, or the store has no Add button: stop the run there.
            if !BackgroundExtensionInstall.installedIDs(profile: profile).contains(item.id) {
                failed.insert(item.id)
                queue = []
            }
            next(engine: engine, window: window)
        }
    }
}
#endif
