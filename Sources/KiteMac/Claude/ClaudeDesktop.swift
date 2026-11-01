import AppKit
import KiteCore

/// The Mac side of `ClaudeDesktopLink`: puts Kite's tools into the Claude desktop app,
/// hands ⌘J requests to it, and opens headless tasks there.
@MainActor
enum ClaudeDesktop {
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier)
    }

    static var isInstalled: Bool { appURL != nil }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier).isEmpty
    }

    /// `KITE_CLAUDE_DESKTOP_CONFIG` points tests at a scratch file instead of the real one.
    nonisolated static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_CLAUDE_DESKTOP_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        return ClaudeDesktopLink.configURL(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    nonisolated static var isLinked: Bool {
        ClaudeDesktopLink.isLinked(try? Data(contentsOf: configURL))
    }

    /// Adds Kite's server to `claude_desktop_config.json`, keeping everything else in it.
    /// The file as it was is kept next to it as `claude_desktop_config.json.kite-backup`.
    nonisolated static func link(cli: String, profile: String?) -> ClaudeDesktopLinkResult {
        let url = configURL
        let files = FileManager.default
        let existing = try? Data(contentsOf: url)
        do {
            guard let data = try ClaudeDesktopLink.merged(existing, server: ClaudeDesktopLink.server(kiteCLI: cli, profile: profile)) else {
                return .alreadyLinked
            }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing {
                let backup = url.appendingPathExtension("kite-backup")
                try? files.removeItem(at: backup)
                try existing.write(to: backup)
            }
            try data.write(to: url, options: .atomic)
            return .added
        } catch let error as ClaudeDesktopLink.ConfigError {
            return .failed(error.description)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Quits and reopens Desktop so it loads a changed config. Only after the user agrees:
    /// quitting ends whatever Desktop is doing.
    static func relaunch() {
        guard let appURL else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier)
        guard !running.isEmpty else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return
        }
        running.forEach { $0.terminate() }
        Task { @MainActor in
            var waited = 0
            while waited < 50, running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    /// A new Desktop chat with `prompt` ready to send. Returns false when Desktop isn't installed.
    @discardableResult
    static func openChat(prompt: String) -> Bool {
        guard isInstalled else { return false }
        return NSWorkspace.shared.open(ClaudeDesktopLink.chatURL(prompt: prompt))
    }

    /// Opens a Claude Code session in Desktop's Code tab. Returns what went wrong, or nil.
    nonisolated static func openSession(_ sessionID: String) -> String? {
        guard let claude = ClaudeConnect.findClaude() else { return "Couldn't find Claude Code." }
        let (status, output) = ClaudeConnect.run(claude, ClaudeDesktopLink.resumeInDesktopArguments(sessionID: sessionID))
        guard status != 0 else { return nil }
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "claude --desktop exited with status \(status)." : String(message.suffix(400))
    }
}

/// What adding Kite to Desktop's config did.
enum ClaudeDesktopLinkResult: Equatable, Sendable {
    case added, alreadyLinked
    case failed(String)

    var line: String {
        switch self {
        case .added: "Added Kite to the Claude desktop app. Quit and reopen Claude to load it."
        case .alreadyLinked: "The Claude desktop app already has Kite."
        case let .failed(reason): "Couldn't add Kite to the Claude desktop app: \(reason)"
        }
    }
}
