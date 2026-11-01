import AppKit
import KiteCore

/// The ⌘J route picker's dialogs, and its list of folders.
@MainActor
enum ClaudeRoutePicker {
    /// Recent Claude Code folders, with the current route's folder kept in the list.
    static func folders(including route: ClaudeRoute) -> [String] {
        var folders = ClaudeCodeFolders.recent(home: FileManager.default.homeDirectoryForCurrentUser)
        if case let .folder(path) = route, !folders.contains(path) { folders.insert(path, at: 0) }
        return folders
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Claude works in this folder, with its CLAUDE.md and memory, when you ask from this space."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Asks for a Claude Project's link and a name for it.
    static func askForProject() -> ClaudeRoute? {
        let alert = NSAlert()
        alert.messageText = "Add a Claude Project"
        alert.informativeText = "Paste the project's link from claude.ai/code (open the project, then copy the address). "
            + "Requests from this space are posted in that project's conversation."
        let link = NSTextField(string: "")
        link.placeholderString = "https://claude.ai/code/project/chan_…"
        let name = NSTextField(string: "")
        name.placeholderString = "Name, e.g. Komado"
        let stack = NSStackView(views: [link, name])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        for field in [link, name] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = link
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let id = ClaudeRoute.projectID(fromLink: link.stringValue) else {
            let error = NSAlert()
            error.messageText = "That isn't a Claude Project link"
            error.informativeText = "A project link looks like https://claude.ai/code/project/chan_…"
            error.runModal()
            return nil
        }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .project(id: id, name: title.isEmpty ? "Project" : title)
    }
}
