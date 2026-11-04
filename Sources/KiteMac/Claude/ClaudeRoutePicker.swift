import AppKit
import KiteCore

/// The ⌘J route picker's dialogs, and its list of folders.
@MainActor
enum ClaudeRoutePicker {
    /// Recent Claude Code folders, with the current route's folder kept in the list.
    static func folders(including route: ClaudeRoute) -> [String] {
        // A test profile's fixture home, never the user's own ~/.claude.
        let home = ClaudeCodeSessions.home(environment: ProcessInfo.processInfo.environment,
                                           userHome: FileManager.default.homeDirectoryForCurrentUser)
        var folders = ClaudeCodeFolders.recent(home: home)
        if case let .folder(path) = route, !folders.contains(path) { folders.insert(path, at: 0) }
        return folders
    }

    static func chooseFolder(message: String = "Claude works in this folder, with its CLAUDE.md and memory, when you ask from this space.") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = message
        return WindowPresenter.runModal(panel) == .OK ? panel.url?.path : nil
    }

    /// Asks for a Claude Project's link and a name for it: "Add a Claude Project", in Arc's dialog sheet (`ArcDialog`) on `window`.
    static func askForProject(over window: NSWindow?, completion: @escaping (ClaudeRoute) -> Void) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return NSSound.beep() }
        ArcDialog.present(
            on: window,
            title: "Add a Claude Project",
            message: "Paste the project's link from claude.ai/code (open the project, then copy the address). "
                + "Requests from this space are posted in that project's conversation.",
            fields: [
                .init(text: "", placeholder: "https://claude.ai/code/project/chan_…"),
                .init(text: "", placeholder: "Name, e.g. Bakery"),
            ],
            actions: [.init(title: "Cancel", role: .cancel), .init(title: "Add", role: .primary)]
        ) { action, texts in
            guard action == 1 else { return }
            guard let id = ClaudeRoute.projectID(fromLink: texts[0]) else {
                ArcDialog.present(
                    on: window,
                    title: "That isn't a Claude Project link",
                    message: "A project link looks like https://claude.ai/code/project/chan_…",
                    actions: [.init(title: "OK", role: .primary)]
                ) { _, _ in }
                return
            }
            let title = texts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.project(id: id, name: title.isEmpty ? "Project" : title))
        }
    }
}
