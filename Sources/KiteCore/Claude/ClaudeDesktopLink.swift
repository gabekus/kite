import Foundation

/// Kite's link to the Claude desktop app, so Kite's Claude and the desktop app are one Claude.
///
/// What the desktop app knows (chat history, chat search, memory, projects) lives in the
/// user's claude.ai account and is only reachable from inside a desktop or claude.ai chat:
/// there's no API that hands it to `claude -p`. So the link works the other way round:
///
/// 1. Kite's MCP server goes into `claude_desktop_config.json`. Desktop then has Kite's
///    tools in its Chat tab, Cowork and its local Code sessions, and anything Claude does in
///    Kite from there is part of that chat, with Desktop's memory and history.
/// 2. ⌘J hands the request to Desktop (`claude://claude.ai/new?q=…`) instead of running a
///    separate headless Claude, so the conversation happens in Desktop.
/// 3. A task that did run headless in Kite opens in Desktop's Code tab through
///    `claude://resume?session=<id>`, and carries on there.
public enum ClaudeDesktopLink {
    /// The name Kite's server has in Desktop's config (the same as in Claude Code's).
    public static let serverName = "kite"

    /// Desktop's bundle identifier, to find, quit and reopen it.
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// `~/Library/Application Support/Claude/claude_desktop_config.json` on macOS.
    public static func configURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
    }

    /// Kite's entry for `mcpServers`.
    public static func server(kiteCLI: String, profile: String?) -> [String: Any] {
        var server: [String: Any] = ["command": kiteCLI, "args": ["mcp"]]
        if let profile { server["env"] = ["KITE_SUPPORT_PATH": profile] }
        return server
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        /// The file isn't a JSON object, so Kite won't touch it.
        case notAnObject
        case mcpServersNotAnObject

        public var description: String {
            switch self {
            case .notAnObject: "claude_desktop_config.json isn't a JSON object, so Kite left it alone."
            case .mcpServersNotAnObject: "mcpServers in claude_desktop_config.json isn't an object, so Kite left it alone."
            }
        }
    }

    /// The config with Kite's server added or replaced, everything else kept as it was.
    /// `existing` is the file's bytes, nil or empty when there's no file yet.
    /// Returns nil when Kite's entry is already exactly this, so the file isn't rewritten.
    public static func merged(_ existing: Data?, server: [String: Any]) throws -> Data? {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw ConfigError.notAnObject
            }
            root = object
        }
        var servers: [String: Any] = [:]
        if let current = root["mcpServers"] {
            guard let object = current as? [String: Any] else { throw ConfigError.mcpServersNotAnObject }
            servers = object
        }
        if let current = servers[serverName], NSDictionary(dictionary: ["s": current]).isEqual(to: ["s": server]) {
            return nil
        }
        servers[serverName] = server
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// True when the config already has an entry named `kite`.
    public static func isLinked(_ config: Data?) -> Bool {
        guard let config, let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    // MARK: Handing a request to Desktop

    /// Desktop truncates `q` at about 14,000 characters; stay under it.
    public static let promptLimit = 12_000

    /// A new Desktop chat with `prompt` in the composer, ready to send.
    public static func chatURL(prompt: String) -> URL {
        URL(string: "claude://claude.ai/new?q=" + encode(String(prompt.prefix(promptLimit))))!
    }

    /// Strict query encoding: `+`, `&`, `=`, `#` and `?` in the prompt are encoded too.
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// What ⌘J puts in Desktop's composer: the goal, and the tab the user attached, so
    /// Desktop's Claude can read it with Kite's tools.
    public static func prompt(goal: String, tab: ClaudeInvocation.TabContext?) -> String {
        guard let tab else { return goal }
        return """
            \(goal)

            (From Kite. I'm looking at “\(tab.title)” — \(tab.url) — Kite tab id \(tab.id.uuidString). \
            Use the Kite tools to read or act on it.)
            """
    }

    /// Opens a headless task's Claude Code session in Desktop's Code tab.
    ///
    /// This is the link `claude --desktop --resume <id>` opens itself. Kite opens it
    /// directly: the CLI refuses `--desktop` unless stdin and stdout are a terminal, and a
    /// GUI app launching it never has one ("can't run non-interactively … or redirected output").
    public static func resumeURL(sessionID: String) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    /// The oldest Desktop that understands `claude://resume` (what Claude Code checks for).
    public static let minimumResumeVersion = "1.1.9669"

    /// True when `version` (Desktop's CFBundleShortVersionString) is at least
    /// `minimumResumeVersion`. An unreadable version gets the benefit of the doubt.
    public static func supportsResume(version: String?) -> Bool {
        guard let version else { return true }
        let parts = { (v: String) in v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let have = parts(version), need = parts(minimumResumeVersion)
        guard !have.isEmpty else { return true }
        for i in 0..<max(have.count, need.count) {
            let a = i < have.count ? have[i] : 0, b = i < need.count ? need[i] : 0
            if a != b { return a > b }
        }
        return true
    }
}

/// Where ⌘J's requests go.
public enum ClaudeRunsIn: String, CaseIterable, Sendable {
    /// Desktop's Chat tab, with Kite's tools: one Claude, with Desktop's memory and history.
    case desktop
    /// Headless Claude Code inside Kite (the transcript shows in the ⌘J bar).
    case kite

    public static let defaultsKey = "claudeRunsIn"
}
