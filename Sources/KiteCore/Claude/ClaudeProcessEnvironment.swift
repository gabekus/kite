import Foundation

/// The environment of every `claude` Kite starts (⌘J tasks, the Claude Code bar, Ask on Page,
/// link previews, Tidy Tabs, Tidy Tab Titles, Tidy Downloads, Instant Links, setup). On a real
/// profile it's Kite's own environment with the login shell's PATH. On a test profile
/// (`KITE_SUPPORT_PATH` set) HOME and CLAUDE_CONFIG_DIR also point at the test Claude home
/// (`ClaudeCodeSessions.home`), so a test build never reads or writes the user's own `~/.claude`.
public enum ClaudeProcessEnvironment {
    /// What the environment depends on besides the login PATH: the test-profile state. A cached
    /// environment is kept per key, so one worked out for one profile is never used for another.
    public struct Key: Hashable, Sendable {
        public let supportPath: String?
        public let home: String

        public init(environment: [String: String], userHome: URL) {
            supportPath = environment["KITE_SUPPORT_PATH"]
            home = ClaudeCodeSessions.home(environment: environment, userHome: userHome).path
        }

        public var isTestProfile: Bool { supportPath != nil }
    }

    /// Kite's one rule for a test profile: `KITE_SUPPORT_PATH` is set, even to an empty string
    /// (main.swift, `AppDelegate.supportDirectory`). A test profile never drives the user's own
    /// Claude: their `~/.claude`, their Claude app, their installs.
    public static func isTestProfile(_ environment: [String: String]) -> Bool {
        environment["KITE_SUPPORT_PATH"] != nil
    }

    /// The variables a test profile moves to its Claude home.
    public static let isolatedKeys = ["HOME", "CLAUDE_CONFIG_DIR"]

    /// `export` lines for a shell script (the Terminal sign-in) that put it in `environment`'s Claude
    /// home: one per `isolatedKeys` variable that differs from Kite's own `base`, so a real profile
    /// gets none.
    public static func exports(_ environment: [String: String], base: [String: String]) -> String {
        isolatedKeys.compactMap { key in
            guard let value = environment[key], value != base[key] else { return nil }
            return "export \(key)=\(shellQuote(value))\n"
        }.joined()
    }

    /// `string` as one shell word: as is when it's plainly safe, else single-quoted.
    public static func shellQuote(_ string: String) -> String {
        !string.isEmpty && string.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? string : "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Kite's environment `base` with the login shell's PATH (when it gave one), without Kite's
    /// own test switches, isolated on a test profile.
    public static func make(_ base: [String: String], loginPath: String?, userHome: URL) -> [String: String] {
        var environment = base
        let path = loginPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.contains("/") { environment["PATH"] = path }
        // Kite's own test switches mustn't leak into Claude Code.
        environment["KITE_DIAGNOSTICS"] = nil
        return ClaudeCodeSessions.processEnvironment(environment, environment: base,
                                                     home: ClaudeCodeSessions.home(environment: base, userHome: userHome))
    }

    /// Environments worked out once per `Key` (the login shell is slow). Safe from any thread;
    /// the first caller for a key works it out while later ones wait.
    public final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var environments: [Key: [String: String]] = [:]

        public init() {}

        public func environment(for key: Key, make: () -> [String: String]) -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = environments[key] { return cached }
            let environment = make()
            environments[key] = environment
            return environment
        }
    }
}
