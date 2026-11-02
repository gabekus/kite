import Foundation

/// The user's own Claude Code sessions (the CLI's, and the Claude desktop app's Code tab, which
/// runs the same Claude Code), shown in Kite's Claude Code bar so they can be read and continued
/// without switching apps.
///
/// Claude Code keeps every session as a JSON Lines transcript at
/// `~/.claude/projects/<folder key>/<session id>.jsonl`, one line per message: `type` is
/// `user`/`assistant` (with `message`, `cwd`, `gitBranch`, `timestamp`), or a bookkeeping line
/// (`summary`, `custom-title`, …). Kite only reads these files; a turn sent from Kite runs
/// `claude -p --resume <id>`, which appends to the same transcript.
public struct ClaudeCodeSession: Identifiable, Hashable, Sendable {
    /// Claude Code's session id (the transcript's file name).
    public var id: String
    public var transcript: URL
    /// The folder the session works in. nil when the transcript doesn't say (a brand new file).
    public var directory: String?
    public var title: String
    public var gitBranch: String?
    /// The transcript's last change.
    public var updatedAt: Date

    public init(id: String, transcript: URL, directory: String?, title: String, gitBranch: String?, updatedAt: Date) {
        self.id = id
        self.transcript = transcript
        self.directory = directory
        self.title = title
        self.gitBranch = gitBranch
        self.updatedAt = updatedAt
    }

    /// The folder's name, for the row's detail.
    public var folderName: String? { directory.map(ClaudeRoute.folderName) }

    /// Written to in the last `window` seconds: probably running right now, in a terminal or Desktop.
    public func isLive(now: Date = Date(), window: TimeInterval = ClaudeCodeSessions.liveWindow) -> Bool {
        now.timeIntervalSince(updatedAt) < window
    }
}

public enum ClaudeCodeSessions {
    /// How recently a transcript must have changed for its session to count as live.
    public static let liveWindow: TimeInterval = 90
    /// How many recent sessions the bar lists, besides pinned ones.
    public static let recentLimit = 5
    /// Bytes read from each end of a transcript for its title and folder.
    static let peekBytes = 256 * 1024

    public static func projectsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// `8c0f…-…`: Claude Code names transcripts by their session's UUID. Subagents' and other
    /// side files (`agent-…jsonl`) aren't sessions.
    public static func isSessionID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// The pinned sessions (in pin order), then the most recently used others, up to `limit`.
    /// `excluding` leaves out sessions working in those folders or below (Kite's own ⌘J tasks).
    /// `known` is the last listing: a transcript that hasn't changed since isn't read again.
    public static func list(home: URL, pinned: [String], limit: Int = recentLimit, excluding: [String] = [],
                            known: [String: ClaudeCodeSession] = [:],
                            files: FileManager = .default) -> (pinned: [ClaudeCodeSession], recent: [ClaudeCodeSession]) {
        let candidates = transcripts(home: home, files: files)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.date >= b.date ? a : b })
        func session(id: String, file: URL, date: Date) -> ClaudeCodeSession? {
            if let cached = known[id], cached.updatedAt == date, cached.transcript == file { return cached }
            return Self.session(id: id, file: file, date: date)
        }
        let pinnedSessions = pinned.compactMap { id in byID[id].flatMap { session(id: id, file: $0.url, date: $0.date) } }
        var recent: [ClaudeCodeSession] = []
        let pinnedSet = Set(pinned)
        for candidate in candidates.sorted(by: { $0.date > $1.date }) where !pinnedSet.contains(candidate.id) {
            guard recent.count < limit else { break }
            guard let session = session(id: candidate.id, file: candidate.url, date: candidate.date) else { continue }
            if let directory = session.directory, excluding.contains(where: { isInside(directory, $0) }) { continue }
            recent.append(session)
        }
        return (pinnedSessions, recent)
    }

    /// The transcript of one session, wherever its folder is.
    public static func transcript(id: String, home: URL, files: FileManager = .default) -> URL? {
        transcripts(home: home, files: files).first { $0.id == id }?.url
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// Every top-level transcript with its change date. Directory listings only: cheap enough to run
    /// every few seconds while the bar is open.
    static func transcripts(home: URL, files: FileManager) -> [(id: String, url: URL, date: Date)] {
        let root = projectsDirectory(home: home)
        guard let folders = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles]) else { return [] }
        var found: [(id: String, url: URL, date: Date)] = []
        for folder in folders {
            guard let names = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for file in names where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard isSessionID(id) else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                found.append((id, file, date))
            }
        }
        return found
    }

    /// The session's folder, branch and title, from the transcript's first and last lines.
    /// nil for a transcript with nothing the user said (an empty or bookkeeping-only file).
    static func session(id: String, file: URL, date: Date) -> ClaudeCodeSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: peekBytes)) ?? Data()
        var tail = Data()
        if size > UInt64(peekBytes) {
            try? handle.seek(toOffset: max(UInt64(peekBytes), size - UInt64(peekBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        guard let info = ClaudeCodeTranscript.info(head: head, tail: tail) else { return nil }
        return ClaudeCodeSession(id: id, transcript: file, directory: info.directory, title: info.title,
                                 gitBranch: info.gitBranch, updatedAt: date)
    }
}

/// Reading a Claude Code transcript (`<session>.jsonl`).
public enum ClaudeCodeTranscript {
    public struct Info: Hashable, Sendable {
        public var directory: String?
        public var gitBranch: String?
        public var title: String
    }

    public static let maxTitleLength = 80

    /// What the session list shows. The title is the one the user gave (`/rename`), else Claude
    /// Code's summary, else the first thing the user asked. `tail` is the file's end when it's
    /// too big to read whole (its first line may be cut; that line is skipped).
    public static func info(head: Data, tail: Data = Data()) -> Info? {
        var directory: String?, branch: String?, firstPrompt: String?, summary: String?, customTitle: String?
        func scan(_ lines: [JSONValue]) {
            for line in lines {
                switch line["type"]?.stringValue {
                case "custom-title":
                    if let title = line["customTitle"]?.stringValue, !title.isEmpty { customTitle = title }
                case "summary":
                    if let text = line["summary"]?.stringValue, !text.isEmpty { summary = text }
                case "user", "assistant":
                    if line["isSidechain"]?.boolValue == true { continue }
                    if let cwd = line["cwd"]?.stringValue, !cwd.isEmpty { directory = cwd }
                    if let b = line["gitBranch"]?.stringValue, !b.isEmpty, b != "HEAD" { branch = b }
                    if firstPrompt == nil, line["type"]?.stringValue == "user", line["isMeta"]?.boolValue != true,
                       let text = userText(line["message"]?["content"]), let prompt = promptLine(text) {
                        firstPrompt = prompt
                    }
                default:
                    continue
                }
            }
        }
        let headLines = lines(head)
        // Only the first folder seen in the head counts for the first prompt; the tail's lines
        // say where the session is now (it can `cd`), and its latest branch and title.
        scan(headLines)
        if !tail.isEmpty { scan(Array(lines(tail).dropFirst())) }
        guard let title = customTitle ?? summary ?? firstPrompt else { return nil }
        return Info(directory: directory, gitBranch: branch, title: cut(title, to: maxTitleLength))
    }

    /// The conversation as the bar shows it: what the user said, Claude's replies, one line per
    /// tool call and tool errors. Subagents' lines, Claude Code's own injected messages and
    /// tool output are left out. Keeps the last `ClaudeTask.maxEntries`.
    public static func entries(_ data: Data) -> [ClaudeTask.Entry] {
        var entries: [ClaudeTask.Entry] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines(data) {
            guard let type = line["type"]?.stringValue, type == "user" || type == "assistant",
                  line["isSidechain"]?.boolValue != true else { continue }
            let date = line["timestamp"]?.stringValue.flatMap { iso.date(from: $0) } ?? Date.distantPast
            let content = line["message"]?["content"]
            if type == "assistant" {
                for block in content?.arrayValue ?? [] {
                    switch block["type"]?.stringValue {
                    case "text":
                        if let text = block["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            entries.append(.init(.assistant, text, date: date))
                        }
                    case "tool_use":
                        let name = ClaudeStream.toolName(block["name"]?.stringValue ?? "tool")
                        let summary = ClaudeStream.summary(of: block["input"] ?? .null, tool: name)
                        entries.append(.init(.tool, summary.isEmpty ? name : "\(name) · \(summary)", date: date))
                    default:
                        continue
                    }
                }
                continue
            }
            if line["isMeta"]?.boolValue == true || line["isCompactSummary"]?.boolValue == true { continue }
            if let blocks = content?.arrayValue {
                for block in blocks where block["type"]?.stringValue == "tool_result" && block["is_error"]?.boolValue == true {
                    let text = ClaudeStream.firstLine(ClaudeStream.resultText(block["content"]), limit: 200)
                    if !text.isEmpty { entries.append(.init(.toolError, text, date: date)) }
                }
            }
            guard let text = userText(content) else { continue }
            if let entry = userEntry(text, date: date) { entries.append(entry) }
        }
        return entries.count > ClaudeTask.maxEntries ? Array(entries.suffix(ClaudeTask.maxEntries)) : entries
    }

    /// The text the user typed in a `user` line: a string, or its text blocks (tool results and
    /// images aren't the user's words).
    static func userText(_ content: JSONValue?) -> String? {
        switch content {
        case .string(let text)?:
            return text
        case .array(let blocks)?:
            let texts = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// A user line as the transcript shows it. Slash commands become a note; Claude Code's own
    /// wrappers (command output, reminders, caveats) are dropped.
    static func userEntry(_ text: String, date: Date) -> ClaudeTask.Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let command = tag("command-name", in: trimmed) {
            let args = tag("command-args", in: trimmed).map { $0.isEmpty ? "" : " " + $0 } ?? ""
            return .init(.note, command + args, date: date)
        }
        if trimmed.hasPrefix("[Request interrupted") { return .init(.note, "Interrupted.", date: date) }
        if isInjected(trimmed) { return nil }
        return .init(.user, trimmed, date: date)
    }

    /// The first prompt's first line, unless it's Claude Code's own (a command, a caveat).
    static func promptLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = tag("command-name", in: trimmed) {
            // `/init`, `/review 12`: not a title, but better than nothing for a command-only session.
            let args = tag("command-args", in: trimmed) ?? ""
            return args.isEmpty ? nil : "\(command) \(args)"
        }
        guard !trimmed.isEmpty, !isInjected(trimmed), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return first.trimmingCharacters(in: .whitespaces)
    }

    static func isInjected(_ text: String) -> Bool {
        for prefix in ["<local-command", "<command-", "<system-reminder>", "<bash-", "<user-memory-input>", "Caveat: "]
            where text.hasPrefix(prefix) { return true }
        return false
    }

    /// The text inside `<name>…</name>`.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cut(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Each parseable JSON line. A cut or damaged line is skipped.
    static func lines(_ data: Data) -> [JSONValue] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(JSONValue.self, from: Data($0))
        }
    }
}

/// How a turn sent from Kite runs: Claude Code on its own, in the session's folder, with the
/// user's own settings, tools and MCP servers. It's an extra window on the user's sessions, not
/// Kite's browser agent, so Kite adds nothing of its own except where to send the output.
public enum ClaudeCodeInvocation {
    /// What Claude Code may do without asking, since nobody can answer a prompt in `-p`.
    public enum Permissions: String, CaseIterable, Codable, Sendable {
        /// File edits go ahead; other tools follow the user's settings (`permissions.allow`), and
        /// anything else is refused and shows as a refused tool call.
        case acceptEdits
        /// Everything goes ahead, like `--dangerously-skip-permissions`.
        case bypassPermissions

        public static let defaultsKey = "claudeCodePermissions"

        public var label: String {
            switch self {
            case .acceptEdits: "Edits allowed, other tools as in your settings"
            case .bypassPermissions: "Full access: every tool runs without asking"
            }
        }
    }

    public static let systemPrompt = """
        The user is messaging you from Kite, their web browser, which shows this Claude Code session in a \
        small panel. Nobody can answer a permission prompt there: a tool call that needs one is refused, so \
        if one is, say which command or change you need and why, and carry on with what you can do. Keep \
        replies short and lead with the result.
        """

    /// Claude Code's arguments for one turn. The prompt goes on stdin. `resume` continues that
    /// session; `newSession` starts one under that id, so Kite knows it before Claude Code says.
    public static func arguments(resume: String?, newSession: String? = nil, permissions: Permissions) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", permissions.rawValue,
            "--append-system-prompt", systemPrompt,
        ]
        if let resume {
            arguments += ["--resume", resume]
        } else if let newSession {
            arguments += ["--session-id", newSession]
        }
        return arguments
    }
}

/// The sessions the user pinned to the Claude Code bar, in `<profile>/Claude/code-sessions.json`.
public struct ClaudeCodePins: Codable, Equatable, Sendable {
    public var pinned: [String]

    public init(pinned: [String] = []) {
        self.pinned = pinned
    }

    public static let limit = 20

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// Pins at the end, or unpins.
    public mutating func toggle(_ id: String) {
        if let i = pinned.firstIndex(of: id) {
            pinned.remove(at: i)
        } else {
            pinned.append(id)
            if pinned.count > Self.limit { pinned.removeFirst(pinned.count - Self.limit) }
        }
    }

    /// A session that continued under a new id keeps its pin.
    public mutating func rename(_ old: String, to new: String) {
        guard let i = pinned.firstIndex(of: old) else { return }
        if pinned.contains(new) { pinned.remove(at: i) } else { pinned[i] = new }
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Claude", isDirectory: true).appendingPathComponent("code-sessions.json")
    }

    public static func load(from url: URL) -> ClaudeCodePins {
        guard let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode(ClaudeCodePins.self, from: data) else { return ClaudeCodePins() }
        return pins
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
