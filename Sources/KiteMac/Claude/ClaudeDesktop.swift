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

    /// False on a test profile: it never hands requests to, opens or relaunches the user's own Claude app.
    nonisolated static var mayDrive: Bool { !ClaudeProcessEnvironment.isTestProfile(ProcessInfo.processInfo.environment) }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier).isEmpty
    }

    /// `KITE_CLAUDE_DESKTOP_CONFIG` points tests at a scratch file instead of the real one.
    nonisolated static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_CLAUDE_DESKTOP_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        // A test profile's is in its test Claude home, never the user's own.
        return ClaudeDesktopLink.configURL(home: ClaudeCodeSessions.home(environment: ProcessInfo.processInfo.environment,
                                                                         userHome: FileManager.default.homeDirectoryForCurrentUser))
    }

    nonisolated static var isLinked: Bool {
        ClaudeDesktopLink.isLinked(try? Data(contentsOf: configURL))
    }

    /// Adds Kite's server to `claude_desktop_config.json`, keeping everything else in it.
    /// The file as it was is kept next to it as `claude_desktop_config.json.kite-backup`.
    nonisolated static func link(cli: String, profile: String?) -> ClaudeDesktopLinkResult {
        if let reason = ClaudeSetupGuard.refusal(.desktop, cli: cli, environment: ProcessInfo.processInfo.environment) {
            return .skipped(reason)
        }
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
        guard mayDrive, let appURL else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier)
        guard !running.isEmpty else {
            WindowPresenter.openApplication(at: appURL)
            return
        }
        running.forEach { $0.terminate() }
        Task { @MainActor in
            var waited = 0
            while waited < 50, running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            WindowPresenter.openApplication(at: appURL)
        }
    }

    /// A new Desktop chat with `prompt` ready to send. Returns false when Desktop isn't installed.
    @discardableResult
    static func openChat(prompt: String) -> Bool {
        guard mayDrive, isInstalled else { return false }
        return WindowPresenter.open(ClaudeDesktopLink.chatURL(prompt: prompt))
    }

    /// Opens a Claude Code session in Desktop's Code tab. Returns what went wrong, or nil.
    static func openSession(_ sessionID: String) -> String? {
        guard mayDrive else { return "A test profile doesn't open the Claude app." }
        guard let appURL else { return "The Claude app isn't installed. Get it at claude.ai/download." }
        let version = Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard ClaudeDesktopLink.supportsResume(version: version) else {
            return "Claude \(version ?? "") is too old to open Claude Code sessions. Update it to \(ClaudeDesktopLink.minimumResumeVersion) or later."
        }
        guard let url = ClaudeDesktopLink.resumeURL(sessionID: sessionID) else {
            return "This task's session id (\(sessionID)) isn't one Claude can open."
        }
        return WindowPresenter.open(url) ? nil : "macOS couldn't open the Claude app."
    }
}

/// What adding Kite to Desktop's config did.
enum ClaudeDesktopLinkResult: Equatable, Sendable {
    case added, alreadyLinked
    case failed(String)
    /// A test build, which leaves the real config alone (`ClaudeSetupGuard`).
    case skipped(String)

    var line: String {
        switch self {
        case .added: "Added Kite to the Claude desktop app. Quit and reopen Claude to load it."
        case .alreadyLinked: "The Claude desktop app already has Kite."
        case let .failed(reason): "Couldn't add Kite to the Claude desktop app: \(reason)"
        case let .skipped(reason): "Left the Claude desktop app alone: \(reason)."
        }
    }
}
