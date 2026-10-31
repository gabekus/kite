import AppKit
import KiteCore

/// "Connect Claude…": links the `kite` command onto the PATH, registers Kite's MCP
/// server with Claude Code, and adds it to the Claude desktop app's
/// claude_desktop_config.json, after the user says so.
@MainActor
enum ClaudeConnect {
    /// Where the `kite` link goes. `KITE_BIN_DIR` overrides it for tests.
    static var linkDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_BIN_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
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
            Cowork and Code sessions can use your browser. Kite quits and reopens Claude to load it.
            """ : "")
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Copy Desktop Config")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
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
                if linked == .added, ClaudeDesktop.isRunning { ClaudeDesktop.relaunch() }
                let done = NSAlert()
                done.messageText = "Claude"
                done.informativeText = lines.joined(separator: "\n\n")
                done.runModal()
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
        guard let claude = findClaude() else {
            return "Couldn't find the claude command. Install Claude Code, then run:\nclaude mcp add -s user kite -- \(cli) mcp"
        }
        var add = ["mcp", "add", "-s", "user", "kite"]
        if let profile { add += ["-e", "KITE_SUPPORT_PATH=\(profile)"] }
        add += ["--", cli, "mcp"]
        var (status, output) = run(claude, add)
        if status != 0, output.contains("already exists") {
            _ = run(claude, ["mcp", "remove", "-s", "user", "kite"])
            (status, output) = run(claude, add)
        }
        return status == 0
            ? "Added Kite to Claude Code (user scope). Start a new Claude Code session to use it."
            : "claude mcp add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// GUI apps don't get the shell's PATH, so look where Claude Code installs, then ask a login shell.
    nonisolated static func findClaude() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["KITE_CLAUDE_BIN"] { return override }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let (status, output) = run("/bin/zsh", ["-lc", "command -v claude"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && path.hasPrefix("/") ? path : nil
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
