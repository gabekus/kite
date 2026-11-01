import AppKit
import KiteCore
import UniformTypeIdentifiers

/// Settings › Advanced › "Export Data" (g96): every space and its tabs as Markdown, saved where
/// the save panel says, as Arc does (`DataExport`).
extension AppDelegate {
    /// Arc's save panel: a sheet on the settings window, Markdown (`md`, else plain text) only,
    /// named "… Data Export.md", with New Folder. A failed write shows the error.
    func exportData(from window: NSWindow?) {
        guard let store = browserStore else { return }
        let markdown = DataExport.markdown(spaces: store.state.spaces)
        // Test builds (KITE_SUPPORT_PATH) can skip the panel, which would bring Kite forward.
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let path = environment["KITE_TEST_EXPORT_DATA_PATH"], !path.isEmpty {
            try? Data(markdown.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = DataExport.fileName
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(markdown.utf8).write(to: url)
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }
}
