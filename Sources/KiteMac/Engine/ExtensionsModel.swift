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
    /// The user's extensions: everything but Kite's helper and the password manager Kite
    /// treats as part of itself (Settings), which can't be removed, turned off or pinned here.
    @Published private(set) var extensions: [InstalledExtension] = []
    /// The chosen password manager while it's installed and on: the address field's key
    /// button opens it.
    @Published private(set) var passwordManager: InstalledExtension?
    /// Shown in the toolbar, in order. Kite keeps these; Chromium has no pin state for Alloy tabs.
    @Published private(set) var pinnedIDs: [String]

    let engine: WebEngine
    private var helper: ChromiumPage?
    private var helperReady = false
    private var waiting: [() -> Void] = []

    /// In the profile folder (not UserDefaults), so it follows the profile and test
    /// profiles keep their own. Each Kite profile pins its own extensions.
    private var pinnedFile: URL { Self.pinnedFile(profile) }

    private static func pinnedFile(_ profile: String) -> URL {
        let name = profile == Profile.defaultDirectory ? "PinnedExtensions.json" : "PinnedExtensions.\(profile).json"
        return AppDelegate.supportDirectory.appendingPathComponent(name)
    }
    private static var shared: [String: ExtensionsModel] = [:]
    /// The Chromium profile folder whose extensions these are.
    let profile: String

    /// One model per profile, shared by its windows.
    static func shared(engine: WebEngine) -> ExtensionsModel {
        let profile = engine.profileDirectory ?? Profile.defaultDirectory
        if let model = shared[profile] { return model }
        let model = ExtensionsModel(engine: engine)
        shared[profile] = model
        return model
    }

    init(engine: WebEngine) {
        self.engine = engine
        profile = engine.profileDirectory ?? Profile.defaultDirectory
        let saved = (try? Data(contentsOf: Self.pinnedFile(profile))).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        pinnedIDs = (saved ?? []).filter(ChromeWebStore.isExtensionID)
    }

    /// Pinned extensions that are installed and on, in pin order.
    var pinned: [InstalledExtension] {
        pinnedIDs.compactMap { id in extensions.first { $0.id == id && $0.enabled } }
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func setPinned(_ id: String, _ pinned: Bool) {
        pinnedIDs.removeAll { $0 == id }
        if pinned { pinnedIDs.append(id) }
        try? JSONEncoder().encode(pinnedIDs).write(to: pinnedFile, options: .atomic)
    }

    /// Re-reads the list (installs happen in Chromium, so ask whenever it's shown).
    func refresh() {
        call("kiteHelper.list()") { [weak self] value, error in
            guard let self, let json = (value as? String)?.data(using: .utf8) else {
                if let error { NSLog("Kite: couldn't list extensions: %@", error) }
                return
            }
            let folders = self.extensionFolders()
            let all = InstalledExtensions.list(managementJSON: json, folders: folders)
            let managerID = PasswordManagerIntegration.current.extensionID
            self.extensions = all.filter { $0.id != managerID }
            self.passwordManager = all.first { $0.id == managerID && $0.enabled }
            // Chromium writes a new extension's folder to Secure Preferences a few seconds
            // later; until then there's no icon or popup, so look again.
            if all.contains(where: { folders[$0.id] == nil }), self.folderRetries < 5 {
                self.folderRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
            } else {
                self.folderRetries = 0
            }
        }
    }

    private var folderRetries = 0

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

    private var profileDefault: URL {
        AppDelegate.supportDirectory.appendingPathComponent("Chromium", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
    }

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

#if canImport(CEFBridge)
import SwiftUI

/// The extensions a window shows: its current space's profile's, which change as you move
/// between spaces with different profiles.
@MainActor
final class ExtensionsSelection: ObservableObject {
    @Published private(set) var model: ExtensionsModel

    init(_ model: ExtensionsModel) {
        self.model = model
    }

    func show(_ model: ExtensionsModel) {
        guard model !== self.model else { return }
        self.model = model
        model.refresh()
    }
}

/// `content` for the selection's current model.
struct ExtensionsSelectionView<Content: View>: View {
    @ObservedObject var selection: ExtensionsSelection
    @ViewBuilder let content: (ExtensionsModel) -> Content

    var body: some View { content(selection.model) }
}
#endif
