import AppKit
import KiteCore

// "Import from Another Browser…", the Mac side of KiteCore/BrowserImport.swift: bookmarks
// and history from Safari, Firefox and the Chromium browsers (Chrome, Brave, Edge, Vivaldi,
// Opera), from the source browser profile you pick. Arc's Arc menu has the item, between Set as
// Default Browser and Check for Updates.

extension BrowserWindowController {
    @objc func importFromAnotherBrowser(_ sender: Any?) {
        guard let window else { return }
        BrowserImportController.start(store: store, window: window, toast: { [weak self] in self?.showToast($0) })
    }
}

@MainActor
enum BrowserImportController {
    /// Where a browser keeps its data (its profiles, Chromium's Local State, Firefox's
    /// profiles.ini). A test build (one with `KITE_SUPPORT_PATH`) can point
    /// `KITE_BROWSER_DATA_PATH` at a folder of hand-made files laid out the same way
    /// (Google/Chrome/Default/Bookmarks, Firefox/profiles.ini, Safari/Bookmarks.plist, …), so
    /// tests never read the user's real browser data.
    nonisolated static func dataFolder(_ browser: ImportBrowser) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let path = environment["KITE_BROWSER_DATA_PATH"] {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(browser.dataFolder, isDirectory: true)
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return browser == .safari
            ? library.appendingPathComponent(browser.dataFolder, isDirectory: true)
            : library.appendingPathComponent("Application Support", isDirectory: true).appendingPathComponent(browser.dataFolder, isDirectory: true)
    }

    /// One profile's folder.
    nonisolated static func profileFolder(_ browser: ImportBrowser, _ profile: ImportProfile) -> URL {
        if profile.isAbsolute { return URL(fileURLWithPath: profile.directory, isDirectory: true) }
        let root = dataFolder(browser)
        return profile.directory.isEmpty ? root : root.appendingPathComponent(profile.directory, isDirectory: true)
    }

    /// The browser's profiles that have something to import, and which one to offer first.
    struct Profiles {
        var list: [ImportProfile]
        var preferred: Int
    }

    /// Chromium browsers list their profiles in `Local State`, Firefox in `profiles.ini`;
    /// Safari and Opera have one. A profile folder without bookmarks or history isn't offered.
    nonisolated static func profiles(_ browser: ImportBrowser) -> Profiles {
        let root = dataFolder(browser)
        var candidates: [ImportProfile] = []
        var preferredDirectory = browser.defaultProfile?.directory
        if browser.isChromium, browser.hasProfiles,
           let data = try? Data(contentsOf: root.appendingPathComponent("Local State")) {
            candidates = ImportProfiles.chromium(localState: data)
        } else if browser == .firefox,
                  let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            let parsed = ImportProfiles.firefox(ini: text)
            candidates = parsed.profiles
            preferredDirectory = parsed.defaultDirectory
        }
        if candidates.isEmpty, let profile = browser.defaultProfile { candidates = [profile] }
        let list = candidates.filter { profile in
            let folder = profileFolder(browser, profile)
            return (browser.bookmarkFiles + [browser.historyFile]).contains { access(folder.appendingPathComponent($0)) != .missing }
        }
        let preferred = list.firstIndex { $0.directory == preferredDirectory } ?? 0
        return Profiles(list: list, preferred: preferred)
    }

    enum Access { case readable, denied, missing }

    /// Whether Kite may read `file`: reading anything in ~/Library/Safari needs Full Disk Access.
    nonisolated static func access(_ file: URL) -> Access {
        let fd = open(file.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        return errno == EPERM || errno == EACCES ? .denied : .missing
    }

    /// Browsers with a profile on this Mac, in the order the dialog lists them, with their profiles.
    static func installed() -> [(browser: ImportBrowser, profiles: Profiles)] {
        ImportBrowser.allCases.compactMap { browser in
            let profiles = profiles(browser)
            return profiles.list.isEmpty ? nil : (browser, profiles)
        }
    }

    static func start(store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        let browsers = installed()
        if let mode = testMode {
            return runTest(mode, browsers, store: store, toast: toast)
        }
        guard !browsers.isEmpty else {
            return showError("Kite didn’t find another browser to import from.", detail: "Kite imports from Safari, Chrome, Brave, Edge, Vivaldi, Opera and Firefox.", window: window)
        }

        // Arc's "Import from your old browser" dialog: pick the browser (and its profile, when it
        // has several), then Continue.
        let alert = NSAlert()
        alert.messageText = "Import from your old browser"
        alert.informativeText = "Import everything you need from your old browser to hit the ground running with Kite."
        let picker = BrowserPicker(browsers)
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let (browser, profile, several) = picker.selected
                if browser == .safari, !hasSafariAccess() {
                    askForFullDiskAccess(store: store, window: window, toast: toast)
                } else {
                    confirmAndImport(browser, profile, namedAfterProfile: several, store: store, window: window, toast: toast)
                }
            }
        }
    }

    // MARK: Test hook

    /// `KITE_TEST_IMPORT`, on a throwaway profile only: the menu item logs the dialog's choices
    /// (stderr, "KITE_TEST_IMPORT: Chrome [Person 1*, Work] | Firefox [default-release*]", * the
    /// one offered first) instead of showing the dialog, since an alert sheet brings Kite to the
    /// front. A value other than 1, or the text of `test-import-pick` in the profile folder, is
    /// "Browser" or "Browser/Profile name" to import right away, without the replace question.
    nonisolated static var testMode: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KITE_SUPPORT_PATH"]?.isEmpty == false,
              let value = environment["KITE_TEST_IMPORT"], !value.isEmpty else { return nil }
        return value
    }

    private static func runTest(_ mode: String, _ browsers: [(browser: ImportBrowser, profiles: Profiles)],
                                store: BrowserStore, toast: @escaping (String) -> Void) {
        let line = browsers.map { entry in
            let names = entry.profiles.list.enumerated().map { $0.offset == entry.profiles.preferred ? "\($0.element.name)*" : $0.element.name }
            return "\(entry.browser.title) [\(names.joined(separator: ", "))]"
        }.joined(separator: " | ")
        FileHandle.standardError.write(Data("KITE_TEST_IMPORT: \(line)\n".utf8))
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] ?? "").appendingPathComponent("test-import-pick")
        let pick = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (mode == "1" ? nil : mode)
        guard let pick, !pick.isEmpty else { return }
        let parts = pick.split(separator: "/", maxSplits: 1).map(String.init)
        guard let entry = browsers.first(where: { $0.browser.title == parts[0] }) else {
            FileHandle.standardError.write(Data("KITE_TEST_IMPORT: no \(parts[0])\n".utf8))
            return
        }
        let profile = parts.count > 1
            ? entry.profiles.list.first { $0.name == parts[1] }
            : entry.profiles.list[entry.profiles.preferred]
        guard let profile else {
            FileHandle.standardError.write(Data("KITE_TEST_IMPORT: no profile \(pick)\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("KITE_TEST_IMPORT: importing \(entry.browser.title)/\(profile.name)\n".utf8))
        runImport(entry.browser, profile, namedAfterProfile: entry.profiles.list.count > 1, store: store, toast: toast)
    }

    private static func hasSafariAccess() -> Bool {
        let folder = dataFolder(.safari)
        let files = (ImportBrowser.safari.bookmarkFiles + [ImportBrowser.safari.historyFile]).map { access(folder.appendingPathComponent($0)) }
        return !files.contains(.denied)
    }

    /// Arc's "Import from Safari" screen: Safari's files need Full Disk Access.
    private static func askForFullDiskAccess(store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Import from Safari"
        alert.informativeText = "To import Safari browser history, Kite will need Full Disk Access. Feel free to remove access when this step is finished."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
                askToRestart(store: store, window: window, toast: toast)
            }
        }
    }

    private static func askToRestart(store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Import from Safari"
        alert.informativeText = "After you have given access, you can choose to restart Kite now, or continue and restart later."
        let canRestart = Bundle.main.bundleURL.pathExtension == "app"
        if canRestart { alert.addButton(withTitle: "Restart Kite") }
        alert.addButton(withTitle: "Continue without restarting")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                switch (canRestart, index) {
                case (true, 0):
                    restartKite()
                case (true, 1), (false, 0):
                    guard hasSafariAccess() else {
                        return showError(
                            "Kite still can’t read Safari’s data.",
                            detail: "Turn on Kite in System Settings › Privacy & Security › Full Disk Access, then restart Kite and import again.",
                            window: window
                        )
                    }
                    confirmAndImport(.safari, ImportBrowser.safari.defaultProfile!, namedAfterProfile: false, store: store, window: window, toast: toast)
                default:
                    break
                }
            }
        }
    }

    /// Quits and reopens Kite.app, so macOS applies the new Full Disk Access setting.
    private static func restartKite() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    /// Reads the browser's bookmarks; asks first only when an earlier import's space would be replaced.
    private static func confirmAndImport(_ browser: ImportBrowser, _ profile: ImportProfile, namedAfterProfile: Bool,
                                         store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        let id = browser.spaceID(for: profile)
        guard let index = store.state.spaceIndex(id) else {
            return runImport(browser, profile, namedAfterProfile: namedAfterProfile, store: store, toast: toast)
        }
        let name = store.state.spaces[index].name
        let source = namedAfterProfile ? "\(browser.title)’s “\(profile.name)” profile" : browser.title
        let alert = NSAlert()
        alert.messageText = "Import from \(browser.title)"
        alert.informativeText = "This replaces the “\(name)” space from your last import with the bookmarks in \(source) now, including changes you made to it in Kite."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { runImport(browser, profile, namedAfterProfile: namedAfterProfile, store: store, toast: toast) }
        }
    }

    private static func runImport(_ browser: ImportBrowser, _ profile: ImportProfile, namedAfterProfile: Bool,
                                  store: BrowserStore, toast: @escaping (String) -> Void) {
        toast("Now importing… Sit tight!")
        let folder = profileFolder(browser, profile)
        let wantsHistory = store.history != nil
        Task {
            let read = await Task.detached { readData(browser, folder: folder, history: wantsHistory) }.value
            if let bookmarks = read.bookmarks, !bookmarks.isEmpty {
                let n = store.state.spaces.count
                let icon = BrowserStore.spaceIcons[n % BrowserStore.spaceIcons.count]
                let theme = Theme.presets[n % Theme.presets.count]
                let previous = store.state.spaces.first { $0.id == browser.spaceID(for: profile) }
                let space = BookmarkImport.space(for: browser, profile: profile, namedAfterProfile: namedAfterProfile, bookmarks,
                                                 theme: previous?.theme ?? theme, icon: previous?.icon ?? icon)
                store.mutate { $0.merge(imported: [space]) }
            }
            if let history = read.history, !history.isEmpty { store.history?.merge(history) }
            let gotBookmarks = read.bookmarks != nil
            let gotHistory = read.history != nil || !wantsHistory
            switch (gotBookmarks, gotHistory) {
            case (true, true): toast("Success! We imported all of your stuff")
            case (false, false): toast("We weren’t able to import… please try again!")
            default: toast("Only some of your data imported. Please try again!")
            }
        }
    }

    /// What could be read: nil for a part that failed (missing files count as nothing to import).
    private struct ReadResult: Sendable {
        var bookmarks: BookmarkImport.Result?
        var history: [HistoryEntry]?
    }

    nonisolated private static func readData(_ browser: ImportBrowser, folder: URL, history wantsHistory: Bool) -> ReadResult {
        var result = ReadResult()
        let files = browser.bookmarkFiles.map { folder.appendingPathComponent($0) }
        let present = files.filter { access($0) != .missing }
        if present.isEmpty {
            result.bookmarks = BookmarkImport.Result()
        } else {
            if browser == .firefox {
                result.bookmarks = (try? BrowserHistoryImport.firefoxBookmarks(from: present[0])).map { BookmarkImport.firefox($0) }
            } else {
                let data = present.compactMap { try? Data(contentsOf: $0) }
                if !data.isEmpty {
                    result.bookmarks = browser.isChromium
                        ? try? BookmarkImport.chromium(data)
                        : try? BookmarkImport.safari(data[0])
                }
            }
        }
        if wantsHistory {
            let file = folder.appendingPathComponent(browser.historyFile)
            if access(file) == .missing {
                result.history = []
            } else {
                result.history = switch browser {
                case .safari: try? BrowserHistoryImport.safari(from: file)
                case .firefox: try? BrowserHistoryImport.firefox(from: file)
                default: try? BrowserHistoryImport.chromium(from: file)
                }
            }
        }
        return result
    }

    private static func showError(_ message: String, detail: String, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}

/// The dialog's browser menu, with Arc's line under it saying what comes across, and a profile
/// menu under that for a browser with more than one profile (Arc's import has a source-profile
/// picker; it's left out when there's only one profile to pick).
@MainActor
private final class BrowserPicker: NSObject {
    let view: NSView
    private let browsers: [(browser: ImportBrowser, profiles: BrowserImportController.Profiles)]
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let label = NSTextField(wrappingLabelWithString: "")
    /// The profile picked for each browser, kept while switching between browsers.
    private var chosen: [ImportBrowser: Int] = [:]

    init(_ browsers: [(browser: ImportBrowser, profiles: BrowserImportController.Profiles)]) {
        self.browsers = browsers
        let width: CGFloat = 260
        // The profile row is there only when some browser on this Mac has several profiles, so
        // the dialog stays as it was otherwise.
        let profileRow: CGFloat = browsers.contains { $0.profiles.list.count > 1 } ? 32 : 0
        popup.addItems(withTitles: browsers.map(\.browser.title))
        popup.setAccessibilityIdentifier("importBrowserPicker")
        popup.frame = NSRect(x: 0, y: 34 + profileRow, width: width, height: 26)
        profilePopup.setAccessibilityIdentifier("importProfilePicker")
        profilePopup.setAccessibilityLabel("Profile")
        profilePopup.frame = NSRect(x: 0, y: 34, width: width, height: 26)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 2, y: 0, width: width - 2, height: 30)
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60 + profileRow))
        super.init()
        view.addSubview(popup)
        if profileRow > 0 { view.addSubview(profilePopup) }
        view.addSubview(label)
        popup.target = self
        popup.action = #selector(changed)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        changed()
    }

    private var entry: (browser: ImportBrowser, profiles: BrowserImportController.Profiles) {
        browsers[max(0, popup.indexOfSelectedItem)]
    }

    /// The browser, its profile, and whether it has others (so the space is named after the profile).
    var selected: (ImportBrowser, ImportProfile, Bool) {
        let entry = entry
        let index = chosen[entry.browser] ?? entry.profiles.preferred
        return (entry.browser, entry.profiles.list[index], entry.profiles.list.count > 1)
    }

    @objc private func changed() {
        let entry = entry
        label.stringValue = entry.browser.importsDescription
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: entry.profiles.list.map(\.name))
        profilePopup.selectItem(at: chosen[entry.browser] ?? entry.profiles.preferred)
        profilePopup.isHidden = entry.profiles.list.count < 2
    }

    @objc private func profileChanged() {
        chosen[entry.browser] = max(0, profilePopup.indexOfSelectedItem)
    }
}
