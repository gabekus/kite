import Foundation

/// Where ⌘J sends a request made in a space. Each space keeps its own route, so a request
/// typed in the Komado space goes to the Komado project. A space that hasn't picked one
/// goes where ⌘J always has.
///
/// What can be addressed (checked 1 Nov 2026):
/// - A Claude Project (Claude Code Projects, `claude.ai/code/project/chan_…`) has no public
///   API to post into. The desktop app's `claude://` links open a project's page but only
///   prefill a prompt in a new chat, and Claude Code's own "send to project" call sits
///   behind its approval dialog and its login token. So Kite opens the project page itself,
///   in a Peek over the tab, and posts the request in the project's own composer: it's the
///   project's real conversation, and its replies show live in the Peek.
/// - A folder on this Mac is a Claude Code project: `claude -p` run in it picks up its
///   CLAUDE.md and memory, and the transcript shows in the ⌘J bar like any Kite task.
public enum ClaudeRoute: Hashable, Codable, Sendable {
    /// A new chat: the Claude desktop app, or a task here in Kite (the bar's own switch).
    case newChat
    /// A Claude Project, posted on its page in a Peek.
    case project(id: String, name: String)
    /// Claude Code in a folder on this Mac, with Kite's tools.
    case folder(path: String)

    /// The route's name in the ⌘J bar.
    public var label: String {
        switch self {
        case .newChat: "New chat"
        case let .project(_, name): name
        case let .folder(path): Self.folderName(path)
        }
    }

    public static func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    // MARK: Claude Projects

    private static func isProjectID(_ text: String) -> Bool {
        text.wholeMatch(of: /chan_[A-Za-z0-9_-]{1,120}/) != nil
    }

    /// The project id in a link the user pasted: `https://claude.ai/code/project/chan_…`
    /// (a thread link `…/chan_…/cmsg_…` too), or a bare `chan_…`.
    public static func projectID(fromLink link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if isProjectID(text) { return text }
        guard let url = URL(string: text), url.scheme == "https", url.host == "claude.ai" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0] == "code", parts[1] == "project",
              isProjectID(parts[2]) else { return nil }
        return parts[2]
    }

    public static func projectURL(id: String) -> URL {
        URL(string: "https://claude.ai/code/project/")!.appendingPathComponent(id)
    }

    /// What's posted in the project: the request, and the tab the user attached.
    public static func projectMessage(goal: String, tab: ClaudeInvocation.TabContext?) -> String {
        guard let tab else { return goal }
        return "\(goal)\n\n(From Kite. I'm looking at “\(tab.title)” — \(tab.url))"
    }

    /// What the composer script reports back.
    public enum ComposerState: String, Sendable {
        /// The page hasn't shown its composer yet.
        case waiting
        /// claude.ai is asking the user to sign in.
        case signIn = "signin"
        /// The text is in the composer but the send button isn't ready.
        case typed
        case sent
    }

    /// JavaScript for the project page: puts `message` in the composer (once) and presses
    /// Send. Returns a `ComposerState` raw value, so Kite runs it again until `sent`.
    public static func composerScript(message: String) -> String {
        let literal = (try? JSONEncoder().encode(message)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return """
            (() => {
              const text = \(literal);
              if (/^\\/(login|logout)/.test(location.pathname)) return 'signin';
              const box = document.querySelector('[contenteditable="true"][role="textbox"], div.ProseMirror[contenteditable="true"], textarea');
              if (!box) return 'waiting';
              const current = box.tagName === 'TEXTAREA' ? box.value : box.innerText;
              if (current.trim() !== text.trim()) {
                box.focus();
                if (box.tagName === 'TEXTAREA') {
                  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(box, text);
                  box.dispatchEvent(new Event('input', { bubbles: true }));
                } else {
                  document.execCommand('selectAll', false);
                  document.execCommand('insertText', false, text);
                }
                return 'typed';
              }
              const send = [...document.querySelectorAll('button')].find(b =>
                /send/i.test(b.getAttribute('aria-label') || '') && !b.disabled);
              if (!send) return 'typed';
              send.click();
              return 'sent';
            })()
            """
    }
}

/// Every space's route, and the projects the user has added, in `<profile>/Claude/routes.json`.
public struct ClaudeRoutes: Codable, Equatable, Sendable {
    public struct Project: Hashable, Codable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Keyed by space id.
    public var spaces: [String: ClaudeRoute]
    /// Projects the user added, offered in every space's picker.
    public var projects: [Project]

    public init(spaces: [String: ClaudeRoute] = [:], projects: [Project] = []) {
        self.spaces = spaces
        self.projects = projects
    }

    public func route(for space: UUID) -> ClaudeRoute {
        spaces[space.uuidString] ?? .newChat
    }

    public mutating func set(_ route: ClaudeRoute, for space: UUID) {
        spaces[space.uuidString] = route == .newChat ? nil : route
        if case let .project(id, name) = route { addProject(id: id, name: name) }
    }

    /// Adds a project, or renames the one with that id.
    public mutating func addProject(id: String, name: String) {
        if let i = projects.firstIndex(where: { $0.id == id }) {
            projects[i].name = name
        } else {
            projects.append(Project(id: id, name: name))
        }
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Claude", isDirectory: true).appendingPathComponent("routes.json")
    }

    public static func load(from url: URL) -> ClaudeRoutes {
        guard let data = try? Data(contentsOf: url),
              let routes = try? JSONDecoder().decode(ClaudeRoutes.self, from: data) else { return ClaudeRoutes() }
        return routes
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The folders the user has run Claude Code in, most recent first, for the route picker.
public enum ClaudeCodeFolders {
    /// `~/.claude.json` lists every folder Claude Code has opened; `~/.claude/projects/<folder
    /// with / and . as ->` holds its transcripts, whose change date says how recently.
    /// Temporary folders and worktrees are left out.
    public static func recent(home: URL, limit: Int = 8, files: FileManager = .default,
                              candidate: ((String) -> Bool)? = nil) -> [String] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [] }
        let transcripts = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let folders: [(path: String, used: Date)] = projects.keys.compactMap { path in
            guard candidate?(path) ?? isCandidate(path, home: home.path) else { return nil }
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let key = transcriptKey(path)
            let used = (try? files.attributesOfItem(atPath: transcripts.appendingPathComponent(key).path))?[.modificationDate] as? Date
            return (path, used ?? .distantPast)
        }
        return folders.sorted { $0.used != $1.used ? $0.used > $1.used : $0.path < $1.path }.prefix(limit).map(\.path)
    }

    /// Claude Code's name for a folder's transcript directory.
    public static func transcriptKey(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    static func isCandidate(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path != home else { return false }
        for prefix in ["/tmp/", "/private/", "/var/", "/Volumes/"] where path.hasPrefix(prefix) { return false }
        return !path.contains("/.claude/worktrees/") && !path.contains("/Library/")
    }
}
