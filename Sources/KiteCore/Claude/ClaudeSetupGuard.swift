import Foundation

/// Keeps test builds out of the user's own Claude setup. Connect Claude and Set Up Claude point
/// Claude Code (user scope), the Claude desktop app and `~/.local/bin/kite` at whichever Kite runs
/// them, so a build on a test profile or in an agent's worktree would leave Claude on a throwaway
/// profile and a build that gets deleted, and Kite's tools stop connecting. Such a build only
/// writes what a test redirected: `KITE_CLAUDE_BIN`, `KITE_CLAUDE_DESKTOP_CONFIG`, `KITE_BIN_DIR`.
public enum ClaudeSetupGuard {
    public enum Target: String, Sendable {
        case claudeCode = "KITE_CLAUDE_BIN"
        case desktop = "KITE_CLAUDE_DESKTOP_CONFIG"
        case commandLink = "KITE_BIN_DIR"
    }

    /// Why this Kite leaves `target` alone, or nil when it may write it.
    /// - Parameter cli: the `kite` command Claude would be pointed at.
    public static func refusal(_ target: Target, cli: String, environment: [String: String]) -> String? {
        if environment[target.rawValue] != nil { return nil }
        if environment["KITE_SUPPORT_PATH"] != nil {
            return "this Kite runs on a test profile (KITE_SUPPORT_PATH). Set \(target.rawValue) to test this step"
        }
        if cli.contains("/.claude/worktrees/") {
            return "this Kite is a worktree build, which gets deleted. Set \(target.rawValue) to test this step"
        }
        return nil
    }
}
