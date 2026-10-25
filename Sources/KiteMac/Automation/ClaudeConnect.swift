import AppKit

/// "Connect Claude Code…": links the `kite` command onto the PATH and registers
/// Kite's MCP server with Claude Code, after the user says so. Claude Desktop
/// can't be configured from outside, so it gets a config snippet to paste.
@MainActor
enum ClaudeConnect {
    /// Where the `kite` link goes. `KITE_BIN_DIR` overrides it for tests.
    static var linkDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_BIN_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static func present(_ automation: AutomationController) {
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code to Kite?"
        alert.informativeText = """
            Kite will:
            • link the kite command into \(linkDirectory.path), for scripts and terminals
            • run \(automation.claudeCodeCommand)

            For Claude Desktop, Copy Desktop Config puts what to add to claude_desktop_config.json on the clipboard.
            """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Copy Desktop Config")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            connect(automation)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(desktopConfig(automation), forType: .string)
        default:
            break
        }
    }

    static func desktopConfig(_ automation: AutomationController) -> String {
        var server: [String: Any] = ["command": automation.cliPath, "args": ["mcp"]]
        if let profile = automation.profileOverride { server["env"] = ["KITE_SUPPORT_PATH": profile] }
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["kite": server]],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func connect(_ automation: AutomationController) {
        let cli = automation.cliPath
        let profile = automation.profileOverride
        let directory = linkDirectory
        Task.detached {
            let lines = [linkCommand(cli: cli, into: directory), registerWithClaudeCode(cli: cli, profile: profile)]
            await MainActor.run {
                let done = NSAlert()
                done.messageText = "Claude Code"
                done.informativeText = lines.joined(separator: "\n\n")
                done.runModal()
            }
        }
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
