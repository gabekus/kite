import AppKit
import KiteCore

/// One click on the sidebar's Claude button sets Claude up: Kite's tools on, Claude Code
/// installed (Anthropic's installer, after asking) and signed in, and Kite's MCP server
/// added to Claude Code and the Claude desktop app so both can use Kite too.
extension ClaudeTasksController {
    /// Returns true once everything is ready. Anything the user has to do (install, sign in)
    /// is asked for here; until it's done the button keeps its yellow dot.
    func setUp() async -> Bool {
        guard !isSettingUp else { return false }
        isSettingUp = true
        defer { isSettingUp = false }

        if !automation.isEnabled { automation.setEnabled(true) }
        guard automation.isEnabled else { return false }

        var lookup = await ClaudeCommand.lookUp()
        if case .unknown = lookup {
            tell("Couldn't look for Claude Code",
                 "Your login shell took more than \(Int(LoginShellProbe.timeout)) seconds to start, so Kite couldn't check whether "
                 + "Claude Code is installed. Click the Claude button to try again.")
            return false
        }
        if case .missing = lookup {
            // The installer writes to the real home (~/.local, the shell's PATH): never from a test profile.
            guard !ClaudeProcessEnvironment.isTestProfile(ProcessInfo.processInfo.environment) else {
                tell("Claude Code isn't installed", "A test profile doesn't install Claude Code. Set KITE_CLAUDE_BIN to a claude to run.")
                return false
            }
            guard ask("Set up Claude in Kite",
                      "Kite runs Claude with Claude Code, on your own Claude plan. Claude Code isn't installed yet.\n\n"
                      + "Install it now? Kite runs Anthropic's installer:\n\(Self.installCommand)",
                      confirm: "Install Claude Code") else { return false }
            let (_, output) = await Task.detached { ClaudeConnect.runLoginShell(Self.installCommand) }.value
            // The install changed where claude is and maybe the shell's PATH: ask the shell again.
            ClaudeConnect.loginShell.invalidate()
            lookup = await ClaudeCommand.lookUp()
            guard case .found = lookup else {
                tell("Claude Code didn't install", String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)))
                return false
            }
        }
        guard case .found(let claude) = lookup else { return false }

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
        let desktop = ClaudeDesktop.isInstalled
        let linked = await Task.detached { () -> ClaudeDesktopLinkResult? in
            _ = await ClaudeConnect.register(cli: cli, profile: profile, linkDirectory: directory)
            // The Claude app gets Kite's tools too, so ⌘J can hand requests to it.
            return desktop ? ClaudeDesktop.link(cli: cli, profile: profile) : nil
        }.value
        // A test profile linked its own test config: the user's Claude app has nothing new to load.
        if linked == .added, ClaudeDesktop.mayDrive, ClaudeDesktop.isRunning {
            // Quitting Claude would cut off whatever it's doing, so ask.
            if ask("Reopen the Claude app?",
                   "Kite added its tools to the Claude desktop app, so ⌘J can hand requests to it and its chats can use "
                   + "your browser. Claude loads them when it next opens.",
                   confirm: "Reopen Claude") {
                ClaudeDesktop.relaunch()
            }
        }
        markSetUp(true)
        return true
    }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// `claude auth status` prints JSON with `loggedIn`. An older Claude Code without it counts as signed in.
    nonisolated static func isSignedIn(_ claude: ClaudeCommand) -> Bool {
        let (status, output) = claude.run(["auth", "status"])
        guard status == 0, let start = output.firstIndex(of: "{"),
              let json = try? JSONValue.decode(Data(output[start...].utf8)) else { return status == 0 }
        return json["loggedIn"]?.boolValue ?? true
    }

    /// `claude auth login` needs a terminal (it opens the browser and waits).
    private func openSignIn(_ claude: ClaudeCommand) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Kite Claude Sign In.command")
        // A test profile signs in to its test Claude home, never the user's own ~/.claude.
        let body = claude.signInScript()
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            tell("Couldn't open Terminal", "Run this in a terminal, then click the Claude button again:\n\(claude.signInCommand)")
        }
    }

    private func ask(_ title: String, _ text: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return WindowPresenter.runModal(alert) == .alertFirstButtonReturn
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        _ = WindowPresenter.runModal(alert)
    }
}
