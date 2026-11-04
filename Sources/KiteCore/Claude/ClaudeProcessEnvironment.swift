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
            let support = environment["KITE_SUPPORT_PATH"]
            supportPath = support?.isEmpty == false ? support : nil
            home = ClaudeCodeSessions.home(environment: environment, userHome: userHome).path
        }

        public var isTestProfile: Bool { supportPath != nil }
    }

    /// `base` with HOME and CLAUDE_CONFIG_DIR moved to the test Claude home on a test profile;
    /// `base` unchanged on a real one. For a quick `claude` call that doesn't need the login PATH.
    public static func isolated(_ base: [String: String], userHome: URL) -> [String: String] {
        ClaudeCodeSessions.processEnvironment(base, environment: base,
                                              home: ClaudeCodeSessions.home(environment: base, userHome: userHome))
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
