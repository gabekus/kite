import AppKit
import KiteCore

// "Import from Another Browser…", the Mac side of KiteCore/BrowserImport.swift: bookmarks
// and history from Safari and the Chromium browsers (Chrome, Brave, Edge, Vivaldi, Opera).
// Arc's Arc menu has the item, between Set as Default Browser and Check for Updates.

extension BrowserWindowController {
    @objc func importFromAnotherBrowser(_ sender: Any?) {
        guard let window else { return }
        BrowserImportController.start(store: store, window: window, toast: { [weak self] in self?.showToast($0) })
    }
}

@MainActor
enum BrowserImportController {
    /// Where a browser keeps its default profile. A test build (one with `KITE_SUPPORT_PATH`)
    /// can point `KITE_BROWSER_DATA_PATH` at a folder of hand-made files laid out the same way
    /// (Google/Chrome/Default/Bookmarks, Safari/Bookmarks.plist, …), so tests never read the
    /// user's real browser data.
    nonisolated static func profileFolder(_ browser: ImportBrowser) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let path = environment["KITE_BROWSER_DATA_PATH"] {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(browser.profilePath, isDirectory: true)
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return browser.isChromium
            ? library.appendingPathComponent("Application Support", isDirectory: true).appendingPathComponent(browser.profilePath, isDirectory: true)
            : library.appendingPathComponent(browser.profilePath, isDirectory: true)
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

    /// Browsers with a profile on this Mac, in the order the dialog lists them.
    static func installed() -> [ImportBrowser] {
        ImportBrowser.allCases.filter { browser in
            let folder = profileFolder(browser)
            return (browser.bookmarkFiles + [browser.historyFile]).contains {
                access(folder.appendingPathComponent($0)) != .missing
            }
        }
    }

    static func start(store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        let browsers = installed()
        guard !browsers.isEmpty else {
            return showError("Kite didn’t find another browser to import from.", detail: "Kite imports from Safari, Chrome, Brave, Edge, Vivaldi and Opera.", window: window)
        }

        // Arc's "Import from your old browser" dialog: pick the browser, then Continue.
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
                let browser = picker.selected
                if browser == .safari, !hasSafariAccess() {
                    askForFullDiskAccess(store: store, window: window, toast: toast)
                } else {
                    confirmAndImport(browser, store: store, window: window, toast: toast)
                }
            }
        }
    }

    private static func hasSafariAccess() -> Bool {
        let folder = profileFolder(.safari)
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
                    confirmAndImport(.safari, store: store, window: window, toast: toast)
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
    private static func confirmAndImport(_ browser: ImportBrowser, store: BrowserStore, window: NSWindow, toast: @escaping (String) -> Void) {
        guard store.state.spaceIndex(browser.spaceID) != nil else {
            return runImport(browser, store: store, toast: toast)
        }
        let alert = NSAlert()
        alert.messageText = "Import from \(browser.title)"
        alert.informativeText = "This replaces the “\(browser.title)” space from your last import with \(browser.title)’s bookmarks now, including changes you made to it in Kite."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { runImport(browser, store: store, toast: toast) }
        }
    }

    private static func runImport(_ browser: ImportBrowser, store: BrowserStore, toast: @escaping (String) -> Void) {
        toast("Now importing… Sit tight!")
        let folder = profileFolder(browser)
        let wantsHistory = store.history != nil
        Task {
            let read = await Task.detached { readData(browser, folder: folder, history: wantsHistory) }.value
            if let bookmarks = read.bookmarks, !bookmarks.isEmpty {
                let n = store.state.spaces.count
                let icon = BrowserStore.spaceIcons[n % BrowserStore.spaceIcons.count]
                let theme = Theme.presets[n % Theme.presets.count]
                let previous = store.state.spaces.first { $0.id == browser.spaceID }
                let space = BookmarkImport.space(for: browser, bookmarks, theme: previous?.theme ?? theme, icon: previous?.icon ?? icon)
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
            let data = present.compactMap { try? Data(contentsOf: $0) }
            if !data.isEmpty {
                result.bookmarks = browser.isChromium
                    ? try? BookmarkImport.chromium(data)
                    : try? BookmarkImport.safari(data[0])
            }
        }
        if wantsHistory {
            let file = folder.appendingPathComponent(browser.historyFile)
            if access(file) == .missing {
                result.history = []
            } else {
                result.history = browser.isChromium
                    ? try? BrowserHistoryImport.chromium(from: file)
                    : try? BrowserHistoryImport.safari(from: file)
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

/// The dialog's browser menu, with Arc's line under it saying what comes across.
@MainActor
private final class BrowserPicker: NSObject {
    let view: NSView
    private let browsers: [ImportBrowser]
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let label = NSTextField(wrappingLabelWithString: "")

    init(_ browsers: [ImportBrowser]) {
        self.browsers = browsers
        let width: CGFloat = 260
        popup.addItems(withTitles: browsers.map(\.title))
        popup.setAccessibilityIdentifier("importBrowserPicker")
        popup.frame = NSRect(x: 0, y: 34, width: width, height: 26)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 2, y: 0, width: width - 2, height: 30)
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        super.init()
        view.addSubview(popup)
        view.addSubview(label)
        popup.target = self
        popup.action = #selector(changed)
        changed()
    }

    var selected: ImportBrowser { browsers[max(0, popup.indexOfSelectedItem)] }

    @objc private func changed() {
        label.stringValue = selected.importsDescription
    }
}
