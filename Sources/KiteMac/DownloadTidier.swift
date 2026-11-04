import AppKit
import Darwin
import KiteCore

/// Arc Max's Tidy Downloads: when a download finishes, Kite's own Claude (headless `claude -p`
/// on the fast model) suggests a readable name, the file is renamed next to where it is, and
/// the front window shows Arc's "Download renamed!" toast with Undo.
///
/// A rename never replaces another file (a taken name gets " 2", and the move itself refuses to
/// overwrite) and always keeps the original extension. Without Claude Code, or on any error,
/// the file keeps its name.
@MainActor
final class DownloadTidier {
    static let shared = DownloadTidier()

    /// Longest Kite waits for a name before leaving the file as it is.
    private let timeout: TimeInterval = 30
    /// The renames Undo can put back, by download.
    private var originals: [UUID: (original: String, renamed: String)] = [:]

    func tidy(_ item: DownloadItem, sourceTitle: String?) {
        // An incognito download's name and tab title never go to Claude.
        guard !item.isIncognito, TidyDownloads.isEnabled(), !item.path.isEmpty,
              FileManager.default.fileExists(atPath: item.path) else { return }
        let fileName = (item.path as NSString).lastPathComponent
        let prompt = TidyDownloads.prompt(fileName: fileName, tabTitle: sourceTitle, domain: item.sourceHost,
                                          language: TidyDownloads.languageName())
        let timeout = timeout
        let check = Jev.fileNameCheck(fileName: fileName, tabTitle: sourceTitle)
        Task.detached(priority: .utility) { [weak self] in
            // A name that already says what the file is stays, without a Claude run.
            if let jev = JevClient.shared, await Jev.skipsTidy(check, ask: jev.ask) { return }
            guard let output = await Self.askClaude(prompt, timeout: timeout),
                  let proposed = TidyDownloads.name(fromClaudeOutput: output),
                  let name = TidyDownloads.tidiedName(proposed, original: fileName) else { return }
            await self?.rename(item.id, from: item.path, to: name)
        }
    }

    // MARK: Renaming

    private func rename(_ id: UUID, from path: String, to name: String) {
        // The user may have moved, renamed or trashed it while Claude thought.
        guard DownloadsModel.shared.list.items.first(where: { $0.id == id })?.path == path,
              let destination = Self.move(path, toName: name) else { return }
        originals[id] = (path, destination)
        DownloadsModel.shared.moved(id, to: destination)
        Self.frontBrowser?.showToast(TidyDownloads.renamedMessage, undo: { [weak self] in
            MainActor.assumeIsolated { self?.undo(id) }
        })
    }

    /// Arc's toast Undo: the file gets its old name back (or the nearest free one).
    func undo(_ id: UUID) {
        guard let (original, renamed) = originals.removeValue(forKey: id),
              DownloadsModel.shared.list.items.first(where: { $0.id == id })?.path == renamed,
              let destination = Self.move(renamed, toName: (original as NSString).lastPathComponent) else { return }
        DownloadsModel.shared.moved(id, to: destination)
        Self.frontBrowser?.showToast(TidyDownloads.revertedMessage)
    }

    /// Renames the file in its own folder to `name`, or the first free "name 2"…, and returns the
    /// new path. The rename is atomic and fails rather than replace anything already there.
    private static func move(_ path: String, toName name: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        let current = (path as NSString).lastPathComponent
        let fileManager = FileManager.default
        let free = TidyDownloads.available(name) { candidate in
            // On a case-insensitive disk the file itself would count as "taken" by a case-only change.
            candidate != current && fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate))
                && !sameFile((directory as NSString).appendingPathComponent(candidate), path)
        }
        let destination = (directory as NSString).appendingPathComponent(free)
        let caseOnly = sameFile(destination, path)
        // RENAME_EXCL: never overwrite. A case-only change of the same file can't use it.
        let result = caseOnly ? Darwin.rename(path, destination) : renamex_np(path, destination, UInt32(RENAME_EXCL))
        guard result == 0 else {
            NSLog("Kite: Tidy Downloads couldn't rename \(current): \(String(cString: strerror(errno)))")
            return nil
        }
        return destination
    }

    private static func sameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    static var frontBrowser: BrowserWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
    }

    // MARK: Claude

    /// One `claude -p` run with no tools or MCP servers, in an empty folder. Nil on any failure.
    nonisolated private static func askClaude(_ prompt: String, timeout: TimeInterval) async -> String? {
        guard let claude = ClaudeConnect.findClaude() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KiteTidyDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Its own process group, ended whole at the timeout: a child left holding stdout can't hang the read.
        let process = OneShotProcess(executable: claude, arguments: TidyDownloads.arguments(),
                                     environment: environment, directory: directory)
        guard let result = await process.run(input: Data(prompt.utf8), timeout: timeout), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// GUI apps get a bare PATH and Claude Code may be a Node script: the login shell's PATH, once.
    nonisolated private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let (status, output) = ClaudeConnect.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, path.contains("/") { environment["PATH"] = path }
        // Kite's own test switches mustn't leak into Claude Code.
        environment["KITE_DIAGNOSTICS"] = nil
        environment["KITE_SUPPORT_PATH"] = nil
        environment["KITE_TEST_DOWNLOADS_PATH"] = nil
        return environment
    }()
}
