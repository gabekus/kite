import Foundation

/// How Kite runs Claude Code for a task: headless (`claude -p`), on the user's own
/// Claude login, with Kite's MCP server as its only tools.
public enum ClaudeInvocation {
    /// The environment variable that tells `kite mcp` which task its tool calls belong to,
    /// so the tabs a task opens go into that task's folder.
    public static let taskEnvironmentKey = "KITE_AGENT_TASK"

    /// Claude Code's arguments for one turn of a task. The prompt goes on stdin.
    ///
    /// - Only Kite's tools: `--strict-mcp-config` ignores the user's other MCP servers,
    ///   `--tools ""` removes Claude Code's built-in tools (shell, files, web fetch).
    /// - `dontAsk` refuses anything not allowed up front; every Kite tool is allowed,
    ///   and Kite itself asks before anything that commits on the user's behalf.
    public static func arguments(kiteCLI: String, profile: String?, taskID: UUID, resume sessionID: String?,
                                 model: String? = nil) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--mcp-config", mcpConfig(kiteCLI: kiteCLI, profile: profile, taskID: taskID),
            "--strict-mcp-config",
            "--tools", "",
            "--allowedTools", "mcp__kite",
            "--permission-mode", "dontAsk",
            "--append-system-prompt", systemPrompt,
        ]
        if let model { arguments += ["--model", model] }
        if let sessionID { arguments += ["--resume", sessionID] }
        return arguments
    }

    /// `{"mcpServers":{"kite":{…}}}` for `--mcp-config`, as one JSON string.
    public static func mcpConfig(kiteCLI: String, profile: String?, taskID: UUID) -> String {
        var environment: [String: JSONValue] = [taskEnvironmentKey: .string(taskID.uuidString)]
        if let profile { environment["KITE_SUPPORT_PATH"] = .string(profile) }
        let config: JSONValue = [
            "mcpServers": ["kite": ["type": "stdio", "command": .string(kiteCLI), "args": ["mcp"], "env": .object(environment)]],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static let systemPrompt = """
        You are Claude running inside Kite, the user's web browser, on a task the user started from Kite's \
        Claude Tasks panel. They may not be watching: work on your own until the task is done, then reply with \
        the result. Your reply is shown in a small panel and a notification, so lead with the answer and keep it short; \
        use a list or a small table when it helps.

        Your only tools are Kite's (mcp__kite__*), acting in the user's real browser, signed in as them. \
        Open the tabs you need with tabs_create: they open in the background, in this task's folder in the Claude \
        space, so you never take over the tab the user is looking at. Don't switch_tab or switch_space unless the \
        user asks. Prefer read_page, find and get_page_text over screenshots, and use batch to save round trips. \
        Close tabs you opened that aren't part of the result. If the user attached a tab, it's theirs: read it, \
        but don't navigate away from it.

        Only submit forms, send, post, pay, buy or delete what the user asked for. If they turned on Kite's Ask \
        Before Claude Acts, Kite asks them first; if they decline, say what you couldn't do instead of retrying. Never \
        enter credentials or payment details yourself, and never ask for them: when a page needs the user signed in \
        (a login form, a password or a one-time code), call sign_in on that tab. Kite shows it to the user, who signs \
        in with their password manager while you wait; then carry on. \(UntrustedContent.notice)
        """

    /// The tab the user attached to a task ("Ask about this tab").
    public struct TabContext: Hashable, Sendable {
        public var id: UUID
        public var title: String
        public var url: String

        public init(id: UUID, title: String, url: String) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    /// What goes on stdin for the first turn: the goal, plus the attached tab.
    public static func prompt(goal: String, tab: TabContext?) -> String {
        guard let tab else { return goal }
        return """
            \(goal)

            The user attached the tab they're looking at (tab id \(tab.id.uuidString)). Read it with read_page or \
            get_page_text using that id. Its title and URL:
            \(UntrustedContent.wrap("\(tab.title)\n\(tab.url)", source: tab.url))
            """
    }
}
