import AppKit
import KiteCore
import UniformTypeIdentifiers

// Import from Arc, the Mac side of `ArcImport`.
//
// Arc shuts down on 2026-12-22. Some time after that, delete this file, the
// "Import from Arc…" item in MainMenu.swift, and KiteCore/ArcImport.swift.

extension BrowserWindowController {
    @objc func importFromArc(_ sender: Any?) {
        guard let window else { return }
        ArcImportController.start(store: store, window: window)
    }
}

@MainActor
enum ArcImportController {
    static var sidebarFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    /// Reads Arc's sidebar from its usual place, or asks for the file if Arc isn't there.
    static func start(store: BrowserStore, window: NSWindow) {
        if let data = try? Data(contentsOf: sidebarFile) {
            confirm(data, store: store, window: window)
            return
        }
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

        let reimported = result.spaces.filter { store.state.spaceIndex($0.id) != nil }.count
        var lines = [summary(result)]
        lines += result.notes
        lines.append(reimported > 0
            ? "\(count(reimported, "space")) imported before will be replaced with Arc's current version, including changes you made to them in Kite."
            : "Importing again later replaces these spaces with Arc's current version, including changes you make to them in Kite.")

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
            MainActor.assumeIsolated {
                let skipUntitled = untitledBox?.state != .on
                let spaces = result.spaces.filter { !(skipUntitled && result.untitledSpaceIDs.contains($0.id)) }
                store.mutate { $0.merge(imported: spaces, favorites: result.favorites) }
            }
        }
    }

    private static func summary(_ result: ArcImport.Result) -> String {
        // Counts leave out unnamed spaces; their checkbox gives their own.
        let untitled = result.spaces.filter { result.untitledSpaceIDs.contains($0.id) }
        var parts = [count(result.spaces.count - untitled.count, "space")]
        if !result.favorites.isEmpty { parts.append(count(result.favorites.count, "favorite")) }
        parts.append(count(result.tabCount - untitled.reduce(0) { $0 + $1.allTabs.count }, "tab"))
        if result.folderCount > 0 { parts.append(count(result.folderCount, "folder")) }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Found \(list)."
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func showError(_ message: String, detail: String, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
