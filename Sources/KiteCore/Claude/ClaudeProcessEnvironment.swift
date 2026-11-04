import Foundation

/// The environment of every `claude` Kite starts (⌘J tasks, the Claude Code bar, Ask on Page,
/// link previews, Tidy Tabs, Tidy Tab Titles, Tidy Downloads, Instant Links, setup). On a real
/// profile it's Kite's own environment with the login shell's PATH. On a test profile
/// (`KITE_SUPPORT_PATH` set) HOME and CLAUDE_CONFIG_DIR also point at the test Claude home
/// (`ClaudeCodeSessions.home`), so a test build never reads or writes the user's own `~/.claude`.
/// It's built afresh for each run from the login shell's cached answers (`LoginShellCache`), so it
/// always follows the current test-profile state.
public enum ClaudeProcessEnvironment {
    /// Kite's one rule for a test profile: `KITE_SUPPORT_PATH` is set, even to an empty string
    /// (main.swift, `AppDelegate.supportDirectory`). A test profile never drives the user's own
    /// Claude: their `~/.claude`, their Claude app, their installs.
    public static func isTestProfile(_ environment: [String: String]) -> Bool {
        environment["KITE_SUPPORT_PATH"] != nil
    }

    /// The variables a test profile moves to its Claude home.
    public static let isolatedKeys = ["HOME", "CLAUDE_CONFIG_DIR"]

    /// `export` lines for a shell script (the Terminal sign-in) that put it in `environment`'s Claude
    /// home: on a test profile (`kite`, Kite's own environment) every `isolatedKeys` variable
    /// `environment` has, whatever the script's own shell would set; on a real profile none.
    public static func exports(_ environment: [String: String], kite: [String: String]) -> String {
        guard isTestProfile(kite) else { return "" }
        return isolatedKeys.compactMap { key in
            environment[key].map { "export \(key)=\(Shell.quote($0))\n" }
        }.joined()
    }

    /// Where Claude Code and Node usually live, put ahead of launchd's bare PATH when the login shell
    /// gave no PATH, so a Node-script `claude` still finds `node`.
    public static func fallbackDirectories(userHome: URL) -> [String] {
        [userHome.appendingPathComponent(".local/bin", isDirectory: true).path, "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// `path` with `directories` in front, each once and only if it isn't in `path` already.
    public static func prepending(_ directories: [String], to path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init)
        let missing = directories.reduce(into: [String]()) { result, directory in
            if !directory.isEmpty, !parts.contains(directory), !result.contains(directory) { result.append(directory) }
        }
        parts.insert(contentsOf: missing, at: 0)
        return parts.joined(separator: ":")
    }

    /// Kite's environment `base` with the login shell's PATH, without Kite's own test switches,
    /// isolated on a test profile. With no login PATH (the shell failed or timed out) it keeps
    /// Kite's PATH with `fallbackDirectories` in front.
    public static func make(_ base: [String: String], loginPath: String?, userHome: URL,
                            fallbackDirectories: [String] = []) -> [String: String] {
        var environment = base
        let path = loginPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.contains("/") {
            environment["PATH"] = path
        } else if !fallbackDirectories.isEmpty {
            environment["PATH"] = prepending(fallbackDirectories, to: base["PATH"])
        }
        // Kite's own test switches mustn't leak into Claude Code.
        environment["KITE_DIAGNOSTICS"] = nil
        return ClaudeCodeSessions.processEnvironment(environment, environment: base,
                                                     home: ClaudeCodeSessions.home(environment: base, userHome: userHome))
    }
}

/// Shell words.
public enum Shell {
    /// `string` as one shell word: as is when it's plainly safe, else single-quoted.
    public static func quote(_ string: String) -> String {
        !string.isEmpty && string.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? string : "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
