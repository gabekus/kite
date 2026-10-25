import AppKit
import KiteCore

/// One click on the sidebar's Claude button sets Claude up: Kite's tools on, Claude Code
/// installed (Anthropic's installer, after asking) and signed in, and Kite's MCP server
/// added to Claude Code so it can use Kite from a terminal too.
extension ClaudeTasksController {
    /// Returns true once everything is ready. Anything the user has to do (install, sign in)
    /// is asked for here; until it's done the button keeps its yellow dot.
    func setUp() async -> Bool {
        guard !isSettingUp else { return false }
        isSettingUp = true
        defer { isSettingUp = false }

        if !automation.isEnabled { automation.setEnabled(true) }
        guard automation.isEnabled else { return false }

        var claude = await Task.detached { ClaudeConnect.findClaude() }.value
        if claude == nil {
            guard ask("Set up Claude in Kite",
                      "Kite runs Claude with Claude Code, on your own Claude plan. Claude Code isn't installed yet.\n\n"
                      + "Install it now? Kite runs Anthropic's installer:\n\(Self.installCommand)",
                      confirm: "Install Claude Code") else { return false }
            let (_, output) = await Task.detached { ClaudeConnect.run("/bin/zsh", ["-lc", Self.installCommand]) }.value
            claude = await Task.detached { ClaudeConnect.findClaude() }.value
            guard claude != nil else {
                tell("Claude Code didn't install", String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)))
                return false
            }
        }
        guard let claude else { return false }

        let signedIn = await Task.detached { Self.isSignedIn(claude) }.value
        if !signedIn {
            if ask("Sign in to Claude",
                   "Claude Code needs you to sign in once with your Claude account. Kite will open Terminal to do it; "
                   + "come back and click the Claude button when you're done.",
                   confirm: "Sign In…") {
                openSignIn(claude)
            }
            return false
        }

        let cli = automation.cliPath, profile = automation.profileOverride, directory = ClaudeConnect.linkDirectory
        _ = await Task.detached { ClaudeConnect.register(cli: cli, profile: profile, linkDirectory: directory) }.value
        markSetUp(true)
        return true
    }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// `claude auth status` prints JSON with `loggedIn`. An older Claude Code without it counts as signed in.
    nonisolated static func isSignedIn(_ claude: String) -> Bool {
        let (status, output) = ClaudeConnect.run(claude, ["auth", "status"])
        guard status == 0, let start = output.firstIndex(of: "{"),
              let json = try? JSONValue.decode(Data(output[start...].utf8)) else { return status == 0 }
        return json["loggedIn"]?.boolValue ?? true
    }

    /// `claude auth login` needs a terminal (it opens the browser and waits).
    private func openSignIn(_ claude: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Kite Claude Sign In.command")
        let body = "#!/bin/zsh -l\n\(AutomationController.shellQuote(claude)) auth login\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            tell("Couldn't open Terminal", "Run this in a terminal, then click the Claude button again:\n\(claude) auth login")
        }
    }

    private func ask(_ title: String, _ text: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
