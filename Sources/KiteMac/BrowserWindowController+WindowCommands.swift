import AppKit
import KiteCore
import UniformTypeIdentifiers

/// Arc's smaller File, View, Window and Help commands: Share, Save Page As,
/// Clear Cookies/Cache and Refresh, Stay On Top, default browser, troubleshooting.
extension BrowserWindowController {
    @objc func share(_ sender: Any?) {
        guard let url = store.state.selectedTab?.url, let root = window?.contentView else { return NSSound.beep() }
        // Anchor near the top of the sidebar, where Arc's address pill sits.
        let anchor = NSRect(x: 20, y: root.bounds.height - 60, width: 160, height: 24)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: root, preferredEdge: .maxY)
    }

    @objc func savePageAs(_ sender: Any?) {
        guard let window, let page = shownPage, let tab = store.state.selectedTab else { return NSSound.beep() }
        page.archive { data, fileExtension in
            guard let data else { return NSSound.beep() }
            let panel = NSSavePanel()
            let name = tab.title.isEmpty ? (tab.url?.host() ?? "Page") : tab.title
            panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + "." + fileExtension
            if let type = UTType(filenameExtension: fileExtension) { panel.allowedContentTypes = [type] }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
            }
        }
    }

    @objc func clearCookiesAndRefresh(_ sender: Any?) { clearSiteData(.cookies) }
    @objc func clearCacheAndRefresh(_ sender: Any?) { clearSiteData(.cache) }

    private func clearSiteData(_ kind: SiteDataKind) {
        guard let page = shownPage, let url = store.state.selectedTab?.url else { return NSSound.beep() }
        page.clearSiteData(kind, for: url) { [weak self, weak page] in
            page?.reloadIgnoringCache()
            self?.showToast(kind == .cookies ? "Cleared cookies" : "Cleared cache")
        }
    }

    @objc func toggleStayOnTop(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            // macOS asks the user to confirm the change.
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        }
    }

    static var isDefaultBrowser: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            return false
        }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    @objc func revealDataFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.supportDirectory])
    }

    /// Version, engine and macOS, for bug reports.
    @objc func copyKiteInfo(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        let text = """
            Kite \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
            Engine: \(pool.engine.name)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied Kite info")
    }

    /// Window › View Downloads… (⇧⌘J, as in Arc): the downloads list from the sidebar's bottom bar.
    @objc func viewDownloads(_ sender: Any?) {
        guard store.isSidebarVisible || downloadsButton.isListShown else {
            // The list hangs from the sidebar's button: bring the sidebar back first.
            store.toggleSidebar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.downloadsButton.toggle() }
            return
        }
        downloadsButton.toggle()
    }

    /// History › View History (⌘Y; Arc's Archive › View History): "Opens your History in a new
    /// Today tab", as Arc's shortcut list puts it.
    @objc func viewHistory(_ sender: Any?) {
        let page = InternalPage.history
        store.mutate { state in
            let id = state.openTab(url: page.url)
            state.update(tab: id) { $0.title = page.title }
        }
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        EssentialShortcutsWindow.show(menu: NSApp.mainMenu, overrides: (NSApp.delegate as? AppDelegate)?.keyBindings.bindings)
    }
}
