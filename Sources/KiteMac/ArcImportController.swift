import AppKit
import KiteCore
import UniformTypeIdentifiers

// Import from Arc, the Mac side of `ArcImport`.
//
// Arc shuts down on 2026-12-22. Some time after that, delete this file, the
// "Import from Arc…" item in MainMenu.swift, KiteCore/ArcImport.swift, ArcArchiveImport.swift,
// ArcSettingsImport.swift, ArcKeyBindingsImport.swift, ArcHistoryImport.swift,
// ArcSiteSearchImport.swift, ArcLinkRoutingImport.swift, and BrowserState.arcProfileMap, and make
// AppDelegate.airTraffic private again.

extension BrowserWindowController {
    @objc func importFromArc(_ sender: Any?) {
        guard let window else { return }
        ArcImportController.start(store: store, window: window)
    }
}

@MainActor
enum ArcImportController {
    /// Arc's folder in Application Support. A test build (one with `KITE_SUPPORT_PATH`)
    /// can point `KITE_ARC_DATA_PATH` at a folder of hand-made files instead, so tests
    /// never read the user's real Arc data.
    nonisolated static var arcDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let path = environment["KITE_ARC_DATA_PATH"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc")
    }

    static var sidebarFile: URL { arcDirectory.appendingPathComponent("StorableSidebar.json") }

    /// Shortcuts the user changed in Arc's Settings → Shortcuts.
    static var keyBindingsFile: URL { arcDirectory.appendingPathComponent("StorableKeyBindings.json") }

    /// Arc's Air Traffic Control routes.
    static var linkRoutingFile: URL { arcDirectory.appendingPathComponent("StorableLinkRouting.json") }

    /// Arc's archived tabs (Archive › View Archive).
    static var archiveFile: URL { arcDirectory.appendingPathComponent("StorableArchiveItems.json") }

    /// An Arc profile's browsing history; `profile` is its folder ("Default", "Profile 1"…).
    static func historyFile(profile: String) -> URL {
        arcDirectory.appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("History")
    }

    /// Arc's profile names by folder, from Chromium's `Local State`, where Arc's
    /// setProfileUserVisibleName(for:name:) keeps them.
    static func readProfileNames() -> [String: String] {
        let file = arcDirectory.appendingPathComponent("User Data/Local State")
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return Dictionary(ImportProfiles.chromium(localState: data).map { ($0.directory, $0.name) }) { first, _ in first }
    }

    private static let arcDefaultsDomain = "company.thebrowser.Browser"

    /// The Arc settings Kite also has, from Arc's defaults. Under `KITE_ARC_DATA_PATH`, from a
    /// company.thebrowser.Browser.plist in that folder instead.
    static func readArcSettings() -> ArcSettings {
        let keys = ["shouldWarnBeforeQuitting", "openExternalLinksInLittleBrowserEnabled", "autoArchiveTimeThresholdsPerProfile"]
        var defaults: [String: Any] = [:]
        if ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] != nil,
           ProcessInfo.processInfo.environment["KITE_ARC_DATA_PATH"] != nil {
            let file = arcDirectory.appendingPathComponent(arcDefaultsDomain + ".plist")
            defaults = (NSDictionary(contentsOf: file) as? [String: Any]) ?? [:]
        } else {
            for key in keys {
                defaults[key] = CFPreferencesCopyAppValue(key as CFString, arcDefaultsDomain as CFString)
            }
        }
        return ArcSettings(defaults: defaults)
    }

    /// Reads Arc's sidebar from its usual place, or asks for the file if Arc isn't there.
    static func start(store: BrowserStore, window: NSWindow) {
        // Reading Arc's history takes a moment; a second press meanwhile does nothing.
        guard !isReading else { return }
        if let test = testMode, test.dataPath == nil {
            return testLog("no KITE_ARC_DATA_PATH, so nothing read")
        }
        if let data = try? Data(contentsOf: sidebarFile) {
            confirm(data, store: store, window: window)
            return
        }
        if testMode != nil { return testLog("no StorableSidebar.json") }
        let panel = NSOpenPanel()
        panel.message = "Kite couldn't find Arc's data. Choose StorableSidebar.json from Arc's folder in Application Support."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = sidebarFile.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    confirm(try Data(contentsOf: url), store: store, window: window)
                } catch {
                    showError("Kite couldn't read that file.", detail: error.localizedDescription, window: window)
                }
            }
        }
    }

    private static func confirm(_ data: Data, store: BrowserStore, window: NSWindow) {
        let result: ArcImport.Result
        do {
            result = try ArcImport.parse(data)
        } catch ArcImport.Failure.noSpaces {
            return showError("There are no spaces to import.", detail: "Arc's sidebar has no spaces with tabs in them.", window: window)
        } catch {
            return showError("That isn't Arc's sidebar file.", detail: "Choose StorableSidebar.json from Arc's folder in Application Support.", window: window)
        }

        // Incognito windows keep no history, so there's nowhere to put Arc's.
        let wantsHistory = store.historyRoot != nil
        let historyFiles = ArcImport.Result.withDefault(result.profiles).map { ($0, historyFile(profile: $0)) }
        isReading = true
        Task {
            defer { isReading = false }
            // Each profile's History can be large; copying and reading it stays off the main thread.
            let histories = await Task.detached {
                wantsHistory ? Dictionary(uniqueKeysWithValues: historyFiles.map { ($0.0, ArcHistoryImport.read(from: $0.1)) }) : [:]
            }.value
            // The window may have closed while the files were read.
            confirm(result, histories: histories, store: store, window: window.isVisible ? window : NSApp.mainWindow ?? window)
        }
    }

    private static var isReading = false

    private static func confirm(_ result: ArcImport.Result, histories: [String: [HistoryEntry]], store: BrowserStore, window: NSWindow) {
        let reimported = result.spaces.filter { store.state.spaceIndex($0.id) != nil }.count
        let siteSearches = ArcSiteSearchImport.read()
        let keyBindings = (try? Data(contentsOf: keyBindingsFile)).flatMap { try? ArcKeyBindingsImport.parse($0) } ?? []
        let archive = (try? Data(contentsOf: archiveFile)).map(ArcArchiveImport.parse) ?? []
        let routes = (try? Data(contentsOf: linkRoutingFile)).flatMap(ArcLinkRoutingImport.parse)
        let profileNames = readProfileNames()
        let settings = readArcSettings()
        // What the dialog counts is what imports with the unnamed spaces left out, as they start.
        let named = result.namedSpaceProfiles
        let historyCount = ArcImport.Result.withDefault(named).reduce(0) { $0 + (histories[$1]?.count ?? 0) }
        // The routes that will come over: to a named space here or a space Kite already has.
        let shownRoutes = routes?.keeping(spaces: Set(result.spaces.filter { !result.untitledSpaceIDs.contains($0.id) }.map(\.id))
            .union(store.state.spaces.map(\.id)))
        var lines = [summary(result)]
        let extras = [
            archive.isEmpty ? nil : count(archive.count, "archived tab"),
            historyCount == 0 ? nil : count(historyCount, "history page"),
            siteSearches.isEmpty ? nil : count(siteSearches.count, "Site Search shortcut"),
            keyBindings.isEmpty ? nil : count(keyBindings.count, "keyboard shortcut change"),
            shownRoutes.flatMap { $0.rules.isEmpty ? nil : count($0.rules.count, "Air Traffic Control route") },
            settings.isEmpty ? nil : count(settings.names.count, "Arc setting") + " (" + settings.names.joined(separator: ", ") + ")",
        ].compactMap { $0 }
        if !extras.isEmpty { lines.append("Also imports \(list(extras)).") }
        if archive.count > BrowserState.archiveLimit {
            lines.append("Kite's archive keeps the latest \(BrowserState.archiveLimit) tabs, so older archived tabs are left out.")
        }
        if let n = routes?.profileRoutes, n > 0 {
            lines.append("\(count(n, "Air Traffic Control route")) to an Arc profile \(n == 1 ? "is" : "are") left out: Kite's routes open in a space or Little Kite.")
        }
        if let n = routes?.unreadable, n > 0 {
            lines.append("Kite couldn't read \(count(n, "Air Traffic Control route")), so \(n == 1 ? "it's" : "they're") left out.")
        }
        if let routes, let shownRoutes, routes.rules.count > shownRoutes.rules.count {
            lines.append("Routes to a space that isn't imported are left out.")
        }
        if let id = shownRoutes?.defaultSpace,
           let space = result.spaces.first(where: { $0.id == id }) ?? store.state.spaces.first(where: { $0.id == id }) {
            lines.append("Links from other apps that no route catches open in \(space.name), as in Arc.")
        }
        if let profiles = profilesLine(named, names: profileNames, state: store.state) { lines.append(profiles) }
        if result.profiles.contains(where: { !named.contains($0) }) {
            lines.append("A profile only unnamed spaces use comes over, with its favorites and history, only if you include them.")
        }
        lines += result.notes
        lines.append(reimported > 0
            ? "\(count(reimported, "space")) imported before will be replaced with Arc's current version, including changes you made to them in Kite."
            : "Importing again later replaces these spaces with Arc's current version, including changes you make to them in Kite.")
        if let shownRoutes, !shownRoutes.rules.isEmpty {
            lines.append("Importing again also replaces the Air Traffic Control routes that came from Arc.")
        }

        /// Imports, leaving out unnamed spaces unless `includeUntitled`.
        func perform(includeUntitled: Bool) {
            let spaces = result.spaces.filter { includeUntitled || !result.untitledSpaceIDs.contains($0.id) }
            var merged: BrowserState.ArcMerge?
            store.mutateWithoutUndo {
                merged = $0.mergeArc(spaces, favoritesByProfile: result.favoritesByProfile, profileNames: profileNames)
                $0.mergeSiteSearches(siteSearches)
                $0.mergeArchive(imported: archive)
                $0.apply(settings)
            }
            // Arc's own setting, else its Air Traffic Control default (Kite keeps that default as the setting).
            if let little = settings.opensExternalLinksInLittleKite ?? routes?.defaultOpensInLittleKite, testMode == nil {
                UserDefaults.standard.set(little, forKey: LittleKite.opensExternalLinksKey)
            }
            // Each Arc profile's history goes to the Kite profile it went to.
            for (arc, kite) in merged?.profiles ?? [:] {
                if let entries = histories[arc], !entries.isEmpty { store.historyRoot?.forProfile(kite).merge(entries) }
            }
            if !keyBindings.isEmpty {
                (NSApp.delegate as? AppDelegate)?.keyBindings.merge(keyBindings, menu: NSApp.mainMenu)
            }
            if let routes = routes?.keeping(spaces: Set(store.state.spaces.map(\.id))), !routes.isEmpty {
                (NSApp.delegate as? AppDelegate)?.airTraffic.state.merge(arc: routes)
            }
        }

        if let test = testMode {
            testLog(lines.joined(separator: " | "))
            guard test.imports else { return }
            perform(includeUntitled: false)
            if let routing = (NSApp.delegate as? AppDelegate)?.airTraffic.state {
                testLog("imported; Air Traffic Control has \(count(routing.rules.count, "route")), default \(routing.defaultDestination.map { "\($0)" } ?? "the Little Kite setting")")
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Import from Arc"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        // Arc has unnamed spaces the user often never set up; leave them out unless asked.
        var untitledBox: NSButton?
        if !result.untitledSpaceIDs.isEmpty {
            let untitled = result.spaces.filter { result.untitledSpaceIDs.contains($0.id) }
            let tabs = untitled.reduce(0) { $0 + $1.allTabs.count }
            let box = NSButton(
                checkboxWithTitle: "Include \(count(untitled.count, "unnamed space")) (\(count(tabs, "tab")))",
                target: nil,
                action: nil
            )
            box.state = .off
            box.sizeToFit()
            alert.accessoryView = box
            untitledBox = box
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { perform(includeUntitled: untitledBox?.state == .on) }
        }
    }

    // MARK: Test hook

    /// `KITE_TEST_IMPORT`, on a throwaway profile with `KITE_ARC_DATA_PATH` set: Import from Arc
    /// writes its dialog's text to stderr instead of showing it, since an alert sheet brings Kite
    /// to the front. `KITE_TEST_IMPORT=Arc` then imports, leaving out the unnamed spaces, as
    /// `Browser` does for Import from Another Browser. Without `KITE_ARC_DATA_PATH` it reads nothing.
    private static var testMode: (imports: Bool, dataPath: String?)? {
        guard let mode = BrowserImportController.testMode else { return nil }
        return (mode == "Arc", ProcessInfo.processInfo.environment["KITE_ARC_DATA_PATH"])
    }

    private static func testLog(_ line: String) {
        FileHandle.standardError.write(Data("KITE_TEST_IMPORT: Arc: \(line)\n".utf8))
    }

    /// Which Arc profiles get a new Kite profile, or nil when every space stays in the default one.
    private static func profilesLine(_ profiles: [String], names: [String: String], state: BrowserState) -> String? {
        guard profiles.contains(where: { $0 != Profile.defaultDirectory }) else { return nil }
        let existing = state.existingProfiles(forArc: profiles, names: names)
        let new = profiles.filter { existing[$0] == nil }.map { BrowserState.arcProfileName($0, names: names) }
        var line = "Your spaces use \(count(profiles.count, "Arc profile"))."
        if !new.isEmpty { line += " Kite makes \(new.count == 1 ? "a profile" : "profiles") for \(list(new.map { "“\($0)”" }))." }
        if new.count < profiles.count {
            line += new.isEmpty ? " They go into Kite profiles you already have." : " The others go into Kite profiles you already have."
        }
        return line + " Sign-ins don't carry over, so you'll sign in to sites again."
    }

    private static func summary(_ result: ArcImport.Result) -> String {
        // Counts leave out unnamed spaces; their checkbox gives their own.
        let untitled = result.spaces.filter { result.untitledSpaceIDs.contains($0.id) }
        let favorites = result.favorites(in: result.namedSpaceProfiles)
        var parts = [count(result.spaces.count - untitled.count, "space")]
        if !favorites.isEmpty { parts.append(count(favorites.count, "favorite")) }
        parts.append(count(result.spaces.reduce(0) { $0 + (untitled.contains($1) ? 0 : $1.allTabs.count) }, "tab"))
        if result.folderCount > 0 { parts.append(count(result.folderCount, "folder")) }
        if result.splitCount > 0 { parts.append(count(result.splitCount, "split view")) }
        return "Found \(list(parts))."
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ parts: [String]) -> String {
        parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? ""
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func showError(_ message: String, detail: String, window: NSWindow) {
        if testMode != nil { return testLog("\(message) \(detail)") }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
