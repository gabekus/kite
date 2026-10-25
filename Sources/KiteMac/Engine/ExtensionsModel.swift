#if canImport(CEFBridge)
import AppKit
import Combine
import KiteCore

/// The extensions installed in Kite's Chromium profile, and managing them.
///
/// Chromium won't open chrome://extensions in Kite's (Alloy-style) tabs, so Kite drives
/// its own helper extension instead (Resources/KiteHelperExtension): its manage.html is
/// loaded in a browser nobody sees, and its chrome.management calls do the work.
/// Removing still asks with Chrome's own "Remove …?" dialog, attached to the window.
@MainActor
final class ExtensionsModel: ObservableObject {
    @Published private(set) var extensions: [InstalledExtension] = []

    private let engine: WebEngine
    private var helper: ChromiumPage?
    private var helperReady = false
    private var waiting: [() -> Void] = []

    init(engine: WebEngine) {
        self.engine = engine
    }

    /// Re-reads the list (installs happen in Chromium, so ask whenever it's shown).
    func refresh() {
        call("kiteHelper.list()") { [weak self] value, error in
            guard let self, let json = (value as? String)?.data(using: .utf8) else {
                if let error { NSLog("Kite: couldn't list extensions: %@", error) }
                return
            }
            self.extensions = InstalledExtensions.list(managementJSON: json, folders: self.extensionFolders())
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard ChromeWebStore.isExtensionID(id) else { return }
        call("kiteHelper.setEnabled(\"\(id)\", \(enabled))") { [weak self] _, error in
            if let error { NSLog("Kite: couldn't turn %@ %@: %@", id, enabled ? "on" : "off", error) }
            self?.refresh()
        }
    }

    /// Asks with Chrome's "Remove …?" dialog; the list updates either way.
    func remove(_ id: String) {
        guard ChromeWebStore.isExtensionID(id) else { return }
        call("kiteHelper.remove(\"\(id)\")", userGesture: true) { [weak self] _, error in
            if let error { NSLog("Kite: couldn't remove %@: %@", id, error) }
            self?.refresh()
        }
    }

    // MARK: Helper page

    private func call(_ expression: String, userGesture: Bool = false, completion: @escaping (Any?, String?) -> Void) {
        let run = { [weak self] in
            guard let helper = self?.helper else { return completion(nil, "Kite's helper extension isn't loaded.") }
            helper.evaluate(expression, userGesture: userGesture, completion: completion)
        }
        if helperReady { return run() }
        waiting.append(run)
        startHelper()
    }

    private func startHelper() {
        guard helper == nil,
              let url = URL(string: "chrome-extension://\(KiteHelperExtension.id)/\(KiteHelperExtension.pagePath)"),
              let page = engine.makePage(url: url, restoring: nil) as? ChromiumPage else { return }
        helper = page
        // In a window but hidden: Chromium parents the Remove dialog to it.
        if let content = NSApp.mainWindow?.contentView ?? NSApp.windows.first?.contentView {
            page.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            page.view.isHidden = true
            content.addSubview(page.view, positioned: .below, relativeTo: nil)
        }
        page.onEvent = { [weak self] event in
            guard let self, case let .navigationState(isLoading, _, _) = event, !isLoading, !self.helperReady else { return }
            self.helperReady = true
            let pending = self.waiting
            self.waiting = []
            pending.forEach { $0() }
        }
    }

    // MARK: Files

    private var profileDefault: URL { AppDelegate.supportDirectory.appendingPathComponent("Chromium/Default", isDirectory: true) }

    /// Each extension's folder, from Secure Preferences, else (for an install Chromium
    /// hasn't written there yet) the newest version under Extensions/<id>.
    private func extensionFolders() -> [String: URL] {
        let extensionsDirectory = profileDefault.appendingPathComponent("Extensions", isDirectory: true)
        var folders: [String: URL] = [:]
        if let data = try? Data(contentsOf: profileDefault.appendingPathComponent("Secure Preferences")) {
            folders = InstalledExtensions.folders(securePreferences: data, extensionsDirectory: extensionsDirectory)
        }
        let fileManager = FileManager.default
        for id in (try? fileManager.contentsOfDirectory(atPath: extensionsDirectory.path)) ?? [] where folders[id] == nil {
            let versions = (try? fileManager.contentsOfDirectory(atPath: extensionsDirectory.appendingPathComponent(id).path)) ?? []
            if let newest = versions.filter({ !$0.hasPrefix(".") }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                folders[id] = extensionsDirectory.appendingPathComponent(id).appendingPathComponent(newest, isDirectory: true)
            }
        }
        return folders
    }
}
#endif
