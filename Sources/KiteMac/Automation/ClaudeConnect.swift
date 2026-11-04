import AppKit
import KiteCore

/// "Connect Claude…": links the `kite` command onto the PATH, registers Kite's MCP
/// server with Claude Code, and adds it to the Claude desktop app's
/// claude_desktop_config.json, after the user says so.
@MainActor
enum ClaudeConnect {
    /// Where the `kite` link goes. `KITE_BIN_DIR` overrides it for tests; a test profile without it
    /// links into its test Claude home, never the user's own ~/.local/bin.
    static var linkDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["KITE_BIN_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return ClaudeCodeSessions.home(environment: environment, userHome: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static func present(_ automation: AutomationController) {
        let desktop = ClaudeDesktop.isInstalled
        let alert = NSAlert()
        alert.messageText = desktop ? "Connect Claude Code and the Claude app to Kite?" : "Connect Claude Code to Kite?"
        alert.informativeText = """
            Kite will:
            • link the kite command into \(linkDirectory.path), for scripts and terminals
            • run \(automation.claudeCodeCommand)
            """ + (desktop ? """

            • add Kite to the Claude desktop app (claude_desktop_config.json, with a backup), so its chats, \
            Cowork and Code sessions can use your browser.
            """ + (ClaudeDesktop.mayDrive ? " Kite quits and reopens Claude to load it." : "") : "")
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Copy Desktop Config")
        alert.addButton(withTitle: "Cancel")
        switch WindowPresenter.runModal(alert) {
        case .alertFirstButtonReturn:
            connect(automation, desktop: desktop)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(desktopConfig(automation), forType: .string)
        default:
            break
        }
    }

    static func desktopConfig(_ automation: AutomationController) -> String {
        let server = ClaudeDesktopLink.server(kiteCLI: automation.cliPath, profile: automation.profileOverride)
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": [ClaudeDesktopLink.serverName: server]],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func connect(_ automation: AutomationController, desktop: Bool) {
        let cli = automation.cliPath
        let profile = automation.profileOverride
        let directory = linkDirectory
        Task.detached {
            let linked = desktop ? ClaudeDesktop.link(cli: cli, profile: profile) : nil
            let lines = register(cli: cli, profile: profile, linkDirectory: directory) + (linked.map { [$0.line] } ?? [])
            await MainActor.run {
                // The user asked for this, so reload Desktop now rather than leave it without Kite.
                if linked == .added, ClaudeDesktop.mayDrive, ClaudeDesktop.isRunning { ClaudeDesktop.relaunch() }
                let done = NSAlert()
                done.messageText = "Claude"
                done.informativeText = lines.joined(separator: "\n\n")
                _ = WindowPresenter.runModal(done)
            }
        }
    }

    /// Links `kite` and adds Kite's MCP server to Claude Code. Returns what happened, a line per step.
    nonisolated static func register(cli: String, profile: String?, linkDirectory directory: URL) -> [String] {
        [linkCommand(cli: cli, into: directory), registerWithClaudeCode(cli: cli, profile: profile)]
    }

    nonisolated private static func linkCommand(cli: String, into directory: URL) -> String {
        let link = directory.appendingPathComponent("kite")
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            if let existing = try? files.destinationOfSymbolicLink(atPath: link.path) {
                if existing == cli { return "kite is already linked at \(link.path)." }
                try files.removeItem(at: link)
            } else if files.fileExists(atPath: link.path) {
                return "\(link.path) already exists and isn't Kite's link, so it was left alone."
            }
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: cli)
            return "Linked kite at \(link.path)."
        } catch {
            return "Couldn't link kite at \(link.path): \(error.localizedDescription)"
        }
    }

    nonisolated private static func registerWithClaudeCode(cli: String, profile: String?) -> String {
        guard let claude = ClaudeCommand.find() else {
            return "Couldn't find the claude command. Install Claude Code, then run:\nclaude mcp add -s user kite -- \(cli) mcp"
        }
        var add = ["mcp", "add", "-s", "user", "kite"]
        if let profile { add += ["-e", "KITE_SUPPORT_PATH=\(profile)"] }
        add += ["--", cli, "mcp"]
        var (status, output) = claude.run(add)
        if status != 0, output.contains("already exists") {
            _ = claude.run(["mcp", "remove", "-s", "user", "kite"])
            (status, output) = claude.run(add)
        }
        return status == 0
            ? "Added Kite to Claude Code (user scope). Start a new Claude Code session to use it."
            : "claude mcp add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Whether this is a test profile (`ClaudeProcessEnvironment.isTestProfile`).
    nonisolated static var isTestProfile: Bool { ClaudeProcessEnvironment.isTestProfile(ProcessInfo.processInfo.environment) }

    /// GUI apps don't get the shell's PATH, so look where Claude Code installs, then ask a login shell.
    /// Only `ClaudeCommand.find` calls it, so the executable never goes out without its environment.
    nonisolated fileprivate static func findClaude() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["KITE_CLAUDE_BIN"] { return override }
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let home = userHome.path
        // ~/.claude is the test Claude home on a test profile (`ClaudeCodeSessions.home`).
        let claudeHome = ClaudeCodeSessions.home(environment: environment, userHome: userHome).path
        for candidate in ["\(home)/.local/bin/claude", "\(claudeHome)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let path = loginShell("command -v claude")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// The environment of every `claude` Kite starts (`ClaudeProcessEnvironment`): GUI apps get a bare
    /// PATH and Claude Code may be a Node script, so it has the login shell's. Worked out once per
    /// test-profile state, on the first caller's thread, which is never the main one. On a test
    /// profile HOME and CLAUDE_CONFIG_DIR are the test Claude home, never the user's own `~/.claude`.
    nonisolated fileprivate static func environment() -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        return environments.environment(for: .init(environment: base, userHome: userHome)) {
            ClaudeProcessEnvironment.make(base, loginPath: loginShell("printf %s \"$PATH\""), userHome: userHome)
        }
    }

    nonisolated private static let environments = ClaudeProcessEnvironment.Cache()

    /// How long a login shell may take: a `.zshrc` that hangs mustn't hold up every `claude`.
    nonisolated static let loginShellTimeout: TimeInterval = 10

    /// What a login `zsh -lc script` prints, or nil when it failed or ran past the timeout.
    nonisolated private static func loginShell(_ script: String) -> String? {
        let shell = OneShotProcess(executable: "/bin/zsh", arguments: ["-lc", script])
        guard let result = shell.run(input: Data(), timeout: loginShellTimeout), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// Runs `executable` to the end. `environment` replaces Kite's own (nil inherits it).
    nonisolated static func run(_ executable: String, _ arguments: [String],
                                environment: [String: String]? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Claude Code and the environment to run it in (`ClaudeConnect.environment`). The only way Kite
/// gets the `claude` executable, so no run of it can miss a test profile's Claude home.
struct ClaudeCommand: Sendable {
    let executable: String
    let environment: [String: String]

    /// Nil when Claude Code isn't installed. May run a login shell: never on the main thread.
    nonisolated static func find() -> ClaudeCommand? {
        guard let executable = ClaudeConnect.findClaude() else { return nil }
        return ClaudeCommand(executable: executable, environment: ClaudeConnect.environment())
    }

    /// The same command without `keys` in its environment (a feature's own test switches).
    func removing(_ keys: [String]) -> ClaudeCommand {
        var environment = environment
        for key in keys { environment[key] = nil }
        return ClaudeCommand(executable: executable, environment: environment)
    }

    /// A process for `arguments` in `directory`, not started yet.
    func process(arguments: [String], directory: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        return process
    }

    /// A one-shot run (`OneShotProcess`) of `arguments` in `directory`.
    func oneShot(arguments: [String], directory: URL) -> OneShotProcess {
        OneShotProcess(executable: executable, arguments: arguments, environment: environment, directory: directory)
    }

    /// A quick call (`claude auth status`, `claude mcp add`) run to the end: its status and output.
    func run(_ arguments: [String]) -> (Int32, String) {
        ClaudeConnect.run(executable, arguments, environment: environment)
    }
}
