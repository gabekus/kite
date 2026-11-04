import Foundation

/// The user's own Claude Code sessions (the CLI's, and the Claude desktop app's Code tab, which
/// runs the same Claude Code), shown in Kite's Claude Code bar so they can be read and continued
/// without switching apps.
///
/// Claude Code keeps every session as a JSON Lines transcript at
/// `~/.claude/projects/<folder key>/<session id>.jsonl`, one line per message: `type` is
/// `user`/`assistant` (with `message`, `cwd`, `gitBranch`, `timestamp`), or a bookkeeping line
/// (`custom-title`, `ai-title`, `summary` in older versions, …). Kite only reads these files; a
/// turn sent from Kite runs `claude -p --resume <id>`, which appends to the same transcript and
/// keeps the session's id (checked with Claude Code 2.1.316). The Claude app keeps its own titles
/// for its Code tab's sessions apart from the transcripts (`ClaudeDesktopSessions`).
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

    /// The home folder the bar reads Claude Code's and the Claude app's sessions from. A test
    /// profile (`KITE_SUPPORT_PATH` set, even empty, as everywhere in Kite) never reads the user's
    /// own: it reads `KITE_TEST_CLAUDE_HOME` (a fixture folder holding `.claude/projects`), or else the
    /// empty profile folder (a folder in the temporary directory when the path is empty).
    public static func home(environment: [String: String], userHome: URL) -> URL {
        guard let support = environment["KITE_SUPPORT_PATH"] else { return userHome }
        if let fixture = environment["KITE_TEST_CLAUDE_HOME"], !fixture.isEmpty {
            return URL(fileURLWithPath: fixture, isDirectory: true)
        }
        guard !support.isEmpty else {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Kite Test Claude Home", isDirectory: true)
        }
        return URL(fileURLWithPath: support, isDirectory: true)
    }

    /// The environment for a `claude` Kite starts. On a test profile it gets `home` (the fixture,
    /// or the empty profile folder) as its HOME and config folder, so it never reads or writes the
    /// user's own `~/.claude`.
    public static func processEnvironment(_ base: [String: String], environment: [String: String], home: URL) -> [String: String] {
        guard ClaudeProcessEnvironment.isTestProfile(environment) else { return base }
        var result = base
        result["HOME"] = home.path
        result["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude", isDirectory: true).path
        return result
    }

    /// What the bar watches for changes while it's open: Claude Code's transcripts, and the Claude
    /// app's session files (their titles).
    public static func watchedDirectories(home: URL) -> [URL] {
        [projectsDirectory(home: home), ClaudeDesktopSessions.directory(home: home)]
    }

    /// Listings that follow file changes start at most this often (the old poll's rate); the last
    /// change in a burst still gets one.
    public static let minimumListingInterval: TimeInterval = 2

    /// How long to wait before listing again after a change, given when the last listing started.
    public static func listingDelay(lastStarted: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastStarted else { return 0 }
        return max(0, minimumListingInterval - now.timeIntervalSince(lastStarted))
    }

    /// Whether a change at `path` (as FSEvents reports it, symlinks resolved) can change the bar: a
    /// session's transcript (`<projects>/<folder>/<uuid>.jsonl`) outside `excluding` (Kite's own ⌘J
    /// tasks' folders), or one of the Claude app's session files (their titles). Subagents' files,
    /// tool output and other side files don't count.
    public static func isListingChange(_ path: String, projects: String, desktop: String, excluding: [String]) -> Bool {
        func under(_ folder: String) -> String? {
            let folder = folder.hasSuffix("/") ? folder : folder + "/"
            return path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : nil
        }
        if under(desktop) != nil { return path.hasSuffix(".json") }
        guard let rest = under(projects) else { return false }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[1].hasSuffix(".jsonl"), isSessionID(String(parts[1].dropLast(6))) else { return false }
        let key = String(parts[0])
        return !excluding.map(ClaudeCodeFolders.transcriptKey).contains { key == $0 || key.hasPrefix($0 + "-") }
    }

    /// `8c0f…-…`: Claude Code names transcripts by their session's UUID. Subagents' and other
    /// side files (`agent-…jsonl`) aren't sessions.
    public static func isSessionID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// The pinned sessions (in pin order), then the most recently used others, up to `limit`.
    /// `excluding` leaves out sessions working in those folders or below (Kite's own ⌘J tasks).
    /// `known` is the last listing: a transcript that hasn't changed since isn't read again.
    /// `desktop` is what the Claude app says about its sessions: their titles win (they're the
    /// ones the user sees there, renames included), and the ones archived there aren't recent.
    /// `shown` is the session the bar shows, which stays readable once newer ones push it off the list.
    public static func list(home: URL, pinned: [String], limit: Int = recentLimit, excluding: [String] = [],
                            known: [String: ClaudeCodeSession] = [:], desktop: [String: ClaudeDesktopSession] = [:],
                            shown: String? = nil, files: FileManager = .default)
        -> (pinned: [ClaudeCodeSession], recent: [ClaudeCodeSession], shown: ClaudeCodeSession?) {
        let candidates = transcripts(home: home, files: files)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.date >= b.date ? a : b })
        func session(id: String, file: URL, date: Date) -> ClaudeCodeSession? {
            var session: ClaudeCodeSession?
            if let cached = known[id], cached.updatedAt == date, cached.transcript == file {
                session = cached
            } else {
                session = Self.session(id: id, file: file, date: date)
            }
            if let title = desktop[id]?.title { session?.title = ClaudeCodeTranscript.cut(title, to: ClaudeCodeTranscript.maxTitleLength) }
            return session
        }
        let pinnedSessions = pinned.compactMap { id in byID[id].flatMap { session(id: id, file: $0.url, date: $0.date) } }
        var recent: [ClaudeCodeSession] = []
        let pinnedSet = Set(pinned)
        for candidate in candidates.sorted(by: { $0.date > $1.date })
            where !pinnedSet.contains(candidate.id) && desktop[candidate.id]?.isArchived != true {
            guard recent.count < limit else { break }
            guard let session = session(id: candidate.id, file: candidate.url, date: candidate.date) else { continue }
            if let directory = session.directory, excluding.contains(where: { isInside(directory, $0) }) { continue }
            recent.append(session)
        }
        let shownSession = shown.flatMap { id in
            (pinnedSessions + recent).first { $0.id == id } ?? byID[id].flatMap { session(id: id, file: $0.url, date: $0.date) }
        }
        return (pinnedSessions, recent, shownSession)
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
    /// Code's own (`ai-title`, or a summary from older versions), else the first thing the user asked. `tail` is the file's end when it's
    /// too big to read whole (its first line may be cut; that line is skipped).
    public static func info(head: Data, tail: Data = Data()) -> Info? {
        var directory: String?, branch: String?, firstPrompt: String?, summary: String?, customTitle: String?, aiTitle: String?
        func scan(_ lines: [JSONValue]) {
            for line in lines {
                switch line["type"]?.stringValue {
                case "custom-title":
                    if let title = line["customTitle"]?.stringValue, !title.isEmpty { customTitle = title }
                case "ai-title":
                    if let title = line["aiTitle"]?.stringValue, !title.isEmpty { aiTitle = title }
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
        if let cut = tail.firstIndex(of: 0x0A) { scan(lines(Data(tail[cut...]))) }
        guard let title = customTitle ?? aiTitle ?? summary ?? firstPrompt else { return nil }
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

/// Follows one transcript as it grows, for the bar's live view: each read parses only the lines
/// appended since the last one. Transcripts get big (tool output and images are in them: tens of
/// MB is common, and over 100 MB happens), and reading one whole takes seconds, so a big file's
/// first read starts at its last `startBytes`: the bar keeps only the last `ClaudeTask.maxEntries`.
public struct ClaudeCodeTranscriptReader: Sendable {
    public static let startBytes: UInt64 = 8 << 20

    public private(set) var entries: [ClaudeTask.Entry] = []
    /// Where the next read starts: just after the last whole line read.
    public private(set) var offset: UInt64 = 0

    public init() {}

    /// Reads what was added to `file`. False when the conversation didn't change.
    public mutating func read(_ file: URL, startBytes: UInt64 = startBytes) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var changed = false
        if size < offset {
            // Rewritten from scratch: start over.
            changed = !entries.isEmpty
            entries = []
            offset = 0
        }
        // A cut first line doesn't parse and is skipped.
        if offset == 0, size > startBytes { offset = size - startBytes }
        guard size > offset else { return changed }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { return changed }
        // Only whole lines: one still being written is read next time.
        let whole = data[data.startIndex...lastNewline]
        offset += UInt64(whole.count)
        let new = ClaudeCodeTranscript.entries(Data(whole))
        guard !new.isEmpty else { return changed }
        entries += new
        if entries.count > ClaudeTask.maxEntries { entries.removeFirst(entries.count - ClaudeTask.maxEntries) }
        return true
    }
}

/// What the Claude app keeps about one of its Code tab's sessions.
public struct ClaudeDesktopSession: Hashable, Sendable {
    public var title: String?
    public var isArchived: Bool

    public init(title: String?, isArchived: Bool) {
        self.title = title
        self.isArchived = isArchived
    }
}

/// The Claude app's Code tab runs Claude Code, whose transcripts are in `~/.claude/projects` like the
/// terminal's, but the app keeps each session's title (made up after the first turn, or given by
/// the user) in its own file, `~/Library/Application Support/Claude/claude-code-sessions/<account>/
/// <org>/local_<app session id>.json`, with `cliSessionId` (the transcript's id), `title` and
/// `isArchived`. Kite only reads these.
public enum ClaudeDesktopSessions {
    public struct Index: Sendable {
        struct File: Sendable {
            var date: Date
            var cliSessionID: String?
            var session: ClaudeDesktopSession
        }

        var files: [String: File] = [:]

        public init() {}

        /// Each session the app knows, by Claude Code session id.
        public var byCLISessionID: [String: ClaudeDesktopSession] {
            var sessions: [String: ClaudeDesktopSession] = [:]
            for file in files.values {
                if let id = file.cliSessionID { sessions[id] = file.session }
            }
            return sessions
        }
    }

    public static func directory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// The app's sessions, reading only the files that changed since `previous`.
    public static func index(home: URL, previous: Index = Index(), files: FileManager = .default) -> Index {
        var index = Index()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        func children(_ url: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        for account in children(directory(home: home)) {
            for org in children(account) {
                for file in children(org) where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
                    let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                    if let known = previous.files[file.path], known.date == date {
                        index.files[file.path] = known
                    } else if let data = try? Data(contentsOf: file), let parsed = parse(data) {
                        index.files[file.path] = .init(date: date, cliSessionID: parsed.cliSessionID, session: parsed.session)
                    }
                }
            }
        }
        return index
    }

    static func parse(_ data: Data) -> (cliSessionID: String?, session: ClaudeDesktopSession)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (object["cliSessionId"] as? String,
                ClaudeDesktopSession(title: title?.isEmpty == false ? title : nil, isArchived: object["isArchived"] as? Bool ?? false))
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
