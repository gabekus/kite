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
            let lines = await register(cli: cli, profile: profile, linkDirectory: directory) + (linked.map { [$0.line] } ?? [])
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
    nonisolated static func register(cli: String, profile: String?, linkDirectory directory: URL) async -> [String] {
        [linkCommand(cli: cli, into: directory), await registerWithClaudeCode(cli: cli, profile: profile)]
    }

    nonisolated private static func linkCommand(cli: String, into directory: URL) -> String {
        let link = directory.appendingPathComponent("kite")
        if let reason = ClaudeSetupGuard.refusal(.commandLink, cli: cli, environment: ProcessInfo.processInfo.environment) {
            return "Left \(link.path) alone: \(reason)."
        }
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

    nonisolated private static func registerWithClaudeCode(cli: String, profile: String?) async -> String {
        if let reason = ClaudeSetupGuard.refusal(.claudeCode, cli: cli, environment: ProcessInfo.processInfo.environment) {
            return "Left Claude Code's kite server alone: \(reason)."
        }
        guard let claude = await ClaudeCommand.find() else {
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

    /// The login shell's PATH and `claude` (`LoginShellCache`). AppDelegate warms it at launch.
    nonisolated static let loginShell = LoginShellCache()

    /// GUI apps don't get the shell's PATH, so look where Claude Code installs, then ask the login shell.
    /// Only `ClaudeCommand.lookUp` calls it, so the executable never goes out without its environment.
    nonisolated fileprivate static func findClaude(_ shell: LoginShellCache.Snapshot) -> String? {
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
        return shell.answers.claude
    }

    /// The environment for `executable` (`ClaudeProcessEnvironment`), built for each run so it follows
    /// the test-profile state: GUI apps get a bare PATH and Claude Code may be a Node script, so it has
    /// the login shell's PATH, or, when the shell gave none, Kite's with `claude`'s own folder and the
    /// usual install folders in front. On a test profile HOME and CLAUDE_CONFIG_DIR are the test
    /// Claude home, never the user's own `~/.claude`.
    nonisolated fileprivate static func environment(for executable: String, _ shell: LoginShellCache.Snapshot) -> [String: String] {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let folder = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return ClaudeProcessEnvironment.make(ProcessInfo.processInfo.environment, loginPath: shell.answers.path, userHome: userHome,
                                             fallbackDirectories: [folder] + ClaudeProcessEnvironment.fallbackDirectories(userHome: userHome))
    }

    /// Runs `script` in a login shell to the end (the Claude Code installer): its status and output.
    nonisolated static func runLoginShell(_ script: String) -> (Int32, String) {
        run("/bin/zsh", ["-lc", script])
    }

    /// Runs `executable` to the end. `environment` replaces Kite's own (nil inherits it).
    nonisolated fileprivate static func run(_ executable: String, _ arguments: [String],
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

/// Claude Code and the environment to run it in (`ClaudeConnect.environment`). It can't be built
/// outside this file, and its executable and environment can't be read apart, so no run of `claude`
/// can miss a test profile's Claude home.
struct ClaudeCommand: Sendable {
    private let executable: String
    private let environment: [String: String]

    private init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    enum Lookup: Sendable {
        case found(ClaudeCommand)
        /// Not installed.
        case missing
        /// The login shell ran past its timeout, so Kite couldn't look everywhere.
        case unknown
    }

    /// Where Claude Code is. Awaits the login shell's answers the first time (`LoginShellCache`).
    static func lookUp() async -> Lookup {
        let shell = await ClaudeConnect.loginShell.snapshot()
        guard let executable = ClaudeConnect.findClaude(shell) else { return shell.timedOut ? .unknown : .missing }
        return .found(ClaudeCommand(executable: executable, environment: ClaudeConnect.environment(for: executable, shell)))
    }

    /// Nil when Claude Code isn't installed, or couldn't be looked for.
    static func find() async -> ClaudeCommand? {
        if case .found(let command) = await lookUp() { return command }
        return nil
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
    /// It blocks, so never on the main thread.
    func run(_ arguments: [String]) -> (Int32, String) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return ClaudeConnect.run(executable, arguments, environment: environment)
    }

    /// `claude auth login` as shell lines: on a test profile it first exports the test Claude home.
    var signInCommand: String {
        ClaudeProcessEnvironment.exports(environment, kite: ProcessInfo.processInfo.environment)
            + "\(Shell.quote(executable)) auth login\n"
    }

    /// A Terminal script (`.command`) that signs in to Claude Code.
    func signInScript() -> String {
        "#!/bin/zsh -l\n" + signInCommand
    }
}
