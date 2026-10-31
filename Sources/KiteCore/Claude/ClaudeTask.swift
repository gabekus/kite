import Foundation

/// A goal the user handed to Kite's own Claude ("Claude Tasks"). Kite runs Claude Code
/// headless on the user's own Claude plan, wired only to Kite's tools, so a task keeps
/// working in background tabs while the user does something else.
///
/// What's kept is what the panel shows: the user's messages, Claude's replies, and one
/// short line per tool call. Page text and tool results never go in here.
public struct ClaudeTask: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, done, failed, stopped

        public var isFinished: Bool { self != .running }
    }

    public struct Entry: Hashable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// What the user asked.
            case user
            /// Claude's own words.
            case assistant
            /// One tool call, e.g. "read_page · tab 3F2A".
            case tool
            /// A tool call that came back as an error (a denied confirmation, say).
            case toolError
            /// Something about the run itself: couldn't start, Kite turned control on, stopped.
            case note
            case error
        }

        public var kind: Kind
        public var text: String
        public var date: Date
        /// True while Claude's reply is still streaming in. Not saved.
        public var isStreaming = false

        public init(_ kind: Kind, _ text: String, date: Date = Date(), isStreaming: Bool = false) {
            self.kind = kind
            self.text = text
            self.date = date
            self.isStreaming = isStreaming
        }

        private enum CodingKeys: String, CodingKey { case kind, text, date }
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: Status
    /// Claude Code's session, so a follow-up resumes the same conversation.
    public var sessionID: String?
    public var entries: [Entry]
    /// The folder in the Claude space that holds this task's tabs.
    public var folderID: UUID?
    /// Tabs this task opened.
    public var tabIDs: [UUID]
    public var costUSD: Double
    /// Finished since the user last looked at it.
    public var unread: Bool

    public static let maxEntries = 400
    public static let maxTitleLength = 60

    public init(id: UUID = UUID(), goal: String, now: Date = Date()) {
        self.id = id
        title = Self.title(for: goal)
        createdAt = now
        updatedAt = now
        status = .running
        sessionID = nil
        entries = [Entry(.user, goal, date: now)]
        folderID = nil
        tabIDs = []
        costUSD = 0
        unread = false
    }

    /// The goal's first line, cut to fit a sidebar folder and a list row.
    public static func title(for goal: String) -> String {
        let line = goal.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return "Task" }
        return line.count > maxTitleLength ? String(line.prefix(maxTitleLength - 1)) + "…" : line
    }

    /// Claude's last reply: what the notification and the list row show.
    public var lastReply: String? {
        entries.last { $0.kind == .assistant && !$0.text.isEmpty }?.text
    }

    /// Adds the user's follow-up and marks the task running again.
    public mutating func followUp(_ text: String, now: Date = Date()) {
        append(Entry(.user, text, date: now))
        status = .running
        unread = false
        updatedAt = now
    }

    public mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            // Keep the first goal so the task still says what it was for.
            entries.removeSubrange(1...(entries.count - Self.maxEntries))
        }
    }

    /// Applies one event from Claude Code's stream.
    public mutating func apply(_ event: ClaudeStreamEvent, now: Date = Date()) {
        updatedAt = now
        switch event {
        case .session(let id, _, _):
            sessionID = id
        case .textDelta(let text):
            if let last = entries.indices.last, entries[last].kind == .assistant, entries[last].isStreaming {
                entries[last].text += text
            } else {
                append(Entry(.assistant, text, date: now, isStreaming: true))
            }
        case .text(let text):
            if let last = entries.indices.last, entries[last].kind == .assistant, entries[last].isStreaming {
                entries[last].text = text
                entries[last].isStreaming = false
            } else {
                append(Entry(.assistant, text, date: now))
            }
        case let .toolUse(_, name, summary):
            append(Entry(.tool, summary.isEmpty ? name : "\(name) · \(summary)", date: now))
        case let .toolResult(_, isError, summary):
            if isError { append(Entry(.toolError, summary, date: now)) }
        case let .result(isError, text, cost, sessionID):
            costUSD += cost ?? 0
            if let sessionID { self.sessionID = sessionID }
            if isError {
                append(Entry(.error, text.isEmpty ? "Claude stopped with an error." : text, date: now))
                status = .failed
            } else {
                // The reply is already in the transcript as text; the result only repeats it.
                if lastReply == nil, !text.isEmpty { append(Entry(.assistant, text, date: now)) }
                status = .done
            }
            for i in entries.indices where entries[i].isStreaming { entries[i].isStreaming = false }
            unread = true
        }
    }

    /// The process ended. A run that never sent its result failed, unless the user stopped it.
    public mutating func processExited(status code: Int32, stderr: String, stopped: Bool, now: Date = Date()) {
        updatedAt = now
        for i in entries.indices where entries[i].isStreaming { entries[i].isStreaming = false }
        if stopped {
            status = .stopped
            append(Entry(.note, "Stopped.", date: now))
        } else if status == .running {
            status = .failed
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            append(Entry(.error, detail.isEmpty ? "Claude Code exited (status \(code)) without finishing." : String(detail.suffix(600)), date: now))
            unread = true
        }
    }
}

/// The saved list of tasks, newest first, in `<profile>/Claude/tasks.json`.
public struct ClaudeTaskList: Codable, Sendable {
    public var tasks: [ClaudeTask]

    public static let limit = 50

    public init(tasks: [ClaudeTask] = []) {
        self.tasks = tasks
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Claude", isDirectory: true).appendingPathComponent("tasks.json")
    }

    /// A list saved while a task ran comes back with that task stopped: its process is gone.
    public static func load(from url: URL) -> ClaudeTaskList {
        guard let data = try? Data(contentsOf: url) else { return ClaudeTaskList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var list = try? decoder.decode(ClaudeTaskList.self, from: data) else { return ClaudeTaskList() }
        for i in list.tasks.indices where list.tasks[i].status == .running {
            list.tasks[i].status = .stopped
            list.tasks[i].append(ClaudeTask.Entry(.note, "Stopped when Kite quit."))
        }
        return list
    }

    /// Only the user can read it: it holds what they asked Claude to do.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(ClaudeTaskList(tasks: Array(tasks.prefix(Self.limit)))).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
