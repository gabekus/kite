import Foundation
import KiteCore

/// Arc Max's Tidy Tab Titles: when a tab is pinned, Kite's built-in Claude (`claude -p`, no
/// tools) picks a short name for it, set as the tab's custom name. Renaming the tab first wins,
/// as in Arc ("User renamed the tab before the automatic tab name could be generated").
@MainActor
final class TidyTabTitlesController {
    static let shared = TidyTabTitlesController()

    /// Tabs waiting on Claude, so pinning, unpinning and pinning again asks once.
    private var pending: Set<UUID> = []
    /// A reply that takes longer than this is dropped.
    nonisolated private static let timeout: TimeInterval = 45

    func tabsPinned(_ tabs: [BrowserTab], in store: BrowserStore) {
        guard TidyTabTitles.isEnabled() else { return }
        for tab in tabs where !pending.contains(tab.id) {
            pending.insert(tab.id)
            let prompt = TidyTabTitles.prompt(title: tab.title, url: tab.url, language: TidyTabTitles.language())
            let id = tab.id
            Task { [weak self, weak store] in
                let name = await Task.detached { Self.ask(prompt) }.value
                self?.finish(id, name: name, store: store)
            }
        }
    }

    private func finish(_ id: UUID, name: String?, store: BrowserStore?) {
        pending.remove(id)
        guard let name, let store, TidyTabTitles.isEnabled(),
              let location = store.state.location(of: id), location.section == .pinned,
              let tab = store.state.tab(id), tab.customTitle == nil
        else { return }
        let oldTitle = tab.displayTitle
        store.mutate { $0.renameTab(id, to: name) }
        // Arc wipes the old title out and the new one in, with sparks, as the name lands.
        if let renamed = store.state.tab(id), renamed.displayTitle != oldTitle {
            store.animateAIRename(id, from: oldTitle)
        }
    }

    /// A test build's stand-in reply (`KITE_TEST_TIDY_TITLE`, only with a test profile), so the
    /// rename and its animation can be checked without asking Claude.
    nonisolated private static func testReply() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KITE_SUPPORT_PATH"] != nil, let name = environment["KITE_TEST_TIDY_TITLE"], !name.isEmpty
        else { return nil }
        return name
    }

    /// Runs Claude Code once and reads the name from its reply. Nil if it isn't set up, fails or
    /// takes too long.
    nonisolated private static func ask(_ prompt: String) -> String? {
        if let stub = testReply() {
            Thread.sleep(forTimeInterval: 1)
            return stub
        }
        guard let claude = ClaudeConnect.findClaude() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = TidyTabTitles.arguments()
        process.environment = ClaudeTasksController.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let handle = input.fileHandleForWriting
        try? handle.write(contentsOf: Data(prompt.utf8))
        try? handle.close()
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return TidyTabTitles.title(fromReply: String(decoding: data, as: UTF8.self))
    }
}
